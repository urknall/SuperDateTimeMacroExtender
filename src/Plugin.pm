package Plugins::SuperDateTimeMacroExtender::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use List::Util qw(first);
use POSIX qw(ceil floor);
use Scalar::Util qw(blessed);
use Digest::MD5 qw(md5_hex);

# Compatibility: POSIX::round is not available in all Perl versions (added in Perl 5.22)
# Try to import it, but provide a fallback if it's not available
my $has_posix_round;
BEGIN {
	$has_posix_round = eval {
		require POSIX;
		POSIX->import('round');
		1;
	};
}

# Fallback round implementation for older Perl versions
# Rounds to nearest integer, with ties rounding away from zero
sub _round_fallback {
	my ($x) = @_;
	return 0 unless defined $x;
	# Handle positive and negative numbers correctly
	# For positive: int($x + 0.5)
	# For negative: int($x - 0.5) to round away from zero
	return $x >= 0 ? int($x + 0.5) : int($x - 0.5);
}

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

# JSON support - VersionOneAndTwo provides backward compatibility with older LMS versions
# and provides decode_json/encode_json functions
use JSON::XS::VersionOneAndTwo;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.superdatetimemacroextender',
	defaultLevel => 'WARN',
	description  => 'SuperDateTime Macro Extender',
});

# Prefs namespace
my $prefs = preferences('plugin.superdatetimemacroextender');
# Defaults aligned with common LMS plugins (DomoticzControl uses 30s cache)
use constant CACHE_TTL_SECONDS  => 60;
use constant HTTP_TIMEOUT_SECS  => 10;
use constant MAX_QUEUE_SIZE     => 50;  # Prevent unbounded queue growth
use constant MAX_CACHE_CLIENTS  => 100; # Limit cache entries
use constant CACHE_PRUNE_PERCENT => 0.2; # Prune 20% of oldest entries when cache is full
use constant MAX_STALE_CACHE_AGE => 300; # Maximum age (5 min) for stale cache fallback

# Precompiled regex patterns for efficiency
my $INT_REGEX   = qr/^-?\d+$/;
# Enhanced NUM_REGEX: supports optional leading +/-, decimals, and scientific notation (e.g., 1e-3, 1.5E+10)
my $NUM_REGEX   = qr/^[+-]?(?:\d+\.?\d*|\d*\.?\d+)(?:[eE][+-]?\d+)?$/;

# Field name constants
use constant RESULT_KEY => 'result';
use constant RAW_KEY    => 'raw';

# Utility function for string trimming
sub _trim {
	my $s = shift;
	return $s unless defined $s;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

# Utility function to get field value with case variants (using List::Util::first)
sub _getFieldVariant {
	my ($item, @variants) = @_;
	my $found = first { defined $item->{$_} } @variants;
	return defined $found ? $item->{$found} : undef;
}

# Utility function to create a raw item from key-value pair
sub _makeRawItem {
	my ($k, $v) = @_;
	return {
		id    => $k,
		idx   => ($k =~ $INT_REGEX) ? int($k) : undef,
		Name  => "Key_$k",
		Value => $v,
		Data  => defined $v ? "$v" : '',
	};
}

# Utility function to check if aggregate has any data
sub _hasAggregateData {
	my ($agg) = @_;
	return 0 unless $agg && ref($agg) eq 'HASH';
	return (scalar(keys %{ $agg->{by_id} || {} }) || 
	        scalar(keys %{ $agg->{by_idx} || {} }) || 
	        scalar(keys %{ $agg->{by_name} || {} }));
}

# Handler chain pointer (previous sdtMacroString dispatch)
my $funcptr;

# Per-key queue and processing to avoid hammering endpoints during frequent clock refresh
# and prevent cross-client data contamination
# requestsQueue: { key => [@requests] }
# requestProcessing: { key => 0|1 }
my %requestsQueue;
my %requestProcessing;

# Cache: key structure depends on cache_mode preference
# - Server-wide mode (default): key = 'server:' + joined URLs
# - Per-client mode: key = client_id or 'server'
# cache: { key => [expires_epoch, normalized_records] }
my %cache;

sub initPlugin {
	my $class = shift;

	$prefs->init({
		# Multiple URLs stored as arrayref for cleaner internal handling
		api_urls => [],
		# Cache mode: 'server' (default, shared cache) or 'client' (per-client cache)
		cache_mode => 'server',
	});

	# Register settings page (adds "Settings" link in the plugin list)
	if (main::WEBUI) {
		require Plugins::SuperDateTimeMacroExtender::Settings;
		Plugins::SuperDateTimeMacroExtender::Settings->new();
	}

	# Register our macro handler and keep the previously registered handler
	$funcptr = Slim::Control::Request::addDispatch(['sdtMacroString'], [1, 1, 1, \&macroString]);

	$class->SUPER::initPlugin();
}

# === Public: sdtMacroString handler ===
sub macroString {
	my ($request) = @_;
	my $format = $request->getParam('format') // '';

	my $urls = _getUrls();
	# If not configured, just chain through.
	if (!@$urls) {
		_callNext($request, $format);
		return;
	}

	# Only do work if our macros are present.
	# Supported macros:
	#   ~e<id>~<field>~[func]~[arg]~     (lookup by result[].id)
	#   ~i<idx>~<field>~[func]~[arg]~    (lookup by result[].idx)
	#   ~n<name>~<field>~[func]~[arg]~   (lookup by result[].Name)
	# Use more specific pattern to avoid triggering on partial matches
	if ($format =~ m/~[ein][^~]+~[^~]+~/) {
		_manageMacroQueue($request, $urls);
	} else {
		_callNext($request, $format);
	}
}

sub _manageMacroQueue {
	my ($request, $urls) = @_;
	my $client = $request->client();
	
	# Determine cache key based on cache mode preference
	my $cache_mode = $prefs->get('cache_mode') // 'server';
	my $key;
	if ($cache_mode eq 'server') {
		# Server-wide cache mode (default): use a global key based on URLs
		# This allows multiple clients to share the same cached data
		# Use MD5 hash to avoid collisions when URLs contain special characters
		$key = 'server:' . md5_hex(join("\x00", @$urls));
	} else {
		# Per-client cache mode: use client ID
		$key = $client ? $client->id : 'server';
	}

	my $now = time;
	if (!$requestProcessing{$key}) {
		# Serve from cache if valid
		if (exists $cache{$key} && $cache{$key}[0] > $now) {
			_processOne($request, $cache{$key}[1]);
			return;
		}

		$requestProcessing{$key} = 1;
		$request->setStatusProcessing();

		# Start fetching from the first URL
		# Fetch and merge data from ALL configured URLs
		_startFetch($request, $key, $urls, 0, { by_id => {}, by_idx => {}, by_name => {} });
	} else {
		# Initialize queue for this key if needed
		$requestsQueue{$key} ||= [];
		
		# Prevent unbounded queue growth per key
		if (scalar(@{$requestsQueue{$key}}) >= MAX_QUEUE_SIZE) {
			$log->warn("Request queue full for key $key, dropping request");
			_callNext($request, $request->getParam('format') // '');
			return;
		}
		$request->setStatusProcessing();
		push @{$requestsQueue{$key}}, $request;
	}
}

sub _startFetch {
	my ($request, $key, $urls, $idx, $agg) = @_;

	$agg ||= { by_id => {}, by_idx => {}, by_name => {} };

	# Note: URLs are fetched sequentially, which adds latency when multiple endpoints are configured.
	# Parallel fetching would improve performance but requires significant refactoring with
	# concurrent HTTP requests and proper result merging. For typical use cases with 1-3 URLs
	# and caching enabled, the sequential approach is acceptable.
	
	# If we've processed all URLs, finalize.
	if (!$urls || ref($urls) ne 'ARRAY' || $idx > $#$urls) {
		my $has = _hasAggregateData($agg);
		my $use_data = $agg;
		
		if ($has) {
			# Prune cache if it exceeds max clients
			if (scalar(keys %cache) >= MAX_CACHE_CLIENTS) {
				_pruneCache();
			}
			$cache{$key} = [ time + CACHE_TTL_SECONDS, $agg ];
			$log->debug("Cached results for $key (cache size: " . scalar(keys %cache) . ")") if $log->is_debug;
		}
		elsif (exists $cache{$key}) {
			# No fresh data fetched - use stale cache as fallback (if not too old)
			my $age = time - ($cache{$key}[0] - CACHE_TTL_SECONDS);
			if ($age <= MAX_STALE_CACHE_AGE) {
				$log->warn("All fetches failed for key $key, using stale cache (age: ${age}s)");
				$use_data = $cache{$key}[1];
				$has = 1;  # Mark that we have data to use
			} else {
				$log->error("All fetches failed for key $key, stale cache too old (age: ${age}s > " . MAX_STALE_CACHE_AGE . "s), discarding");
				# Cache is too stale, discard it
				delete $cache{$key};
			}
		}
		
		_processOne($request, $has ? $use_data : undef);
		_requestDoneDrainQueue($key, $has ? $use_data : undef);
		return;
	}

	my $url = $urls->[$idx];
	if (!$url || $url eq '') {
		$log->debug("Skipping empty URL at index $idx") if $log->is_debug;
		_startFetch($request, $key, $urls, $idx + 1, $agg);
		return;
	}

	# Validate URL format
	if ($url !~ m{^https?://}i) {
		$log->warn("Invalid URL format (must start with http:// or https://): $url");
		_startFetch($request, $key, $urls, $idx + 1, $agg);
		return;
	}

	$log->debug("Fetching JSON from $url") if $log->is_debug;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&_fetchOk,
		\&_fetchErr,
		{
			request   => $request,
			key       => $key,
			urls      => $urls,
			url_index => $idx,
			agg       => $agg,
			cache     => 0,
			timeout   => HTTP_TIMEOUT_SECS,
		}
	);
	$http->get($url);
}

sub _fetchOk {
	my ($http) = @_;
	my $params  = $http->params() || {};
	my $request = $params->{request};
	my $key     = $params->{key} // 'server';
	my $urls    = $params->{urls};
	my $idx     = $params->{url_index} // 0;
	my $agg     = $params->{agg} || { by_id => {}, by_idx => {}, by_name => {} };

	my $content = $http->content();
	my $records;

	eval {
		my $data = decode_json($content);
		$records = _normalizeData($data);
		1;
	} or do {
		my $err = $@ || 'unknown JSON error';
		$log->warn("JSON decode failed: $err");
		$records = undef;
	};

	# Merge parsed records into the aggregate (do not stop at the first URL)
	if ($records) {
		_mergeRecords($agg, $records);
	}

	# Continue with next URL
	_startFetch($request, $key, $urls, $idx + 1, $agg);
}

sub _fetchErr {
	my ($http, $error) = @_;
	my $params  = $http->params() || {};
	my $request = $params->{request};
	my $key     = $params->{key} // 'server';
	my $urls    = $params->{urls};
	my $idx     = $params->{url_index} // 0;
	my $agg     = $params->{agg} || { by_id => {}, by_idx => {}, by_name => {} };

	my $url = $urls->[$idx] // 'unknown';
	$log->warn("JSON fetch failed for URL[$idx] ($url): $error");

	# Continue with next URL (keep anything already merged)
	_startFetch($request, $key, $urls, $idx + 1, $agg);
}

sub _requestDoneDrainQueue {
	my ($key, $records) = @_;

	# Initialize queue for this key if it doesn't exist
	$requestsQueue{$key} ||= [];

	# Drain queued requests for this specific key using the same records (or cache if available)
	while (my $r = shift @{$requestsQueue{$key}}) {
		my $use = $records;
		if (!$use && exists $cache{$key} && $cache{$key}[0] > time) {
			$use = $cache{$key}[1];
		}
		_processOne($r, $use);
	}

	$requestProcessing{$key} = 0;
}

# Prune cache entries when cache is full
# Strategy: First remove expired entries, then remove entries with oldest expiry time if more space needed
sub _pruneCache {
	my @keys = keys %cache;
	# Only prune when we've reached the limit (not before)
	# This is called when scalar(keys %cache) >= MAX_CACHE_CLIENTS at line 221
	return if scalar(@keys) < MAX_CACHE_CLIENTS;
	
	$log->debug("Pruning cache (current size: " . scalar(@keys) . ")") if $log->is_debug;
	
	my $now = time;
	my $initial_count = scalar(@keys);
	
	# Step 1: Remove expired entries first
	my @expired = grep { $cache{$_}[0] <= $now } @keys;
	for my $k (@expired) {
		delete $cache{$k};
	}
	
	my $removed = scalar(@expired);
	$log->debug("Removed $removed expired cache entries") if $removed > 0 && $log->is_debug;
	
	# Step 2: If still at limit, remove entries with oldest expiry time
	@keys = keys %cache;
	if (scalar(@keys) >= MAX_CACHE_CLIENTS) {
		my @sorted = sort { $cache{$a}[0] <=> $cache{$b}[0] } @keys;
		my $to_remove = int(scalar(@sorted) * CACHE_PRUNE_PERCENT);
		$to_remove = 1 if $to_remove < 1;
		
		for my $i (0 .. $to_remove - 1) {
			delete $cache{$sorted[$i]};
			$removed++;
		}
	}
	
	$log->debug("Pruned total of $removed cache entries (was: $initial_count, now: " . scalar(keys %cache) . ")") if $log->is_debug;
}

sub _processOne {
	my ($request, $records) = @_;
	my $format = $request->getParam('format') // '';

	# If we have no records, just chain through.
	if (!$records) {
		_callNext($request, $format);
		return;
	}

	my $out = _replaceMacros($format, $records);
	_callNext($request, $out);
}

sub _callNext {
	my ($request, $format) = @_;

	$request->addResult('macroString', $format);
	$request->addParam('format', $format);

	if (defined $funcptr && ref($funcptr) eq 'CODE') {
		eval { $funcptr->($request) };
		if ($@) {
			$log->error('Error while calling chained macro handler: ' . $@);
			$request->setStatusBadDispatch();
		}
	} else {
		$request->setStatusDone();
	}
}

sub _getUrls {
	my $raw = $prefs->get('api_urls');
	$raw //= [];

	# Support both arrayref (preferred) and string (legacy)
	my @urls;
	if (ref($raw) eq 'ARRAY') {
		@urls = @$raw;
	} else {
		@urls = split(/[\r\n]+/, $raw);
	}

	# trim + drop empties + validate
	my @out;
	for my $u (@urls) {
		next if !defined $u;
		$u = _trim($u);
		next if $u eq '';
		# Basic URL validation - must start with http:// or https://
		if ($u =~ m{^https?://}i) {
			push @out, $u;
		} else {
			$log->warn("Skipping invalid URL (missing http:// or https://): $u");
		}
	}
	return \@out;
}

# Utility function for numeric sorting of keys
# Sorts keys numerically if they match INT_REGEX, otherwise uses lexicographic sort
# Numeric keys sort before non-numeric keys
sub _sortKeysNumerically {
	my @keys = @_;
	return sort { 
		my $a_is_num = ($a =~ $INT_REGEX);
		my $b_is_num = ($b =~ $INT_REGEX);
		
		# Both numeric: numeric sort
		if ($a_is_num && $b_is_num) {
			return int($a) <=> int($b);
		}
		# One numeric, one not: numeric comes first
		elsif ($a_is_num) {
			return -1;
		}
		elsif ($b_is_num) {
			return 1;
		}
		# Both non-numeric: lexicographic sort
		else {
			return $a cmp $b;
		}
	} @keys;
}

# Normalize the payload into lookup maps.
# We accept either:
#   { result => [ {id, idx, Name/name, Value/value, Data/data, text, unit, ...}, ... ] }
# or:
#   { raw => { "1": 12.3, "2": "On", ... } }
# or:
#   { "1": 12.3, ... }  (raw root)
sub _normalizeData {
	my ($data) = @_;
	return undef if !$data || ref($data) ne 'HASH';

	my @items;

	if (ref($data->{+RESULT_KEY}) eq 'ARRAY') {
		@items = @{ $data->{+RESULT_KEY} };
	} elsif (ref($data->{+RAW_KEY}) eq 'HASH') {
		# Use numeric sort for raw keys to maintain proper order (1, 2, 10 instead of 1, 10, 2)
		for my $k (_sortKeysNumerically(keys %{ $data->{+RAW_KEY} })) {
			push @items, _makeRawItem($k, $data->{+RAW_KEY}{$k});
		}
	} elsif (!exists $data->{+RESULT_KEY} && !exists $data->{+RAW_KEY}) {
		# Fallback: treat top-level hash keys as raw data with numeric sort
		for my $k (_sortKeysNumerically(keys %$data)) {
			my $v = $data->{$k};
			# Skip complex refs (HASH/ARRAY), but allow scalar-like blessed objects (e.g., JSON booleans)
			if (ref($v)) {
				my $r = ref($v);
				# Skip HASH and ARRAY refs
				next if $r eq 'HASH' || $r eq 'ARRAY';
				# Skip other non-blessed refs (CODE, GLOB, etc.)
				next unless blessed($v);
				# Blessed objects (JSON::XS::Boolean, JSON::PP::Boolean, etc.) are allowed as they stringify properly
			}
			push @items, _makeRawItem($k, $v);
		}
	} else {
		return undef;
	}

	my (%by_id, %by_idx, %by_name);
	for my $it (@items) {
		next if ref($it) ne 'HASH';
		my $id = _getFieldVariant($it, 'id', 'Id');
		my $idx = _getFieldVariant($it, 'idx', 'Idx');
		my $name = _getFieldVariant($it, 'Name', 'name');

		$by_id{$id} = $it if defined $id;
		$by_idx{int($idx)} = $it if defined $idx && $idx =~ $INT_REGEX;
		$by_name{$name} = $it if defined $name;
	}

	return { by_id => \%by_id, by_idx => \%by_idx, by_name => \%by_name };
}

sub _mergeRecords {
	my ($agg, $records) = @_;
	return if !$agg || ref($agg) ne 'HASH';
	return if !$records || ref($records) ne 'HASH';

	# Merge all three map types
	for my $map_type (qw(by_id by_idx by_name)) {
		$agg->{$map_type} ||= {};
		if (ref($records->{$map_type}) eq 'HASH') {
			# Copy each key-value pair from records to agg
			for my $k (keys %{ $records->{$map_type} }) {
				$agg->{$map_type}{$k} = $records->{$map_type}{$k};
			}
		}
	}
}





# Replace our macros in a format string using lookup maps.
# Supported forms:
#   ~e<id>~<field>~[func]~[arg]~
#   ~i<idx>~<field>~[func]~[arg]~
#   ~n<name>~<field>~[func]~[arg]~
# Notes:
# - <field> is any key in the selected result item hash.
# - [func] and [arg] are optional. If present, [func] must be a known function (round, ceil, floor, truncate, shorten).
# - If text after a field is not a known function, the macro ends at the field and the text remains literal.
#   Example: "~eTempA~Value~text" becomes "23.5text" (macro replaced, "text" stays as literal)
sub _replaceMacros {
	my ($format, $records) = @_;
	return $format if !defined $format;
	return $format if !$records || ref($records) ne 'HASH';

	my %funcs = map { $_ => 1 } qw(round ceil floor truncate shorten);

	my $out = $format;
	my $pos = 0;
	my @replacements; # Track replacements for debug logging

	while (1) {
		my $start = index($out, '~', $pos);
		last if $start < 0;

		my $type = substr($out, $start + 1, 1);
		if ($type ne 'e' && $type ne 'i' && $type ne 'n') {
			$pos = $start + 1;
			next;
		}

		my $q1 = index($out, '~', $start + 2);
		if ($q1 < 0) {
			# Incomplete macro - skip and continue searching
			$pos = $start + 1;
			next;
		}
		my $key = substr($out, $start + 2, $q1 - ($start + 2));

		my $q2 = index($out, '~', $q1 + 1);
		if ($q2 < 0) {
			# Incomplete macro - skip and continue searching
			$pos = $q1 + 1;
			next;
		}
		my $field = substr($out, $q1 + 1, $q2 - ($q1 + 1));

		my $end = $q2;
		my ($func, $arg);

		my $q3 = index($out, '~', $q2 + 1);
		if ($q3 >= 0) {
			my $funcCand = substr($out, $q2 + 1, $q3 - ($q2 + 1));
			if ($funcCand ne '' && $funcs{$funcCand}) {
				# Known function found
				$func = $funcCand;
				$end = $q3;

				my $q4 = index($out, '~', $q3 + 1);
				if ($q4 >= 0) {
					$arg = substr($out, $q3 + 1, $q4 - ($q3 + 1));
					$end = $q4;
				}
			}
			# If funcCand is not a known function (or is empty), the macro ends at q2 (after the field).
			# Any text following is treated as literal, not part of the macro.
			# This allows: "~eTempA~Data~text..." → "23.5text..." (where "text..." remains literal)
		}

		my $whole = substr($out, $start, $end - $start + 1);

		my $item = _lookupItem($records, $type, $key);
		if (!$item || ref($item) ne 'HASH') {
			$pos = $end + 1;
			next;
		}

		my $val = _getFieldValue($item, $field);
		if (!defined $val) {
			$pos = $end + 1;
			next;
		}

		my $rep = _macroSubFunc($val, $func, $arg);

		# Track successful replacement for debug logging
		if ($log->is_debug) {
			push @replacements, "$whole -> $rep";
		}

		substr($out, $start, length($whole), $rep);
		$pos = $start + length($rep);
	}

	# Log all replacements made
	if ($log->is_debug && @replacements) {
		$log->debug("Macro replacements: " . join(', ', @replacements));
	}

	return $out;
}

sub _lookupItem {
	my ($records, $type, $key) = @_;
	return undef if !$records || ref($records) ne 'HASH';

	if ($type eq 'e') {
		return (ref($records->{by_id}) eq 'HASH') ? $records->{by_id}{$key} : undef;
	}
	elsif ($type eq 'i') {
		return undef if !defined $key || $key !~ $INT_REGEX;
		my $idx = int($key);
		return (ref($records->{by_idx}) eq 'HASH') ? $records->{by_idx}{$idx} : undef;
	}
	elsif ($type eq 'n') {
		return (ref($records->{by_name}) eq 'HASH') ? $records->{by_name}{$key} : undef;
	}

	return undef;
}

sub _getFieldValue {
	my ($item, $field) = @_;
	return undef if !$item || ref($item) ne 'HASH';
	return undef if !defined $field || $field eq '';

	return $item->{$field} if exists $item->{$field};

	# Case-insensitive fallback (common between different JSON styles)
	my $lf = lc($field);
	for my $k (keys %$item) {
		next if !defined $k;
		return $item->{$k} if lc($k) eq $lf;
	}

	return undef;
}

sub _macroSubFunc {
	my ($value, $func, $funcArg) = @_;

	my $replaceStr;
	if (ref($value)) {
		eval { $replaceStr = encode_json($value); };
		if ($@) {
			$log->warn("Failed to encode JSON value: $@");
			$replaceStr = "[complex value]";
		}
	}
	else {
		$replaceStr = defined $value ? "$value" : '';
	}

	return $replaceStr if !defined $func || $func eq '';

	my $result = eval {
		if ($func eq 'truncate') {
			my $dec = (defined $funcArg && $funcArg =~ $INT_REGEX) ? (0 + $funcArg) : 0;
			# Clamp decimal argument to prevent extreme values (e.g., 10**5000)
			# Range: -12 to 12 is sufficient for typical use cases
			$dec = -12 if $dec < -12;
			$dec = 12 if $dec > 12;
			# Return original string if not numeric (instead of 0)
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			# True truncation (not rounding) for decimal places
			# Supports negative decimal places like round (tens, hundreds, etc.)
			# For negative decimals, use integer divisor to avoid float artifacts
			if ($dec < 0) {
				my $divisor = 10 ** (-$dec);
				my $truncated = int($val / $divisor) * $divisor;
				return sprintf('%d', $truncated);
			}
			elsif ($dec > 0) {
				my $factor = 10 ** $dec;
				# Truncate by using int() on the scaled value
				my $truncated = int($val * $factor) / $factor;
				return sprintf('%.' . $dec . 'f', $truncated);
			} else {
				return sprintf('%d', int($val));
			}
		}
		elsif ($func eq 'ceil') {
			# Return original string if not numeric (instead of 0)
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			return sprintf('%d', ceil($val));
		}
		elsif ($func eq 'floor') {
			# Return original string if not numeric (instead of 0)
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			return sprintf('%d', floor($val));
		}
		elsif ($func eq 'round') {
			my $dec = (defined $funcArg && $funcArg =~ $INT_REGEX) ? (0 + $funcArg) : 0;
			# Clamp decimal argument to prevent extreme values (e.g., 10**5000)
			# Range: -12 to 12 is sufficient for typical use cases
			$dec = -12 if $dec < -12;
			$dec = 12 if $dec > 12;
			# Return original string if not numeric (instead of 0)
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			# Use POSIX::round() if available, otherwise use fallback implementation
			# Works correctly for positive (0.01) and negative (100) decimal factors
			# Negative $dec rounds to tens (-1), hundreds (-2), thousands (-3), etc.
			# For negative decimals, use integer divisor to avoid float artifacts
			if ($dec < 0) {
				my $divisor = 10 ** (-$dec);
				my $rounded = $has_posix_round ? round($val / $divisor) : _round_fallback($val / $divisor);
				return sprintf('%d', $rounded * $divisor);
			}
			else {
				my $factor = 10 ** $dec;
				my $rounded = $has_posix_round ? round($val * $factor) / $factor : _round_fallback($val * $factor) / $factor;
				# Format output based on decimal places (only positive values make sense for sprintf)
				if ($dec > 0) {
					return sprintf('%.' . $dec . 'f', $rounded);
				}
				else {
					# For $dec = 0, return as integer
					return sprintf('%d', $rounded);
				}
			}
		}
		elsif ($func eq 'shorten') {
			my $n = (defined $funcArg && $funcArg =~ $INT_REGEX) ? (0 + $funcArg) : 0;
			# Return original string if length is negative or zero (no shortening)
			return $replaceStr if $n <= 0;
			return substr($replaceStr, 0, $n);
		}
		else {
			return $replaceStr;
		}
	};

	if ($@) {
		$log->error('Error while trying to eval macro function: [' . $@ . ']');
		return $replaceStr;
	}

	return $result;
}

1;

