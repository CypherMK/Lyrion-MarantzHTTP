package Plugins::MarantzHTTP::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our $VERSION = '1.7.1';

my $prefs = preferences('plugin.marantzhttp');

$prefs->init({
    ip                          => '192.168.20.93',
    port                        => '8080',
    mac_z1                      => '',
    mac_z2                      => '',
    power_on_z1                 => 1,
    source_z1                   => 'SISAT/CBL',
    set_volume_on_power_z1      => 1,
    power_volume_z1             => 40,
    pause_on_off_or_source_z1   => 1,
    resume_on_source_z1         => 1,
    power_on_z2                 => 0,
    source_z2                   => 'Z2NET',
    set_volume_on_power_z2      => 0,
    power_volume_z2             => 30,
    pause_on_off_or_source_z2   => 0,
    resume_on_source_z2         => 0,
    sync_volume                 => 1,
    poll_interval               => 2,
});

my %syncing_clients;
my %last_poweron_time;
my %mismatch_counter;
my %match_counter;

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Plugins::MarantzHTTP::Settings;
    Plugins::MarantzHTTP::Settings->new();

    # Register AJAX endpoint to fetch Marantz sources without CORS limitations
    eval {
        require Slim::Web::Pages;
        Slim::Web::Pages->addPageFunction('plugins/MarantzHTTP/ajax_sources', \&ajaxSources);
    };

    # Volume sync: Lyrion -> Marantz
    Slim::Control::Request::subscribe(\&volumeCallback, [['mixer'], ['volume']]);

    # Playback polling management: start/stop polling timer
    Slim::Control::Request::subscribe(\&playbackCallback, [['play'], ['pause'], ['stop']]);
    Slim::Control::Request::subscribe(\&playbackCallback, [['playlist'], ['newsong', 'pause', 'stop', 'play', 'resume', 'open']]);

    # Power On / Source trigger: ONLY on explicit Play and Playlist Start from inactive/standby state
    # (Excludes 'newsong', track skips, jump, seek to prevent resetting volume on track changes)
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['play']]);
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['playlist'], ['play', 'open', 'load', 'loadtracks', 'loadalbum']]);

    # Check initial playback state
    checkAndManagePolling();
}

sub shutdownPlugin {
    stopPollingTimer();
}

# --------------------------------------------------------------------------
# Dedicated Play Trigger Callback: Auto Power-On (ONLY on Power-Up / Standby Wakeup)
# --------------------------------------------------------------------------
my %receiver_power_state; # 'ON' or 'STANDBY'
my %zone_is_playing;      # 1 if currently active/playing in this zone

sub playTriggerCallback {
    my $request = shift;
    my $client  = $request->client();
    return unless $client;

    # Strictly ignore Pause and Stop commands, and any track jump/seek/newsong
    if ($request->isCommand([['pause']]) || 
        $request->isCommand([['stop']]) || 
        $request->isCommand([['playlist'], ['pause']]) || 
        $request->isCommand([['playlist'], ['stop']]) ||
        $request->isCommand([['playlist'], ['newsong']]) ||
        $request->isCommand([['playlist'], ['jump']]) ||
        $request->isCommand([['playlist'], ['index']])) {
        return;
    }

    # Ensure client is actually in playing state and not paused
    if ($client->isPaused() || $client->isStopped()) {
        return;
    }

    my $zone = getClientZone($client);
    return unless $zone;

    my $ip   = $prefs->get('ip');
    my $port = $prefs->get('port') || '8080';
    return unless $ip;

    my $now = time();

    # Debounce: avoid sending duplicate power-on commands within 8 seconds for the same zone
    if ($last_poweron_time{$zone} && ($now - $last_poweron_time{$zone} < 8)) {
        return;
    }

    # CRITICAL BUGFIX: If receiver zone is ALREADY powered ON and actively playing,
    # do NOT re-send Power-ON and do NOT reset the volume!
    # "Set volume upon power-on" must ONLY apply when powering on the Marantz from Standby/Off.
    if ($zone_is_playing{$zone} && $receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON') {
        return;
    }

    if ($zone eq 'MV' && $prefs->get('power_on_z1')) {
        $last_poweron_time{$zone} = $now;
        $zone_is_playing{$zone} = 1;
        $receiver_power_state{$zone} = 'ON';
        my $source = $prefs->get('source_z1') || 'SISAT/CBL';
        my $vol = $prefs->get('set_volume_on_power_z1') ? $prefs->get('power_volume_z1') : undef;
        _sendPowerSourceAndVolume($ip, $port, 'ZMON', $source, $zone, $vol, $client);
    } elsif ($zone eq 'Z2' && $prefs->get('power_on_z2')) {
        $last_poweron_time{$zone} = $now;
        $zone_is_playing{$zone} = 1;
        $receiver_power_state{$zone} = 'ON';
        my $source = $prefs->get('source_z2') || 'Z2NET';
        my $vol = $prefs->get('set_volume_on_power_z2') ? $prefs->get('power_volume_z2') : undef;
        _sendPowerSourceAndVolume($ip, $port, 'Z2ON', $source, $zone, $vol, $client);
    }
}

# --------------------------------------------------------------------------
# Playback Polling Manager: Start or stop background volume polling
# --------------------------------------------------------------------------
sub playbackCallback {
    my $request = shift;
    my $client = $request ? $request->client() : undef;
    if ($client) {
        my $zone = getClientZone($client);
        if ($zone) {
            if ($client->isStopped()) {
                $zone_is_playing{$zone} = 0;
            } elsif ($client->isPlaying()) {
                if ($receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON') {
                    $zone_is_playing{$zone} = 1;
                }
            }
        }
    }
    checkAndManagePolling();
}

# --------------------------------------------------------------------------
# Send Power-On, Input Source, and Power-On Volume Commands
# --------------------------------------------------------------------------
sub _sendPowerSourceAndVolume {
    my ($ip, $port, $power_cmd, $source_cmd, $zone, $initial_volume, $client) = @_;
    return unless $ip && $power_cmd;

    # Clean up commands
    $power_cmd =~ s/^\s+|\s+$//g;
    $power_cmd =~ s/^\?//;

    # Send Power ON command
    my $url_power = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$power_cmd";
    _sendHttpRequest($url_power);

    my $now = eval { require Time::HiRes; Time::HiRes::time() } || time();

    # If an input source is configured, send it after a 600ms delay to allow AVR power-up
    if ($source_cmd) {
        $source_cmd =~ s/^\s+|\s+$//g;
        $source_cmd =~ s/^\?//;
        if ($source_cmd ne '') {
            my $url_source = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$source_cmd";
            require Slim::Utils::Timers;
            Slim::Utils::Timers::setTimer(undef, $now + 0.6, sub {
                _sendHttpRequest($url_source);
            });
        }
    }

    # If power-on volume setting is enabled for this zone, send it after 800ms
    if (defined $initial_volume && $initial_volume ne '') {
        my $vol = int($initial_volume);
        $vol = 0 if $vol < 0;
        $vol = 98 if $vol > 98;
        my $vol_cmd = ($zone eq 'Z2' ? 'Z2' : 'MV') . $vol;
        my $url_vol = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$vol_cmd";
        require Slim::Utils::Timers;
        Slim::Utils::Timers::setTimer(undef, $now + 0.8, sub {
            _sendHttpRequest($url_vol);
            # Also align player volume in LMS mixer so UI slider reflects the initial volume
            if ($client) {
                my $mac = lc($client->id() || '');
                $mac =~ s/[^a-f0-9]//g;
                $syncing_clients{$mac} = 1;
                $client->execute(['mixer', 'volume', $vol]);
                $syncing_clients{$mac} = 0;
            }
        });
    }
}

# --------------------------------------------------------------------------
# HTTP Request Dispatcher: Uses LMS SimpleAsyncHTTP + fallback to curl
# --------------------------------------------------------------------------
sub _sendHttpRequest {
    my $url = shift;
    return unless $url;

    eval {
        require Slim::Networking::SimpleAsyncHTTP;
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                # Success
            },
            sub {
                my ($http, $error) = @_;
                # Silent on error / unreachable
            },
            { timeout => 3 }
        );
        $http->get($url);
    };

    # Also dispatch via background curl for maximum reliability across systems
    system("curl -s -m 2 \"$url\" > /dev/null 2>&1 &");
}

# --------------------------------------------------------------------------
# Volume Sync: Lyrion -> Marantz
# --------------------------------------------------------------------------
sub volumeCallback {
    my $request = shift;
    my $client = $request->client();

    if ($client && $request->isCommand([['mixer'], ['volume']])) {
        my $mac = lc($client->id() || '');
        $mac =~ s/[^a-f0-9]//g;

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
            _sendHttpRequest($url);
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
    $mac =~ s/[^a-f0-9]//g;

    my $mac_z1 = lc($prefs->get('mac_z1') || '');
    $mac_z1 =~ s/[^a-f0-9]//g;

    my $mac_z2 = lc($prefs->get('mac_z2') || '');
    $mac_z2 =~ s/[^a-f0-9]//g;

    # If Zone 1 MAC matches explicitly
    if ($mac_z1 && $mac eq $mac_z1) {
        return 'MV';
    }

    # If Zone 2 MAC matches explicitly
    if ($mac_z2 && $mac eq $mac_z2) {
        return 'Z2';
    }

    # If Zone 1 MAC is empty and client does NOT match Zone 2, default to Main Zone ('MV')
    if (!$mac_z1 && (!$mac_z2 || $mac ne $mac_z2)) {
        return 'MV';
    }

    return '';
}

# --------------------------------------------------------------------------
# Playback Monitoring & Polling Management
# --------------------------------------------------------------------------
sub shouldPollMarantz {
    for my $client (Slim::Player::Client::clients()) {
        my $zone = getClientZone($client);
        next unless $zone;

        # Poll for volume sync if playing
        if ($client->isPlaying() && $prefs->get('sync_volume')) {
            return 1;
        }

        # Poll for auto-resume if paused and auto-resume is enabled for that zone
        if ($client->isPaused()) {
            if ($zone eq 'MV' && $prefs->get('resume_on_source_z1')) {
                return 1;
            } elsif ($zone eq 'Z2' && $prefs->get('resume_on_source_z2')) {
                return 1;
            }
        }
    }
    return 0;
}

sub checkAndManagePolling {
    if (shouldPollMarantz()) {
        startPollingTimer();
    } else {
        stopPollingTimer();
    }
}

sub startPollingTimer {
    stopPollingTimer();
    return unless shouldPollMarantz();

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
    unless (shouldPollMarantz()) {
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
# Volume Sync & Status Polling: Marantz -> Lyrion
# --------------------------------------------------------------------------
sub pollActiveMarantzZones {
    my $ip = $prefs->get('ip');
    my $port = $prefs->get('port') || '8080';
    return unless $ip;

    my %active_zones;
    for my $client (Slim::Player::Client::clients()) {
        my $zone = getClientZone($client);
        next unless $zone;

        if ($client->isPlaying() && $prefs->get('sync_volume')) {
            $active_zones{$zone} ||= $client;
        } elsif ($client->isPaused()) {
            if ($zone eq 'MV' && $prefs->get('resume_on_source_z1')) {
                $active_zones{$zone} ||= $client;
            } elsif ($zone eq 'Z2' && $prefs->get('resume_on_source_z2')) {
                $active_zones{$zone} ||= $client;
            }
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

    # Extract Power status (zonePower, ZonePower, Power)
    my $raw_power;
    if ($content =~ /<(?:zonePower|ZonePower|Power)>\s*<value>([^<]+)<\/value>/i) {
        $raw_power = uc($1);
        $raw_power =~ s/^\s+|\s+$//g;
    }

    # Extract Input Source (InputFuncSelect)
    my $raw_input;
    if ($content =~ /<InputFuncSelect>\s*<value>([^<]+)<\/value>/i) {
        $raw_input = uc($1);
        $raw_input =~ s/^\s+|\s+$//g;
    }

    my $is_standby = 0;
    if (defined $raw_power) {
        if ($raw_power eq 'STANDBY' || $raw_power eq 'OFF') {
            $is_standby = 1;
            $receiver_power_state{$zone} = 'STANDBY';
            $zone_is_playing{$zone} = 0;
        } elsif ($raw_power eq 'ON') {
            $receiver_power_state{$zone} = 'ON';
        }
    }

    my $configured_source = ($zone eq 'MV') ? $prefs->get('source_z1') : $prefs->get('source_z2');
    my $source_matches = 1;
    if (!$is_standby && defined $raw_input && $raw_input ne '') {
        $source_matches = _isSourceMatch($configured_source, $raw_input);
    }

    # --------------------------------------------------------------------------
    # 1. Volume Sync: Marantz -> Lyrion (Only when sync_volume is enabled & client is playing)
    # --------------------------------------------------------------------------
    if ($prefs->get('sync_volume') && $client->isPlaying()) {
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

            if (defined $vol) {
                $vol = 0 if $vol < 0;
                $vol = 98 if $vol > 98;

                my $current_vol = int($client->volume() || 0);

                # Only execute command if volume has actually changed
                if (abs($vol - $current_vol) >= 1) {
                    my $mac = lc($client->id() || '');
                    $mac =~ s/[^a-f0-9]//g;
                    $syncing_clients{$mac} = 1;
                    $client->execute(['mixer', 'volume', $vol]);
                    $syncing_clients{$mac} = 0;
                }
            }
        }
    }

    # Fail-safe check: Only evaluate auto-pause/resume if valid status tags were present in XML
    return unless (defined $raw_power || defined $raw_input);

    # --------------------------------------------------------------------------
    # 2. Fail-Safe Auto-Pause on Receiver Power-OFF / Source Change (Playing -> Pause)
    # --------------------------------------------------------------------------
    my $pause_enabled = ($zone eq 'MV') ? $prefs->get('pause_on_off_or_source_z1') : $prefs->get('pause_on_off_or_source_z2');
    if ($pause_enabled && $client->isPlaying()) {
        # Grace period: do not pause within 8 seconds of starting playback/power-on
        my $now = time();
        my $last_start = $last_poweron_time{$zone} || 0;
        if ($now - $last_start < 8) {
            $mismatch_counter{$zone} = 0;
            return;
        }

        # 2-stage verification to prevent false triggers during AVR input switching
        if ($is_standby || !$source_matches) {
            $mismatch_counter{$zone} = ($mismatch_counter{$zone} || 0) + 1;
            if ($mismatch_counter{$zone} >= 2) {
                $mismatch_counter{$zone} = 0;
                if ($client->isPlaying()) {
                    # Verified receiver power-off or source change: pause player safely
                    $client->execute(['pause', 1]);
                }
            }
        } else {
            # Verified active and correct source: clear counter
            $mismatch_counter{$zone} = 0;
        }
    }

    # --------------------------------------------------------------------------
    # 3. Fail-Safe Auto-Resume on Source Selection (Paused -> Resume)
    # --------------------------------------------------------------------------
    my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
    if ($resume_enabled && $client->isPaused()) {
        if (!$is_standby && $source_matches) {
            $match_counter{$zone} = ($match_counter{$zone} || 0) + 1;
            if ($match_counter{$zone} >= 2) {
                $match_counter{$zone} = 0;
                if ($client->isPaused()) {
                    # Verified receiver is ON and returned to player source: safely resume playback
                    $client->execute(['pause', 0]);
                }
            }
        } else {
            $match_counter{$zone} = 0;
        }
    }
}

# --------------------------------------------------------------------------
# Helper: Normalize and compare configured source against receiver XML source
# --------------------------------------------------------------------------
sub _isSourceMatch {
    my ($configured, $reported) = @_;
    return 1 unless defined $configured && defined $reported;

    my $c = uc($configured);
    my $r = uc($reported);

    # Strip SI or Z2 prefixes and non-alphanumerics
    $c =~ s/^SI//; $c =~ s/^Z2//; $c =~ s/[^A-Z0-9]//g;
    $r =~ s/^SI//; $r =~ s/^Z2//; $r =~ s/[^A-Z0-9]//g;

    return 1 if $c eq '' || $r eq '';

    # Normalize common Denon/Marantz source name aliases
    $c = 'SATCBL' if ($c eq 'CBLSAT' || $c eq 'SATCBL');
    $r = 'SATCBL' if ($r eq 'CBLSAT' || $r eq 'SATCBL');

    $c = 'MEDIAPLAYER' if ($c eq 'MPLAY' || $c eq 'MEDIAPLAYER');
    $r = 'MEDIAPLAYER' if ($r eq 'MPLAY' || $r eq 'MEDIAPLAYER');

    $c = 'HEOS' if ($c eq 'NET' || $c eq 'HEOS' || $c eq 'INTERNETRADIO');
    $r = 'HEOS' if ($r eq 'NET' || $r eq 'HEOS' || $r eq 'INTERNETRADIO');

    $c = 'BT' if ($c eq 'BT' || $c eq 'BLUETOOTH');
    $r = 'BT' if ($r eq 'BT' || $r eq 'BLUETOOTH');

    $c = 'BD' if ($c eq 'BD' || $c eq 'BLURAY');
    $r = 'BD' if ($r eq 'BD' || $r eq 'BLURAY');

    return ($c eq $r || index($r, $c) != -1 || index($c, $r) != -1) ? 1 : 0;
}

# --------------------------------------------------------------------------
# AJAX Handler: Fetch Marantz Sources via LMS Server (Bypasses browser CORS)
# --------------------------------------------------------------------------
sub ajaxSources {
    my ($httpClient, $params, $callback, @args) = @_;
    my $ip = $params->{ip} || $prefs->get('ip') || '192.168.20.93';
    my $port = $params->{port} || $prefs->get('port') || '8080';

    require Plugins::MarantzHTTP::Settings;
    my ($z1_sources, $z2_sources, $discovered) = Plugins::MarantzHTTP::Settings::fetchReceiverSources($ip, $port);

    my @z1_json;
    for my $it (@$z1_sources) {
        my $v = $it->{value} // '';
        my $n = $it->{name} // '';
        $v =~ s/\\/\\\\/g; $v =~ s/"/\\"/g;
        $n =~ s/\\/\\\\/g; $n =~ s/"/\\"/g;
        push @z1_json, "{\"value\":\"$v\",\"name\":\"$n\"}";
    }

    my @z2_json;
    for my $it (@$z2_sources) {
        my $v = $it->{value} // '';
        my $n = $it->{name} // '';
        $v =~ s/\\/\\\\/g; $v =~ s/"/\\"/g;
        $n =~ s/\\/\\\\/g; $n =~ s/"/\\"/g;
        push @z2_json, "{\"value\":\"$v\",\"name\":\"$n\"}";
    }

    my $json_str = sprintf('{"success":1,"fetched":%d,"ip":"%s","port":"%s","sources_z1":[%s],"sources_z2":[%s]}',
        $discovered ? 1 : 0,
        $ip,
        $port,
        join(',', @z1_json),
        join(',', @z2_json)
    );

    require Slim::Web::HTTP;
    return Slim::Web::HTTP::sendContent($httpClient, 'application/json; charset=utf-8', $json_str);
}

1;
