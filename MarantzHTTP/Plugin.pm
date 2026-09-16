package Plugins::MarantzHTTP::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.marantzhttp');
$prefs->init({ ip => '192.168.20.93', port => '8080', mac_z1 => '', mac_z2 => '' });

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);
    
    require Plugins::MarantzHTTP::Settings;
    Plugins::MarantzHTTP::Settings->new();
    
    Slim::Control::Request::subscribe(\&volumeCallback, [['mixer'], ['volume']]);
}

sub volumeCallback {
    my $request = shift;
    my $client = $request->client();
    
    if ($client && $request->isCommand([['mixer'], ['volume']])) {
        my $volume = int($client->volume());
        $volume = 98 if $volume > 98; 
        
        my $ip = $prefs->get('ip');
        my $port = $prefs->get('port');
        my $mac = lc($client->id());
        
        my $mac_z1 = lc($prefs->get('mac_z1') || '');
        my $mac_z2 = lc($prefs->get('mac_z2') || '');
        
        my $zone_cmd = '';
        
        if ($mac eq $mac_z1) {
            $zone_cmd = 'MV';
        } elsif ($mac eq $mac_z2) {
            $zone_cmd = 'Z2';
        } elsif ($mac_z1 eq '' && $mac_z2 eq '') {
            $zone_cmd = 'MV'; 
        }
        
        if ($zone_cmd) {
            my $url = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$zone_cmd$volume";
            system("curl -s -m 2 \"$url\" > /dev/null 2>&1 &");
        }
    }
}

1;
