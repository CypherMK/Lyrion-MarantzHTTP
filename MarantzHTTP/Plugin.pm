package Plugins::MarantzHTTP::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our $VERSION = '1.9.0';

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
    set_sound_mode_on_power_z1  => 0,        # 1 to enforce sound mode on startup
    sound_mode_z1               => '',       # e.g. 'MSSTEREO', 'MSDIRECT', 'MSPURE DIRECT', 'MSMCH STEREO'
    set_room_preset_on_power_z1 => 0,        # 1 to enforce Dirac / Audyssey preset on startup
    room_preset_z1              => '',       # e.g. 'SPPR 1', 'SPPR 2', 'PSDIRAC 1', 'PSMULTEQ:AUDYSSEY'
    set_volume_on_power_z1      => 1,
    power_volume_z1             => 40,
    pause_on_off_or_source_z1   => 1,
    resume_on_source_z1         => 1,
    play_playlist_on_power_z1   => 0,
    playlist_type_z1            => 'standard', # 'standard' or 'dynamic' (via Dynamic Playlists v4.7.1)
    playlist_z1                 => '',
    dynamic_playlist_z1         => '',
    shuffle_z1                  => 0,
    play_only_if_empty_z1       => 0,
    power_on_z2                 => 0,
    source_z2                   => 'Z2NET',
    set_volume_on_power_z2      => 0,
    power_volume_z2             => 30,
    pause_on_off_or_source_z2   => 0,
    resume_on_source_z2         => 0,
    play_playlist_on_power_z2   => 0,
    playlist_type_z2            => 'standard', # 'standard' or 'dynamic' (via Dynamic Playlists v4.7.1)
    playlist_z2                 => '',
    dynamic_playlist_z2         => '',
    shuffle_z2                  => 0,
    play_only_if_empty_z2       => 0,
    sync_volume                 => 1,
    poll_interval               => 2,
});

my %syncing_clients;
my %last_marantz_synced_vol;
my %last_marantz_vol_sync_time;
my %last_poweron_time;
my %last_playlist_start_time;
my %mismatch_counter;
my %match_counter;
my %receiver_power_state;     # 'ON' or 'STANDBY'
my %receiver_source_state;    # last reported source (e.g. 'SAT/CBL', 'GAME1')
my %receiver_surround_state;  # last reported surround/sound mode (e.g. 'STEREO', 'MCH STEREO')
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

sub _formatSoundModeCmd {
    my $mode = shift;
    return '' unless defined $mode;
    $mode =~ s/^\s+|\s+$//g;
    $mode =~ s/^\?//;
    return '' if $mode eq '' || $mode eq 'NONE';
    # Normalize: Marantz surround direct command starts with 'MS' (e.g. MSSTEREO, MSDIRECT, MSMCH STEREO, MSVIRTUAL)
    $mode = 'MS' . $mode unless ($mode =~ /^MS/i);
    return $mode;
}

# Clean sound mode dispatcher
sub _sendSoundModeCommand {
    my ($ip, $port, $sound_mode_cmd, $zone) = @_;
    return unless $ip && $sound_mode_cmd;

    $sound_mode_cmd =~ s/^\s+|\s+$//g;
    return if $sound_mode_cmd eq '' || $sound_mode_cmd eq 'NONE';

    my $url_sound_mode = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$sound_mode_cmd";
    _infoLog("[ACTION OUT] Dispatching Sound Mode command: $sound_mode_cmd -> $url_sound_mode");
    _sendHttpRequest($url_sound_mode);
}

sub _formatRoomPresetCmd {
    my $preset = shift;
    return '' unless defined $preset;
    $preset =~ s/^\s+|\s+$//g;
    $preset =~ s/^\?//;
    return '' if $preset eq '' || $preset eq 'NONE';
    return $preset;
}

# Clean Dirac / Audyssey room calibration preset dispatcher
sub _sendRoomPresetCommand {
    my ($ip, $port, $preset_cmd, $zone) = @_;
    return unless $ip && $preset_cmd;

    $preset_cmd =~ s/^\s+|\s+$//g;
    return if $preset_cmd eq '' || $preset_cmd eq 'NONE';

    my $url_preset = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$preset_cmd";
    _infoLog("[ACTION OUT] Dispatching Dirac/Audyssey Preset command: $preset_cmd -> $url_preset");
    _sendHttpRequest($url_preset);
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
        $prefs->setChange(\&checkAndManagePolling, qw(sync_volume poll_interval ip port mac_z1 mac_z2 power_on_z1 source_z1 set_sound_mode_on_power_z1 sound_mode_z1 set_room_preset_on_power_z1 room_preset_z1 play_playlist_on_power_z1 playlist_type_z1 playlist_z1 dynamic_playlist_z1 shuffle_z1 play_only_if_empty_z1 power_on_z2 source_z2 play_playlist_on_power_z2 playlist_type_z2 playlist_z2 dynamic_playlist_z2 shuffle_z2 play_only_if_empty_z2));
    };

    # Register AJAX playlists and receiver detection endpoints
    eval {
        require Slim::Web::Pages;
        Slim::Web::Pages->addPageFunction('plugins/MarantzHTTP/playlists.json', \&Plugins::MarantzHTTP::Settings::getPlaylistsAjax);
        Slim::Web::Pages->addPageFunction('settings/plugins/MarantzHTTP/playlists.json', \&Plugins::MarantzHTTP::Settings::getPlaylistsAjax);
        Slim::Web::Pages->addPageFunction('plugins/MarantzHTTP/detect.json', \&Plugins::MarantzHTTP::Settings::detectReceiverAjax);
        Slim::Web::Pages->addPageFunction('settings/plugins/MarantzHTTP/detect.json', \&Plugins::MarantzHTTP::Settings::detectReceiverAjax);
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

    # 2. Strictly ignore Stop commands, track jump/seek/index/time
    if ($request->isCommand([['stop']]) || 
        $request->isCommand([['playlist'], ['stop']]) || 
        $request->isCommand([['playlist'], ['jump']]) || 
        $request->isCommand([['playlist'], ['index']]) ||
        $request->isCommand([['time']])) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': command is stop/jump/index/time ('$req_str')");
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

    # 5. Check if playback is ALREADY active and AVR is already ON and on correct source:
    # Gapless playback prebuffering (LMS issues 'playlist open' ~10s before track end),
    # seeking inside the current track, or transitioning between playlist tracks should
    # NEVER re-trigger power or source commands when everything is already running!
    my $configured_source = ($zone eq 'MV') ? $prefs->get('source_z1') : $prefs->get('source_z2');
    my $is_already_on = ($receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON');
    my $is_source_match = ($receiver_source_state{$zone} && _isSourceMatch($configured_source, $receiver_source_state{$zone}));

    if ($client->isPlaying() && $zone_is_playing{$zone} && $is_already_on && $is_source_match) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': playback already active and receiver confirmed ON on correct source ('$req_str')");
        return;
    }

    # 6. Playback confirmed active or starting! Ensure receiver is ON and set to Lyrion source!
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
        my $sm_log = $prefs->get('set_sound_mode_on_power_z1') ? _formatSoundModeCmd($prefs->get('sound_mode_z1')) : 'DISABLED';

        _infoLog(sprintf("[TRIGGER] Ensuring Power & Source for Main Zone ('%s') | Reason: %s | PowerCmd: %s | Source: %s | SoundMode: %s | InitialVol: %s | AVR: %s",
            $client_name, $reason || 'Play Trigger', $power_cmd // 'NONE', $source_cmd // 'NONE', $sm_log || 'DISABLED', defined $vol ? $vol : 'PRESERVED', $is_already_on ? 'ON' : 'STANDBY/UNKNOWN'));

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

            my $is_newsong = ($request->isCommand([['playlist'], ['newsong']]) || 
                              $request->isCommand([['playlist'], ['open']]) || 
                              $request->isCommand([['time']]) ||
                              $req_str =~ /\b(?:newsong|open|time)\b/i);
            my $is_already_active = ($zone_is_playing{$zone} && 
                                     $receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON' &&
                                     $receiver_source_state{$zone} && _isSourceMatch($configured_source, $receiver_source_state{$zone}));

            # Avoid track-change and seek audio dropouts: Do NOT send power/source switch commands if AVR is already ON and playing
            if ($is_newsong || $is_already_active) {
                $zone_is_playing{$zone} = 1;
                _debugLog("[PLAYBACK] Track transition, seek or steady playback on '$client_name' (Zone $zone). Receiver confirmed ON and on correct source. Suppressed redundant commands.");
            } elsif ($now - $last_start > 4 && !$receiver_is_on_other_source && (!$receiver_power_state{$zone} || $receiver_power_state{$zone} ne 'ON')) {
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

    # 2b. Sound Mode command (Main Zone - Stereo, Direct, Multi Ch Stereo, Virtual, etc.)
    # ONLY executed upon initial power-on from Standby/Off to prevent audio interruptions during playback!
    if ($zone eq 'MV' && !$is_already_on) {
        my $sound_mode_cmd = _formatSoundModeCmd($prefs->get('sound_mode_z1'));
        my $sound_mode_enabled = $prefs->get('set_sound_mode_on_power_z1') ? 1 : 0;
        if ($sound_mode_enabled && $sound_mode_cmd) {
            # Stagger dispatch after power and source (+1.6s delay) so audio DSP/DAC is initialized
            _debugLog("[ACTION OUT] Scheduling initial power-on Sound Mode command: $sound_mode_cmd (+1600ms delay)");
            my $timer_sub_sm = sub {
                _debugLog("[ACTION OUT] Executing delayed Sound Mode command on power-on: $sound_mode_cmd");
                _sendSoundModeCommand($ip, $port, $sound_mode_cmd, $zone);
            };
            Slim::Utils::Timers::setTimer(undef, $now + 1.6, $timer_sub_sm);
            push @{ $zone_pending_timers{$zone} }, $timer_sub_sm if $zone_pending_timers{$zone};
        }

        # 2c. Dirac / Audyssey Room Calibration Preset command (Main Zone)
        my $room_preset_cmd = _formatRoomPresetCmd($prefs->get('room_preset_z1'));
        my $room_preset_enabled = $prefs->get('set_room_preset_on_power_z1') ? 1 : 0;
        if ($room_preset_enabled && $room_preset_cmd) {
            # Stagger dispatch (+1.8s delay) right after sound mode so audio DSP is ready
            _debugLog("[ACTION OUT] Scheduling initial power-on Dirac/Audyssey Preset command: $room_preset_cmd (+1800ms delay)");
            my $timer_sub_rp = sub {
                _debugLog("[ACTION OUT] Executing delayed Dirac/Audyssey Preset command on power-on: $room_preset_cmd");
                _sendRoomPresetCommand($ip, $port, $room_preset_cmd, $zone);
            };
            Slim::Utils::Timers::setTimer(undef, $now + 1.8, $timer_sub_rp);
            push @{ $zone_pending_timers{$zone} }, $timer_sub_rp if $zone_pending_timers{$zone};
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

    # 4. Startup Playlist Autoplay on Receiver Power-ON
    if (!$is_already_on && $power_cmd) {
        _playConfiguredPlaylist($client, $zone, 'Plugin Power-On Command');
    }
}

# --------------------------------------------------------------------------
# Startup Playlist Autoplay Manager
# Loads and plays selected playlist from playlist folder with optional shuffle
# --------------------------------------------------------------------------
sub _loadAndPlayPlaylist {
    my ($client, $playlist, $shuffle) = @_;
    return unless $client && defined $playlist && $playlist ne '';

    my $client_name = eval { $client->name() } || $client->id() || 'player';
    _infoLog("[AUTOPLAY TASK] Start playlist inladen: '$playlist' voor '$client_name' (Shuffle: $shuffle)");

    # 1. Stop en wis eventuele bestaande wachtrij
    eval { $client->execute(['playlist', 'clear']); };

    # 2. Stel shuffle modus in (1 = tracks, 0 = uit)
    eval { $client->execute(['playlist', 'shuffle', $shuffle ? 1 : 0]); };

    # 3. Detecteer type playlist: bestandspad, URL of database naam/ID
    my $url_to_play = '';
    if ($playlist =~ m{^(?:file|https?|db):}i) {
        $url_to_play = $playlist;
    } elsif (-f $playlist) {
        $url_to_play = "file://$playlist";
    }

    # Zoek indien nodig via Slim::Schema
    unless ($url_to_play) {
        eval {
            require Slim::Schema;
            my $pl_obj = Slim::Schema->single('Playlist', { 'title' => $playlist })
                      || Slim::Schema->find('Playlist', $playlist)
                      || Slim::Schema->objectForUrl({ 'url' => $playlist, playlist => 1 })
                      || Slim::Schema->objectForUrl({ 'url' => "file://$playlist", playlist => 1 });
            if ($pl_obj && eval { $pl_obj->can('url') }) {
                $url_to_play = $pl_obj->url;
            }
        };
    }

    # 4. Voer de LMS laad-opdracht uit
    if ($url_to_play) {
        _infoLog("[AUTOPLAY TASK] Playlist afspelen via URL: $url_to_play");
        eval { $client->execute(['playlist', 'play', $url_to_play]); };
    } else {
        _infoLog("[AUTOPLAY TASK] Playlist afspelen via playlistcontrol / title: $playlist");
        eval {
            require Slim::Control::Request;
            Slim::Control::Request::executeRequest($client, ['playlistcontrol', 'cmd:load', "playlist_name:$playlist"]);
        };
        # Fallback directe play
        eval { $client->execute(['playlist', 'play', $playlist]); };
    }

    # 5. Bevestig nummer-shuffle en forceer Play
    if ($shuffle) {
        eval { $client->execute(['playlist', 'shuffle', 1]); };
    } else {
        eval { $client->execute(['playlist', 'shuffle', 0]); };
    }
    eval { $client->execute(['play']); };
    _infoLog("[AUTOPLAY TASK] Playlist succesvol gestart op '$client_name'!");
}

# --------------------------------------------------------------------------
# Dynamic Playlists (v4.7.1) Manager: Continuous Smart Playlist Execution
# --------------------------------------------------------------------------
sub _loadAndPlayDynamicPlaylist {
    my ($client, $dpl_id, $shuffle) = @_;
    return unless $client && defined $dpl_id && $dpl_id ne '';

    my $client_name = eval { $client->name() } || $client->id() || 'player';
    _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Starten van Dynamic Playlist: '$dpl_id' voor '$client_name' (Shuffle: $shuffle)");

    # 1. Bepaal kandidaat ID's (bijv. 'topliedjes' -> 'dplccustom_topliedjes', 'sqlplaylist_topliedjes', etc.)
    my $clean_id = $dpl_id;
    $clean_id =~ s/^\s+|\s+$//g;

    my @candidate_ids;

    # Kijk eerst of Settings::getAvailableDynamicPlaylists een exacte match kent
    eval {
        require Plugins::MarantzHTTP::Settings;
        my $known = Plugins::MarantzHTTP::Settings::getAvailableDynamicPlaylists(0);
        if ($known && ref($known) eq 'ARRAY') {
            for my $item (@$known) {
                my $iid = $item->{id} || '';
                my $ititle = $item->{title} || '';
                my $iraw = $item->{raw_name} || '';
                if (lc($iid) eq lc($clean_id) || lc($ititle) =~ /\b\Q$clean_id\E\b/i || lc($iraw) eq lc($clean_id)) {
                    push @candidate_ids, $iid;
                    last;
                }
            }
        }
    };

    my $stripped = $clean_id;
    $stripped =~ s/\.(sql|dpl|xml)$//i;
    $stripped =~ s/^(dplccustom_|dplcustom_|dplusercustom_|sqlplaylist_|dynamicplaylist_|custom_|dplc_|dpl_|sql_)//i;

    push @candidate_ids, $clean_id;
    push @candidate_ids, lc($clean_id);
    push @candidate_ids, $stripped;
    push @candidate_ids, lc($stripped);
    push @candidate_ids, "dplccustom_" . lc($stripped);
    push @candidate_ids, "sqlplaylist_" . lc($stripped);
    push @candidate_ids, "sqlplaylist_" . lc($stripped) . ".sql";
    push @candidate_ids, lc($stripped) . ".sql";
    push @candidate_ids, "custom_" . lc($stripped);
    push @candidate_ids, "dplcustom_" . lc($stripped);
    push @candidate_ids, "dplusercustom_" . lc($stripped);

    # Ontdubbel kandidaten met behoud van volgorde
    my %seen_cands;
    @candidate_ids = grep { defined $_ && $_ ne '' && !$seen_cands{$_}++ } @candidate_ids;

    # 2. Stel shuffle in op de speler
    eval { $client->execute(['playlist', 'shuffle', $shuffle ? 1 : 0]); };

    # 3. Probeer Dynamic Playlists activatie met de kandidaat ID's
    my $activated_id = '';
    my $total_tracks = 0;

    for my $cid (@candidate_ids) {
        _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Probeer Dynamic Playlist activatie met ID: '$cid' op '$client_name'...");

        # Poging A: Standaard LMS CLI execute
        eval {
            $client->execute(['dynamicplaylist', 'playlist', 'play', $cid]);
        };

        $total_tracks = eval { $client->playlistLength() } || 0;
        if ($total_tracks > 0) {
            $activated_id = $cid;
            _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Gelukt via client->execute! Wachtrij bevat $total_tracks tracks (ID: '$cid').");
            last;
        }

        # Poging B: Slim::Control::Request
        eval {
            require Slim::Control::Request;
            Slim::Control::Request::executeRequest($client, ['dynamicplaylist', 'playlist', 'play', $cid]);
        };

        $total_tracks = eval { $client->playlistLength() } || 0;
        if ($total_tracks > 0) {
            $activated_id = $cid;
            _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Gelukt via Slim::Control::Request! Wachtrij bevat $total_tracks tracks (ID: '$cid').");
            last;
        }

        # Poging C: Alternatieve CLI syntax zonder 'playlist': ['dynamicplaylist', 'play', $cid]
        eval {
            $client->execute(['dynamicplaylist', 'play', $cid]);
        };

        $total_tracks = eval { $client->playlistLength() } || 0;
        if ($total_tracks > 0) {
            $activated_id = $cid;
            _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Gelukt via ['dynamicplaylist', 'play', '$cid']! ($total_tracks tracks).");
            last;
        }

        # Poging D: Directe Perl method aanroep indien Plugins::DynamicPlayLists::Plugin actief is
        eval {
            require Slim::Utils::PluginManager;
            if (Slim::Utils::PluginManager->isEnabled('Plugins::DynamicPlayLists::Plugin') || eval { require Plugins::DynamicPlayLists::Plugin; 1 }) {
                if (Plugins::DynamicPlayLists::Plugin->can('playPlaylist')) {
                    Plugins::DynamicPlayLists::Plugin::playPlaylist($client, $cid);
                }
            }
        };

        $total_tracks = eval { $client->playlistLength() } || 0;
        if ($total_tracks > 0) {
            $activated_id = $cid;
            _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Gelukt via Plugins::DynamicPlayLists::Plugin::playPlaylist (ID: '$cid').");
            last;
        }
    }

    # 4. Zorg dat weergave start
    eval { $client->execute(['play']); };

    if ($activated_id) {
        _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Dynamic Playlist '$activated_id' (invoer: '$dpl_id') succesvol geactiveerd op '$client_name' via Dynamic Playlists (v4.7.1)!");
    } else {
        _warnLog("[AUTOPLAY DYNAMIC v4.7.1] Dynamic Playlist '$dpl_id' kon niet direct worden gevonden onder kandidaat-ID's (" . join(', ', @candidate_ids) . "). Controleer of de playlist in Dynamic Playlist Creator of LMS bestaat.");
    }
}

sub _playConfiguredPlaylist {
    my ($client, $zone, $reason) = @_;
    return unless $client && $zone;

    my $enabled = ($zone eq 'MV') ? $prefs->get('play_playlist_on_power_z1') : $prefs->get('play_playlist_on_power_z2');
    return unless $enabled;

    my $playlist_type = ($zone eq 'MV') ? ($prefs->get('playlist_type_z1') || 'standard') : ($prefs->get('playlist_type_z2') || 'standard');

    my $playlist = '';
    if ($playlist_type eq 'dynamic') {
        $playlist = ($zone eq 'MV') ? $prefs->get('dynamic_playlist_z1') : $prefs->get('dynamic_playlist_z2');
    } else {
        $playlist = ($zone eq 'MV') ? $prefs->get('playlist_z1') : $prefs->get('playlist_z2');
    }
    return unless defined $playlist && $playlist ne '';

    my $raw_shuffle = ($zone eq 'MV') ? ($prefs->get('shuffle_z1') // 0) : ($prefs->get('shuffle_z2') // 0);
    # Enforce track shuffle only (1 = tracks, 0 = off).
    my $shuffle = ($raw_shuffle == 1) ? 1 : 0;

    my $client_name = eval { $client->name() } || $client->id() || 'player';

    # Optional check: only play if player's queue is empty
    my $only_if_empty = ($zone eq 'MV') ? $prefs->get('play_only_if_empty_z1') : $prefs->get('play_only_if_empty_z2');
    if ($only_if_empty) {
        my $is_playing = eval { $client->isPlaying() } || 0;
        my $queue_count = eval { Slim::Player::Playlist::count($client) };
        unless (defined $queue_count) {
            $queue_count = eval { scalar(@{Slim::Player::Playlist::playList($client) || []}) } || 0;
        }
        if ($queue_count > 0 || $is_playing) {
            _infoLog(sprintf("[AUTOPLAY OVERSLAAN] %s '%s' NIET gestart op '%s' (Zone %s): wachtrij bevat %d tracks (isPlaying=%d) en 'Alleen als wachtrij leeg is' is actief.",
                ($playlist_type eq 'dynamic' ? 'Dynamic Playlist' : 'Playlist'), $playlist, $client_name, $zone, $queue_count, $is_playing));
            return;
        }
    }

    my $now = time();
    # Debounce: avoid restarting playlist within 10 seconds
    if ($last_playlist_start_time{$zone} && ($now - $last_playlist_start_time{$zone} < 10)) {
        _debugLog("[AUTOPLAY] Zone $zone playlist start onderdrukt (recent trigger actief: " . ($now - $last_playlist_start_time{$zone}) . "s geleden).");
        return;
    }
    $last_playlist_start_time{$zone} = $now;
    $last_poweron_time{$zone} = $now;
    $zone_is_playing{$zone} = 1;
    $zone_awaiting_resume{$zone} = 0;

    _infoLog(sprintf("[AUTOPLAY] Marantz Inschakelen: Starten van %s '%s' op '%s' (Zone %s, Shuffle: %d, Reden: %s)",
        ($playlist_type eq 'dynamic' ? 'Dynamic Playlist' : 'Standaard Playlist'),
        $playlist, $client_name, $zone, $shuffle, $reason || 'Power On'));

    my $now_hires = eval { require Time::HiRes; Time::HiRes::time() } || time();
    require Slim::Utils::Timers;

    # Small 1.0s delay so Marantz audio DAC / HDMI / input negotiation is ready
    my $play_task = sub {
        if ($playlist_type eq 'dynamic') {
            _loadAndPlayDynamicPlaylist($client, $playlist, $shuffle);
        } else {
            _loadAndPlayPlaylist($client, $playlist, $shuffle);
        }
    };

    Slim::Utils::Timers::setTimer(undef, $now_hires + 1.0, $play_task);
    push @{ $zone_pending_timers{$zone} }, $play_task if $zone_pending_timers{$zone};
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

sub _getClientForZone {
    my $zone = shift;
    my @clients = eval { Slim::Player::Client::clients() };
    return undef unless scalar(@clients);

    my $target_mac = lc(($zone eq 'MV') ? ($prefs->get('mac_z1') || '') : ($prefs->get('mac_z2') || ''));
    $target_mac =~ s/[^a-f0-9]//g;

    if ($target_mac) {
        for my $c (@clients) {
            next unless $c;
            my $mac = lc(eval { $c->macAddress() } || $c->id() || '');
            $mac =~ s/[^a-f0-9]//g;
            return $c if $mac eq $target_mac;
        }
    }

    # Fallback for Zone 1: if only 1 player or if no explicit MAC set, use primary player
    if ($zone eq 'MV') {
        my $mac_z2 = lc($prefs->get('mac_z2') || '');
        $mac_z2 =~ s/[^a-f0-9]//g;
        for my $c (@clients) {
            next unless $c;
            my $mac = lc(eval { $c->macAddress() } || $c->id() || '');
            $mac =~ s/[^a-f0-9]//g;
            return $c if !$mac_z2 || ($mac ne $mac_z2);
        }
        return $clients[0];
    }
    return undef;
}

# --------------------------------------------------------------------------
# Playback Monitoring & Polling Management
# --------------------------------------------------------------------------
sub shouldPollMarantz {
    my $ip = _getTargetIp();
    return 0 unless $ip;

    # 1. Volume sync enabled
    return 1 if $prefs->get('sync_volume');

    # 2. Startup playlist enabled on Zone 1 or Zone 2 (MUST poll to detect receiver power-on!)
    return 1 if ($prefs->get('play_playlist_on_power_z1') || $prefs->get('play_playlist_on_power_z2'));

    # 3. Fail-safe auto-pause / auto-resume enabled on Zone 1 or Zone 2
    return 1 if ($prefs->get('pause_on_off_or_source_z1') || $prefs->get('resume_on_source_z1') ||
                 $prefs->get('pause_on_off_or_source_z2') || $prefs->get('resume_on_source_z2'));

    # 4. Any client is playing
    my @clients = eval { Slim::Player::Client::clients() };
    for my $client (@clients) {
        return 1 if $client && $client->isPlaying();
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

    my $client_z1 = _getClientForZone('MV');
    my $client_z2 = _getClientForZone('Z2');

    # Always poll Main Zone if player is available or configured
    if ($client_z1) {
        _debugLog("[POLL OUT] Polling Main Zone XML status from $ip:$port...");
        _queryMarantzStatus($ip, $port, 'MV', 'formMainZone_MainZoneXmlStatusLite.xml', $client_z1);
    }
    if ($client_z2 && ($prefs->get('mac_z2') || $prefs->get('power_on_z2') || $prefs->get('play_playlist_on_power_z2'))) {
        _debugLog("[POLL OUT] Polling Zone 2 XML status from $ip:$port...");
        _queryMarantzStatus($ip, $port, 'Z2', 'formZone2_Zone2XmlStatusLite.xml', $client_z2);
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

    # Extract Surround / Sound Mode (Zone 1)
    my $raw_surround = _extractXmlTagValue($content, 'selectSurround') 
                    // _extractXmlTagValue($content, 'SurroundMode')
                    // _extractXmlTagValue($content, 'surroundMode');
    if (defined $raw_surround && $raw_surround ne '') {
        $receiver_surround_state{$zone} = uc($raw_surround);
    }

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

    # Detect AVR Power-ON transition (STANDBY/OFF -> ON)
    my $power_turned_on = ($prev_power eq 'STANDBY' && !$is_standby);
    if ($power_turned_on) {
        _infoLog("[POWER EVENT] Marantz Zone $zone is ingeschakeld (STANDBY -> ON)!");

        # Bekrachtig geluidsmodus (Sound Mode) voor Hoofdzone indien geconfigureerd
        if ($zone eq 'MV') {
            my $sm_cmd = _formatSoundModeCmd($prefs->get('sound_mode_z1'));
            my $sm_enabled = $prefs->get('set_sound_mode_on_power_z1') ? 1 : 0;
            my $ip = _getTargetIp();
            my $port = _getTargetPort();
            if ($sm_enabled && $sm_cmd && $ip) {
                _infoLog("[POWER EVENT] Geluidsmodus bekrachtigen voor Hoofdzone bij inschakelen: $sm_cmd");
                _sendSoundModeCommand($ip, $port, $sm_cmd, $zone);
            }

            my $rp_cmd = _formatRoomPresetCmd($prefs->get('room_preset_z1'));
            my $rp_enabled = $prefs->get('set_room_preset_on_power_z1') ? 1 : 0;
            if ($rp_enabled && $rp_cmd && $ip) {
                _infoLog("[POWER EVENT] Dirac/Audyssey preset bekrachtigen voor Hoofdzone bij inschakelen: $rp_cmd");
                _sendRoomPresetCommand($ip, $port, $rp_cmd, $zone);
            }
        }

        my $play_playlist = ($zone eq 'MV') ? $prefs->get('play_playlist_on_power_z1') : $prefs->get('play_playlist_on_power_z2');
        if ($play_playlist) {
            # Zorg dat de ingangsbron bekrachtigd wordt indien geconfigureerd
            if ($configured_source && $configured_source ne '') {
                my $src_cmd = $configured_source;
                $src_cmd =~ s/^\s+|\s+$//g;
                $src_cmd =~ s/^\?//;
                my $ip = _getTargetIp();
                my $port = _getTargetPort();
                if ($ip && $src_cmd) {
                    _infoLog("[POWER EVENT] Ingangsbron bekrachtigen: $src_cmd");
                    _sendHttpRequest("http://$ip:$port/goform/formiPhoneAppDirect.xml?$src_cmd");
                }
            }

            _playConfiguredPlaylist($client, $zone, 'AVR Power-On Detected');
        }
    }

    # Detecteer wisselen van ingangsbron naar Lyrion terwijl Marantz al aan staat
    my $source_switched_to_lyrion = (!$is_standby && $prev_source ne 'UNKNOWN' && !_isSourceMatch($configured_source, $prev_source) && $source_matches);
    if ($source_switched_to_lyrion) {
        _infoLog("[SOURCE EVENT] Marantz Zone $zone bron gewijzigd naar Lyrion '$configured_source'.");

        # Bekrachtig geluidsmodus bij wisselen naar Lyrion indien gewenst
        if ($zone eq 'MV') {
            my $sm_cmd = _formatSoundModeCmd($prefs->get('sound_mode_z1'));
            my $sm_enabled = $prefs->get('set_sound_mode_on_power_z1') ? 1 : 0;
            my $ip = _getTargetIp();
            my $port = _getTargetPort();
            if ($sm_enabled && $sm_cmd && $ip) {
                _infoLog("[SOURCE EVENT] Geluidsmodus bekrachtigen voor Lyrion: $sm_cmd");
                _sendSoundModeCommand($ip, $port, $sm_cmd, $zone);
            }

            my $rp_cmd = _formatRoomPresetCmd($prefs->get('room_preset_z1'));
            my $rp_enabled = $prefs->get('set_room_preset_on_power_z1') ? 1 : 0;
            if ($rp_enabled && $rp_cmd && $ip) {
                _infoLog("[SOURCE EVENT] Dirac/Audyssey preset bekrachtigen voor Lyrion: $rp_cmd");
                _sendRoomPresetCommand($ip, $port, $rp_cmd, $zone);
            }
        }

        my $play_playlist = ($zone eq 'MV') ? $prefs->get('play_playlist_on_power_z1') : $prefs->get('play_playlist_on_power_z2');
        if ($play_playlist && !$client->isPlaying()) {
            _playConfiguredPlaylist($client, $zone, 'Source Switched to Lyrion');
        }
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
