package Plugins::MarantzHTTP::Settings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('plugin.marantzhttp');

sub name { 'PLUGIN_MARANTZHTTP' }

sub page { 'plugins/MarantzHTTP/settings/basic.html' }

sub prefs { 
    return ($prefs, qw(ip port mac_z1 power_on_z1 source_z1 set_volume_on_power_z1 power_volume_z1 pause_on_off_or_source_z1 resume_on_source_z1 mac_z2 power_on_z2 source_z2 set_volume_on_power_z2 power_volume_z2 pause_on_off_or_source_z2 resume_on_source_z2 sync_volume poll_interval)); 
}

# Standard input sources available on Marantz & Denon AVRs
sub getDefaultSourcesZ1 {
    return [
        { value => 'SISAT/CBL',       name => 'CBL/SAT' },
        { value => 'SIMEDIA_PLAYER',  name => 'Media Player' },
        { value => 'SICD',            name => 'CD' },
        { value => 'SIAUX1',          name => 'AUX 1' },
        { value => 'SIAUX2',          name => 'AUX 2' },
        { value => 'SIBD',            name => 'Blu-ray' },
        { value => 'SIDVD',           name => 'DVD' },
        { value => 'SITV',            name => 'TV Audio' },
        { value => 'SIHEOS',          name => 'HEOS / Network' },
        { value => 'SINET',           name => 'Internet Radio' },
        { value => 'SIBT',            name => 'Bluetooth' },
        { value => 'SIGAME',          name => 'Game' },
        { value => 'SIPHONO',         name => 'Phono' },
        { value => 'SITUNER',         name => 'Tuner' },
        { value => 'SI8K',            name => '8K HDMI' },
        { value => 'SIUSB/IPOD',      name => 'USB' },
    ];
}

sub getDefaultSourcesZ2 {
    return [
        { value => 'Z2NET',           name => 'HEOS / Network' },
        { value => 'Z2SAT/CBL',       name => 'CBL/SAT' },
        { value => 'Z2MEDIA_PLAYER',  name => 'Media Player' },
        { value => 'Z2CD',            name => 'CD' },
        { value => 'Z2AUX1',          name => 'AUX 1' },
        { value => 'Z2AUX2',          name => 'AUX 2' },
        { value => 'Z2BD',            name => 'Blu-ray' },
        { value => 'Z2DVD',           name => 'DVD' },
        { value => 'Z2TV',            name => 'TV Audio' },
        { value => 'Z2BT',            name => 'Bluetooth' },
        { value => 'Z2TUNER',         name => 'Tuner' },
        { value => 'Z2SOURCE',        name => 'Follow Main Zone' },
    ];
}

# Fetch dynamic renamed sources from Marantz receiver if online
sub fetchReceiverSources {
    my ($ip, $port) = @_;
    return (getDefaultSourcesZ1(), getDefaultSourcesZ2()) unless $ip;
    $port ||= '8080';

    my @z1_sources;
    my @z2_sources;

    # Try synchronous retrieval via LWP or curl if available
    eval {
        require LWP::UserAgent;
        my $ua = LWP::UserAgent->new(timeout => 2);
        my $req_body = '<?xml version="1.0" encoding="utf-8"?><tx><cmd id="1">GetRenameSource</cmd></tx>';
        my $res = $ua->post("http://$ip:$port/goform/AppCommand.xml", Content_Type => 'text/xml', Content => $req_body);
        if ($res && $res->is_success) {
            my $content = $res->decoded_content;
            while ($content =~ /<param\s+name="([^"]+)">([^<]+)<\/param>/gi) {
                my $raw = uc($1);
                my $friendly = $2;
                $raw =~ s/^\s+|\s+$//g;
                $friendly =~ s/^\s+|\s+$//g;

                my $cmd_z1 = "SI$raw";
                my $cmd_z2 = "Z2$raw";

                if ($raw eq 'CBL/SAT' || $raw eq 'CBL_SAT' || $raw eq 'SAT_CBL') {
                    $cmd_z1 = 'SISAT/CBL';
                    $cmd_z2 = 'Z2SAT/CBL';
                } elsif ($raw eq 'MPLAY' || $raw eq 'MEDIA_PLAYER') {
                    $cmd_z1 = 'SIMEDIA_PLAYER';
                    $cmd_z2 = 'Z2MEDIA_PLAYER';
                } elsif ($raw eq 'NET' || $raw eq 'HEOS') {
                    $cmd_z1 = 'SIHEOS';
                    $cmd_z2 = 'Z2NET';
                } elsif ($raw eq 'BT') {
                    $cmd_z1 = 'SIBT';
                    $cmd_z2 = 'Z2BT';
                }

                push @z1_sources, { value => $cmd_z1, name => $friendly };
                push @z2_sources, { value => $cmd_z2, name => $friendly };
            }
        }
    };

    if (!@z1_sources) {
        @z1_sources = @{ getDefaultSourcesZ1() };
    }
    if (!@z2_sources) {
        @z2_sources = @{ getDefaultSourcesZ2() };
    } else {
        # Ensure Z2SOURCE is present in Zone 2
        unless (grep { $_->{value} eq 'Z2SOURCE' } @z2_sources) {
            push @z2_sources, { value => 'Z2SOURCE', name => 'Follow Main Zone' };
        }
    }

    return (\@z1_sources, \@z2_sources);
}

sub beforeRender {
    my ($class, $params) = @_;
    my $ip = $prefs->get('ip');
    my $port = $prefs->get('port') || '8080';

    my ($z1_list, $z2_list) = fetchReceiverSources($ip, $port);
    $params->{sources_z1} = $z1_list;
    $params->{sources_z2} = $z2_list;

    # Ensure currently selected source is available in dropdown even if custom
    my $current_z1 = $prefs->get('source_z1');
    if ($current_z1 && !grep { $_->{value} eq $current_z1 } @{$z1_list}) {
        unshift @{$params->{sources_z1}}, { value => $current_z1, name => $current_z1 };
    }

    my $current_z2 = $prefs->get('source_z2');
    if ($current_z2 && !grep { $_->{value} eq $current_z2 } @{$z2_list}) {
        unshift @{$params->{sources_z2}}, { value => $current_z2, name => $current_z2 };
    }
}

1;

