package Plugins::MarantzHTTP::Settings;
use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.marantzhttp');

sub name { 'PLUGIN_MARANTZHTTP' }
sub page { 'plugins/MarantzHTTP/settings/basic.html' }
sub prefs { return ($prefs, qw(ip port mac_z1 mac_z2)); }

1;
