package Plugins::MarantzHTTP::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our $VERSION = '1.6';

my $prefs = preferences('plugin.marantzhttp');
$prefs->init({
    ip            => '192.168.20.93',
    port          => '8080',
    mac_z1        => '',
    mac_z2        => '',
    sync_volume   => 1,
    poll_interval => 2,
});

my %syncing_clients;

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Plugins::MarantzHTTP::Settings;
    Plugins::MarantzHTTP::Settings->new();

    # Volume sync: Lyrion -> Marantz
    Slim::Control::Request::subscribe(\&volumeCallback, [['mixer'], ['volume']]);

    # Playback monitoring: start/stop polling based on whether songs are playing
    Slim::Control::Request::subscribe(\&playbackCallback, [['play'], ['pause'], ['stop']]);
    Slim::Control::Request::subscribe(\&playbackCallback, [['playlist'], ['newsong', 'pause', 'stop', 'play', 'resume', 'open']]);

    # Check initial playback state
    checkAndManagePolling();
}

sub shutdownPlugin {
    stopPollingTimer();
}

# --------------------------------------------------------------------------
# Volume Sync: Lyrion -> Marantz
# --------------------------------------------------------------------------
sub volumeCallback {
    my $request = shift;
    my $client = $request->client();

    if ($client && $request->isCommand([['mixer'], ['volume']])) {
        my $mac = lc($client->id() || '');

        # Prevent circular feedback loops when volume is updated by Marantz sync
        return if $syncing_clients{$mac};

        my $volume = int($client->volume());
        $volume = 0 if $volume < 0;
        $volume = 98 if $volume > 98;

        my $ip = $prefs->get('ip');
        my $port = $prefs->get('port') || '8080';
        return unless $ip;

        my $zone_cmd = getClientZone($client);

        if ($zone_cmd) {
            my $url = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$zone_cmd$volume";
            system("curl -s -m 2 \"$url\" > /dev/null 2>&1 &");
        }
    }
}

# --------------------------------------------------------------------------
# Helper: Determine Zone ('MV' or 'Z2') for Client
# --------------------------------------------------------------------------
sub getClientZone {
    my $client = shift;
    return '' unless $client;

    my $mac = lc($client->id() || '');
    my $mac_z1 = lc($prefs->get('mac_z1') || '');
    my $mac_z2 = lc($prefs->get('mac_z2') || '');

    if ($mac_z1 && $mac eq $mac_z1) {
        return 'MV';
    } elsif ($mac_z2 && $mac eq $mac_z2) {
        return 'Z2';
    } elsif (!$mac_z1 && !$mac_z2) {
        # Default to Main Zone if no MAC addresses are configured
        return 'MV';
    }
    return '';
}

# --------------------------------------------------------------------------
# Playback Monitoring & Polling Management
# --------------------------------------------------------------------------
sub playbackCallback {
    my $request = shift;
    checkAndManagePolling();
}

sub isAnyTargetClientPlaying {
    for my $client (Slim::Player::Client::clients()) {
        my $zone = getClientZone($client);
        if ($zone && $client->isPlaying()) {
            return 1;
        }
    }
    return 0;
}

sub checkAndManagePolling {
    # If the feature toggle is disabled, ensure timer is stopped
    unless ($prefs->get('sync_volume')) {
        stopPollingTimer();
        return;
    }

    # Only poll when songs are currently playing
    if (isAnyTargetClientPlaying()) {
        startPollingTimer();
    } else {
        stopPollingTimer();
    }
}

sub startPollingTimer {
    stopPollingTimer();

    return unless $prefs->get('sync_volume');
    return unless isAnyTargetClientPlaying();

    my $interval = int($prefs->get('poll_interval') || 2);
    $interval = 2 if $interval < 1;
    $interval = 10 if $interval > 10;

    my $now = eval { require Time::HiRes; Time::HiRes::time() } || time();
    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer(undef, $now + $interval, \&pollTimerCallback);
}

sub stopPollingTimer {
    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(undef, \&pollTimerCallback);
}

sub pollTimerCallback {
    # Feature toggle check
    unless ($prefs->get('sync_volume')) {
        return;
    }

    # Playback check: stop polling if no target client is playing songs
    unless (isAnyTargetClientPlaying()) {
        return;
    }

    pollActiveMarantzZones();

    # Schedule next poll cycle
    my $interval = int($prefs->get('poll_interval') || 2);
    $interval = 2 if $interval < 1;
    $interval = 10 if $interval > 10;

    my $now = eval { require Time::HiRes; Time::HiRes::time() } || time();
    Slim::Utils::Timers::setTimer(undef, $now + $interval, \&pollTimerCallback);
}

# --------------------------------------------------------------------------
# Volume Sync: Marantz -> Lyrion
# --------------------------------------------------------------------------
sub pollActiveMarantzZones {
    my $ip = $prefs->get('ip');
    my $port = $prefs->get('port') || '8080';
    return unless $ip;

    my %active_zones;
    for my $client (Slim::Player::Client::clients()) {
        my $zone = getClientZone($client);
        if ($zone && $client->isPlaying()) {
            $active_zones{$zone} ||= $client;
        }
    }

    if ($active_zones{'MV'}) {
        _queryMarantzStatus($ip, $port, 'MV', 'formMainZone_MainZoneXmlStatusLite.xml', $active_zones{'MV'});
    }
    if ($active_zones{'Z2'}) {
        _queryMarantzStatus($ip, $port, 'Z2', 'formZone2_Zone2XmlStatusLite.xml', $active_zones{'Z2'});
    }
}

sub _queryMarantzStatus {
    my ($ip, $port, $zone, $endpoint, $client) = @_;
    my $url = "http://$ip:$port/goform/$endpoint";

    require Slim::Networking::SimpleAsyncHTTP;
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $content = $http->content();
            _handleMarantzXmlResponse($content, $zone, $client);
        },
        sub {
            my ($http, $error) = @_;
            # Silent on network timeout or AVR standby
        },
        { timeout => 2 }
    );
    $http->get($url);
}

sub _handleMarantzXmlResponse {
    my ($content, $zone, $client) = @_;
    return unless $content && $client;

    # Parse volume from MasterVolume, Zone2Volume, or Volume XML tags
    if ($content =~ /<(?:MasterVolume|Zone2Volume|Volume)>\s*<value>([^<]+)<\/value>/i) {
        my $raw = $1;
        $raw =~ s/^\s+|\s+$//g;

        my $vol;
        if ($raw =~ /^-([\d\.]+)$/) {
            # Negative dB (e.g., -45.0 dB -> 80 - 45 = 35)
            $vol = int(80 - $1 + 0.5);
        } elsif ($raw =~ /^[\+]?([\d\.]+)$/) {
            # Direct numeric scale (e.g., 35, 45.5)
            $vol = int($1 + 0.5);
        }

        return unless defined $vol;
        $vol = 0 if $vol < 0;
        $vol = 98 if $vol > 98;

        my $current_vol = int($client->volume() || 0);

        # Only execute command if volume has actually changed
        if (abs($vol - $current_vol) >= 1) {
            my $mac = lc($client->id() || '');
            $syncing_clients{$mac} = 1;
            $client->execute(['mixer', 'volume', $vol]);
            $syncing_clients{$mac} = 0;
        }
    }
}

1;
