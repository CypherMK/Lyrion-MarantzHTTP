package Plugins::MarantzHTTP::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our $VERSION = '2.0.0';

# Initialize Lyrion / LMS Logger Category
my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.marantzhttp',
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_MARANTZHTTP',
});

my $prefs = preferences('plugin.marantzhttp');

$prefs->init({
    # --- Receiver 1 (Primary) ---
    ip                          => '',
    port                        => '8080',
    sync_volume                 => 1,
    poll_interval               => 2,

    # Receiver 1 Zone 1 (Main Zone)
    mac_z1                      => '',
    power_on_z1                 => 1,
    source_z1                   => 'SISAT/CBL',
    set_sound_mode_on_power_z1  => 0,
    sound_mode_z1               => '',
    set_room_preset_on_power_z1 => 0,
    room_preset_z1              => '',
    set_volume_on_power_z1      => 1,
    power_volume_z1             => 40,
    pause_on_off_or_source_z1   => 1,
    resume_on_source_z1         => 1,
    play_playlist_on_power_z1   => 0,
    playlist_type_z1            => 'standard',
    playlist_z1                 => '',
    dynamic_playlist_z1         => '',
    shuffle_z1                  => 0,
    play_only_if_empty_z1       => 0,

    # Receiver 1 Zone 2
    mac_z2                      => '',
    power_on_z2                 => 0,
    source_z2                   => 'Z2NET',
    set_volume_on_power_z2      => 0,
    power_volume_z2             => 30,
    pause_on_off_or_source_z2   => 0,
    resume_on_source_z2         => 0,
    play_playlist_on_power_z2   => 0,
    playlist_type_z2            => 'standard',
    playlist_z2                 => '',
    dynamic_playlist_z2         => '',
    shuffle_z2                  => 0,
    play_only_if_empty_z2       => 0,

    # --- Receiver 2 (Secondary) ---
    r2_enabled                  => 0,
    r2_ip                       => '',
    r2_port                     => '8080',
    r2_sync_volume              => 1,
    r2_poll_interval            => 2,

    # Receiver 2 Zone 1 (Main Zone)
    r2_mac_z1                   => '',
    r2_power_on_z1              => 1,
    r2_source_z1                => 'SISAT/CBL',
    r2_set_sound_mode_on_power_z1 => 0,
    r2_sound_mode_z1            => '',
    r2_set_room_preset_on_power_z1 => 0,
    r2_room_preset_z1           => '',
    r2_set_volume_on_power_z1   => 1,
    r2_power_volume_z1          => 40,
    r2_pause_on_off_or_source_z1 => 1,
    r2_resume_on_source_z1      => 1,
    r2_play_playlist_on_power_z1 => 0,
    r2_playlist_type_z1         => 'standard',
    r2_playlist_z1              => '',
    r2_dynamic_playlist_z1      => '',
    r2_shuffle_z1               => 0,
    r2_play_only_if_empty_z1    => 0,

    # Receiver 2 Zone 2
    r2_mac_z2                   => '',
    r2_power_on_z2              => 0,
    r2_source_z2                => 'Z2NET',
    r2_set_volume_on_power_z2   => 0,
    r2_power_volume_z2          => 30,
    r2_pause_on_off_or_source_z2 => 0,
    r2_resume_on_source_z2      => 0,
    r2_play_playlist_on_power_z2 => 0,
    r2_playlist_type_z2         => 'standard',
    r2_playlist_z2              => '',
    r2_dynamic_playlist_z2      => '',
    r2_shuffle_z2               => 0,
    r2_play_only_if_empty_z2    => 0,
});

# Per-client state tracking for volume feedback loop prevention
my %syncing_clients;
my %last_marantz_synced_vol;
my %last_marantz_vol_sync_time;

# Independent state tracking keyed by compound key "$rec:$zone" (e.g. "1:MV", "1:Z2", "2:MV", "2:Z2")
my %receiver_power_state;     # 'ON' or 'STANDBY'
my %receiver_source_state;    # last reported source (e.g. 'SAT/CBL')
my %receiver_surround_state;  # last reported surround mode (e.g. 'STEREO')
my %zone_is_playing;          # 1 if currently active/playing in this zone
my %zone_awaiting_resume;     # 1 if zone was auto-paused
my %internal_auto_pause;      # 1 while executing fail-safe auto-pause
my %zone_pending_timers;      # Active timer handles per zone to allow cancellation
my %last_poweron_time;        # epoch timestamp of last power-on trigger
my %last_playlist_start_time; # epoch timestamp of last playlist autoplay
my %mismatch_counter;         # consecutive mismatch poll count
my %match_counter;            # consecutive match poll count

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

# --------------------------------------------------------------------------
# Multi-Receiver Configuration Accessors
# --------------------------------------------------------------------------
sub _getTargetIp {
    my $rec = shift || 1;
    my $pref_key = ($rec == 2) ? 'r2_ip' : 'ip';
    my $ip = $prefs->get($pref_key);
    return '' unless defined $ip;
    $ip =~ s/^\s+|\s+$//g;
    $ip =~ s{^https?://}{}i;
    $ip =~ s{/.*$}{};
    return $ip;
}

sub _getTargetPort {
    my $rec = shift || 1;
    my $pref_key = ($rec == 2) ? 'r2_port' : 'port';
    my $port = $prefs->get($pref_key);
    return '8080' unless defined $port;
    $port =~ s/^\s+|\s+$//g;
    $port =~ s/[^0-9]//g;
    return $port ne '' ? $port : '8080';
}

sub _isReceiverEnabled {
    my $rec = shift || 1;
    if ($rec == 2) {
        return ($prefs->get('r2_enabled') && _getTargetIp(2) ne '') ? 1 : 0;
    }
    return (_getTargetIp(1) ne '') ? 1 : 0;
}

# Resolve preference name for a specific receiver (1 or 2) and zone ('MV' or 'Z2')
sub _getZonePref {
    my ($rec, $zone, $prop) = @_;
    my $prefix = ($rec == 2) ? 'r2_' : '';
    my $suffix = ($zone eq 'Z2') ? '_z2' : '_z1';
    my $key = $prefix . $prop . $suffix;
    return $prefs->get($key);
}

sub _formatSoundModeCmd {
    my $mode = shift;
    return '' unless defined $mode;
    $mode =~ s/^\s+|\s+$//g;
    $mode =~ s/^\?//;
    return '' if $mode eq '' || $mode eq 'NONE';
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
        $prefs->setChange(\&checkAndManagePolling, qw(
            sync_volume poll_interval ip port mac_z1 mac_z2 power_on_z1 source_z1 set_sound_mode_on_power_z1 sound_mode_z1 set_room_preset_on_power_z1 room_preset_z1 play_playlist_on_power_z1 playlist_type_z1 playlist_z1 dynamic_playlist_z1 shuffle_z1 play_only_if_empty_z1 power_on_z2 source_z2 play_playlist_on_power_z2 playlist_type_z2 playlist_z2 dynamic_playlist_z2 shuffle_z2 play_only_if_empty_z2
            r2_enabled r2_ip r2_port r2_sync_volume r2_poll_interval r2_mac_z1 r2_mac_z2 r2_power_on_z1 r2_source_z1 r2_set_sound_mode_on_power_z1 r2_sound_mode_z1 r2_set_room_preset_on_power_z1 r2_room_preset_z1 r2_play_playlist_on_power_z1 r2_playlist_type_z1 r2_playlist_z1 r2_dynamic_playlist_z1 r2_shuffle_z1 r2_play_only_if_empty_z1 r2_power_on_z2 r2_source_z2 r2_play_playlist_on_power_z2 r2_playlist_type_z2 r2_playlist_z2 r2_dynamic_playlist_z2 r2_shuffle_z2 r2_play_only_if_empty_z2
        ));
    };

    # Register AJAX playlists and receiver detection endpoints
    eval {
        require Slim::Web::Pages;
        Slim::Web::Pages->addPageFunction('plugins/MarantzHTTP/playlists.json', \&Plugins::MarantzHTTP::Settings::getPlaylistsAjax);
        Slim::Web::Pages->addPageFunction('settings/plugins/MarantzHTTP/playlists.json', \&Plugins::MarantzHTTP::Settings::getPlaylistsAjax);
        Slim::Web::Pages->addPageFunction('plugins/MarantzHTTP/detect.json', \&Plugins::MarantzHTTP::Settings::detectReceiverAjax);
        Slim::Web::Pages->addPageFunction('settings/plugins/MarantzHTTP/detect.json', \&Plugins::MarantzHTTP::Settings::detectReceiverAjax);
    };

    my $target_ip_r1 = _getTargetIp(1) || '[Not Configured]';
    my $target_port_r1 = _getTargetPort(1);
    _infoLog("MarantzHTTP v$VERSION initialized. Receiver 1: $target_ip_r1:$target_port_r1");

    if ($prefs->get('r2_enabled')) {
        my $target_ip_r2 = _getTargetIp(2) || '[Not Configured]';
        my $target_port_r2 = _getTargetPort(2);
        _infoLog("MarantzHTTP: Receiver 2 is ENABLED. Target AVR 2: $target_ip_r2:$target_port_r2");
    }

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
    my $key = shift; # Key is "$rec:$zone" e.g. "1:MV" or zone name for backward compatibility
    return unless $key;

    # Also normalize if single zone name passed
    my @target_keys = ($key =~ /:/) ? ($key) : ("1:$key", "2:$key");

    require Slim::Utils::Timers;
    for my $tk (@target_keys) {
        if ($zone_pending_timers{$tk}) {
            for my $timer_id (@{ $zone_pending_timers{$tk} }) {
                if ($timer_id) {
                    eval { Slim::Utils::Timers::killTimers(undef, $timer_id); };
                }
            }
            delete $zone_pending_timers{$tk};
        }
    }
}

sub _cancelAllZoneTimers {
    for my $r (1, 2) {
        for my $z ('MV', 'Z2') {
            _cancelZoneTimers("$r:$z");
        }
    }
}

# --------------------------------------------------------------------------
# Helper: Determine Receiver (1 or 2) and Zone ('MV' or 'Z2') for Client
# --------------------------------------------------------------------------
sub getClientBinding {
    my $client = shift;
    return () unless $client;

    my $mac = lc(eval { $client->macAddress() } || $client->id() || '');
    $mac =~ s/[^a-f0-9]//g;
    return () unless $mac;

    # 1. Receiver 1 Explicit Matches
    my $mac_r1_z1 = lc($prefs->get('mac_z1') || '');
    $mac_r1_z1 =~ s/[^a-f0-9]//g;
    return (1, 'MV') if $mac_r1_z1 && $mac eq $mac_r1_z1;

    my $mac_r1_z2 = lc($prefs->get('mac_z2') || '');
    $mac_r1_z2 =~ s/[^a-f0-9]//g;
    return (1, 'Z2') if $mac_r1_z2 && $mac eq $mac_r1_z2;

    # 2. Receiver 2 Explicit Matches (if enabled)
    if ($prefs->get('r2_enabled')) {
        my $mac_r2_z1 = lc($prefs->get('r2_mac_z1') || '');
        $mac_r2_z1 =~ s/[^a-f0-9]//g;
        return (2, 'MV') if $mac_r2_z1 && $mac eq $mac_r2_z1;

        my $mac_r2_z2 = lc($prefs->get('r2_mac_z2') || '');
        $mac_r2_z2 =~ s/[^a-f0-9]//g;
        return (2, 'Z2') if $mac_r2_z2 && $mac eq $mac_r2_z2;
    }

    # 3. Backward Compatibility Fallback for Receiver 1:
    # If mac_z1 is NOT explicitly configured and there is only 1 player (or other configured players don't match)
    if (!$mac_r1_z1 && (!$mac_r1_z2 || $mac ne $mac_r1_z2)) {
        my $r2_z1 = lc($prefs->get('r2_mac_z1') || '');
        $r2_z1 =~ s/[^a-f0-9]//g;
        my $r2_z2 = lc($prefs->get('r2_mac_z2') || '');
        $r2_z2 =~ s/[^a-f0-9]//g;
        if ((!$r2_z1 || $mac ne $r2_z1) && (!$r2_z2 || $mac ne $r2_z2)) {
            my @all_clients = eval { Slim::Player::Client::clients() };
            if (scalar(@all_clients) <= 1) {
                return (1, 'MV');
            }
        }
    }

    return ();
}

# Backward compatibility shim for any external calls
sub getClientZone {
    my $client = shift;
    my ($rec, $zone) = getClientBinding($client);
    return $zone || '';
}

sub _getClientForReceiverZone {
    my ($rec, $zone) = @_;
    my @clients = eval { Slim::Player::Client::clients() };
    return undef unless scalar(@clients);

    my $target_mac = lc(_getZonePref($rec, $zone, 'mac') || '');
    $target_mac =~ s/[^a-f0-9]//g;

    if ($target_mac) {
        for my $c (@clients) {
            next unless $c;
            my $mac = lc(eval { $c->macAddress() } || $c->id() || '');
            $mac =~ s/[^a-f0-9]//g;
            return $c if $mac eq $target_mac;
        }
    }

    # Fallback for Receiver 1 Zone 1: if only 1 player or if no explicit MAC set, use primary player
    if ($rec == 1 && $zone eq 'MV') {
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

# Backward compatibility shim
sub _getClientForZone {
    my $zone = shift;
    return _getClientForReceiverZone(1, $zone);
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

    my ($rec, $zone) = getClientBinding($client);
    unless ($rec && $zone) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': player MAC does not match configured Receiver 1 or Receiver 2 zones");
        return;
    }

    my $state_key = "$rec:$zone";

    # 1. Ignore if plugin itself initiated fail-safe auto-pause
    if ($internal_auto_pause{$state_key}) {
        delete $internal_auto_pause{$state_key};
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
    my $configured_source = _getZonePref($rec, $zone, 'source');
    my $is_already_on = ($receiver_power_state{$state_key} && $receiver_power_state{$state_key} eq 'ON');
    my $is_source_match = ($receiver_source_state{$state_key} && _isSourceMatch($configured_source, $receiver_source_state{$state_key}));

    if ($client->isPlaying() && $zone_is_playing{$state_key} && $is_already_on && $is_source_match) {
        _debugLog("[EVENT IN] playTriggerCallback ignored for '$client_name': playback already active on Receiver $rec Zone $zone and confirmed ON on correct source ('$req_str')");
        return;
    }

    # 6. Playback confirmed active or starting! Ensure receiver is ON and set to Lyrion source!
    ensurePowerAndSource($client, $rec, $zone, "Trigger: $req_str");
}

# --------------------------------------------------------------------------
# Central Power & Source Manager: Guarantees Marantz Power-ON and Correct Source
# --------------------------------------------------------------------------
sub ensurePowerAndSource {
    my ($client, $rec, $zone, $reason) = @_;
    return unless $client && $rec && $zone;

    my $client_name = eval { $client->name() } || $client->id() || 'player';
    my $ip   = _getTargetIp($rec);
    my $port = _getTargetPort($rec);

    unless ($ip) {
        _warnLog("[CONFIG] ensurePowerAndSource: Receiver $rec IP address is not configured in settings. Skipping command.");
        return;
    }

    my $state_key = "$rec:$zone";
    my $now = time();

    # Debounce: avoid sending duplicate commands within 2 seconds for the same receiver zone
    if ($last_poweron_time{$state_key} && ($now - $last_poweron_time{$state_key} < 2)) {
        my $elapsed = $now - $last_poweron_time{$state_key};
        _debugLog("[ACTION OUT] Debounce active for Receiver $rec Zone $zone ($elapsed s < 2s). Skipping duplicate dispatch.");
        return;
    }
    $last_poweron_time{$state_key} = $now;
    $zone_is_playing{$state_key} = 1;
    $zone_awaiting_resume{$state_key} = 0;
    $mismatch_counter{$state_key} = 0;
    $match_counter{$state_key} = 0;

    my $is_already_on = ($receiver_power_state{$state_key} && $receiver_power_state{$state_key} eq 'ON') ? 1 : 0;

    my $power_on_enabled = _getZonePref($rec, $zone, 'power_on');
    my $power_cmd = $power_on_enabled ? ($zone eq 'Z2' ? 'Z2ON' : 'ZMON') : undef;
    my $source_cmd = _getZonePref($rec, $zone, 'source') || ($zone eq 'Z2' ? 'Z2NET' : 'SISAT/CBL');
    my $vol = (!$is_already_on && _getZonePref($rec, $zone, 'set_volume_on_power')) ? _getZonePref($rec, $zone, 'power_volume') : undef;
    my $sm_log = ($zone eq 'MV' && _getZonePref($rec, $zone, 'set_sound_mode_on_power')) ? _formatSoundModeCmd(_getZonePref($rec, $zone, 'sound_mode')) : 'DISABLED';

    _infoLog(sprintf("[TRIGGER] Ensuring Power & Source for Receiver %d Zone %s ('%s') | Reason: %s | PowerCmd: %s | Source: %s | SoundMode: %s | InitialVol: %s | AVR: %s",
        $rec, $zone, $client_name, $reason || 'Play Trigger', $power_cmd // 'NONE', $source_cmd // 'NONE', $sm_log || 'DISABLED', defined $vol ? $vol : 'PRESERVED', $is_already_on ? 'ON' : 'STANDBY/UNKNOWN'));

    _sendPowerSourceAndVolume($rec, $ip, $port, $power_cmd, $source_cmd, $zone, $vol, $client, $is_already_on);
}

# --------------------------------------------------------------------------
# Playback Polling Manager: Start or stop background volume polling
# --------------------------------------------------------------------------
sub playbackCallback {
    my $request = shift;
    my $client = $request ? $request->client() : undef;
    return unless $client;

    my ($rec, $zone) = getClientBinding($client);
    my $client_name = eval { $client->name() } || $client->id() || 'player';
    my $req_str = $request->getRequestString() || 'playback event';

    _debugLog("[EVENT IN] playbackCallback for '$client_name' (Receiver: " . ($rec || 'None') . ", Zone: " . ($zone || 'None') . ") | Request: '$req_str'");

    if ($rec && $zone) {
        my $state_key = "$rec:$zone";
        if ($client->isStopped()) {
            $zone_is_playing{$state_key} = 0;
            _cancelZoneTimers($state_key);
            _debugLog("[STATUS] Receiver $rec Zone $zone player is STOPPED.");
        } elsif ($client->isPaused()) {
            my $configured_source = _getZonePref($rec, $zone, 'source');
            my $is_on_lyrion = ($receiver_power_state{$state_key} && $receiver_power_state{$state_key} eq 'ON' &&
                                $receiver_source_state{$state_key} && _isSourceMatch($configured_source, $receiver_source_state{$state_key}));
            if ($is_on_lyrion && !$zone_awaiting_resume{$state_key}) {
                $zone_awaiting_resume{$state_key} = 0;
                $match_counter{$state_key} = 0;
                _debugLog("[STATUS] Receiver $rec Zone $zone player is PAUSED manually by user while on Lyrion source. Auto-Resume disarmed.");
            } else {
                _debugLog("[STATUS] Receiver $rec Zone $zone player is PAUSED (awaiting Marantz return to Lyrion source).");
            }
        } elsif ($client->isPlaying()) {
            $zone_awaiting_resume{$state_key} = 0;
            $match_counter{$state_key} = 0;
            _debugLog("[STATUS] Receiver $rec Zone $zone player is PLAYING.");

            my $now = time();
            my $last_start = $last_poweron_time{$state_key} || 0;
            my $configured_source = _getZonePref($rec, $zone, 'source');
            my $receiver_is_on_other_source = ($receiver_source_state{$state_key} && !_isSourceMatch($configured_source, $receiver_source_state{$state_key}));

            my $is_newsong = ($request->isCommand([['playlist'], ['newsong']]) || 
                              $request->isCommand([['playlist'], ['open']]) || 
                              $request->isCommand([['time']]) ||
                              $req_str =~ /\b(?:newsong|open|time)\b/i);
            my $is_already_active = ($zone_is_playing{$state_key} && 
                                     $receiver_power_state{$state_key} && $receiver_power_state{$state_key} eq 'ON' &&
                                     $receiver_source_state{$state_key} && _isSourceMatch($configured_source, $receiver_source_state{$state_key}));

            # Avoid track-change and seek audio dropouts: Do NOT send power/source switch commands if AVR is already ON and playing
            if ($is_newsong || $is_already_active) {
                $zone_is_playing{$state_key} = 1;
                _debugLog("[PLAYBACK] Track transition, seek or steady playback on '$client_name' (Receiver $rec Zone $zone). Receiver confirmed ON and on correct source. Suppressed redundant commands.");
            } elsif ($now - $last_start > 4 && !$receiver_is_on_other_source && (!$receiver_power_state{$state_key} || $receiver_power_state{$state_key} ne 'ON')) {
                _infoLog("[PLAYBACK SAFETY] Active playback detected on '$client_name' (Receiver $rec Zone $zone). Ensuring Marantz power & source.");
                ensurePowerAndSource($client, $rec, $zone, "Playback active safety: $req_str");
            } else {
                $zone_is_playing{$state_key} = 1;
            }
        }
    }

    checkAndManagePolling();
}

# --------------------------------------------------------------------------
# Send Power-On, Input Source, and Power-On Volume Commands
# --------------------------------------------------------------------------
sub _sendPowerSourceAndVolume {
    my ($rec, $ip, $port, $power_cmd, $source_cmd, $zone, $initial_volume, $client, $is_already_on) = @_;
    return unless $ip;

    my $state_key = "$rec:$zone";
    my $now = eval { require Time::HiRes; Time::HiRes::time() } || time();
    require Slim::Utils::Timers;

    _cancelZoneTimers($state_key);
    $zone_pending_timers{$state_key} = [];

    # 1. Power ON command (if configured)
    if ($power_cmd) {
        $power_cmd =~ s/^\s+|\s+$//g;
        $power_cmd =~ s/^\?//;
        my $url_power = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$power_cmd";
        _debugLog("[ACTION OUT] Receiver $rec: Dispatching Power-ON command: $power_cmd -> $url_power");
        _sendHttpRequest($url_power);
    }

    # 2. Source Switch command: ALWAYS send!
    if ($source_cmd) {
        $source_cmd =~ s/^\s+|\s+$//g;
        $source_cmd =~ s/^\?//;
        if ($source_cmd ne '') {
            my $url_source = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$source_cmd";

            if ($is_already_on) {
                _debugLog("[ACTION OUT] Receiver $rec already ON. Dispatching Source Switch immediately: $source_cmd -> $url_source");
                _sendHttpRequest($url_source);

                my $timer_sub = sub {
                    _debugLog("[ACTION OUT] Receiver $rec: Re-confirming Source Switch: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                };
                Slim::Utils::Timers::setTimer(undef, $now + 0.8, $timer_sub);
                push @{ $zone_pending_timers{$state_key} }, $timer_sub;
            } else {
                # AVR waking from standby: Stagger retries to allow DSP/HDMI/network initialization (+1.2s and +3.0s)
                _debugLog("[ACTION OUT] Receiver $rec waking from standby. Scheduling Source Switch: $source_cmd (+1.2s and +3.0s retry)");
                my $timer_sub1 = sub {
                    _debugLog("[ACTION OUT] Receiver $rec: Dispatching Source Switch command: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                };
                Slim::Utils::Timers::setTimer(undef, $now + 1.2, $timer_sub1);
                push @{ $zone_pending_timers{$state_key} }, $timer_sub1;

                my $timer_sub2 = sub {
                    _debugLog("[ACTION OUT] Receiver $rec: Re-confirming Source Switch after power-up: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                };
                Slim::Utils::Timers::setTimer(undef, $now + 3.0, $timer_sub2);
                push @{ $zone_pending_timers{$state_key} }, $timer_sub2;
            }
        }
    }

    # 2b. Sound Mode command (Main Zone - Stereo, Direct, Multi Ch Stereo, Virtual, etc.)
    # ONLY executed upon initial power-on from Standby/Off to prevent audio interruptions during playback!
    if ($zone eq 'MV' && !$is_already_on) {
        my $sound_mode_cmd = _formatSoundModeCmd(_getZonePref($rec, $zone, 'sound_mode'));
        my $sound_mode_enabled = _getZonePref($rec, $zone, 'set_sound_mode_on_power') ? 1 : 0;
        if ($sound_mode_enabled && $sound_mode_cmd) {
            _debugLog("[ACTION OUT] Receiver $rec: Scheduling initial power-on Sound Mode command: $sound_mode_cmd (+1600ms delay)");
            my $timer_sub_sm = sub {
                _debugLog("[ACTION OUT] Receiver $rec: Executing delayed Sound Mode command on power-on: $sound_mode_cmd");
                _sendSoundModeCommand($ip, $port, $sound_mode_cmd, $zone);
            };
            Slim::Utils::Timers::setTimer(undef, $now + 1.6, $timer_sub_sm);
            push @{ $zone_pending_timers{$state_key} }, $timer_sub_sm if $zone_pending_timers{$state_key};
        }

        # 2c. Dirac / Audyssey Room Calibration Preset command (Main Zone)
        my $room_preset_cmd = _formatRoomPresetCmd(_getZonePref($rec, $zone, 'room_preset'));
        my $room_preset_enabled = _getZonePref($rec, $zone, 'set_room_preset_on_power') ? 1 : 0;
        if ($room_preset_enabled && $room_preset_cmd) {
            _debugLog("[ACTION OUT] Receiver $rec: Scheduling initial power-on Dirac/Audyssey Preset command: $room_preset_cmd (+1800ms delay)");
            my $timer_sub_rp = sub {
                _debugLog("[ACTION OUT] Receiver $rec: Executing delayed Dirac/Audyssey Preset command on power-on: $room_preset_cmd");
                _sendRoomPresetCommand($ip, $port, $room_preset_cmd, $zone);
            };
            Slim::Utils::Timers::setTimer(undef, $now + 1.8, $timer_sub_rp);
            push @{ $zone_pending_timers{$state_key} }, $timer_sub_rp if $zone_pending_timers{$state_key};
        }
    }

    # 3. Initial Volume (only on initial power-on from Standby/Off)
    if (!$is_already_on && defined $initial_volume && $initial_volume ne '') {
        my $vol = int($initial_volume);
        $vol = 0 if $vol < 0;
        $vol = 98 if $vol > 98;
        my $vol_formatted = sprintf("%02d", $vol);
        my $vol_cmd = ($zone eq 'Z2' ? 'Z2' : 'MV') . $vol_formatted;
        my $url_vol = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$vol_cmd";

        _debugLog("[ACTION OUT] Receiver $rec: Scheduling Power-On Volume: $vol_cmd (+2000ms delay)");
        my $timer_sub3 = sub {
            _debugLog("[ACTION OUT] Receiver $rec: Dispatching Power-On Volume command: $vol_cmd -> $url_vol");
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
        push @{ $zone_pending_timers{$state_key} }, $timer_sub3;
    }

    # 4. Startup Playlist Autoplay on Receiver Power-ON
    if (!$is_already_on && $power_cmd) {
        _playConfiguredPlaylist($client, $rec, $zone, "Receiver $rec Plugin Power-On Command");
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

    eval { $client->execute(['playlist', 'clear']); };
    eval { $client->execute(['playlist', 'shuffle', $shuffle ? 1 : 0]); };

    my $url_to_play = '';
    if ($playlist =~ m{^(?:file|https?|db):}i) {
        $url_to_play = $playlist;
    } elsif (-f $playlist) {
        $url_to_play = "file://$playlist";
    }

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

    if ($url_to_play) {
        _infoLog("[AUTOPLAY TASK] Playlist afspelen via URL: $url_to_play");
        eval { $client->execute(['playlist', 'play', $url_to_play]); };
    } else {
        _infoLog("[AUTOPLAY TASK] Playlist afspelen via playlistcontrol / title: $playlist");
        eval {
            require Slim::Control::Request;
            Slim::Control::Request::executeRequest($client, ['playlistcontrol', 'cmd:load', "playlist_name:$playlist"]);
        };
        eval { $client->execute(['playlist', 'play', $playlist]); };
    }

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

    my $clean_id = $dpl_id;
    $clean_id =~ s/^\s+|\s+$//g;

    my @candidate_ids;

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

    my %seen_cands;
    @candidate_ids = grep { defined $_ && $_ ne '' && !$seen_cands{$_}++ } @candidate_ids;

    eval { $client->execute(['playlist', 'shuffle', $shuffle ? 1 : 0]); };

    my $activated_id = '';
    my $total_tracks = 0;

    for my $cid (@candidate_ids) {
        _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Probeer Dynamic Playlist activatie met ID: '$cid' op '$client_name'...");

        eval { $client->execute(['dynamicplaylist', 'playlist', 'play', $cid]); };
        $total_tracks = eval { $client->playlistLength() } || 0;
        if ($total_tracks > 0) {
            $activated_id = $cid;
            _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Gelukt via client->execute! Wachtrij bevat $total_tracks tracks (ID: '$cid').");
            last;
        }

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

        eval { $client->execute(['dynamicplaylist', 'play', $cid]); };
        $total_tracks = eval { $client->playlistLength() } || 0;
        if ($total_tracks > 0) {
            $activated_id = $cid;
            _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Gelukt via ['dynamicplaylist', 'play', '$cid']! ($total_tracks tracks).");
            last;
        }

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

    eval { $client->execute(['play']); };

    if ($activated_id) {
        _infoLog("[AUTOPLAY DYNAMIC v4.7.1] Dynamic Playlist '$activated_id' (invoer: '$dpl_id') succesvol geactiveerd op '$client_name'!");
    } else {
        _warnLog("[AUTOPLAY DYNAMIC v4.7.1] Dynamic Playlist '$dpl_id' kon niet direct worden gevonden onder kandidaat-ID's.");
    }
}

sub _playConfiguredPlaylist {
    my ($client, $rec, $zone, $reason) = @_;
    return unless $client && $rec && $zone;

    my $enabled = _getZonePref($rec, $zone, 'play_playlist_on_power');
    return unless $enabled;

    my $playlist_type = _getZonePref($rec, $zone, 'playlist_type') || 'standard';
    my $playlist = ($playlist_type eq 'dynamic')
        ? _getZonePref($rec, $zone, 'dynamic_playlist')
        : _getZonePref($rec, $zone, 'playlist');

    return unless defined $playlist && $playlist ne '';

    my $raw_shuffle = _getZonePref($rec, $zone, 'shuffle') // 0;
    my $shuffle = ($raw_shuffle == 1) ? 1 : 0;
    my $client_name = eval { $client->name() } || $client->id() || 'player';

    my $only_if_empty = _getZonePref($rec, $zone, 'play_only_if_empty');
    if ($only_if_empty) {
        my $is_playing = eval { $client->isPlaying() } || 0;
        my $queue_count = eval { Slim::Player::Playlist::count($client) };
        unless (defined $queue_count) {
            $queue_count = eval { scalar(@{Slim::Player::Playlist::playList($client) || []}) } || 0;
        }
        if ($queue_count > 0 || $is_playing) {
            _infoLog(sprintf("[AUTOPLAY OVERSLAAN] %s '%s' NIET gestart op '%s' (Receiver %d Zone %s): wachtrij bevat %d tracks en 'Alleen als wachtrij leeg is' is actief.",
                ($playlist_type eq 'dynamic' ? 'Dynamic Playlist' : 'Playlist'), $playlist, $client_name, $rec, $zone, $queue_count));
            return;
        }
    }

    my $state_key = "$rec:$zone";
    my $now = time();
    if ($last_playlist_start_time{$state_key} && ($now - $last_playlist_start_time{$state_key} < 10)) {
        _debugLog("[AUTOPLAY] Receiver $rec Zone $zone playlist start onderdrukt (recent trigger actief).");
        return;
    }
    $last_playlist_start_time{$state_key} = $now;
    $last_poweron_time{$state_key} = $now;
    $zone_is_playing{$state_key} = 1;
    $zone_awaiting_resume{$state_key} = 0;

    _infoLog(sprintf("[AUTOPLAY] Receiver %d Inschakelen: Starten van %s '%s' op '%s' (Zone %s, Shuffle: %d, Reden: %s)",
        $rec, ($playlist_type eq 'dynamic' ? 'Dynamic Playlist' : 'Standaard Playlist'),
        $playlist, $client_name, $zone, $shuffle, $reason || 'Power On'));

    my $now_hires = eval { require Time::HiRes; Time::HiRes::time() } || time();
    require Slim::Utils::Timers;

    my $play_task = sub {
        if ($playlist_type eq 'dynamic') {
            _loadAndPlayDynamicPlaylist($client, $playlist, $shuffle);
        } else {
            _loadAndPlayPlaylist($client, $playlist, $shuffle);
        }
    };

    Slim::Utils::Timers::setTimer(undef, $now_hires + 1.0, $play_task);
    push @{ $zone_pending_timers{$state_key} }, $play_task if $zone_pending_timers{$state_key};
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

        my ($rec, $zone) = getClientBinding($client);
        unless ($rec && $zone) {
            _debugLog("[VOLUME] Player '$client_name' ($mac) does not match Receiver 1 or Receiver 2 MAC.");
            return;
        }

        my $sync_vol_enabled = ($rec == 2) ? $prefs->get('r2_sync_volume') : $prefs->get('sync_volume');
        unless ($sync_vol_enabled) {
            _debugLog("[VOLUME] Volume sync disabled for Receiver $rec.");
            return;
        }

        my $volume = int($client->volume());
        $volume = 0 if $volume < 0;
        $volume = 98 if $volume > 98;

        my $now = time();
        if (defined $last_marantz_synced_vol{$mac} && $last_marantz_synced_vol{$mac} == $volume && ($now - ($last_marantz_vol_sync_time{$mac} || 0) < 3)) {
            _debugLog("[MIXER ECHO GUARD] Volume $volume matches recent Marantz sync, suppressing echo back to AVR.");
            return;
        }

        my $ip = _getTargetIp($rec);
        my $port = _getTargetPort($rec);
        unless ($ip) {
            _debugLog("[VOLUME] Receiver $rec IP not configured, skipping volume sync for '$client_name'");
            return;
        }

        my $vol_formatted = sprintf("%02d", $volume);
        my $url = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$zone$vol_formatted";
        _infoLog("[VOLUME OUT] LMS '$client_name' ($volume) -> Receiver $rec (Zone $zone): $url");
        _sendHttpRequest($url);
    }
}

# --------------------------------------------------------------------------
# Playback Monitoring & Polling Management
# --------------------------------------------------------------------------
sub shouldPollReceiver {
    my $rec = shift || 1;
    my $ip = _getTargetIp($rec);
    return 0 unless $ip;

    if ($rec == 2 && !$prefs->get('r2_enabled')) {
        return 0;
    }

    # 1. Volume sync enabled
    my $sync_vol = ($rec == 2) ? $prefs->get('r2_sync_volume') : $prefs->get('sync_volume');
    return 1 if $sync_vol;

    # 2. Startup playlist enabled on Zone 1 or Zone 2
    my $pl_z1 = _getZonePref($rec, 'MV', 'play_playlist_on_power');
    my $pl_z2 = _getZonePref($rec, 'Z2', 'play_playlist_on_power');
    return 1 if ($pl_z1 || $pl_z2);

    # 3. Fail-safe auto-pause / auto-resume enabled on Zone 1 or Zone 2
    my $pause_z1 = _getZonePref($rec, 'MV', 'pause_on_off_or_source');
    my $resume_z1 = _getZonePref($rec, 'MV', 'resume_on_source');
    my $pause_z2 = _getZonePref($rec, 'Z2', 'pause_on_off_or_source');
    my $resume_z2 = _getZonePref($rec, 'Z2', 'resume_on_source');
    return 1 if ($pause_z1 || $resume_z1 || $pause_z2 || $resume_z2);

    # 4. Any client bound to this receiver is currently playing
    my @clients = eval { Slim::Player::Client::clients() };
    for my $client (@clients) {
        if ($client && $client->isPlaying()) {
            my ($c_rec, $c_zone) = getClientBinding($client);
            return 1 if ($c_rec && $c_rec == $rec);
        }
    }

    return 0;
}

sub shouldPollMarantz {
    return (shouldPollReceiver(1) || shouldPollReceiver(2)) ? 1 : 0;
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
    if ($prefs->get('r2_enabled')) {
        my $int2 = int($prefs->get('r2_poll_interval') || 2);
        $interval = $int2 if ($int2 < $interval);
    }
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

    my $interval = int($prefs->get('poll_interval') || 2);
    if ($prefs->get('r2_enabled')) {
        my $int2 = int($prefs->get('r2_poll_interval') || 2);
        $interval = $int2 if ($int2 < $interval);
    }
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
    # 1. Receiver 1
    if (shouldPollReceiver(1)) {
        my $ip1 = _getTargetIp(1);
        my $port1 = _getTargetPort(1);
        if ($ip1) {
            my $client_r1_z1 = _getClientForReceiverZone(1, 'MV');
            my $client_r1_z2 = _getClientForReceiverZone(1, 'Z2');

            if ($client_r1_z1) {
                _debugLog("[POLL OUT] Polling Receiver 1 Main Zone XML status from $ip1:$port1...");
                _queryMarantzStatus(1, $ip1, $port1, 'MV', 'formMainZone_MainZoneXmlStatusLite.xml', $client_r1_z1);
            }
            if ($client_r1_z2 && ($prefs->get('mac_z2') || $prefs->get('power_on_z2') || $prefs->get('play_playlist_on_power_z2'))) {
                _debugLog("[POLL OUT] Polling Receiver 1 Zone 2 XML status from $ip1:$port1...");
                _queryMarantzStatus(1, $ip1, $port1, 'Z2', 'formZone2_Zone2XmlStatusLite.xml', $client_r1_z2);
            }
        }
    }

    # 2. Receiver 2 (Independent)
    if (_isReceiverEnabled(2) && shouldPollReceiver(2)) {
        my $ip2 = _getTargetIp(2);
        my $port2 = _getTargetPort(2);
        if ($ip2) {
            my $client_r2_z1 = _getClientForReceiverZone(2, 'MV');
            my $client_r2_z2 = _getClientForReceiverZone(2, 'Z2');

            if ($client_r2_z1) {
                _debugLog("[POLL OUT] Polling Receiver 2 Main Zone XML status from $ip2:$port2...");
                _queryMarantzStatus(2, $ip2, $port2, 'MV', 'formMainZone_MainZoneXmlStatusLite.xml', $client_r2_z1);
            }
            if ($client_r2_z2 && ($prefs->get('r2_mac_z2') || $prefs->get('r2_power_on_z2') || $prefs->get('r2_play_playlist_on_power_z2'))) {
                _debugLog("[POLL OUT] Polling Receiver 2 Zone 2 XML status from $ip2:$port2...");
                _queryMarantzStatus(2, $ip2, $port2, 'Z2', 'formZone2_Zone2XmlStatusLite.xml', $client_r2_z2);
            }
        }
    }
}

sub _queryMarantzStatus {
    my ($rec, $ip, $port, $zone, $endpoint, $client) = @_;
    my $url = "http://$ip:$port/goform/$endpoint";

    require Slim::Networking::SimpleAsyncHTTP;
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $res = shift;
            my $content = eval { $res->content() } || eval { $res->result() } || '';
            _debugLog("[POLL RESP] Receiver $rec: Received XML status for Zone $zone (" . length($content) . " bytes)");
            _handleMarantzXmlResponse($rec, $content, $zone, $client);
        },
        sub {
            my ($http, $error) = @_;
            _debugLog("[POLL ERROR] Receiver $rec: Zone $zone XML query ($endpoint) failed: " . ($error || 'Network error'));
            if ($endpoint =~ /Lite\.xml$/) {
                my $fallback_endpoint = $endpoint;
                $fallback_endpoint =~ s/Lite\.xml$/\.xml/;
                my $fallback_url = "http://$ip:$port/goform/$fallback_endpoint";
                my $http_fallback = Slim::Networking::SimpleAsyncHTTP->new(
                    sub {
                        my $res2 = shift;
                        my $c2 = eval { $res2->content() } || eval { $res2->result() } || '';
                        _handleMarantzXmlResponse($rec, $c2, $zone, $client);
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
# --------------------------------------------------------------------------
sub _extractXmlTagValue {
    my ($xml, $tag) = @_;
    return undef unless defined $xml && defined $tag;

    if ($xml =~ /<$tag\b[^>]*>(.*?)<\/$tag>/si) {
        my $inner = $1;
        if ($inner =~ /<value\b[^>]*>([^<]*)<\/value>/si) {
            my $v = $1;
            $v =~ s/^\s+|\s+$//g;
            return $v;
        }
        my $clean = $inner;
        $clean =~ s/<[^>]+>//g;
        $clean =~ s/^\s+|\s+$//g;
        return $clean if $clean ne '';
    }
    return undef;
}

sub _handleMarantzXmlResponse {
    my ($rec, $content, $zone, $client) = @_;
    return unless $content && $client;

    my $client_name = eval { $client->name() } || $client->id() || 'player';
    my $state_key = "$rec:$zone";

    # Extract Power status
    my $raw_power = ($zone eq 'Z2')
        ? (_extractXmlTagValue($content, 'Zone2Power') // _extractXmlTagValue($content, 'zone2Power') // _extractXmlTagValue($content, 'zonePower') // _extractXmlTagValue($content, 'Power'))
        : (_extractXmlTagValue($content, 'ZonePower')  // _extractXmlTagValue($content, 'zonePower')  // _extractXmlTagValue($content, 'Power'));

    $raw_power = uc($raw_power) if defined $raw_power;

    # Extract Input Source
    my $raw_input = ($zone eq 'Z2')
        ? (_extractXmlTagValue($content, 'Zone2InputFuncSelect') // _extractXmlTagValue($content, 'zone2InputFuncSelect') // _extractXmlTagValue($content, 'InputFuncSelect'))
        : (_extractXmlTagValue($content, 'InputFuncSelect'));

    $raw_input = uc($raw_input) if defined $raw_input;

    # Extract Surround / Sound Mode (Zone 1)
    my $raw_surround = _extractXmlTagValue($content, 'selectSurround') 
                    // _extractXmlTagValue($content, 'SurroundMode')
                    // _extractXmlTagValue($content, 'surroundMode');
    if (defined $raw_surround && $raw_surround ne '') {
        $receiver_surround_state{$state_key} = uc($raw_surround);
    }

    my $prev_power  = $receiver_power_state{$state_key}  || 'UNKNOWN';
    my $prev_source = $receiver_source_state{$state_key} || 'UNKNOWN';

    my $is_standby = 0;
    if (defined $raw_power) {
        if ($raw_power eq 'STANDBY' || $raw_power eq 'OFF') {
            $is_standby = 1;
            $receiver_power_state{$state_key} = 'STANDBY';
            $zone_is_playing{$state_key} = 0;
        } elsif ($raw_power eq 'ON') {
            $receiver_power_state{$state_key} = 'ON';
        }
    }

    if (defined $raw_input && $raw_input ne '') {
        $receiver_source_state{$state_key} = $raw_input;
    }

    my $configured_source = _getZonePref($rec, $zone, 'source');
    my $source_matches = 1;
    if (!$is_standby && defined $raw_input && $raw_input ne '') {
        $source_matches = _isSourceMatch($configured_source, $raw_input);
    }

    # Detect AVR Power-ON transition (STANDBY/OFF -> ON)
    my $power_turned_on = ($prev_power eq 'STANDBY' && !$is_standby);
    if ($power_turned_on) {
        _infoLog("[POWER EVENT] Receiver $rec Zone $zone is ingeschakeld (STANDBY -> ON)!");

        if ($zone eq 'MV') {
            my $sm_cmd = _formatSoundModeCmd(_getZonePref($rec, $zone, 'sound_mode'));
            my $sm_enabled = _getZonePref($rec, $zone, 'set_sound_mode_on_power') ? 1 : 0;
            my $ip = _getTargetIp($rec);
            my $port = _getTargetPort($rec);
            if ($sm_enabled && $sm_cmd && $ip) {
                _infoLog("[POWER EVENT] Receiver $rec: Geluidsmodus bekrachtigen voor Hoofdzone: $sm_cmd");
                _sendSoundModeCommand($ip, $port, $sm_cmd, $zone);
            }

            my $rp_cmd = _formatRoomPresetCmd(_getZonePref($rec, $zone, 'room_preset'));
            my $rp_enabled = _getZonePref($rec, $zone, 'set_room_preset_on_power') ? 1 : 0;
            if ($rp_enabled && $rp_cmd && $ip) {
                _infoLog("[POWER EVENT] Receiver $rec: Dirac/Audyssey preset bekrachtigen: $rp_cmd");
                _sendRoomPresetCommand($ip, $port, $rp_cmd, $zone);
            }
        }

        my $play_playlist = _getZonePref($rec, $zone, 'play_playlist_on_power');
        if ($play_playlist) {
            if ($configured_source && $configured_source ne '') {
                my $src_cmd = $configured_source;
                $src_cmd =~ s/^\s+|\s+$//g;
                $src_cmd =~ s/^\?//;
                my $ip = _getTargetIp($rec);
                my $port = _getTargetPort($rec);
                if ($ip && $src_cmd) {
                    _infoLog("[POWER EVENT] Receiver $rec: Ingangsbron bekrachtigen: $src_cmd");
                    _sendHttpRequest("http://$ip:$port/goform/formiPhoneAppDirect.xml?$src_cmd");
                }
            }

            _playConfiguredPlaylist($client, $rec, $zone, "Receiver $rec AVR Power-On Detected");
        }
    }

    # Detect input source switch to Lyrion while already powered on
    my $source_switched_to_lyrion = (!$is_standby && $prev_source ne 'UNKNOWN' && !_isSourceMatch($configured_source, $prev_source) && $source_matches);
    if ($source_switched_to_lyrion) {
        _infoLog("[SOURCE EVENT] Receiver $rec Zone $zone bron gewijzigd naar Lyrion '$configured_source'.");

        if ($zone eq 'MV') {
            my $sm_cmd = _formatSoundModeCmd(_getZonePref($rec, $zone, 'sound_mode'));
            my $sm_enabled = _getZonePref($rec, $zone, 'set_sound_mode_on_power') ? 1 : 0;
            my $ip = _getTargetIp($rec);
            my $port = _getTargetPort($rec);
            if ($sm_enabled && $sm_cmd && $ip) {
                _infoLog("[SOURCE EVENT] Receiver $rec: Geluidsmodus bekrachtigen voor Lyrion: $sm_cmd");
                _sendSoundModeCommand($ip, $port, $sm_cmd, $zone);
            }

            my $rp_cmd = _formatRoomPresetCmd(_getZonePref($rec, $zone, 'room_preset'));
            my $rp_enabled = _getZonePref($rec, $zone, 'set_room_preset_on_power') ? 1 : 0;
            if ($rp_enabled && $rp_cmd && $ip) {
                _infoLog("[SOURCE EVENT] Receiver $rec: Dirac/Audyssey preset bekrachtigen: $rp_cmd");
                _sendRoomPresetCommand($ip, $port, $rp_cmd, $zone);
            }
        }

        my $play_playlist = _getZonePref($rec, $zone, 'play_playlist_on_power');
        if ($play_playlist && !$client->isPlaying()) {
            _playConfiguredPlaylist($client, $rec, $zone, "Receiver $rec Source Switched to Lyrion");
        }
    }

    _debugLog(sprintf("[XML PARSE] Receiver %d Zone %s: Power='%s' | Source reported='%s' (configured='%s', match=%d)", 
        $rec, $zone, $raw_power // 'N/A', $raw_input // 'N/A', $configured_source // 'N/A', $source_matches));

    # --------------------------------------------------------------------------
    # 1. Volume Sync: Marantz -> Lyrion
    # --------------------------------------------------------------------------
    my $sync_vol_enabled = ($rec == 2) ? $prefs->get('r2_sync_volume') : $prefs->get('sync_volume');
    if ($sync_vol_enabled) {
        my $raw_vol_text = ($zone eq 'Z2')
            ? (_extractXmlTagValue($content, 'Zone2Volume') // _extractXmlTagValue($content, 'zone2Volume') // _extractXmlTagValue($content, 'ZoneVolume') // _extractXmlTagValue($content, 'zoneVolume') // _extractXmlTagValue($content, 'MasterVolume') // _extractXmlTagValue($content, 'Volume'))
            : (_extractXmlTagValue($content, 'MasterVolume') // _extractXmlTagValue($content, 'MasterVolumeDisp') // _extractXmlTagValue($content, 'zoneVolume') // _extractXmlTagValue($content, 'ZoneVolume') // _extractXmlTagValue($content, 'Volume'));

        my $vol_display = _extractXmlTagValue($content, 'VolumeDisplay');
        my $is_relative = (defined $vol_display && uc($vol_display) eq 'RELATIVE') ? 1 : 0;

        if (defined $raw_vol_text) {
            my $raw = $raw_vol_text;
            $raw =~ s/^\s+|\s+$//g;

            my $vol;
            if ($raw eq '--' || $raw eq '--dB' || $raw eq '-- dB') {
                $vol = 0;
            } else {
                my $clean_raw = $raw;
                $clean_raw =~ s/[^\d\.\+\-]//g;

                if ($clean_raw =~ /^-([\d\.]+)$/) {
                    $vol = int(80 - $1 + 0.5);
                } elsif ($clean_raw =~ /^\+([\d\.]+)$/) {
                    $vol = int(80 + $1 + 0.5);
                } elsif ($is_relative) {
                    if ($clean_raw =~ /^0(?:\.0+)?$/) {
                        $vol = 80;
                    } elsif ($clean_raw =~ /^([\d\.]+)$/) {
                        $vol = int(80 + $1 + 0.5);
                    }
                } else {
                    if ($clean_raw =~ /^([\d\.]+)$/) {
                        $vol = int($1 + 0.5);
                    }
                }
            }

            if (defined $vol) {
                $vol = 0 if $vol < 0;
                $vol = 100 if $vol > 100;

                my $current_vol = int($client->volume() || 0);

                if (abs($vol - $current_vol) >= 1) {
                    my $mac = lc(eval { $client->macAddress() } || $client->id() || '');
                    $mac =~ s/[^a-f0-9]//g;

                    _infoLog("[VOLUME SYNC] Receiver $rec ($vol) -> LMS '$client_name' (was $current_vol). Updating LMS slider.");
                    $syncing_clients{$mac} = 1;
                    $last_marantz_synced_vol{$mac} = $vol;
                    $last_marantz_vol_sync_time{$mac} = time();

                    eval { $client->execute(['mixer', 'volume', $vol]); };
                    eval { $client->volume($vol); };

                    my $now_hires = eval { require Time::HiRes; Time::HiRes::time() } || time();
                    require Slim::Utils::Timers;
                    Slim::Utils::Timers::setTimer(undef, $now_hires + 1.5, sub {
                        $syncing_clients{$mac} = 0;
                    });
                }
            }
        }
    }

    return unless (defined $raw_power || defined $raw_input);

    # --------------------------------------------------------------------------
    # 2. Fail-Safe Auto-Pause on Receiver Power-OFF / Source Change
    # --------------------------------------------------------------------------
    my $pause_enabled = _getZonePref($rec, $zone, 'pause_on_off_or_source');
    if ($pause_enabled && $client->isPlaying()) {
        my $now = time();
        my $last_start = $last_poweron_time{$state_key} || 0;
        if ($now - $last_start < 15) {
            my $rem = 15 - ($now - $last_start);
            _debugLog(sprintf("[FAIL-SAFE GRACE PERIOD] Receiver %d Zone %s: Playback transition in progress (%ds grace remaining). Auto-pause suppressed.", $rec, $zone, $rem));
            $mismatch_counter{$state_key} = 0;
            return;
        }

        if ($is_standby || !$source_matches) {
            $mismatch_counter{$state_key} = ($mismatch_counter{$state_key} || 0) + 1;
            _debugLog(sprintf("[FAIL-SAFE AUTO-PAUSE] Receiver %d Zone %s mismatch detected (%d/3 checks) | Standby=%d, SourceMatch=%d, Reported='%s', Configured='%s'",
                $rec, $zone, $mismatch_counter{$state_key}, $is_standby, $source_matches, $raw_input // 'N/A', $configured_source // 'N/A'));

            if ($mismatch_counter{$state_key} >= 3) {
                $mismatch_counter{$state_key} = 0;
                if ($client->isPlaying()) {
                    _infoLog("[FAIL-SAFE TRIGGER] Auto-Pausing '$client_name' (Receiver $rec Zone $zone) because AVR is " . ($is_standby ? 'STANDBY' : 'ON') . " and source is '$raw_input' (configured '$configured_source')");
                    $internal_auto_pause{$state_key} = 1;
                    $zone_awaiting_resume{$state_key} = 1;
                    $zone_is_playing{$state_key} = 0;
                    $client->execute(['pause', 1]);
                }
            }
        } else {
            $mismatch_counter{$state_key} = 0;
        }
    }

    if ($is_standby || !$source_matches) {
        if (!$client->isPlaying()) {
            $zone_awaiting_resume{$state_key} = 1;
        }
    }

    # --------------------------------------------------------------------------
    # 3. Fail-Safe Auto-Resume on Source Selection
    # --------------------------------------------------------------------------
    my $resume_enabled = _getZonePref($rec, $zone, 'resume_on_source');
    if ($resume_enabled && !$client->isPlaying()) {
        my $power_turned_on = ($prev_power eq 'STANDBY' && !$is_standby);
        my $source_switched_to_lyrion = ($prev_source ne 'UNKNOWN' && !_isSourceMatch($configured_source, $prev_source) && $source_matches);
        my $should_resume = (!$is_standby && $source_matches && ($zone_awaiting_resume{$state_key} || $power_turned_on || $source_switched_to_lyrion));

        if ($should_resume) {
            $match_counter{$state_key} = ($match_counter{$state_key} || 0) + 1;
            _debugLog(sprintf("[FAIL-SAFE AUTO-RESUME] Receiver %d Zone %s match confirmed (%d/2 checks) | Source=%s | AwaitingResume=%d | PwrTurnedOn=%d | SrcSwitched=%d",
                $rec, $zone, $match_counter{$state_key}, $raw_input // '', $zone_awaiting_resume{$state_key} || 0, $power_turned_on ? 1 : 0, $source_switched_to_lyrion ? 1 : 0));

            if ($match_counter{$state_key} >= 2) {
                $match_counter{$state_key} = 0;
                $zone_awaiting_resume{$state_key} = 0;
                $mismatch_counter{$state_key} = 0;
                $last_poweron_time{$state_key} = time();
                $zone_is_playing{$state_key} = 1;

                _infoLog("[FAIL-SAFE TRIGGER] Auto-Resuming '$client_name' (Receiver $rec Zone $zone) because AVR is ON and source matches '$configured_source'");
                if ($client->isPaused()) {
                    $client->execute(['pause', 0]);
                } elsif ($client->isStopped()) {
                    $client->execute(['play']);
                }
            }
        } else {
            $match_counter{$state_key} = 0;
        }
    }
}

sub _isSourceMatch {
    my ($configured, $reported) = @_;
    return 1 unless defined $configured && defined $reported;

    my $c = uc($configured);
    my $r = uc($reported);

    $c =~ s/^(?:SI|Z2)//;
    $r =~ s/^(?:SI|Z2)//;
    $c =~ s/[^A-Z0-9]//g;
    $r =~ s/[^A-Z0-9]//g;

    return 1 if $c eq '' || $r eq '';

    my %aliases = (
        'CBLSAT'        => 'SATCBL',
        'SATCBL'        => 'SATCBL',
        'MPLAY'         => 'MEDIAPLAYER',
        'MEDIAPLAYER'   => 'MEDIAPLAYER',
        'NET'           => 'HEOS',
        'HEOS'          => 'HEOS',
        'NETWORK'       => 'HEOS',
        'NETUSB'        => 'HEOS',
        'MEDIASERVER'   => 'HEOS',
        'SERVER'        => 'HEOS',
        'ONLINEMUSIC'   => 'HEOS',
        'IRADIO'        => 'HEOS',
        'INTERNETRADIO' => 'HEOS',
        'SPOTIFY'       => 'HEOS',
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

    if (length($c) >= 4 && length($r) >= 4) {
        return 1 if (index($r, $c) == 0 || index($c, $r) == 0);
    }

    return 0;
}

1;
