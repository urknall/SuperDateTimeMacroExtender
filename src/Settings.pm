package Plugins::SuperDateTimeMacroExtender::Settings;

# ============================================================================
# SuperDateTime Macro Extender Settings Page
# ============================================================================
# This module provides the web-based settings interface for the plugin.
# It handles the settings page display and form submission for configuring
# API URLs and cache mode.
#
# Key features:
# - Dynamic URL input fields (add/remove URLs)
# - URL validation (must start with http:// or https://)
# - Duplicate URL detection and removal
# - Warning display for invalid URLs
# - Cache mode selection (server-wide or per-client)
# ============================================================================

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

# Prefs namespace - shared with Plugin.pm
my $prefs = preferences('plugin.superdatetimemacroextender');

# ============================================================================
# Utility Functions
# ============================================================================

# ----------------------------------------------------------------------------
# _uniq() - Remove duplicates from list while preserving order
# ----------------------------------------------------------------------------
# Manual implementation for compatibility with older Perl/List::Util versions
# that don't have List::Util::uniq (added in Perl 5.26/List::Util 1.45).
#
# Parameters:
#   @_ - Input list (may contain duplicates)
# Returns:
#   List with duplicates removed (first occurrence kept)
#
# Example:
#   _uniq('a', 'b', 'a', 'c') → ('a', 'b', 'c')
# ----------------------------------------------------------------------------
sub _uniq {
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

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

# ============================================================================
# LMS Settings Page Interface Methods
# ============================================================================
# These methods are required by the Slim::Web::Settings base class and define
# how the settings page behaves in the LMS web interface.
# ============================================================================

# ----------------------------------------------------------------------------
# needsClient() - Specify if settings page requires a player to be selected
# ----------------------------------------------------------------------------
# Returns:
#   0 - Settings are server-wide, no player selection needed
# ----------------------------------------------------------------------------
sub needsClient { 0 }

# ----------------------------------------------------------------------------
# name() - Get the settings page title string token
# ----------------------------------------------------------------------------
# Returns the string token (not the translated string) for the page title.
# LMS will look up and translate this token based on the user's language.
#
# Returns:
#   String token that maps to localized title in strings.txt
# ----------------------------------------------------------------------------
sub name {
	# Return the string token (not the translated string) - LMS will translate it.
	return 'PLUGIN_SUPERDATETIMEMACROEXTENDER';
}

# ----------------------------------------------------------------------------
# page() - Get the settings page HTML template path
# ----------------------------------------------------------------------------
# Returns the path to the HTML template file with CSRF protection applied.
#
# Returns:
#   CSRF-protected URI to the settings page template
# ----------------------------------------------------------------------------
sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/SuperDateTimeMacroExtender/settings/basic.html');
}

# ----------------------------------------------------------------------------
# prefs() - Specify which preferences this page manages
# ----------------------------------------------------------------------------
# Tells the base class which preferences to auto-save. We handle api_urls
# manually in handler() due to dynamic field count, but cache_mode is
# handled automatically by the base class.
#
# Returns:
#   ($prefs, @pref_names) - Prefs object and list of pref names
# ----------------------------------------------------------------------------
sub prefs {
	# We manage api_urls persistence ourselves in handler() because the UI uses
	# dynamic number of fields (pref_api_url_0..N). If we listed api_urls here,
	# the base class would overwrite our saved value when no matching field exists.
	# However, cache_mode is listed here for automatic handling by the base class.
	return ($prefs, 'cache_mode');
}

# ----------------------------------------------------------------------------
# handler() - Process settings page requests and form submissions
# ----------------------------------------------------------------------------
# Main entry point for settings page. Handles both GET (display settings) and
# POST (save settings) requests.
#
# Parameters:
#   $class  - Class name
#   $client - LMS client object (player), may be undef since needsClient=0
#   $params - Hash reference with request parameters and template variables
#
# Returns:
#   Result from base class handler (renders template)
#
# Processing flow:
# 1. If saveSettings: collect URLs, validate, remove duplicates, save
# 2. Build URL input fields for template (current URLs + 1 empty field)
# 3. Call base class handler to render template
# ----------------------------------------------------------------------------
sub handler {
	my ($class, $client, $params) = @_;

	# ========================================================================
	# Process form submission (if saveSettings is present)
	# ========================================================================
	if ($params->{'saveSettings'}) {
		# Collect all URL fields from form submission
		# Form fields are named: pref_api_url_0, pref_api_url_1, pref_api_url_2, etc.
		my %found;
		for my $k (keys %$params) {
			if ($k =~ /^pref_api_url_(\d+)$/) {
				$found{$1} = $params->{$k};
			}
		}
		
		# Process URLs in order, validate, and separate valid from invalid
		my @ordered;
		my @invalid_urls;
		for my $i (sort { $a <=> $b } keys %found) {
			my $u = $found{$i};
			next if !defined $u;
			
			$u = _trim($u);
			next if $u eq '';  # Skip empty fields
			
			# Validate URL format (must start with http:// or https://)
			if ($u !~ m{^https?://}i) {
				push @invalid_urls, $u;
			} else {
				push @ordered, $u;
			}
		}
		
		# Remove duplicates while preserving order
		my @clean = _uniq(@ordered);
		
		# Save to preferences as arrayref (native prefs type)
		$prefs->set('api_urls', \@clean);
		
		# Set warning message for template if there were invalid URLs
		if (@invalid_urls) {
			$params->{'warning'} = 'PLUGIN_SUPERDATETIMEMACROEXTENDER_SETTINGS_URL_INVALID';
			$params->{'invalid_urls'} = \@invalid_urls;
		} else {
			# Explicitly set to undef to ensure falsy value in template
			# (prevents warning persistence across page refreshes)
			$params->{'warning'} = undef;
			$params->{'invalid_urls'} = undef;
		}
	}

	# ========================================================================
	# Build URL input fields for template
	# ========================================================================
	# Retrieve current URLs from preferences
	my $raw = $prefs->get('api_urls') // [];
	my @urls;
	if (ref($raw) eq 'ARRAY') {
		@urls = @$raw;
	} else {
		# Support legacy string format (newline-separated)
		@urls = split(/[\r\n]+/, $raw);
	}
	
	# Clean URLs (trim whitespace, remove empty entries)
	@urls = map { _trim($_) } @urls;
	@urls = grep { defined $_ && $_ ne '' } @urls;
	
	# Add one extra empty field to allow adding new URLs
	push @urls, '';

	# Build array of hashes for template (template expects { value => ... } format)
	$params->{'api_url_fields'} = [ map { { value => $_ } } @urls ];

	# Call base class handler to render the template
	return $class->SUPER::handler($client, $params);
}

1;