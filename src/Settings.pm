package Plugins::SuperDateTimeMacroExtender::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

# Prefs namespace
my $prefs = preferences('plugin.superdatetimemacroextender');

# Manual uniq implementation for compatibility with older Perl/List::Util versions
# that don't have List::Util::uniq (added in Perl 5.26/List::Util 1.45)
# Takes a list and returns a new list with duplicates removed, preserving order
# Parameters: @_ - input list
# Returns: list with duplicates removed (first occurrence kept)
sub _uniq {
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

# Utility function for string trimming
sub _trim {
	my $s = shift;
	return $s unless defined $s;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub needsClient { 0 }

sub name {
	# Return the string token (not the translated string) - LMS will translate it.
	return 'PLUGIN_SUPERDATETIMEMACROEXTENDER';
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/SuperDateTimeMacroExtender/settings/basic.html');
}

sub prefs {
	# We manage persistence ourselves in handler() because the UI uses a dynamic
	# number of fields (pref_api_url_0..N). If we listed a pref here, the base
	# class would overwrite our saved value when no matching api_urls field
	# exists. However, we do list cache_mode here so it is automatically handled
	# by the base class.
	return ($prefs, 'cache_mode');
}

sub handler {
	my ($class, $client, $params) = @_;

	if ($params->{'saveSettings'}) {
		# Collect all URL fields (pref_api_url_0, pref_api_url_1, ...)
		my %found;
		for my $k (keys %$params) {
			if ($k =~ /^pref_api_url_(\d+)$/) {
				$found{$1} = $params->{$k};
			}
		}
		my @ordered;
		my @invalid_urls;
		for my $i (sort { $a <=> $b } keys %found) {
			my $u = $found{$i};
			next if !defined $u;
			$u = _trim($u);
			next if $u eq '';
			# Validate URL format (must start with http:// or https://)
			if ($u !~ m{^https?://}i) {
				push @invalid_urls, $u;
			} else {
				push @ordered, $u;
			}
		}
		# Remove duplicates while preserving order using manual _uniq implementation
		my @clean = _uniq(@ordered);
		# Store as an arrayref (native prefs type)
		$prefs->set('api_urls', \@clean);
		
		# Pass warning message to template only if there were invalid URLs
		# When all URLs are valid, explicitly set warning to undef to prevent persistence
		if (@invalid_urls) {
			$params->{'warning'} = 'PLUGIN_SUPERDATETIMEMACROEXTENDER_SETTINGS_URL_INVALID';
			$params->{'invalid_urls'} = \@invalid_urls;
		} else {
			# Explicitly set to undef instead of delete to ensure falsy value in template
			$params->{'warning'} = undef;
			$params->{'invalid_urls'} = undef;
		}
	}

	# Build fields for the template: number of urls in prefs + 1 extra empty field.
	my $raw = $prefs->get('api_urls') // [];
	my @urls;
	if (ref($raw) eq 'ARRAY') {
		@urls = @$raw;
	} else {
		@urls = split(/[\r\n]+/, $raw);
	}
	@urls = map { _trim($_) } @urls;
	@urls = grep { defined $_ && $_ ne '' } @urls;
	push @urls, ''; # +1 extra input

	$params->{'api_url_fields'} = [ map { { value => $_ } } @urls ];

	return $class->SUPER::handler($client, $params);
}

1;
