package Plugins::MarantzHTTP::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our $VERSION = '1.7.6';

# Initialize Lyrion / LMS Logger Category
my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.marantzhttp',
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_MARANTZHTTP',
});

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
my %receiver_power_state;     # 'ON' or 'STANDBY'
my %receiver_source_state;    # last reported source (e.g. 'SAT/CBL', 'GAME1')
my %zone_is_playing;          # 1 if currently active/playing in this zone
my %zone_awaiting_resume;     # 1 if zone was auto-paused or waiting for receiver to return to Lyrion
my %internal_auto_pause;      # 1 while plugin is executing fail-safe auto-pause

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

    # Power On / Source trigger: On Play, Playlist start, Unpause (pause 0 / resume / load)
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['play']]);
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['pause']]);
    Slim::Control::Request::subscribe(\&playTriggerCallback, [['playlist'], ['play', 'open', 'load', 'loadtracks', 'loadalbum', 'resume', 'pause']]);

    _infoLog("MarantzHTTP v$VERSION initialized. Target AVR: " . $prefs->get('ip') . ':' . ($prefs->get('port') || '8080'));
    _debugLog("Subscriptions registered: mixer/volume, playback (play,pause,stop,newsong,open), playTrigger (play,pause,playlist:play,open,load,resume,pause)");

    # Check initial playback state
    checkAndManagePolling();
}

sub shutdownPlugin {
    _infoLog("MarantzHTTP plugin shutting down. Stopping all timers.");
    stopPollingTimer();
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
    # If the player is currently paused (e.g. user pressed pause, or toggle pause paused playback),
    # and this command is NOT an explicit unpause ('pause 0'), NEVER switch source or power on!
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
    my $ip   = $prefs->get('ip');
    my $port = $prefs->get('port') || '8080';
    unless ($ip) {
        _warnLog("[CONFIG] ensurePowerAndSource: Marantz IP address is not configured in settings");
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
    $zone_awaiting_resume{$zone} = 0; # Starting or resuming playback clears awaiting_resume flag
    $mismatch_counter{$zone} = 0;     # Reset fail-safe mismatch counter so auto-pause gives grace period
    $match_counter{$zone} = 0;

    my $is_already_on = ($receiver_power_state{$zone} && $receiver_power_state{$zone} eq 'ON') ? 1 : 0;

    if ($zone eq 'MV') {
        my $power_on_enabled = $prefs->get('power_on_z1');
        my $power_cmd = $power_on_enabled ? 'ZMON' : undef;
        my $source_cmd = $prefs->get('source_z1') || 'SISAT/CBL';
        # Only set initial power volume when powering on from Standby/Off
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
            _debugLog("[STATUS] Zone $zone player is STOPPED.");
        } elsif ($client->isPaused()) {
            # Only disarm auto-resume if receiver is currently ON and matches Lyrion source
            # (i.e. user intentionally paused while actively listening to Lyrion).
            # If the receiver is in STANDBY or on another input, maintain awaiting_resume flag!
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

            # Safety Net: If player is actively playing and no recent trigger in last 4s,
            # ensure Marantz power and input source are active (unless receiver is on another source)!
            my $now = time();
            my $last_start = $last_poweron_time{$zone} || 0;
            my $configured_source = ($zone eq 'MV') ? $prefs->get('source_z1') : $prefs->get('source_z2');
            my $receiver_is_on_other_source = ($receiver_source_state{$zone} && !_isSourceMatch($configured_source, $receiver_source_state{$zone}));

            if ($now - $last_start > 4 && !$receiver_is_on_other_source) {
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
                # AVR is already ON (e.g. on GAME1): switch source IMMEDIATELY
                _debugLog("[ACTION OUT] AVR already ON. Dispatching Source Switch immediately: $source_cmd -> $url_source");
                _sendHttpRequest($url_source);

                # Re-confirm at +800ms to guarantee input lock
                Slim::Utils::Timers::setTimer(undef, $now + 0.8, sub {
                    _debugLog("[ACTION OUT] Re-confirming Source Switch: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                });
            } else {
                # AVR waking from Standby: Marantz CPU takes ~600-800ms before accepting input changes
                _debugLog("[ACTION OUT] AVR waking from standby. Scheduling Source Switch: $source_cmd (+700ms and +2000ms retry)");
                Slim::Utils::Timers::setTimer(undef, $now + 0.7, sub {
                    _debugLog("[ACTION OUT] Dispatching Source Switch command: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                });

                # Re-confirm at +2.0s so HDMI board locks onto the selected input
                Slim::Utils::Timers::setTimer(undef, $now + 2.0, sub {
                    _debugLog("[ACTION OUT] Re-confirming Source Switch after power-up: $source_cmd -> $url_source");
                    _sendHttpRequest($url_source);
                });
            }
        }
    }

    # 3. Initial Volume (only on initial power-on from Standby/Off)
    if (!$is_already_on && defined $initial_volume && $initial_volume ne '') {
        my $vol = int($initial_volume);
        $vol = 0 if $vol < 0;
        $vol = 98 if $vol > 98;
        my $vol_cmd = ($zone eq 'Z2' ? 'Z2' : 'MV') . $vol;
        my $url_vol = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$vol_cmd";

        _debugLog("[ACTION OUT] Scheduling Power-On Volume: $vol_cmd (+1200ms delay)");
        Slim::Utils::Timers::setTimer(undef, $now + 1.2, sub {
            _debugLog("[ACTION OUT] Dispatching Power-On Volume command: $vol_cmd -> $url_vol");
            _sendHttpRequest($url_vol);

            if ($client) {
                my $mac = lc($client->id() || '');
                $mac =~ s/[^a-f0-9]//g;
                $syncing_clients{$mac} = 1;
                _debugLog("[MIXER SYNC] Aligning LMS mixer volume to $vol for client $mac");
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
                _debugLog("[HTTP ERROR] $url -> Failed/Timeout: " . ($error || 'Unknown error'));
            },
            { timeout => 3 }
        );
        $http->get($url);
    };
    if ($@) {
        _debugLog("[HTTP WARN] SimpleAsyncHTTP error: $@");
    }

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
        my $client_name = eval { $client->name() } || $mac;

        # Prevent circular feedback loops when volume is updated by Marantz sync
        if ($syncing_clients{$mac}) {
            _debugLog("[MIXER LOOP GUARD] Volume change for $mac suppressed (originates from Marantz sync).");
            return;
        }

        my $volume = int($client->volume());
        $volume = 0 if $volume < 0;
        $volume = 98 if $volume > 98;

        my $ip = $prefs->get('ip');
        my $port = $prefs->get('port') || '8080';
        unless ($ip) {
            _debugLog("[VOLUME] Marantz IP not configured, skipping volume sync for '$client_name'");
            return;
        }

        my $zone_cmd = getClientZone($client);
        if ($zone_cmd) {
            my $url = "http://$ip:$port/goform/formiPhoneAppDirect.xml?$zone_cmd$volume";
            _debugLog("[EVENT IN] Mixer volume changed on '$client_name' -> $volume (Zone: $zone_cmd). Dispatching to Marantz: $url");
            _sendHttpRequest($url);
        } else {
            _debugLog("[VOLUME] Player '$client_name' does not match Zone 1 or Zone 2 MAC.");
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

        # 1. Volume sync or fail-safe pause monitoring while playing
        if ($client->isPlaying()) {
            return 1;
        }

        # 2. Auto-resume monitoring when paused or stopped with resume enabled
        my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
        if ($resume_enabled && (!$client->isPlaying() && ($zone_awaiting_resume{$zone} || $client->isPaused()))) {
            return 1;
        }
    }
    return 0;
}

sub checkAndManagePolling {
    my $should_poll = shouldPollMarantz();
    if ($should_poll) {
        _debugLog("[POLL MANAGER] Active playing or paused player found. Starting background polling timer.");
        startPollingTimer();
    } else {
        _debugLog("[POLL MANAGER] No active player needing sync. Stopping background polling timer.");
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
        _debugLog("[POLL TIMER] Condition not met during tick. Polling stopped.");
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

        if ($client->isPlaying()) {
            $active_zones{$zone} ||= $client;
        } elsif (!$client->isPlaying()) {
            my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
            if ($resume_enabled && ($zone_awaiting_resume{$zone} || $client->isPaused())) {
                $active_zones{$zone} ||= $client;
            }
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
            my $http = shift;
            my $content = $http->content();
            _debugLog("[POLL RESP] Received XML status for Zone $zone (" . length($content) . " bytes)");
            _handleMarantzXmlResponse($content, $zone, $client);
        },
        sub {
            my ($http, $error) = @_;
            _debugLog("[POLL ERROR] Zone $zone XML query failed/timeout: " . ($error || 'Network error'));
        },
        { timeout => 2 }
    );
    $http->get($url);
}

sub _handleMarantzXmlResponse {
    my ($content, $zone, $client) = @_;
    return unless $content && $client;

    my $client_name = eval { $client->name() } || $client->id() || 'player';

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
                    _infoLog("[VOLUME SYNC] Marantz ($vol) -> LMS '$client_name' (was $current_vol). Updating slider.");
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
    # Automatically resumes playback when receiver is turned ON and switched to Lyrion!
    # Works seamlessly if AVR was in standby, switched input, or turned back on.
    # --------------------------------------------------------------------------
    my $resume_enabled = ($zone eq 'MV') ? $prefs->get('resume_on_source_z1') : $prefs->get('resume_on_source_z2');
    if ($resume_enabled && !$client->isPlaying()) {
        my $power_turned_on = ($prev_power eq 'STANDBY' && !$is_standby);
        my $source_switched_to_lyrion = ($prev_source ne 'UNKNOWN' && !_isSourceMatch($configured_source, $prev_source) && $source_matches);
        my $should_resume = (!$is_standby && $source_matches && ($zone_awaiting_resume{$zone} || $power_turned_on || $source_switched_to_lyrion));

        if ($should_resume) {
            $match_counter{$zone} = ($match_counter{$zone} || 0) + 1;
            _debugLog(sprintf("[FAIL-SAFE AUTO-RESUME] Zone %s match confirmed (%d/1 checks) | Source=%s | AwaitingResume=%d | PwrTurnedOn=%d | SrcSwitched=%d",
                $zone, $match_counter{$zone}, $raw_input // '', $zone_awaiting_resume{$zone} || 0, $power_turned_on ? 1 : 0, $source_switched_to_lyrion ? 1 : 0));
            if ($match_counter{$zone} >= 1) {
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

    _debugLog("[AJAX IN] Request to discover Marantz sources from $ip:$port");

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

    _debugLog("[AJAX OUT] Discovered sources: Z1 count=" . scalar(@$z1_sources) . ", Z2 count=" . scalar(@$z2_sources));

    require Slim::Web::HTTP;
    return Slim::Web::HTTP::sendContent($httpClient, 'application/json; charset=utf-8', $json_str);
}

1;
