#!/usr/bin/perl
# Usage: release.pl <repofile> <version> <zipfile> <url> <name>
#   repofile: Path to repo.xml file
#   version:  Version string (e.g., "1.0.0")
#   zipfile:  Path to zip file to calculate SHA for
#   url:      Base URL (zip filename will be appended)
#   name:     Plugin name identifier (e.g., "CustomClockHelper")
#
# Examples:
#   perl release.pl repo.xml 1.0.0 CustomClockHelper.zip http://example.com CustomClockHelper
#   perl release.pl repo.xml 2.0.0 PluginName.zip http://example.com PluginName

use strict;

use XML::Simple;
use File::Basename;
use Digest::SHA;

my $repofile = $ARGV[0];
my $version = $ARGV[1];
my $zipfile = $ARGV[2];
my $url = $ARGV[3];
my $name = $ARGV[4];

# Name parameter is required
if (!defined $name || $name eq '') {
    die "Error: Plugin name parameter is required\n";
}

my $repo = XMLin($repofile, ForceArray => 1, KeepRoot => 0, KeyAttr => 0, NoAttr => 0);

# Ensure plugins section exists
if (!exists $repo->{plugins}) {
    $repo->{plugins} = [{ plugin => [] }];
} elsif (!exists $repo->{plugins}[0]->{plugin}) {
    $repo->{plugins}[0]->{plugin} = [];
}

# Find the plugin with matching name, or create new one
my $plugin_index = -1;
my $plugins = $repo->{plugins}[0]->{plugin};

for (my $i = 0; $i < scalar(@$plugins); $i++) {
    if (exists $plugins->[$i]->{name} && $plugins->[$i]->{name} eq $name) {
        $plugin_index = $i;
        last;
    }
}

# If not found, add new plugin entry
if ($plugin_index == -1) {
    push @$plugins, { name => $name };
    $plugin_index = scalar(@$plugins) - 1;
}

# Calculate SHA
open (my $fh, "<", $zipfile) or die $!;
binmode $fh;

my $digest = Digest::SHA->new;
$digest->addfile($fh);
close $fh;

# Update the plugin entry
$plugins->[$plugin_index]->{name} = $name;
$plugins->[$plugin_index]->{version} = $version;
$plugins->[$plugin_index]->{sha}[0] = $digest->hexdigest;
$url .= "/$zipfile";
$plugins->[$plugin_index]->{url}[0] = $url;

print("name   : $name\n");
print("version: $version\n");
print("sha    : ", $digest->hexdigest, "\n");
print("url    : $url\n");

XMLout($repo, RootName => 'extensions', NoSort => 1, XMLDecl => 1, KeyAttr => '', OutputFile => $repofile, NoAttr => 0);


