package Plugins::SuperDateTimeMacroExtender::Plugin;

# ============================================================================
# SuperDateTime Macro Extender Plugin for Logitech Media Server
# ============================================================================
# This plugin extends SuperDateTime/Custom Clock functionality by fetching
# data from JSON endpoints and making it available via custom macros.
#
# Key Features:
# - Fetch data from multiple JSON endpoints
# - Cache results to reduce API load
# - Provide macro-based access to fetched data
# - Chain with SuperDateTime for combined functionality
# - Support server-wide or per-client caching strategies
#
# Macro Syntax:
# - ~e<id>~<field>~[func]~[arg]~    (lookup by id)
# - ~i<idx>~<field>~[func]~[arg]~   (lookup by numeric index)
# - ~n<name>~<field>~[func]~[arg]~  (lookup by name)
#
# Functions: round, ceil, floor, truncate, shorten
# ============================================================================

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use List::Util qw(first);
use POSIX qw(ceil floor);
use Scalar::Util qw(blessed);
use Digest::MD5 qw(md5_hex);

# ============================================================================
# POSIX::round Compatibility Layer
# ============================================================================
# POSIX::round() was added in Perl 5.22 (2015) and is not available in older
# versions. This compatibility check attempts to import it and sets a flag
# indicating its availability. If unavailable, we use a fallback implementation.
# ============================================================================
my $has_posix_round;
BEGIN {
	$has_posix_round = eval {
		require POSIX;
		POSIX->import('round');
		1;
	};
}

# ============================================================================
# Fallback round() Implementation
# ============================================================================
# Provides rounding functionality for Perl versions that don't have POSIX::round.
# This implementation follows standard mathematical rounding: rounds to the nearest
# integer with ties rounding away from zero (half-up for positive, half-down for negative).
#
# Examples:
#   2.5  →  3   (rounds up, away from zero)
#   2.4  →  2   (rounds down to nearest)
#   -2.5 → -3   (rounds down, away from zero)
#   -2.4 → -2   (rounds up to nearest)
#
# Parameters:
#   $x - Numeric value to round
# Returns:
#   Rounded integer value, or 0 if input is undefined
# ============================================================================
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

# ============================================================================
# JSON Support
# ============================================================================
# JSON::XS::VersionOneAndTwo provides backward compatibility with older LMS
# versions by offering both old (1.x) and new (2.x) JSON::XS API styles.
# This module provides decode_json() and encode_json() functions.
# ============================================================================
use JSON::XS::VersionOneAndTwo;

# ============================================================================
# Logging Configuration
# ============================================================================
# Creates a dedicated log category for this plugin with default WARN level.
# Users can adjust log level in LMS settings for debugging (DEBUG level shows
# cache operations, macro replacements, and HTTP fetch details).
# ============================================================================
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.superdatetimemacroextender',
	defaultLevel => 'WARN',
	description  => 'SuperDateTime Macro Extender',
});

# ============================================================================
# Preferences and Constants
# ============================================================================
# Prefs namespace for storing plugin configuration
my $prefs = preferences('plugin.superdatetimemacroextender');

# Cache and HTTP timeout constants
# These values are tuned for typical use cases and align with similar LMS plugins
use constant CACHE_TTL_SECONDS  => 60;   # How long to cache API responses (seconds)
use constant HTTP_TIMEOUT_SECS  => 10;   # Maximum time to wait for HTTP response
use constant MAX_QUEUE_SIZE     => 50;   # Maximum pending requests per cache key
use constant MAX_CACHE_CLIENTS  => 100;  # Maximum number of cache entries before pruning
use constant CACHE_PRUNE_PERCENT => 0.2; # Fraction of cache to remove when full (20%)
use constant MAX_STALE_CACHE_AGE => 300; # Maximum age (seconds) for stale cache fallback (5 minutes)

# ============================================================================
# Regular Expression Patterns (Precompiled for Performance)
# ============================================================================
# These patterns are compiled once at load time for efficient reuse throughout
# the plugin's lifetime. Precompiling regex patterns with qr// provides better
# performance when used repeatedly.
# ============================================================================

# Matches integers (with optional leading minus sign): -123, 0, 456
my $INT_REGEX   = qr/^-?\d+$/;

# Matches numeric values including decimals and scientific notation
# Examples: 123, -45.67, 1.5E+10, 1e-3, +0.5, .5, 5.
# This supports: optional +/- sign, decimals, and scientific notation (e/E with +/- exponent)
my $NUM_REGEX   = qr/^[+-]?(?:\d+\.?\d*|\d*\.?\d+)(?:[eE][+-]?\d+)?$/;

# ============================================================================
# Field Name Constants
# ============================================================================
# Keys used to identify result structures in JSON responses
# RESULT_KEY: Standard key for array of result objects
# RAW_KEY: Alternative key for simple key-value mappings
# ============================================================================
use constant RESULT_KEY => 'result';
use constant RAW_KEY    => 'raw';

# ============================================================================
# Utility Functions
# ============================================================================

# ----------------------------------------------------------------------------
# _trim() - Remove leading and trailing whitespace
# ----------------------------------------------------------------------------
# Parameters:
#   $s - String to trim
# Returns:
#   Trimmed string, or original if undefined
# ----------------------------------------------------------------------------
sub _trim {
	my $s = shift;
	return $s unless defined $s;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

# ----------------------------------------------------------------------------
# _getFieldVariant() - Get field value trying multiple key variations
# ----------------------------------------------------------------------------
# Searches for a field in a hash by trying multiple key variants (e.g., 'id' and 'Id').
# Returns the value of the first variant that exists in the hash.
#
# Parameters:
#   $item     - Hash reference to search in
#   @variants - List of key names to try in order
# Returns:
#   Field value if any variant exists, undef otherwise
#
# Example:
#   _getFieldVariant($item, 'id', 'Id') → tries 'id' first, then 'Id'
# ----------------------------------------------------------------------------
sub _getFieldVariant {
	my ($item, @variants) = @_;
	my $found = first { defined $item->{$_} } @variants;
	return defined $found ? $item->{$found} : undef;
}

# ----------------------------------------------------------------------------
# _makeRawItem() - Convert key-value pair to standardized item structure
# ----------------------------------------------------------------------------
# Creates a normalized item record from a raw key-value pair. This is used when
# the JSON endpoint provides simple key-value data instead of structured records.
#
# Parameters:
#   $k - Key (used for id, idx if numeric, and to generate Name)
#   $v - Value (stored as Value and Data fields)
# Returns:
#   Hash reference with standardized structure:
#     - id:    The key itself
#     - idx:   Integer version of key (only if key is numeric)
#     - Name:  Generated name "Key_<k>"
#     - Value: The value
#     - Data:  String representation of value
#
# Example:
#   _makeRawItem("1", 23.5) → { id=>"1", idx=>1, Name=>"Key_1", Value=>23.5, Data=>"23.5" }
# ----------------------------------------------------------------------------
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

# ----------------------------------------------------------------------------
# _hasAggregateData() - Check if aggregate contains any data
# ----------------------------------------------------------------------------
# Verifies whether an aggregate structure (with by_id, by_idx, by_name maps)
# contains any actual records.
#
# Parameters:
#   $agg - Aggregate hash reference with by_id, by_idx, by_name keys
# Returns:
#   True if any of the lookup maps contain data, false otherwise
# ----------------------------------------------------------------------------
sub _hasAggregateData {
	my ($agg) = @_;
	return 0 unless $agg && ref($agg) eq 'HASH';
	return (scalar(keys %{ $agg->{by_id} || {} }) || 
	        scalar(keys %{ $agg->{by_idx} || {} }) || 
	        scalar(keys %{ $agg->{by_name} || {} }));
}

# ============================================================================
# Global State Variables
# ============================================================================

# Handler chain pointer - stores reference to the previous sdtMacroString handler
# This allows us to chain our processing with SuperDateTime's macro handling
my $funcptr;

# ============================================================================
# Request Queue Management
# ============================================================================
# These data structures implement request queuing to prevent hammering external
# endpoints during frequent clock refreshes (which can occur every second).
# Each cache key maintains its own queue and processing state.
#
# requestsQueue: { cache_key => [ request1, request2, ... ] }
#   Holds pending requests waiting for data fetch to complete
#
# requestProcessing: { cache_key => 0|1 }
#   Tracks whether a fetch is currently in progress for this key
# ============================================================================
my %requestsQueue;
my %requestProcessing;

# ============================================================================
# Data Cache
# ============================================================================
# Cache structure depends on the cache_mode preference:
#
# Server-wide mode (default):
#   cache_key = 'server:' + MD5(joined_urls)
#   All clients share the same cached data for identical URL sets
#
# Per-client mode:
#   cache_key = client_id (or 'server' if no client)
#   Each client maintains its own independent cache
#
# Cache entry format: { key => [expiry_epoch, normalized_records] }
#   expiry_epoch: Unix timestamp when this cache entry expires
#   normalized_records: Hash with by_id, by_idx, by_name lookup maps
# ============================================================================
my %cache;

# ============================================================================
# Plugin Initialization
# ============================================================================
# Called by LMS when the plugin is loaded. Sets up preferences, registers
# settings page (if web UI is available), and installs the macro handler.
#
# Parameters:
#   $class - Class name (Plugins::SuperDateTimeMacroExtender::Plugin)
# ============================================================================
sub initPlugin {
	my $class = shift;

	# Initialize preferences with default values
	$prefs->init({
		# Multiple URLs stored as arrayref for cleaner internal handling
		api_urls => [],
		# Cache mode: 'server' (default, shared cache) or 'client' (per-client cache)
		cache_mode => 'server',
	});

	# Register settings page (adds "Settings" link in the plugin list)
	# Only available when web UI is enabled in LMS
	if (main::WEBUI) {
		require Plugins::SuperDateTimeMacroExtender::Settings;
		Plugins::SuperDateTimeMacroExtender::Settings->new();
	}

	# Register our macro handler and preserve the previously registered handler
	# This enables handler chaining: our plugin → SuperDateTime → next handler
	# The [1, 1, 1, ...] parameters specify the handler accepts requests from
	# any source (network, CLI, or internal)
	$funcptr = Slim::Control::Request::addDispatch(['sdtMacroString'], [1, 1, 1, \&macroString]);

	$class->SUPER::initPlugin();
}

# ============================================================================
# Macro String Handler (Public API)
# ============================================================================
# Main entry point for sdtMacroString requests. This method is called by LMS
# when it needs to process macro strings (typically for SuperDateTime/Custom Clock).
#
# Processing flow:
# 1. Check if any API URLs are configured - if not, chain to next handler
# 2. Check if format string contains our macros (~e, ~i, ~n patterns)
# 3. If our macros are present, fetch data and process them
# 4. Always chain to the next handler (SuperDateTime) to process remaining macros
#
# Parameters:
#   $request - LMS request object containing 'format' parameter with macro string
# ============================================================================
sub macroString {
	my ($request) = @_;
	my $format = $request->getParam('format') // '';

	# Get configured API URLs
	my $urls = _getUrls();
	
	# If not configured, just chain through to next handler
	if (!@$urls) {
		_callNext($request, $format);
		return;
	}

	# Only do work if our macros are present in the format string
	# Supported macro patterns:
	#   ~e<id>~<field>~[func]~[arg]~    (lookup by result[].id)
	#   ~i<idx>~<field>~[func]~[arg]~   (lookup by result[].idx - numeric)
	#   ~n<name>~<field>~[func]~[arg]~  (lookup by result[].Name)
	# The regex pattern ~[ein][^~]+~[^~]+~ matches these structures:
	#   ~[ein]  = macro type indicator
	#   [^~]+   = key (id/idx/name value)
	#   ~       = separator
	#   [^~]+   = field name
	#   ~       = separator (function/arg follow optionally)
	if ($format =~ m/~[ein][^~]+~[^~]+~/) {
		_manageMacroQueue($request, $urls);
	} else {
		_callNext($request, $format);
	}
}

# ============================================================================
# Request Queue Management
# ============================================================================

# ----------------------------------------------------------------------------
# _manageMacroQueue() - Manage request queuing and cache lookup
# ----------------------------------------------------------------------------
# Implements the core caching and queuing logic to prevent excessive API calls.
# When multiple requests arrive for the same data, only one HTTP fetch occurs.
#
# Logic flow:
# 1. Determine cache key based on cache_mode setting (server-wide or per-client)
# 2. If not currently fetching AND cache is valid: serve from cache immediately
# 3. If not currently fetching AND cache is expired: start new fetch
# 4. If currently fetching: add request to queue for later processing
#
# Parameters:
#   $request - LMS request object
#   $urls    - Array reference of API URLs to fetch
# ----------------------------------------------------------------------------
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
	
	# Check if we're already processing a request for this cache key
	if (!$requestProcessing{$key}) {
		# Not currently processing - check cache validity
		if (exists $cache{$key} && $cache{$key}[0] > $now) {
			# Cache hit - serve immediately from cache
			_processOne($request, $cache{$key}[1]);
			return;
		}

		# Cache miss or expired - start fetching fresh data
		$requestProcessing{$key} = 1;
		$request->setStatusProcessing();

		# Start fetching from the first URL
		# Fetch and merge data from ALL configured URLs sequentially
		_startFetch($request, $key, $urls, 0, { by_id => {}, by_idx => {}, by_name => {} });
	} else {
		# Already processing - add request to queue
		# Initialize queue for this key if needed
		$requestsQueue{$key} ||= [];
		
		# Prevent unbounded queue growth per key
		# If queue is full, serve the request immediately without our macros
		if (scalar(@{$requestsQueue{$key}}) >= MAX_QUEUE_SIZE) {
			$log->warn("Request queue full for key $key, dropping request");
			_callNext($request, $request->getParam('format') // '');
			return;
		}
		$request->setStatusProcessing();
		push @{$requestsQueue{$key}}, $request;
	}
}

# ----------------------------------------------------------------------------
# _startFetch() - Initiate or continue sequential URL fetching
# ----------------------------------------------------------------------------
# Recursively fetches JSON data from URLs, merging results as it goes.
# This function is called recursively for each URL in the list.
#
# Processing flow:
# 1. If all URLs processed: finalize (cache results, drain queue)
# 2. Skip empty or invalid URLs
# 3. Initiate async HTTP GET for current URL
# 4. On success/failure: callback continues with next URL
#
# Parameters:
#   $request - LMS request object (for the initiating request)
#   $key     - Cache key for this request set
#   $urls    - Array reference of all URLs to fetch
#   $idx     - Current index in URLs array (0-based)
#   $agg     - Aggregate structure accumulating merged data from all URLs
#
# Note: URLs are fetched sequentially (not in parallel) to simplify the code.
# For typical use cases with 1-3 URLs and caching enabled, this is acceptable.
# Parallel fetching would require managing multiple concurrent HTTP requests
# and more complex result merging logic.
# ----------------------------------------------------------------------------
sub _startFetch {
	my ($request, $key, $urls, $idx, $agg) = @_;

	# Ensure aggregate structure exists
	$agg ||= { by_id => {}, by_idx => {}, by_name => {} };
	
	# ========================================================================
	# Check if we've processed all URLs - if so, finalize
	# ========================================================================
	if (!$urls || ref($urls) ne 'ARRAY' || $idx > $#$urls) {
		my $has = _hasAggregateData($agg);
		my $use_data = $agg;
		
		if ($has) {
			# Successfully fetched data - cache it
			# Prune cache first if it's at capacity
			if (scalar(keys %cache) >= MAX_CACHE_CLIENTS) {
				_pruneCache();
			}
			$cache{$key} = [ time + CACHE_TTL_SECONDS, $agg ];
			$log->debug("Cached results for $key (cache size: " . scalar(keys %cache) . ")") if $log->is_debug;
		}
		elsif (exists $cache{$key}) {
			# No fresh data fetched - attempt stale cache fallback
			# Calculate how old the stale cache is
			my $age = time - ($cache{$key}[0] - CACHE_TTL_SECONDS);
			if ($age <= MAX_STALE_CACHE_AGE) {
				# Stale cache is recent enough - use it as fallback
				$log->warn("All fetches failed for key $key, using stale cache (age: ${age}s)");
				$use_data = $cache{$key}[1];
				$has = 1;  # Mark that we have data to use
			} else {
				# Stale cache is too old - discard it
				$log->error("All fetches failed for key $key, stale cache too old (age: ${age}s > " . MAX_STALE_CACHE_AGE . "s), discarding");
				delete $cache{$key};
			}
		}
		
		# Process the initiating request and drain queued requests
		_processOne($request, $has ? $use_data : undef);
		_requestDoneDrainQueue($key, $has ? $use_data : undef);
		return;
	}

	# ========================================================================
	# Process current URL
	# ========================================================================
	my $url = $urls->[$idx];
	
	# Skip empty URLs
	if (!$url || $url eq '') {
		$log->debug("Skipping empty URL at index $idx") if $log->is_debug;
		_startFetch($request, $key, $urls, $idx + 1, $agg);
		return;
	}

	# Validate URL format (must be HTTP or HTTPS)
	if ($url !~ m{^https?://}i) {
		$log->warn("Invalid URL format (must start with http:// or https://): $url");
		_startFetch($request, $key, $urls, $idx + 1, $agg);
		return;
	}

	$log->debug("Fetching JSON from $url") if $log->is_debug;

	# Initiate async HTTP GET request
	# Callbacks: _fetchOk on success, _fetchErr on failure
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

# ----------------------------------------------------------------------------
# _fetchOk() - HTTP success callback
# ----------------------------------------------------------------------------
# Called when HTTP GET request completes successfully. Parses the JSON response,
# normalizes it to our internal format, merges it into the aggregate, and
# continues fetching the next URL.
#
# Parameters:
#   $http - Slim::Networking::SimpleAsyncHTTP object with response data
#
# HTTP params (passed through $http->params()):
#   request   - LMS request object
#   key       - Cache key
#   urls      - Array of all URLs to fetch
#   url_index - Index of current URL
#   agg       - Aggregate data structure
# ----------------------------------------------------------------------------
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

	# Attempt to parse JSON response
	eval {
		my $data = decode_json($content);
		$records = _normalizeData($data);
		1;
	} or do {
		my $err = $@ || 'unknown JSON error';
		$log->warn("JSON decode failed: $err");
		$records = undef;
	};

	# Merge successfully parsed records into the aggregate
	# Even if this URL failed to parse, we continue with remaining URLs
	if ($records) {
		_mergeRecords($agg, $records);
	}

	# Continue with next URL (recursive call)
	_startFetch($request, $key, $urls, $idx + 1, $agg);
}

# ----------------------------------------------------------------------------
# _fetchErr() - HTTP error callback
# ----------------------------------------------------------------------------
# Called when HTTP GET request fails (network error, timeout, etc.).
# Logs the error and continues fetching the next URL. This ensures that
# a failure on one endpoint doesn't prevent fetching from other endpoints.
#
# Parameters:
#   $http  - Slim::Networking::SimpleAsyncHTTP object
#   $error - Error message string
#
# HTTP params (passed through $http->params()):
#   request   - LMS request object
#   key       - Cache key
#   urls      - Array of all URLs to fetch
#   url_index - Index of current URL that failed
#   agg       - Aggregate data structure (unchanged)
# ----------------------------------------------------------------------------
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
	# This resilient approach means one endpoint failure doesn't break the entire fetch
	_startFetch($request, $key, $urls, $idx + 1, $agg);
}

# ----------------------------------------------------------------------------
# _requestDoneDrainQueue() - Process queued requests after fetch completes
# ----------------------------------------------------------------------------
# Called when all URL fetching is complete. Processes the original request and
# then drains all queued requests, serving them with the same data (or cache).
# This prevents duplicate fetches when multiple requests arrive simultaneously.
#
# Parameters:
#   $key     - Cache key identifying this fetch operation
#   $records - Normalized records from fetch (or undef if all fetches failed)
#
# Behavior:
# - Processes all queued requests with the provided data
# - Falls back to cache if data is unavailable but cache is valid
# - Resets processing flag to allow new fetches
# ----------------------------------------------------------------------------
sub _requestDoneDrainQueue {
	my ($key, $records) = @_;

	# Initialize queue for this key if it doesn't exist
	$requestsQueue{$key} ||= [];

	# Drain queued requests for this specific key
	# All queued requests get the same data (or cache fallback)
	while (my $r = shift @{$requestsQueue{$key}}) {
		my $use = $records;
		# Fallback to cache if no fresh data available and cache is still valid
		if (!$use && exists $cache{$key} && $cache{$key}[0] > time) {
			$use = $cache{$key}[1];
		}
		_processOne($r, $use);
	}

	# Clear processing flag to allow new fetches for this key
	$requestProcessing{$key} = 0;
}

# ----------------------------------------------------------------------------
# _pruneCache() - Remove old cache entries when cache is full
# ----------------------------------------------------------------------------
# Called when the cache reaches MAX_CACHE_CLIENTS capacity. Implements a
# two-stage pruning strategy to keep the cache size manageable:
#
# 1. Remove expired entries first (already past their TTL)
# 2. If still at capacity, remove oldest entries (by expiry time)
#    Amount removed: CACHE_PRUNE_PERCENT of cache size (default 20%)
#
# This prevents unbounded cache growth while keeping frequently-used data.
# The minimum removal is 1 entry to ensure progress even with small caches.
# ----------------------------------------------------------------------------
sub _pruneCache {
	my @keys = keys %cache;
	
	# Safety check - only prune when we've reached the limit
	# This function is called when scalar(keys %cache) >= MAX_CACHE_CLIENTS
	return if scalar(@keys) < MAX_CACHE_CLIENTS;
	
	$log->debug("Pruning cache (current size: " . scalar(@keys) . ")") if $log->is_debug;
	
	my $now = time;
	my $initial_count = scalar(@keys);
	
	# ========================================================================
	# Step 1: Remove expired entries first (low-hanging fruit)
	# ========================================================================
	my @expired = grep { $cache{$_}[0] <= $now } @keys;
	for my $k (@expired) {
		delete $cache{$k};
	}
	
	my $removed = scalar(@expired);
	$log->debug("Removed $removed expired cache entries") if $removed > 0 && $log->is_debug;
	
	# ========================================================================
	# Step 2: If still at limit, remove oldest entries by expiry time
	# ========================================================================
	@keys = keys %cache;
	if (scalar(@keys) >= MAX_CACHE_CLIENTS) {
		# Sort by expiry time (oldest first)
		my @sorted = sort { $cache{$a}[0] <=> $cache{$b}[0] } @keys;
		
		# Calculate how many to remove (minimum 1)
		my $to_remove = int(scalar(@sorted) * CACHE_PRUNE_PERCENT);
		$to_remove = 1 if $to_remove < 1;
		
		# Remove the oldest entries
		for my $i (0 .. $to_remove - 1) {
			delete $cache{$sorted[$i]};
			$removed++;
		}
	}
	
	$log->debug("Pruned total of $removed cache entries (was: $initial_count, now: " . scalar(keys %cache) . ")") if $log->is_debug;
}

# ----------------------------------------------------------------------------
# _processOne() - Process a single request with fetched data
# ----------------------------------------------------------------------------
# Replaces macros in the request's format string with data from fetched records,
# then chains to the next handler (typically SuperDateTime).
#
# Parameters:
#   $request - LMS request object
#   $records - Normalized records structure (or undef if no data available)
#
# Behavior:
# - If no data available: pass format string unchanged to next handler
# - If data available: replace macros, then pass to next handler
# ----------------------------------------------------------------------------
sub _processOne {
	my ($request, $records) = @_;
	my $format = $request->getParam('format') // '';

	# If we have no records, just chain through without macro replacement
	if (!$records) {
		_callNext($request, $format);
		return;
	}

	# Replace our macros with data values
	my $out = _replaceMacros($format, $records);
	_callNext($request, $out);
}

# ----------------------------------------------------------------------------
# _callNext() - Chain to next macro handler (typically SuperDateTime)
# ----------------------------------------------------------------------------
# Passes the processed format string to the next handler in the chain.
# This enables our plugin to work alongside SuperDateTime: we process our
# macros first, then SuperDateTime processes its own macros.
#
# Parameters:
#   $request - LMS request object
#   $format  - Format string (with our macros already replaced)
#
# Behavior:
# - Sets result and param on request object
# - Calls next handler if one exists
# - Marks request as done if no next handler
# - Handles errors from next handler gracefully
# ----------------------------------------------------------------------------
sub _callNext {
	my ($request, $format) = @_;

	# Update request with processed format string
	$request->addResult('macroString', $format);
	$request->addParam('format', $format);

	# Call next handler in chain (typically SuperDateTime)
	if (defined $funcptr && ref($funcptr) eq 'CODE') {
		eval { $funcptr->($request) };
		if ($@) {
			$log->error('Error while calling chained macro handler: ' . $@);
			$request->setStatusBadDispatch();
		}
	} else {
		# No next handler - mark request as complete
		$request->setStatusDone();
	}
}

# ----------------------------------------------------------------------------
# _getUrls() - Get and validate configured API URLs
# ----------------------------------------------------------------------------
# Retrieves API URLs from preferences, validates them, and returns clean list.
# Supports both modern arrayref format and legacy newline-separated string.
#
# Returns:
#   Array reference of validated URLs (empty array if none configured)
#
# Validation:
# - Trims whitespace from each URL
# - Removes empty entries
# - Verifies URLs start with http:// or https://
# - Logs warnings for invalid URLs
# ----------------------------------------------------------------------------
sub _getUrls {
	my $raw = $prefs->get('api_urls');
	$raw //= [];

	# Support both arrayref (preferred, modern) and string (legacy, newline-separated)
	my @urls;
	if (ref($raw) eq 'ARRAY') {
		@urls = @$raw;
	} else {
		# Legacy format: URLs separated by newlines
		@urls = split(/[\r\n]+/, $raw);
	}

	# Clean and validate URLs
	my @out;
	for my $u (@urls) {
		next if !defined $u;
		$u = _trim($u);
		next if $u eq '';
		
		# Validate URL format - must start with http:// or https://
		if ($u =~ m{^https?://}i) {
			push @out, $u;
		} else {
			$log->warn("Skipping invalid URL (missing http:// or https://): $u");
		}
	}
	return \@out;
}

# ============================================================================
# Data Normalization Functions
# ============================================================================

# ----------------------------------------------------------------------------
# _sortKeysNumerically() - Sort keys with numeric-aware ordering
# ----------------------------------------------------------------------------
# Provides intelligent sorting that treats numeric strings as numbers.
# This ensures proper ordering like: 1, 2, 10 (not 1, 10, 2).
#
# Sorting rules:
# 1. Both keys numeric: sort numerically (1 < 2 < 10)
# 2. One numeric, one not: numeric comes first
# 3. Both non-numeric: sort lexicographically (alphabetically)
#
# Parameters:
#   @keys - List of keys to sort
# Returns:
#   Sorted list of keys
#
# Examples:
#   ("10", "2", "1") → ("1", "2", "10")
#   ("b", "1", "a", "10") → ("1", "10", "a", "b")
# ----------------------------------------------------------------------------
sub _sortKeysNumerically {
	my @keys = @_;
	return sort { 
		my $a_is_num = ($a =~ $INT_REGEX);
		my $b_is_num = ($b =~ $INT_REGEX);
		
		# Both numeric: use numeric comparison
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
		# Both non-numeric: lexicographic (alphabetic) comparison
		else {
			return $a cmp $b;
		}
	} @keys;
}

# ----------------------------------------------------------------------------
# _normalizeData() - Convert JSON response to standardized lookup structure
# ----------------------------------------------------------------------------
# Accepts multiple JSON formats and converts them to a unified internal format
# with three lookup maps: by_id, by_idx, and by_name.
#
# Supported input formats:
# 1. Standard format with result array:
#    { "result": [ {id, idx, Name, Value, Data, ...}, ... ] }
#
# 2. Raw format with key-value object:
#    { "raw": { "1": 12.3, "2": "On", ... } }
#    (Each key-value pair becomes a record)
#
# 3. Top-level key-value format:
#    { "1": 12.3, "2": "On", ... }
#    (Fallback when neither "result" nor "raw" keys exist)
#
# Parameters:
#   $data - Decoded JSON hash reference
#
# Returns:
#   Hash reference with three lookup maps:
#     by_id:   { id_value => record, ... }
#     by_idx:  { numeric_idx => record, ... }
#     by_name: { name_value => record, ... }
#   Returns undef if data is invalid or empty
#
# Record fields (standard format):
#   - id, idx, Name: Used for lookups
#   - Value, Data, Unit, etc.: Available for macro field access
# ----------------------------------------------------------------------------
sub _normalizeData {
	my ($data) = @_;
	return undef if !$data || ref($data) ne 'HASH';

	my @items;

	# ========================================================================
	# Step 1: Extract items from JSON based on format
	# ========================================================================
	
	if (ref($data->{+RESULT_KEY}) eq 'ARRAY') {
		# Format 1: Standard result array
		# { "result": [ {id, Name, Value, ...}, ... ] }
		@items = @{ $data->{+RESULT_KEY} };
		
	} elsif (ref($data->{+RAW_KEY}) eq 'HASH') {
		# Format 2: Raw key-value object
		# { "raw": { "1": 12.3, "2": "On", ... } }
		# Convert each key-value pair to a standardized item
		# Use numeric sort to maintain proper order (1, 2, 10 instead of 1, 10, 2)
		for my $k (_sortKeysNumerically(keys %{ $data->{+RAW_KEY} })) {
			push @items, _makeRawItem($k, $data->{+RAW_KEY}{$k});
		}
		
	} elsif (!exists $data->{+RESULT_KEY} && !exists $data->{+RAW_KEY}) {
		# Format 3: Top-level key-value pairs (fallback)
		# { "1": 12.3, "2": "On", ... }
		# Treat top-level hash as raw data
		for my $k (_sortKeysNumerically(keys %$data)) {
			my $v = $data->{$k};
			
			# Skip complex reference types that can't be used as values
			if (ref($v)) {
				my $r = ref($v);
				# Skip HASH and ARRAY refs (can't be used as simple values)
				next if $r eq 'HASH' || $r eq 'ARRAY';
				# Skip other non-blessed refs (CODE, GLOB, REF, etc.)
				next unless blessed($v);
				# Allow blessed objects (e.g., JSON::XS::Boolean, JSON::PP::Boolean)
				# These stringify properly and can be used as values
			}
			push @items, _makeRawItem($k, $v);
		}
	} else {
		# Invalid format - no recognized structure
		return undef;
	}

	# ========================================================================
	# Step 2: Build lookup maps from items
	# ========================================================================
	my (%by_id, %by_idx, %by_name);
	for my $it (@items) {
		next if ref($it) ne 'HASH';
		
		# Extract lookup keys with case-insensitive fallback
		my $id = _getFieldVariant($it, 'id', 'Id');
		my $idx = _getFieldVariant($it, 'idx', 'Idx');
		my $name = _getFieldVariant($it, 'Name', 'name');

		# Populate lookup maps
		$by_id{$id} = $it if defined $id;
		$by_idx{int($idx)} = $it if defined $idx && $idx =~ $INT_REGEX;
		$by_name{$name} = $it if defined $name;
	}

	return { by_id => \%by_id, by_idx => \%by_idx, by_name => \%by_name };
}

# ----------------------------------------------------------------------------
# _mergeRecords() - Merge records from one source into aggregate
# ----------------------------------------------------------------------------
# Combines records from multiple JSON endpoints into a single aggregate structure.
# When the same key (id/idx/name) appears in multiple endpoints, the later
# endpoint's record completely replaces the earlier one (fields are NOT merged).
#
# Parameters:
#   $agg     - Aggregate structure to merge into (modified in place)
#   $records - New records to merge from
#
# Merge behavior:
#   If key "TempA" exists in both, $records version replaces $agg version entirely
#   This applies to all three lookup maps: by_id, by_idx, by_name
# ----------------------------------------------------------------------------
sub _mergeRecords {
	my ($agg, $records) = @_;
	return if !$agg || ref($agg) ne 'HASH';
	return if !$records || ref($records) ne 'HASH';

	# Merge all three map types (by_id, by_idx, by_name)
	# For each map type, copy all entries from records to aggregate
	for my $map_type (qw(by_id by_idx by_name)) {
		$agg->{$map_type} ||= {};
		if (ref($records->{$map_type}) eq 'HASH') {
			# Copy each key-value pair from records to aggregate
			# If a key already exists in aggregate, it will be replaced (not merged)
			for my $k (keys %{ $records->{$map_type} }) {
				$agg->{$map_type}{$k} = $records->{$map_type}{$k};
			}
		}
	}
}

# ============================================================================
# Macro Parsing and Replacement
# ============================================================================

# ----------------------------------------------------------------------------
# _replaceMacros() - Replace macro placeholders with data values
# ----------------------------------------------------------------------------
# Scans the format string for our macro patterns and replaces them with
# corresponding values from the fetched data. Supports optional functions
# to transform values (round, ceil, floor, truncate, shorten).
#
# Macro syntax:
#   ~e<id>~<field>~[func]~[arg]~    (lookup by id)
#   ~i<idx>~<field>~[func]~[arg]~   (lookup by numeric index)
#   ~n<name>~<field>~[func]~[arg]~  (lookup by name)
#
# Where:
#   <id>/<idx>/<name> - Key to look up in the records
#   <field>           - Field name to extract from the found record
#   [func]            - Optional function: round, ceil, floor, truncate, shorten
#   [arg]             - Optional function argument (e.g., decimal places for round)
#
# Parameters:
#   $format  - Format string containing macros
#   $records - Normalized records structure with lookup maps
#
# Returns:
#   String with macros replaced by actual values
#
# Behavior:
# - Unknown field names are left unchanged (macro not replaced)
# - If text after field is not a known function, macro ends at field
# - Invalid macros are left unchanged
# - Successfully replaced macros are logged at debug level
#
# Examples:
#   "Temp: ~eTempA~Value~round~1~°C" → "Temp: 23.5°C"
#   "Status: ~i1~Data~" → "Status: Active"
#   "Name: ~nSensor1~Name~" → "Name: Sensor1"
# ----------------------------------------------------------------------------
sub _replaceMacros {
	my ($format, $records) = @_;
	return $format if !defined $format;
	return $format if !$records || ref($records) ne 'HASH';

	# Known transformation functions
	my %funcs = map { $_ => 1 } qw(round ceil floor truncate shorten);

	my $out = $format;
	my $pos = 0;
	my @replacements; # Track replacements for debug logging

	# ========================================================================
	# Scan format string for macros and replace them
	# ========================================================================
	while (1) {
		# Find next potential macro start
		my $start = index($out, '~', $pos);
		last if $start < 0;  # No more macros

		# Check macro type (e/i/n)
		my $type = substr($out, $start + 1, 1);
		if ($type ne 'e' && $type ne 'i' && $type ne 'n') {
			# Not a valid macro type - skip this '~' and continue
			$pos = $start + 1;
			next;
		}

		# Extract key (between first and second ~)
		my $q1 = index($out, '~', $start + 2);
		if ($q1 < 0) {
			# Incomplete macro - no closing ~ for key
			$pos = $start + 1;
			next;
		}
		my $key = substr($out, $start + 2, $q1 - ($start + 2));

		# Extract field (between second and third ~)
		my $q2 = index($out, '~', $q1 + 1);
		if ($q2 < 0) {
			# Incomplete macro - no closing ~ for field
			$pos = $q1 + 1;
			next;
		}
		my $field = substr($out, $q1 + 1, $q2 - ($q1 + 1));

		# Try to extract optional function and argument
		my $end = $q2;  # End of macro (at least through field)
		my ($func, $arg);

		my $q3 = index($out, '~', $q2 + 1);
		if ($q3 >= 0) {
			my $funcCand = substr($out, $q2 + 1, $q3 - ($q2 + 1));
			if ($funcCand ne '' && $funcs{$funcCand}) {
				# Known function found
				$func = $funcCand;
				$end = $q3;

				# Try to extract function argument
				my $q4 = index($out, '~', $q3 + 1);
				if ($q4 >= 0) {
					$arg = substr($out, $q3 + 1, $q4 - ($q3 + 1));
					$end = $q4;
				}
			}
			# If funcCand is not a known function (or is empty), the macro ends
			# at q2 (after the field). Any text following is treated as literal.
			# Example: "~eTempA~Data~text" → "23.5text" (macro replaced, "text" stays literal)
		}

		# Extract the complete macro string for replacement
		my $whole = substr($out, $start, $end - $start + 1);

		# Look up the item/record by key
		my $item = _lookupItem($records, $type, $key);
		if (!$item || ref($item) ne 'HASH') {
			# Item not found - leave macro unchanged
			$pos = $end + 1;
			next;
		}

		# Get field value from item
		my $val = _getFieldValue($item, $field);
		if (!defined $val) {
			# Field not found - leave macro unchanged
			$pos = $end + 1;
			next;
		}

		# Apply optional transformation function
		my $rep = _macroSubFunc($val, $func, $arg);

		# Track successful replacement for debug logging
		if ($log->is_debug) {
			push @replacements, "$whole -> $rep";
		}

		# Replace the macro with the result
		substr($out, $start, length($whole), $rep);
		# Update position to after the replacement
		$pos = $start + length($rep);
	}

	# Log all replacements made (helps with debugging)
	if ($log->is_debug && @replacements) {
		$log->debug("Macro replacements: " . join(', ', @replacements));
	}

	return $out;
}

# ----------------------------------------------------------------------------
# _lookupItem() - Find record by key in lookup maps
# ----------------------------------------------------------------------------
# Retrieves a record from the appropriate lookup map based on macro type.
#
# Parameters:
#   $records - Normalized records structure with by_id, by_idx, by_name maps
#   $type    - Macro type: 'e' (id), 'i' (idx), 'n' (name)
#   $key     - Key value to look up
#
# Returns:
#   Record hash reference if found, undef otherwise
#
# Lookup behavior:
#   'e' → by_id map (exact string match)
#   'i' → by_idx map (numeric key, converted to int)
#   'n' → by_name map (exact string match, case-sensitive)
# ----------------------------------------------------------------------------
sub _lookupItem {
	my ($records, $type, $key) = @_;
	return undef if !$records || ref($records) ne 'HASH';

	if ($type eq 'e') {
		# Lookup by ID (string match)
		return (ref($records->{by_id}) eq 'HASH') ? $records->{by_id}{$key} : undef;
	}
	elsif ($type eq 'i') {
		# Lookup by index (numeric match)
		return undef if !defined $key || $key !~ $INT_REGEX;
		my $idx = int($key);
		return (ref($records->{by_idx}) eq 'HASH') ? $records->{by_idx}{$idx} : undef;
	}
	elsif ($type eq 'n') {
		# Lookup by name (string match, case-sensitive)
		return (ref($records->{by_name}) eq 'HASH') ? $records->{by_name}{$key} : undef;
	}

	return undef;
}

# ----------------------------------------------------------------------------
# _getFieldValue() - Extract field value from record
# ----------------------------------------------------------------------------
# Gets a field value from a record hash with case-insensitive fallback.
# Tries exact match first, then case-insensitive match.
#
# Parameters:
#   $item  - Record hash reference
#   $field - Field name to extract
#
# Returns:
#   Field value if found, undef otherwise
#
# Behavior:
#   1. Try exact field name match first
#   2. If not found, try case-insensitive match
#   3. Return undef if no match found
#
# Example:
#   Field "Value" matches "Value", "value", "VALUE", etc.
# ----------------------------------------------------------------------------
sub _getFieldValue {
	my ($item, $field) = @_;
	return undef if !$item || ref($item) ne 'HASH';
	return undef if !defined $field || $field eq '';

	# Try exact match first
	return $item->{$field} if exists $item->{$field};

	# Case-insensitive fallback
	# This allows "value", "Value", "VALUE" to all match
	my $lf = lc($field);
	for my $k (keys %$item) {
		next if !defined $k;
		return $item->{$k} if lc($k) eq $lf;
	}

	return undef;
}

# ============================================================================
# Macro Transformation Functions
# ============================================================================

# ----------------------------------------------------------------------------
# _macroSubFunc() - Apply transformation function to macro value
# ----------------------------------------------------------------------------
# Converts a field value to a string and optionally applies a transformation
# function (round, ceil, floor, truncate, shorten).
#
# Parameters:
#   $value   - Raw field value (scalar or reference)
#   $func    - Optional function name (round, ceil, floor, truncate, shorten)
#   $funcArg - Optional function argument (e.g., decimal places)
#
# Returns:
#   Transformed string value
#
# Value handling:
# - Scalar values: Convert to string
# - References: Encode as JSON (or "[complex value]" if encoding fails)
# - undefined: Empty string
#
# Functions:
# - round(dec):    Round to dec decimal places (supports negative for tens, hundreds)
# - truncate(dec): Truncate to dec decimal places (cut toward zero)
# - ceil():        Round up to nearest integer
# - floor():       Round down to nearest integer
# - shorten(n):    Keep only first n characters
#
# Error handling:
# - Non-numeric values passed to numeric functions: return unchanged
# - Invalid function arguments: use sensible defaults
# - Exceptions during processing: return original value
# ----------------------------------------------------------------------------
sub _macroSubFunc {
	my ($value, $func, $funcArg) = @_;

	# ========================================================================
	# Step 1: Convert value to string representation
	# ========================================================================
	my $replaceStr;
	if (ref($value)) {
		# Handle references (arrays, hashes, objects) by JSON-encoding them
		eval { $replaceStr = encode_json($value); };
		if ($@) {
			$log->warn("Failed to encode JSON value: $@");
			$replaceStr = "[complex value]";
		}
	}
	else {
		# Handle scalar values
		$replaceStr = defined $value ? "$value" : '';
	}

	# If no function specified, return the string as-is
	return $replaceStr if !defined $func || $func eq '';

	# ========================================================================
	# Step 2: Apply transformation function
	# ========================================================================
	my $result = eval {
		# --------------------------------------------------------------------
		# truncate(dec) - Cut decimal places toward zero
		# --------------------------------------------------------------------
		if ($func eq 'truncate') {
			my $dec = (defined $funcArg && $funcArg =~ $INT_REGEX) ? (0 + $funcArg) : 0;
			
			# Clamp decimal argument to prevent extreme values
			# Range: -12 to 12 is sufficient for typical use cases
			# (larger values would cause overflow or precision loss)
			$dec = -12 if $dec < -12;
			$dec = 12 if $dec > 12;
			
			# Return original string if not numeric
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			
			# Truncate toward zero (not rounding)
			# Supports negative decimal places (tens, hundreds, thousands, etc.)
			if ($dec < 0) {
				# Negative: truncate to tens, hundreds, etc.
				# Use integer division to avoid float artifacts
				my $divisor = 10 ** (-$dec);
				my $truncated = int($val / $divisor) * $divisor;
				return sprintf('%d', $truncated);
			}
			elsif ($dec > 0) {
				# Positive: truncate to decimal places
				my $factor = 10 ** $dec;
				my $truncated = int($val * $factor) / $factor;
				return sprintf('%.' . $dec . 'f', $truncated);
			} else {
				# Zero: truncate to integer
				return sprintf('%d', int($val));
			}
		}
		# --------------------------------------------------------------------
		# ceil() - Round up to nearest integer
		# --------------------------------------------------------------------
		elsif ($func eq 'ceil') {
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			return sprintf('%d', ceil($val));
		}
		# --------------------------------------------------------------------
		# floor() - Round down to nearest integer
		# --------------------------------------------------------------------
		elsif ($func eq 'floor') {
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			return sprintf('%d', floor($val));
		}
		# --------------------------------------------------------------------
		# round(dec) - Round to nearest with dec decimal places
		# --------------------------------------------------------------------
		elsif ($func eq 'round') {
			my $dec = (defined $funcArg && $funcArg =~ $INT_REGEX) ? (0 + $funcArg) : 0;
			
			# Clamp decimal argument to prevent extreme values
			# Range: -12 to 12 is sufficient for typical use cases
			$dec = -12 if $dec < -12;
			$dec = 12 if $dec > 12;
			
			# Return original string if not numeric
			return $replaceStr if $replaceStr !~ $NUM_REGEX;
			my $val = 0.0 + $replaceStr;
			
			# Use POSIX::round() if available, otherwise use fallback
			# Supports both positive (decimal places) and negative (tens, hundreds) values
			if ($dec < 0) {
				# Negative: round to tens, hundreds, etc.
				# Example: round(1234, -2) → 1200
				my $divisor = 10 ** (-$dec);
				my $rounded = $has_posix_round ? round($val / $divisor) : _round_fallback($val / $divisor);
				return sprintf('%d', $rounded * $divisor);
			}
			else {
				# Positive or zero: round to decimal places
				my $factor = 10 ** $dec;
				my $rounded = $has_posix_round ? round($val * $factor) / $factor : _round_fallback($val * $factor) / $factor;
				
				# Format output appropriately
				if ($dec > 0) {
					# Positive: format with decimal places
					return sprintf('%.' . $dec . 'f', $rounded);
				}
				else {
					# Zero: format as integer
					return sprintf('%d', $rounded);
				}
			}
		}
		# --------------------------------------------------------------------
		# shorten(n) - Keep only first n characters
		# --------------------------------------------------------------------
		elsif ($func eq 'shorten') {
			my $n = (defined $funcArg && $funcArg =~ $INT_REGEX) ? (0 + $funcArg) : 0;
			# Return original string if length is negative or zero
			return $replaceStr if $n <= 0;
			# Extract first n characters
			return substr($replaceStr, 0, $n);
		}
		# --------------------------------------------------------------------
		# Unknown function - return value unchanged
		# --------------------------------------------------------------------
		else {
			return $replaceStr;
		}
	};

	# Handle any errors during transformation
	if ($@) {
		$log->error('Error while trying to eval macro function: [' . $@ . ']');
		return $replaceStr;  # Return original value on error
	}

	return $result;
}

1;