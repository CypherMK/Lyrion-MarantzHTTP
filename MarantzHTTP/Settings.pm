package Plugins::MarantzHTTP::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('plugin.marantzhttp');
my $log   = logger('plugin.marantzhttp');

sub name { 'PLUGIN_MARANTZHTTP' }

sub page { 'plugins/MarantzHTTP/settings/basic.html' }

sub prefs { 
    return ($prefs, qw(
        ip port 
        mac_z1 power_on_z1 source_z1 set_volume_on_power_z1 power_volume_z1 pause_on_off_or_source_z1 resume_on_source_z1 
        mac_z2 power_on_z2 source_z2 set_volume_on_power_z2 power_volume_z2 pause_on_off_or_source_z2 resume_on_source_z2 
        sync_volume poll_interval
    )); 
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

# Non-blocking page render: zero network delays, instant load time
sub beforeRender {
    my ($class, $params) = @_;

    $params->{sources_z1} = [ @{ getDefaultSourcesZ1() } ];
    $params->{sources_z2} = [ @{ getDefaultSourcesZ2() } ];

    # Ensure currently configured source is retained in dropdown even if custom
    my $current_z1 = $prefs->get('source_z1');
    if ($current_z1 && !grep { $_->{value} eq $current_z1 } @{$params->{sources_z1}}) {
        unshift @{$params->{sources_z1}}, { value => $current_z1, name => $current_z1 };
    }

    my $current_z2 = $prefs->get('source_z2');
    if ($current_z2 && !grep { $_->{value} eq $current_z2 } @{$params->{sources_z2}}) {
        unshift @{$params->{sources_z2}}, { value => $current_z2, name => $current_z2 };
    }
}

# Input sanitization before saving settings
sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{'saveSettings'}) {
        # Sanitize IP address (strip whitespace, protocol prefixes, trailing slashes)
        if (defined $params->{'pref_ip'}) {
            $params->{'pref_ip'} =~ s/^\s+|\s+$//g;
            $params->{'pref_ip'} =~ s{^https?://}{}i;
            $params->{'pref_ip'} =~ s{/.*$}{};
        }

        # Sanitize Port
        if (defined $params->{'pref_port'}) {
            $params->{'pref_port'} =~ s/^\s+|\s+$//g;
            $params->{'pref_port'} =~ s/[^0-9]//g;
            $params->{'pref_port'} = '8080' if $params->{'pref_port'} eq '';
        }

        # Sanitize MAC addresses (strip spaces)
        if (defined $params->{'pref_mac_z1'}) {
            $params->{'pref_mac_z1'} =~ s/^\s+|\s+$//g;
        }
        if (defined $params->{'pref_mac_z2'}) {
            $params->{'pref_mac_z2'} =~ s/^\s+|\s+$//g;
        }
    }

    return $class->SUPER::handler($client, $params, $callback, @args);
}

1;
