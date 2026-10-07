package Plugins::MarantzHTTP::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our $VERSION = '1.8.3';

# Initialize Lyrion / LMS Logger Category
my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.marantzhttp',
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_MARANTZHTTP',
});

my $prefs = preferences('plugin.marantzhttp');

$prefs->init({
    ip                          => '',       # Configured by user in settings
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
my %last_marantz_synced_vol;
my %last_marantz_vol_sync_time;
my %last_poweron_time;
my %mismatch_counter;
my %match_counter;
my %receiver_power_state;     # 'ON' or 'STANDBY'
my %receiver_source_state;    # last reported source (e.g. 'SAT/CBL', 'GAME1')
my %zone_is_playing;          # 1 if currently active/playing in this zone
my %zone_awaiting_resume;     # 1 if zone was auto-paused or waiting for receiver to return to Lyrion
my %internal_auto_pause;      # 1 while plugin is executing fail-safe auto-pause
my %zone_pending_timers;      # Active timer handles per zone to allow cancellation

# Helper to check if debug logging is enabled via LMS logging settings (plugin.marantzhttp = DEBUG)
sub _isDebug {
    return ($log && $log->is_debug);
}

sub _debugLog {
    my $msg = shift;
    if (_isDebug()) {
        if ($log) {
            $log->debug($msg);
        } else {
            warn "[MarantzHTTP DEBUG] $msg\n";
        }
    }
}

sub _infoLog {
    my $msg = shift;
    if ($log && ($log->is_info || _isDebug())) {
        $log->info($msg);
    }
}

sub _warnLog {
    my $msg = shift;
    if ($log) {
        $log->warn($msg);
    } else {
        warn "[MarantzHTTP WARN] $msg\n";
    }
}

sub _errorLog {
    my $msg = shift;
    if ($log) {
        $log->error($msg);
    } else {
        warn "[MarantzHTTP ERROR] $msg\n";
    }
}

# Helpers to sanitize target IP and port (handles whitespace and protocol prefixes)
sub _getTargetIp {
    my $ip = $prefs->get('ip');
    return '' unless defined $ip;
    $ip =~ s/^\s+|\s+$//g;
    $ip =~ s{^https?://}{}i;
    $ip =~ s{/.*$}{};
    return $ip;
}

sub _getTargetPort {
    my $port = $prefs->get('port');
    return '8080' unless defined $port;
    $port =~ s/^\s+|\s+$//g;
    $port =~ s/[^0-9]//g;
    return $port ne '' ? $port : '8080';
}

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Plugins::MarantzHTTP::Settings;
    Plugins::MarantzHTTP::Settings->new();

    # Volume sync: Lyrion -> Marantz
    Slim::Control::Request::subscribe(\&volumeCallback, [['mixer'], ['volume']]);

    # Playback polling management: start/stop polling timer
    Slim::Control::Request::subscribe(\&playbackCallback, [['play'], ['pause'], ['stop']]);
    Slim::Control::Request::subscribe(\&playbackCallback, [['playlist'], ['newsong', 'pause', 'stop', 'play', 'resume', 'open']]);

    # Power On / Source trigger: On Play, Playlist start, Unpause (pause 0 / resume / load)
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['play']]);
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['pause']]);
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['playlist'], ['play', 'open', 'load', 'loadtracks', 'loadalbum', 'resume', 'pause']]);

    # Client connections & power state subscriptions
    Slim::Control::Request::subscribe(\&clientLifecycleCallback, [['client'], ['new', 'reconnect', 'forget', 'iport']]);
    Slim::Control::Request::subscribe(\&clientLifecycleCallback, [['power']]);

    # Re-evaluate polling immediately on preference changes
    eval {
        $prefs->setChange(\&checkAndManagePolling, qw(sync_volume poll_interval ip port mac_z1 mac_z2));
    };

    my $target_ip = _getTargetIp() || '[Not Configured]';
    my $target_port = _getTargetPort();
    _infoLog("MarantzHTTP v$VERSION initialized. Target AVR: $target_ip:$target_port");
    _debugLog("Subscriptions registered: mixer/volume, playback, playTrigger, clientLifecycle");

    # Check and start background polling
    checkAndManagePolling();
}

sub shutdownPlugin {
    _infoLog("MarantzHTTP plugin shutting down. Stopping all timers.");
    stopPollingTimer();
    _cancelAllZoneTimers();
}

sub clientLifecycleCallback {
    my $request = shift;
    _debugLog("[CLIENT EVENT] Client lifecycle change detected. Updating polling state.");
    checkAndManagePolling();
}

# --------------------------------------------------------------------------
# Timer Management Helpers: Cancel queued retries/volume commands per zone
# --------------------------------------------------------------------------
sub _cancelZoneTimers {
    my $zone = shift;
    return unless $zone && $zone_pending_timers{$zone};
    require Slim::Utils::Timers;
    for my $timer_id (@{ $zone_pending_timers{$zone} }) {
        if ($timer_id) {
            eval { Slim::Utils::Timers::killTimers(undef, $timer_id); };
        }
    }
    delete $zone_pending_timers{$zone};
}

sub _cancelAllZoneTimers {
    for my $z ('MV', 'Z2') {
        _cancelZoneTimers($z);
    }
}

# --------------------------------------------------------------------------
# Dedicated Play Trigger Callback: Auto Power-On & Input Source Selector
# Fires on Play, Playlist start, Unpause / Resume
# --------------------------------------------------------------------------
sub playTriggerCallback {
    my $request = shift;
    my $client  = $request->client();
    return unless $client;

    my $client_id = $client->id() || 'unknown';
    my $client_name = eval { $client->name() } || $client_id;
    my $req_str = $request->getRequestString() || 'play/playlist trigger';
    _debugLog("[EVENT IN] playTriggerCallback from player '$client_name' ($client_id) | Request: '$req_str'");

    my $zone = getClientZone($client);
    unless ($zone) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': player MAC does not match configured Zone 1 or Zone 2");
        return;
    }

    # 1. Ignore if plugin itself initiated fail-safe auto-pause
    if ($internal_auto_pause{$zone}) {
        delete $internal_auto_pause{$zone};
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': internal fail-safe auto-pause in progress");
        return;
    }

    # 2. Strictly ignore Stop commands, track jump/seek/index
    if ($request->isCommand([['stop']]) || 
        $request->isCommand([['playlist'], ['stop']]) || 
        $request->isCommand([['playlist'], ['jump']]) ||
        $request->isCommand([['playlist'], ['index']])) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': command is stop/jump/index ('$req_str')");
        return;
    }

    # 3. Check for explicit pause command ('pause 1' or 'playlist pause 1')
    my $p0 = $request->getParam('_p0');
    my $p1 = $request->getParam('_p1');
    my $p2 = $request->getParam('_p2');
    my $is_explicit_pause = ((defined $p0 && $p0 eq '1') || (defined $p1 && $p1 eq '1') || (defined $p2 && $p2 eq '1') || $req_str =~ /\bpause\s+1\b/i);
    if ($is_explicit_pause) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': explicit pause command ('$req_str')");
        return;
    }

    # 4. Check player status:
    # If the player is currently paused and this command is NOT an explicit unpause ('pause 0'), NEVER switch source or power on!
    my $is_explicit_unpause = ((defined $p0 && $p0 eq '0') || (defined $p1 && $p1 eq '0') || (defined $p2 && $p2 eq '0') || $req_str =~ /\bpause\s+0\b/i);
    if ($client->isPaused() && !$is_explicit_unpause) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': player is paused ('$req_str')");
        return;
    }

    # If the player is stopped and this is not a play command, ignore
    if ($client->isStopped()) {
        my $is_play_cmd = ($request->isCommand([['play']]) || 
                           $request->isCommand([['playlist'], ['play']]) || 
                           $request->isCommand([['playlist'], ['resume']]) ||
                           $request->isCommand([['playlist'], ['open']]) ||
                           $request->isCommand([['playlist'], ['load']]));
        unless ($is_play_cmd) {
            _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': player is stopped ('$req_str')");
            return;
        }
    }

    # 5. Playback confirmed active or starting! Ensure receiver is ON and set to Lyrion source!
    ensurePowerAndSource($client, $zone, "Trigger: $req_str");
}

# --------------------------------------------------------------------------
# Central Power & Source Manager: Guarantees Marantz Power-ON and Correct Source
# --------------------------------------------------------------------------
sub ensurePowerAndSource {
    my ($client, $zone, $reason) = @_;
    return unless $client && $zone;

    my $client_name = eval { $client->name() } || $client->id() || 'player';
    my $ip   = _getTargetIp();
    my $port = _getTargetPort();

    unless ($ip) {
        _warnLog("[CONFIG] ensurePowerAndSource: Marantz IP address is not configured in settings. Skipping command.");
        return;
    }

    my $now = time();

    # Debounce: avoid sending duplicate commands within 2 seconds for the same zone
    if ($last_poweron_time{$zone} && ($now - $last_poweron_time{$zone} < 2)) {
        my $elapsed = $now - $last_poweron_time{$zone};
        _debugLog("[ACTION OUT] Debounce active for Zone $zone ($elapsed s < 2s). Skipping duplicate dispatch.");
        return;
    }
    $last_poweron_time{$zone} = $now;
    $zone_is_playing{$zone} = 1;
    $zone_awaiting_resume{$zone} = 0;
    $mismatch_counter{$zone} = 0;
    $match_counter{$zone} = 0;

    my $is_already_on = ($receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON') ? 1 : 0;

    if ($zone eq 'MV') {
        my $power_on_enabled = $prefs->get('power_on_z1');
        my $power_cmd = $power_on_enabled ? 'ZMON' : undef;
        my $source_cmd = $prefs->get('source_z1') || 'SISAT/CBL';
        my $vol = (!$is_already_on && $prefs->get('set_volume_on_power_z1')) ? $prefs->get('power_volume_z1') : undef;

        _infoLog(sprintf("[TRIGGER] Ensuring Power & Source for Main Zone ('%s') | Reason: %s | PowerCmd: %s | Source: %s | InitialVol: %s | AVR: %s",
            $client_name, $reason || 'Play Trigger', $power_cmd // 'NONE', $source_cmd // 'NONE', defined $vol ? $vol : 'PRESERVED', $is_already_on ? 'ON' : 'STANDBY/UNKNOWN'));

        _sendPowerSourceAndVolume($ip, $port, $power_cmd, $source_cmd, $zone, $vol, $client, $is_already_on);
    } elsif ($zone eq 'Z2') {
        my $power_on_enabled = $prefs->get('power_on_z2');
        my $power_cmd = $power_on_enabled ? 'Z2ON' : undef;
        my $source_cmd = $prefs->get('source_z2') || 'Z2NET';
        my $vol = (!$is_already_on && $prefs->get('set_volume_on_power_z2')) ? $prefs->get('power_volume_z2') : undef;

        _infoLog(sprintf("[TRIGGER] Ensuring Power & Source for Zone 2 ('%s') | Reason: %s | PowerCmd: %s | Source: %s | InitialVol: %s | AVR: %s",
            $client_name, $reason || 'Play Trigger', $power_cmd // 'NONE', $source_cmd // 'NONE', defined $vol ? $vol : 'PRESERVED', $is_already_on ? 'ON' : 'STANDBY/UNKNOWN'));

        _sendPowerSourceAndVolume($ip, $port, $power_cmd, $source_cmd, $zone, $vol, $client, $is_already_on);
    }
}

# --------------------------------------------------------------------------
# Playback Polling Manager: Start or stop background volume polling
# --------------------------------------------------------------------------
sub playbackCallback {
    my $request = shift;
    my $client = $request ? $request->client() : undef;
    return unless $client;

    my $zone = getClientZone($client);
    my $client_name = eval { $client->name() } || $client->id() || 'player';
    my $req_str = $request->getRequestString() || 'playback event';

    _debugLog("[EVENT IN] playbackCallback for '$client_name' (Zone: " . ($zone || 'None') . ") | Request: '$req_str'");

    if ($zone) {
        if ($client->isStopped()) {
            $zone_is_playing{$zone} = 0;
            _cancelZoneTimers($zone);
            _debugLog("[STATUS] Zone $zone player is STOPPED.");
        } elsif ($client->isPaused()) {
            my $configured_source = ($zone eq 'MV') ? $prefs->get('source_z1') : $prefs->get('source_z2');
            my $is_on_lyrion = ($receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON' &&
                                $receiver_source_state{$zone} && _isSourceMatch($configured_source, $receiver_source_state{$zone}));
            if ($is_on_lyrion && !$zone_awaiting_resume{$zone}) {
                $zone_awaiting_resume{$zone} = 0;
                $match_counter{$zone} = 0;
                _debugLog("[STATUS] Zone $zone player is PAUSED manually by user while on Lyrion source. Auto-Resume disarmed.");
            } else {
                _debugLog("[STATUS] Zone $zone player is PAUSED (awaiting Marantz return to Lyrion source).");
            }
        } elsif ($client->isPlaying()) {
            $zone_awaiting_resume{$zone} = 0;
            $match_counter{$zone} = 0;
            _debugLog("[STATUS] Zone $zone player is PLAYING.");

            my $now = time();
            my $last_start = $last_poweron_time{$zone} || 0;
            my $configured_source = ($zone eq 'MV') ? $prefs->get('source_z1') : $prefs->get('source_z2');
            my $receiver_is_on_other_source = ($receiver_source_state{$zone} && !_isSourceMatch($configured_source, $receiver_source_state{$zone}));

            my $is_newsong = ($request->isCommand([['playlist'], ['newsong']]) || $req_str =~ /\bnewsong\b/i);
            my $is_already_active = ($zone_is_playing{$zone} && 
                                     $receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON' &&
                                     $receiver_source_state{$zone} && _isSourceMatch($configured_source, $receiver_source_state{$zone}));

            # Avoid track-change audio dropouts: Do NOT send power/source switch commands if AVR is already ON and playing
            if ($is_newsong || $is_already_active) {
                $zone_is_playing{$zone} = 1;
                _debugLog("[PLAYBACK] Track transition or steady playback on '$client_name' (Zone $zone). Receiver confirmed ON and on correct source. Suppressed redundant commands.");
            } elsif ($now - $last_start > 4 && !$receiver_is_on_other_source) {
                _infoLog("[PLAYBACK SAFETY] Active playback detected on '$client_name' (Zone $zone). Ensuring Marantz power & source.");
                ensurePowerAndSource($client, $zone, "Playback active safety: $req_str");
            } else {
                $zone_is_playing{$zone} = 1;
            }
        }
    }

    checkAndManagePolling();
}

# --------------------------------------------------------------------------
# Send Power-On, Input Source, and Power-On Volume Commands
# --------------------------------------------------------------------------
sub _sendPowerSourceAndVolume {
    my ($ip, $port, $power_cmd, $source_cmd, $zone, $initial_volume, $client, $is_already_on) = @_;
    return unless $ip;

    my $now = eval { require Time::HiRes; Time::HiRes::time() } || time();
    require Slim::Utils::Timers;

    _cancelZoneTimers($zone);
    $zone_pending_timers{$zone} = [];

    # 1. Power ON command (if configured)
    if ($power_cmd) {
        $power_cmd =~ s/^\s+|\s+$//g;
        $power_cmd =~ s/^\?//;
        my $url_power = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$power_cmd";
        _debugLog("[ACTION OUT] Dispatching Power-ON command: $power_cmd -> $url_power");
        _sendHttpRequest($url_power);
    }

    # 2. Source Switch command: ALWAYS send!
    if ($source_cmd) {
        $source_cmd =~ s/^\s+|\s+$//g;
        $source_cmd =~ s/^\?//;
        if ($source_cmd ne '') {
            my $url_source = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$source_cmd";

            if ($is_already_on) {
                _debugLog("[ACTION OUT] AVR already ON. Dispatching Source Switch immediately: $source_cmd -> $url_source");
                _sendHttpRequest($url_source);

                my $timer_sub = sub {
                    _debugLog("[ACTION OUT] Re-confirming Source Switch: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                };
                Slim::Utils::Timers::setTimer(undef, $now + 0.8, $timer_sub);
                push @{ $zone_pending_timers{$zone} }, $timer_sub;
            } else {
                # AVR waking from standby: Stagger retries to allow DSP/HDMI/network initialization (+1.2s and +3.0s)
                _debugLog("[ACTION OUT] AVR waking from standby. Scheduling Source Switch: $source_cmd (+1.2s and +3.0s retry)");
                my $timer_sub1 = sub {
                    _debugLog("[ACTION OUT] Dispatching Source Switch command: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                };
                Slim::Utils::Timers::setTimer(undef, $now + 1.2, $timer_sub1);
                push @{ $zone_pending_timers{$zone} }, $timer_sub1;

                my $timer_sub2 = sub {
                    _debugLog("[ACTION OUT] Re-confirming Source Switch after power-up: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                };
                Slim::Utils::Timers::setTimer(undef, $now + 3.0, $timer_sub2);
                push @{ $zone_pending_timers{$zone} }, $timer_sub2;
            }
        }
    }

    # 3. Initial Volume (only on initial power-on from Standby/Off)
    if (!$is_already_on && defined $initial_volume && $initial_volume ne '') {
        my $vol = int($initial_volume);
        $vol = 0 if $vol < 0;
        $vol = 98 if $vol > 98;
        # Denon/Marantz protocol requires 2-digit volume formatting (e.g. MV05 instead of MV5)
        my $vol_formatted = sprintf("%02d", $vol);
        my $vol_cmd = ($zone eq 'Z2' ? 'Z2' : 'MV') . $vol_formatted;
        my $url_vol = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$vol_cmd";

        _debugLog("[ACTION OUT] Scheduling Power-On Volume: $vol_cmd (+2000ms delay)");
        my $timer_sub3 = sub {
            _debugLog("[ACTION OUT] Dispatching Power-On Volume command: $vol_cmd -> $url_vol");
            _sendHttpRequest($url_vol);

            if ($client) {
                my $mac = lc(eval { $client->macAddress() } || $client->id() || '');
                $mac =~ s/[^a-f0-9]//g;
                $syncing_clients{$mac} = 1;
                $last_marantz_synced_vol{$mac} = $vol;
                $last_marantz_vol_sync_time{$mac} = time();
                _debugLog("[MIXER SYNC] Aligning LMS mixer volume to $vol for client $mac");
                eval { $client->execute(['mixer', 'volume', $vol]); };
                eval { $client->volume($vol); };
                my $timer_clear = sub { $syncing_clients{$mac} = 0; };
                Slim::Utils::Timers::setTimer(undef, $now + 1.5, $timer_clear);
            }
        };
        Slim::Utils::Timers::setTimer(undef, $now + 2.0, $timer_sub3);
        push @{ $zone_pending_timers{$zone} }, $timer_sub3;
    }
}

# --------------------------------------------------------------------------
# HTTP Request Dispatcher: Fully asynchronous native LMS networking
# --------------------------------------------------------------------------
sub _sendHttpRequest {
    my $url = shift;
    return unless $url;

    _debugLog("[HTTP OUT] GET $url");
    eval {
        require Slim::Networking::SimpleAsyncHTTP;
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $res = shift;
                my $code = eval { $res->responseCode() } || 200;
                _debugLog("[HTTP RESP] $url -> Success (HTTP $code)");
            },
            sub {
                my ($http, $error) = @_;
                _warnLog("[HTTP ERROR] $url -> Failed/Timeout: " . ($error || 'Network timeout or unreachable'));
            },
            { timeout => 3 }
        );
        $http->get($url);
    };
    if ($@) {
        _warnLog("[HTTP WARN] SimpleAsyncHTTP error: $@");
    }
}

# --------------------------------------------------------------------------
# Volume Sync: Lyrion -> Marantz (User moves LMS slider -> sent to AVR)
# --------------------------------------------------------------------------
sub volumeCallback {
    my $request = shift;
    my $client = $request ? $request->client() : undef;
    return unless $client;

    if ($request->isCommand([['mixer'], ['volume']])) {
        my $mac = lc(eval { $client->macAddress() } || $client->id() || '');
        $mac =~ s/[^a-f0-9]//g;
        my $client_name = eval { $client->name() } || $mac;

        # Prevent circular feedback loops when volume is updated by Marantz sync
        if ($syncing_clients{$mac}) {
            _debugLog("[MIXER LOOP GUARD] Volume change for $mac suppressed (originates from Marantz sync).");
            return;
        }

        my $volume = int($client->volume());
        $volume = 0 if $volume < 0;
        $volume = 98 if $volume > 98;

        # Check if the volume in LMS matches what was just synced from Marantz in the last 2.5s (echo guard)
        my $now = time();
        if (defined $last_marantz_synced_vol{$mac} && $last_marantz_synced_vol{$mac} == $volume && ($now - ($last_marantz_vol_sync_time{$mac} || 0) < 3)) {
            _debugLog("[MIXER ECHO GUARD] Volume $volume matches recent Marantz sync, suppressing echo back to AVR.");
            return;
        }

        my $ip = _getTargetIp();
        my $port = _getTargetPort();
        unless ($ip) {
            _debugLog("[VOLUME] Marantz IP not configured, skipping volume sync for '$client_name'");
            return;
        }

        my $zone_cmd = getClientZone($client);
        if ($zone_cmd) {
            # Format volume with 2 digits (e.g. MV05 instead of MV5) to prevent volume jumping to 50 on AVR
            my $vol_formatted = sprintf("%02d", $volume);
            my $url = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$zone_cmd$vol_formatted";
            _infoLog("[VOLUME OUT] LMS '$client_name' ($volume) -> Marantz (Zone $zone_cmd): $url");
            _sendHttpRequest($url);
        } else {
            _debugLog("[VOLUME] Player '$client_name' ($mac) does not match Zone 1 or Zone 2 MAC.");
        }
    }
}

# --------------------------------------------------------------------------
# Helper: Determine Zone ('MV' or 'Z2') for Client
# --------------------------------------------------------------------------
sub getClientZone {
    my $client = shift;
    return '' unless $client;

    my $mac = lc(eval { $client->macAddress() } || $client->id() || '');
    $mac =~ s/[^a-f0-9]//g;

    my $mac_z1 = lc($prefs->get('mac_z1') || '');
    $mac_z1 =~ s/[^a-f0-9]//g;

    my $mac_z2 = lc($prefs->get('mac_z2') || '');
    $mac_z2 =~ s/[^a-f0-9]//g;

    # 1. If Zone 1 MAC matches explicitly
    if ($mac_z1 && $mac && $mac eq $mac_z1) {
        return 'MV';
    }

    # 2. If Zone 2 MAC matches explicitly
    if ($mac_z2 && $mac && $mac eq $mac_z2) {
        return 'Z2';
    }

    # 3. Fallback: If mac_z1 is NOT configured and there is only 1 player or if mac_z2 is configured to a different player
    if (!$mac_z1 && (!$mac_z2 || ($mac && $mac ne $mac_z2))) {
        my @all_clients = eval { Slim::Player::Client::clients() };
        if (scalar(@all_clients) <= 1) {
            return 'MV';
        }
    }

    return '';
}

# --------------------------------------------------------------------------
# Playback Monitoring & Polling Management
# --------------------------------------------------------------------------
sub shouldPollMarantz {
    my $ip = _getTargetIp();
    return 0 unless $ip;

    # 1. Continuous Polling: If bidirectional volume sync is enabled, ALWAYS keep background polling running!
    my $sync_vol = $prefs->get('sync_volume');
    if ($sync_vol) {
        return 1;
    }

    # 2. Playback / Auto-Resume monitoring: Check connected players
    my @clients = eval { Slim::Player::Client::clients() };
    for my $client (@clients) {
        next unless $client;
        my $zone = getClientZone($client);
        next unless $zone;

        # Active playing player
        if ($client->isPlaying()) {
            return 1;
        }

        # Auto-resume monitoring when paused or stopped with resume enabled
        my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
        if ($resume_enabled && ($zone_awaiting_resume{$zone} || $client->isPaused())) {
            return 1;
        }
    }
    return 0;
}

sub checkAndManagePolling {
    my $should_poll = shouldPollMarantz();
    if ($should_poll) {
        _debugLog("[POLL MANAGER] Active receiver and player configuration. Ensuring background polling timer is running.");
        startPollingTimer();
    } else {
        _debugLog("[POLL MANAGER] No active player or sync enabled. Stopping background polling timer.");
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
    eval { Slim::Utils::Timers::killTimers(undef, \&pollTimerCallback); };
}

sub pollTimerCallback {
    unless (shouldPollMarantz()) {
        _debugLog("[POLL TIMER] Condition not met during tick. Polling paused.");
        return;
    }

    pollActiveMarantzZones();

    # Schedule next poll cycle
    my $interval = int($prefs->get('poll_interval') || 2);
    $interval = 2 if $interval < 1;
    $interval = 10 if $interval > 10;

    my $now = eval { require Time::HiRes; Time::HiRes::time() } || time();
    require Slim::Utils::Timers;
    Slim::Utils::Timers::setTimer(undef, $now + $interval, \&pollTimerCallback);
}

# --------------------------------------------------------------------------
# Volume Sync & Status Polling: Marantz -> Lyrion
# --------------------------------------------------------------------------
sub pollActiveMarantzZones {
    my $ip = _getTargetIp();
    my $port = _getTargetPort();
    return unless $ip;

    my %active_zones;
    my $sync_vol = $prefs->get('sync_volume');
    my @clients = eval { Slim::Player::Client::clients() };

    for my $client (@clients) {
        next unless $client;
        my $zone = getClientZone($client);
        next unless $zone;

        # If sync_volume is enabled, keep zone active for volume sync
        if ($sync_vol) {
            $active_zones{$zone} ||= $client;
        } elsif ($client->isPlaying()) {
            $active_zones{$zone} ||= $client;
        } elsif ($client->isPaused()) {
            my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
            if ($resume_enabled) {
                $active_zones{$zone} ||= $client;
            }
        } elsif (!$client->isPlaying()) {
            my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
            if ($resume_enabled && $zone_awaiting_resume{$zone}) {
                $active_zones{$zone} ||= $client;
            }
        }
    }

    # Fallback auto-map: If sync_volume is enabled and at least one player is connected,
    # but Zone 1 has not been matched explicitly yet, map the primary connected player to Main Zone
    if ($sync_vol && scalar(@clients) > 0 && !$active_zones{'MV'}) {
        my $primary_client = $clients[0];
        my $z2_client = $active_zones{'Z2'};
        if (!$z2_client || ($primary_client->id() ne $z2_client->id())) {
            $active_zones{'MV'} = $primary_client;
        }
    }

    if ($active_zones{'MV'}) {
        _debugLog("[POLL OUT] Polling Main Zone XML status from $ip:$port...");
        _queryMarantzStatus($ip, $port, 'MV', 'formMainZone_MainZoneXmlStatusLite.xml', $active_zones{'MV'});
    }
    if ($active_zones{'Z2'}) {
        _debugLog("[POLL OUT] Polling Zone 2 XML status from $ip:$port...");
        _queryMarantzStatus($ip, $port, 'Z2', 'formZone2_Zone2XmlStatusLite.xml', $active_zones{'Z2'});
    }
}

sub _queryMarantzStatus {
    my ($ip, $port, $zone, $endpoint, $client) = @_;
    my $url = "http://$ip:$port/goform/$endpoint";

    require Slim::Networking::SimpleAsyncHTTP;
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $res = shift;
            my $content = eval { $res->content() } || eval { $res->result() } || '';
            _debugLog("[POLL RESP] Received XML status for Zone $zone (" . length($content) . " bytes)");
            _handleMarantzXmlResponse($content, $zone, $client);
        },
        sub {
            my ($http, $error) = @_;
            _debugLog("[POLL ERROR] Zone $zone XML query ($endpoint) failed: " . ($error || 'Network error'));
            # Fallback to standard non-Lite XML if Lite is unsupported
            if ($endpoint =~ /Lite\.xml$/) {
                my $fallback_endpoint = $endpoint;
                $fallback_endpoint =~ s/Lite\.xml$/\.xml/;
                my $fallback_url = "http://$ip:$port/goform/$fallback_endpoint";
                my $http_fallback = Slim::Networking::SimpleAsyncHTTP->new(
                    sub {
                        my $res2 = shift;
                        my $c2 = eval { $res2->content() } || eval { $res2->result() } || '';
                        _handleMarantzXmlResponse($c2, $zone, $client);
                    },
                    sub {},
                    { timeout => 3 }
                );
                $http_fallback->get($fallback_url);
            }
        },
        { timeout => 3 }
    );
    $http->get($url);
}

# --------------------------------------------------------------------------
# XML Tag Value Extractor Helper
# Extracts value from <Tag><value>...</value></Tag> or <Tag>...</Tag> robustly
# --------------------------------------------------------------------------
sub _extractXmlTagValue {
    my ($xml, $tag) = @_;
    return undef unless defined $xml && defined $tag;

    if ($xml =~ /<$tag\b[^>]*>(.*?)<\/$tag>/si) {
        my $inner = $1;
        # Check for nested <value>...</value>
        if ($inner =~ /<value\b[^>]*>([^<]*)<\/value>/si) {
            my $v = $1;
            $v =~ s/^\s+|\s+$//g;
            return $v;
        }
        # Direct text inside tag (stripping any nested XML elements)
        my $clean = $inner;
        $clean =~ s/<[^>]+>//g;
        $clean =~ s/^\s+|\s+$//g;
        return $clean if $clean ne '';
    }
    return undef;
}

sub _handleMarantzXmlResponse {
    my ($content, $zone, $client) = @_;
    return unless $content && $client;

    my $client_name = eval { $client->name() } || $client->id() || 'player';

    # Extract Power status (Zone 1 vs Zone 2 scoped tags)
    my $raw_power = ($zone eq 'Z2')
        ? (_extractXmlTagValue($content, 'Zone2Power') // _extractXmlTagValue($content, 'zone2Power') // _extractXmlTagValue($content, 'zonePower') // _extractXmlTagValue($content, 'Power'))
        : (_extractXmlTagValue($content, 'ZonePower')  // _extractXmlTagValue($content, 'zonePower')  // _extractXmlTagValue($content, 'Power'));

    $raw_power = uc($raw_power) if defined $raw_power;

    # Extract Input Source (Zone 1 vs Zone 2 scoped tags)
    my $raw_input = ($zone eq 'Z2')
        ? (_extractXmlTagValue($content, 'Zone2InputFuncSelect') // _extractXmlTagValue($content, 'zone2InputFuncSelect') // _extractXmlTagValue($content, 'InputFuncSelect'))
        : (_extractXmlTagValue($content, 'InputFuncSelect'));

    $raw_input = uc($raw_input) if defined $raw_input;

    # Record previous power and source states to detect physical AVR transitions
    my $prev_power  = $receiver_power_state{$zone}  || 'UNKNOWN';
    my $prev_source = $receiver_source_state{$zone} || 'UNKNOWN';

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

    if (defined $raw_input && $raw_input ne '') {
        $receiver_source_state{$zone} = $raw_input;
    }

    my $configured_source = ($zone eq 'MV') ? $prefs->get('source_z1') : $prefs->get('source_z2');
    my $source_matches = 1;
    if (!$is_standby && defined $raw_input && $raw_input ne '') {
        $source_matches = _isSourceMatch($configured_source, $raw_input);
    }

    _debugLog(sprintf("[XML PARSE] Zone %s: Power='%s' | Source reported='%s' (configured='%s', match=%d)", 
        $zone, $raw_power // 'N/A', $raw_input // 'N/A', $configured_source // 'N/A', $source_matches));

    # --------------------------------------------------------------------------
    # 1. Volume Sync: Marantz -> Lyrion (When sync_volume is enabled)
    # --------------------------------------------------------------------------
    if ($prefs->get('sync_volume')) {
        # Robustly extract volume regardless of tag name casing or nested structure
        my $raw_vol_text = ($zone eq 'Z2')
            ? (_extractXmlTagValue($content, 'Zone2Volume') // _extractXmlTagValue($content, 'zone2Volume') // _extractXmlTagValue($content, 'ZoneVolume') // _extractXmlTagValue($content, 'zoneVolume') // _extractXmlTagValue($content, 'MasterVolume') // _extractXmlTagValue($content, 'Volume'))
            : (_extractXmlTagValue($content, 'MasterVolume') // _extractXmlTagValue($content, 'MasterVolumeDisp') // _extractXmlTagValue($content, 'zoneVolume') // _extractXmlTagValue($content, 'ZoneVolume') // _extractXmlTagValue($content, 'Volume'));

        # Extract VolumeDisplay mode (RELATIVE vs ABSOLUTE)
        my $vol_display = _extractXmlTagValue($content, 'VolumeDisplay');
        my $is_relative = (defined $vol_display && uc($vol_display) eq 'RELATIVE') ? 1 : 0;

        if (defined $raw_vol_text) {
            my $raw = $raw_vol_text;
            $raw =~ s/^\s+|\s+$//g;

            my $vol;
            if ($raw eq '--' || $raw eq '--dB' || $raw eq '-- dB') {
                # Receiver is muted or below minimum threshold
                $vol = 0;
            } else {
                # Strip spaces and 'dB' suffix
                my $clean_raw = $raw;
                $clean_raw =~ s/[^\d\.\+\-]//g;

                if ($clean_raw =~ /^-([\d\.]+)$/) {
                    # Negative dB (e.g. -45.0 dB -> 80 - 45 = 35)
                    $vol = int(80 - $1 + 0.5);
                } elsif ($clean_raw =~ /^\+([\d\.]+)$/) {
                    # Positive dB above 0dB (e.g. +2.0 dB -> 80 + 2 = 82)
                    $vol = int(80 + $1 + 0.5);
                } elsif ($is_relative) {
                    if ($clean_raw =~ /^0(?:\.0+)?$/) {
                        $vol = 80; # 0.0 dB reference level in Relative mode
                    } elsif ($clean_raw =~ /^([\d\.]+)$/) {
                        $vol = int(80 + $1 + 0.5);
                    }
                } else {
                    # Direct numeric absolute scale (0 to 98)
                    if ($clean_raw =~ /^([\d\.]+)$/) {
                        $vol = int($1 + 0.5);
                    }
                }
            }

            if (defined $vol) {
                $vol = 0 if $vol < 0;
                $vol = 100 if $vol > 100;

                my $current_vol = int($client->volume() || 0);

                # Only update LMS mixer if volume actually changed
                if (abs($vol - $current_vol) >= 1) {
                    my $mac = lc(eval { $client->macAddress() } || $client->id() || '');
                    $mac =~ s/[^a-f0-9]//g;

                    _infoLog("[VOLUME SYNC] Marantz ($vol) -> LMS '$client_name' (was $current_vol). Updating LMS slider.");
                    $syncing_clients{$mac} = 1;
                    $last_marantz_synced_vol{$mac} = $vol;
                    $last_marantz_vol_sync_time{$mac} = time();

                    # Dispatch mixer volume command and update player volume directly
                    eval { $client->execute(['mixer', 'volume', $vol]); };
                    eval { $client->volume($vol); };

                    # Keep loop guard active for 1.5s window to ensure async event loop echoes are suppressed
                    my $now_hires = eval { require Time::HiRes; Time::HiRes::time() } || time();
                    require Slim::Utils::Timers;
                    Slim::Utils::Timers::setTimer(undef, $now_hires + 1.5, sub {
                        $syncing_clients{$mac} = 0;
                    });
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
        # Grace period: do not pause within 15 seconds of starting playback/power-on or source switch
        my $now = time();
        my $last_start = $last_poweron_time{$zone} || 0;
        if ($now - $last_start < 15) {
            my $rem = 15 - ($now - $last_start);
            _debugLog(sprintf("[FAIL-SAFE GRACE PERIOD] Zone %s: Playback transition in progress (%ds grace remaining). Auto-pause suppressed.", $zone, $rem));
            $mismatch_counter{$zone} = 0;
            return;
        }

        # 3-stage verification to prevent false triggers during AVR input switching
        if ($is_standby || !$source_matches) {
            $mismatch_counter{$zone} = ($mismatch_counter{$zone} || 0) + 1;
            _debugLog(sprintf("[FAIL-SAFE AUTO-PAUSE] Zone %s mismatch detected (%d/3 checks) | Standby=%d, SourceMatch=%d, Reported='%s', Configured='%s'",
                $zone, $mismatch_counter{$zone}, $is_standby, $source_matches, $raw_input // 'N/A', $configured_source // 'N/A'));

            if ($mismatch_counter{$zone} >= 3) {
                $mismatch_counter{$zone} = 0;
                if ($client->isPlaying()) {
                    _infoLog("[FAIL-SAFE TRIGGER] Auto-Pausing '$client_name' (Zone $zone) because AVR is " . ($is_standby ? 'STANDBY' : 'ON') . " and source is '$raw_input' (configured '$configured_source')");
                    $internal_auto_pause{$zone} = 1;
                    $zone_awaiting_resume{$zone} = 1;
                    $zone_is_playing{$zone} = 0;
                    $client->execute(['pause', 1]);
                }
            }
        } else {
            # Verified active and correct source: clear counter
            $mismatch_counter{$zone} = 0;
        }
    }

    # Arm awaiting_resume whenever receiver is confirmed in standby or on a different input
    if ($is_standby || !$source_matches) {
        if (!$client->isPlaying()) {
            $zone_awaiting_resume{$zone} = 1;
        }
    }

    # --------------------------------------------------------------------------
    # 3. Fail-Safe Auto-Resume on Source Selection (Paused/Stopped -> Resume)
    # --------------------------------------------------------------------------
    my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
    if ($resume_enabled && !$client->isPlaying()) {
        my $power_turned_on = ($prev_power eq 'STANDBY' && !$is_standby);
        my $source_switched_to_lyrion = ($prev_source ne 'UNKNOWN' && !_isSourceMatch($configured_source, $prev_source) && $source_matches);
        my $should_resume = (!$is_standby && $source_matches && ($zone_awaiting_resume{$zone} || $power_turned_on || $source_switched_to_lyrion));

        if ($should_resume) {
            $match_counter{$zone} = ($match_counter{$zone} || 0) + 1;
            _debugLog(sprintf("[FAIL-SAFE AUTO-RESUME] Zone %s match confirmed (%d/2 checks) | Source=%s | AwaitingResume=%d | PwrTurnedOn=%d | SrcSwitched=%d",
                $zone, $match_counter{$zone}, $raw_input // '', $zone_awaiting_resume{$zone} || 0, $power_turned_on ? 1 : 0, $source_switched_to_lyrion ? 1 : 0));

            # Require 2 consecutive matching poll cycles to prevent false resumes when user cycles inputs via remote
            if ($match_counter{$zone} >= 2) {
                $match_counter{$zone} = 0;
                $zone_awaiting_resume{$zone} = 0;
                $mismatch_counter{$zone} = 0;
                $last_poweron_time{$zone} = time();
                $zone_is_playing{$zone} = 1;

                _infoLog("[FAIL-SAFE TRIGGER] Auto-Resuming '$client_name' (Zone $zone) because AVR is ON and source matches '$configured_source'");
                if ($client->isPaused()) {
                    $client->execute(['pause', 0]);
                } elsif ($client->isStopped()) {
                    $client->execute(['play']);
                }
            }
        } else {
            $match_counter{$zone} = 0;
        }
    }
}

sub _isSourceMatch {
    my ($configured, $reported) = @_;
    return 1 unless defined $configured && defined $reported;

    my $c = uc($configured);
    my $r = uc($reported);

    # Strip SI or Z2 prefixes and non-alphanumerics
    $c =~ s/^(?:SI|Z2)//;
    $r =~ s/^(?:SI|Z2)//;
    $c =~ s/[^A-Z0-9]//g;
    $r =~ s/[^A-Z0-9]//g;

    return 1 if $c eq '' || $r eq '';

    # Normalize common Denon/Marantz source name aliases
    my %aliases = (
        'CBLSAT'        => 'SATCBL',
        'SATCBL'        => 'SATCBL',
        'MPLAY'         => 'MEDIAPLAYER',
        'MEDIAPLAYER'   => 'MEDIAPLAYER',
        'NET'           => 'HEOS',
        'HEOS'          => 'HEOS',
        'INTERNETRADIO' => 'HEOS',
        'BLUETOOTH'     => 'BT',
        'BT'            => 'BT',
        'BLURAY'        => 'BD',
        'BD'            => 'BD',
        'TVAUDIO'       => 'TV',
        'TV'            => 'TV',
        'AUX1'          => 'AUX1',
        'AUX2'          => 'AUX2',
        'GAME1'         => 'GAME',
        'GAME'          => 'GAME',
        'PHONO'         => 'PHONO',
        'TUNER'         => 'TUNER',
        'USBIPOD'       => 'USB',
        'USB'           => 'USB',
    );

    $c = $aliases{$c} if exists $aliases{$c};
    $r = $aliases{$r} if exists $aliases{$r};

    return 1 if $c eq $r;

    # Safer boundary matching: only if both are sufficiently specific (>= 4 chars) and start with each other
    if (length($c) >= 4 && length($r) >= 4) {
        return 1 if (index($r, $c) == 0 || index($c, $r) == 0);
    }

    return 0;
}

1;
