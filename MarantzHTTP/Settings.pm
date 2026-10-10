package Plugins::MarantzHTTP::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('plugin.marantzhttp');
my $log   = eval { logger('plugin.marantzhttp') } || eval { Slim::Utils::Log->logger('plugin.marantzhttp') };

# Cache in memory to ensure 0ms instantaneous page loads
my $cached_playlists = [];
my $last_playlist_scan = 0;
my $cached_dynamic_playlists = [];
my $last_dynamic_scan = 0;

sub name { 
    return eval { Slim::Web::HTTP::CSRF->protectName('PLUGIN_MARANTZHTTP') } || 'PLUGIN_MARANTZHTTP';
}

sub page { 
    return eval { Slim::Web::HTTP::CSRF->protectURI('plugins/MarantzHTTP/settings/basic.html') } || 'plugins/MarantzHTTP/settings/basic.html';
}

sub prefs { 
    return ($prefs, qw(
        ip port 
        mac_z1 power_on_z1 source_z1 set_sound_mode_on_power_z1 sound_mode_z1 set_room_preset_on_power_z1 room_preset_z1 set_volume_on_power_z1 power_volume_z1 pause_on_off_or_source_z1 resume_on_source_z1 
        play_playlist_on_power_z1 playlist_type_z1 playlist_z1 dynamic_playlist_z1 shuffle_z1 play_only_if_empty_z1
        mac_z2 power_on_z2 source_z2 set_volume_on_power_z2 power_volume_z2 pause_on_off_or_source_z2 resume_on_source_z2 
        play_playlist_on_power_z2 playlist_type_z2 playlist_z2 dynamic_playlist_z2 shuffle_z2 play_only_if_empty_z2
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

# Supported sound modes on Marantz AVR (matching receiver capabilities)
sub getDefaultSoundModesZ1 {
    return [
        { value => 'MSSTEREO',        name => 'Stereo',                    desc => 'Stereo 2-kanaals weergave (met subwoofer/bass management)' },
        { value => 'MSDIRECT',        name => 'Direct',                    desc => 'Directe pure weergave (kortste signaalpad)' },
        { value => 'MSPURE DIRECT',   name => 'Pure Direct',               desc => 'Pure Direct (maximale geluidskwaliteit, display uit)' },
        { value => 'MSMCH STEREO',    name => 'Multi Ch Stereo',           desc => 'Multi Channel / All Channel Stereo (over alle speakers)' },
        { value => 'MSDOLBY DIGITAL', name => 'Dolby Surround',            desc => 'Dolby Surround upmixing' },
        { value => 'MSDTS SURROUND',  name => 'DTS Neural:X',              desc => 'DTS Neural:X meerkanaals upmixing' },
        { value => 'MSVIRTUAL',       name => 'Virtual',                   desc => 'Virtuele surroundweergave' },
    ];
}

# Supported Dirac Live & Audyssey room calibration presets on Marantz/Denon AVR
sub getDefaultRoomPresetsZ1 {
    return [
        { value => 'SPPR 1',            name => 'Speaker Preset 1',            desc => 'Speaker Preset 1 (standaard Audyssey of Dirac Slot 1 kalibratie)' },
        { value => 'SPPR 2',            name => 'Speaker Preset 2',            desc => 'Speaker Preset 2 (Dirac Slot 2 of alternatieve configuratie)' },
        { value => 'PSDIRAC 1',         name => 'Dirac Live - Slot 1',         desc => 'Activeert Dirac Live filter slot 1' },
        { value => 'PSDIRAC 2',         name => 'Dirac Live - Slot 2',         desc => 'Activeert Dirac Live filter slot 2' },
        { value => 'PSDIRAC 3',         name => 'Dirac Live - Slot 3',         desc => 'Activeert Dirac Live filter slot 3' },
        { value => 'PSDIRAC OFF',       name => 'Dirac Live - Uit',            desc => 'Schakelt Dirac Live filter uit' },
        { value => 'PSMULTEQ:AUDYSSEY', name => 'Audyssey - Reference',        desc => 'Audyssey MultEQ Reference doelcurve' },
        { value => 'PSMULTEQ:FLAT',     name => 'Audyssey - Flat',             desc => 'Audyssey Flat doelcurve' },
        { value => 'PSMULTEQ:BYP.LR',   name => 'Audyssey - L/R Bypass',       desc => 'Audyssey MultEQ actief met bypass voor Front L/R' },
        { value => 'PSMULTEQ:OFF',      name => 'Audyssey - Uit',              desc => 'Schakelt Audyssey MultEQ correctie uit' },
        { value => 'PSDYNEQ ON',        name => 'Audyssey Dynamic EQ - Aan',   desc => 'Activeert Audyssey Dynamic EQ' },
        { value => 'PSDYNEQ OFF',       name => 'Audyssey Dynamic EQ - Uit',   desc => 'Schakelt Audyssey Dynamic EQ uit' },
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

# Fast, non-blocking scan of LMS in-memory playlists and playlist folder
sub getAvailablePlaylists {
    my $force = shift || 0;
    my $now = time();

    # Return cached playlists if scanned recently (< 60s), ensuring 0ms page renders
    if (!$force && $cached_playlists && scalar(@$cached_playlists) > 0 && ($now - $last_playlist_scan < 60)) {
        return $cached_playlists;
    }

    my %playlists;

    # 1. Native LMS Request: instantaneous, reads from LMS in-memory cache
    eval {
        require Slim::Control::Request;
        my $req = Slim::Control::Request::executeRequest(undef, ['playlists', 0, 1000]);
        if ($req) {
            my $loop = $req->getResultLoop('playlists_loop') || [];
            for my $item (@$loop) {
                my $title = $item->{playlist} || $item->{title} || '';
                my $url   = $item->{url} || $item->{id} || '';
                my $id    = $url || $title;
                if ($id) {
                    $playlists{$id} = {
                        id    => $id,
                        title => $title || $id,
                        url   => $url,
                    };
                }
            }
        }
    };

    # 2. Check playlist folder with strict safety limit (max 100 files, skips if inaccessible)
    eval {
        my $playlistdir = Slim::Utils::Prefs::preferences('server')->get('playlistdir');
        if ($playlistdir && -d $playlistdir) {
            if (opendir(my $dh, $playlistdir)) {
                my $count = 0;
                while (my $file = readdir($dh)) {
                    last if ++$count > 100;
                    next if $file =~ /^\./;
                    if ($file =~ /\.(m3u|m3u8|pls|cue)$/i) {
                        require File::Spec;
                        my $full_path = File::Spec->catfile($playlistdir, $file);
                        my $title = $file;
                        $title =~ s/\.[^.]+$//;
                        $playlists{$full_path} ||= {
                            id    => $full_path,
                            title => "$title ($file)",
                            url   => "file://$full_path",
                        };
                    }
                }
                closedir($dh);
            }
        }
    };

    my @sorted = sort { lc($a->{title}) cmp lc($b->{title}) } values %playlists;
    $cached_playlists = \@sorted;
    $last_playlist_scan = $now;
    return $cached_playlists;
}

sub _cleanDynamicId {
    my $id = shift;
    return '' unless defined $id;
    my $clean = lc($id);
    $clean =~ s/^\s+|\s+$//g;
    $clean =~ s/\.(sql|dpl|xml)$//i;
    $clean =~ s/^(dplccustom_|dplcustom_|dplusercustom_|sqlplaylist_|dynamicplaylist_|custom_|dplc_|dpl_|sql_)//i;
    $clean =~ s/[^a-z0-9]//g;
    return $clean;
}

sub _cleanDynamicTitle {
    my $title = shift;
    return '' unless defined $title;
    my $clean = lc($title);
    $clean =~ s/\s*\([^)]*\)\s*$//;
    $clean =~ s/^\s+|\s+$//g;
    $clean =~ s/\.(sql|dpl|xml)$//i;
    $clean =~ s/^(dplccustom_|dplcustom_|dplusercustom_|sqlplaylist_|dynamicplaylist_|custom_|dplc_|dpl_|sql_)//i;
    $clean =~ s/[^a-z0-9]//g;
    return $clean;
}

sub _matchesDynamicId {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    my $ca = _cleanDynamicId($a);
    my $cb = _cleanDynamicId($b);
    return 1 if ($ca ne '' && $ca eq $cb);
    return 0;
}

# Scan available dynamic playlists from Dynamic Playlists plugin (v4.7.1) and Dynamic Playlist Creator (DPLC)
sub getAvailableDynamicPlaylists {
    my $force = shift || 0;
    my $now = time();

    if (!$force && $cached_dynamic_playlists && scalar(@$cached_dynamic_playlists) > 0 && ($now - $last_dynamic_scan < 60)) {
        return $cached_dynamic_playlists;
    }

    my %dynamic_playlists;

    # 1. Exhaustive disk scan for user's custom Dynamic Playlist Creator (DPLC) & SQLPlayList files
    # DPLC stores .sql and .xml files in 'DynamicPlaylistCreator' directory in prefs or playlistdir
    eval {
        require File::Spec;
        my @candidate_dirs;

        # Preferences directory candidates
        my @prefs_dirs;
        eval {
            if (Slim::Utils::OSDetect->can('dirsFor')) {
                push @prefs_dirs, Slim::Utils::OSDetect::dirsFor('prefs');
            }
        };
        push @prefs_dirs, '/var/lib/squeezeboxserver/prefs', '/etc/squeezeboxserver/prefs', '/var/lib/squeezeboxserver/cache';

        for my $pd (@prefs_dirs) {
            next unless $pd && -d $pd;
            push @candidate_dirs, File::Spec->catdir($pd, 'DynamicPlaylistCreator');
            push @candidate_dirs, File::Spec->catdir($pd, 'dynamicplaylistcreator');
            push @candidate_dirs, File::Spec->catdir($pd, 'plugin', 'DynamicPlaylistCreator');
            push @candidate_dirs, File::Spec->catdir($pd, 'plugin', 'dynamicplaylistcreator');
            push @candidate_dirs, File::Spec->catdir($pd, 'plugin', 'dynamicplaylists');
            push @candidate_dirs, File::Spec->catdir($pd, 'SQLPlaylist');
            push @candidate_dirs, File::Spec->catdir($pd, 'plugin', 'SQLPlaylist');
            push @candidate_dirs, File::Spec->catdir($pd, 'plugin', 'sqlplaylist');
        }

        # DPLC & DynamicPlaylist plugin explicit preferences
        eval {
            my $dplc_custom = Slim::Utils::Prefs::preferences('plugin.dynamicplaylistcreator')->get('customdir');
            push @candidate_dirs, $dplc_custom if $dplc_custom && -d $dplc_custom;
            my $dplc_parent = Slim::Utils::Prefs::preferences('plugin.dynamicplaylistcreator')->get('parentfolder');
            if ($dplc_parent && -d $dplc_parent) {
                push @candidate_dirs, File::Spec->catdir($dplc_parent, 'DynamicPlaylistCreator');
                push @candidate_dirs, $dplc_parent;
            }
            my $dpl_custom = Slim::Utils::Prefs::preferences('plugin.dynamicplaylist')->get('customdir');
            push @candidate_dirs, $dpl_custom if $dpl_custom && -d $dpl_custom;
            my $sql_custom = Slim::Utils::Prefs::preferences('plugin.sqlplaylist')->get('customdir');
            push @candidate_dirs, $sql_custom if $sql_custom && -d $sql_custom;
        };

        # Playlist directory candidates
        eval {
            my $playlistdir = Slim::Utils::Prefs::preferences('server')->get('playlistdir');
            if ($playlistdir && -d $playlistdir) {
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'DynamicPlaylistCreator');
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'dynamicplaylistcreator');
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'DynamicPlayLists');
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'dynamicplaylists');
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'dynamic');
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'SQLPlaylist');
                push @candidate_dirs, File::Spec->catdir($playlistdir, 'sqlplaylist');
                push @candidate_dirs, $playlistdir;
            }
        };

        # Dedup candidate directories and scan
        my %seen_dirs;
        for my $dir (@candidate_dirs) {
            next unless $dir && -d $dir && !$seen_dirs{$dir}++;
            if (opendir(my $dh, $dir)) {
                my @files = readdir($dh);
                closedir($dh);

                for my $file (@files) {
                    next if $file =~ /^\./;
                    if ($file =~ /\.(sql|dpl)$/i) {
                        my $base = $file;
                        $base =~ s/\.[^.]+$//;

                        # Try to resolve friendly title from matching XML or SQL header
                        my $clean_title = '';
                        my $xml_path = File::Spec->catfile($dir, "$base.xml");
                        my $customval_path = File::Spec->catfile($dir, "$base.customvalues.xml");

                        for my $xp ($xml_path, $customval_path) {
                            if (-f $xp && open(my $xfh, '<', $xp)) {
                                my $xml_content = do { local $/; <$xfh> };
                                close($xfh);
                                if ($xml_content =~ /<name>(.*?)<\/name>/i || $xml_content =~ /<title>(.*?)<\/title>/i) {
                                    $clean_title = $1;
                                    last;
                                }
                            }
                        }

                        # If no title from XML, check SQL comments
                        if (!$clean_title) {
                            my $sql_path = File::Spec->catfile($dir, $file);
                            if (open(my $sfh, '<', $sql_path)) {
                                my $lines = 0;
                                while (my $line = <$sfh>) {
                                    last if ++$lines > 30;
                                    if ($line =~ /--\s*Playlist(?:Name)?\s*:\s*(.*)/i || $line =~ /--\s*Name\s*:\s*(.*)/i) {
                                        $clean_title = $1;
                                        $clean_title =~ s/^\s+|\s+$//g;
                                        last;
                                    }
                                }
                                close($sfh);
                            }
                        }

                        if (!$clean_title) {
                            $clean_title = $base;
                            $clean_title =~ s/_/ /g;
                            $clean_title =~ s/\b(\w)/\U$1/g;
                        }

                        # Determine primary ID used by Dynamic Playlists plugin
                        my $lc_base = lc($base);
                        my $is_sqlplaylist = ($dir =~ /sqlplaylist/i);
                        my $prefix = $is_sqlplaylist ? 'sqlplaylist_' : 'dplccustom_';
                        my $full_id = $prefix . $lc_base;

                        # Store strictly under canonical ID (do NOT double-store under $lc_base)
                        my $canonical_key = _cleanDynamicId($full_id) || lc($full_id);
                        $dynamic_playlists{$canonical_key} = {
                            id       => $full_id,
                            title    => "$clean_title ($full_id)",
                            raw_name => $base,
                            clean_id => _cleanDynamicId($full_id),
                            source   => $is_sqlplaylist ? 'SQLPlaylist' : 'Dynamic Playlist Creator',
                        };
                    }
                }
            }
        }
    };

    # 2. Query Dynamic Playlists (v4.7.1) via LMS Slim::Control::Request with player context
    eval {
        require Slim::Control::Request;
        my $client;
        eval {
            $client = Slim::Player::Client::getClient($prefs->get('mac_z1'))
                   || Slim::Player::Client::getClient($prefs->get('mac_z2'))
                   || Slim::Player::Client::getFirst();
        };

        for my $cmd (
            ['dynamicplaylist', 'playlists', 0, 1000],
            ['dynamicplaylists', 0, 1000],
            ['dynamicplaylist', 'items', 0, 1000],
        ) {
            my $req = Slim::Control::Request::executeRequest($client, $cmd);
            if ($req) {
                for my $loop_name (qw(playlists_loop dynamicplaylists_loop playlist_loop item_loop items_loop loop)) {
                    my $loop = $req->getResultLoop($loop_name);
                    if ($loop && ref($loop) eq 'ARRAY' && scalar(@$loop) > 0) {
                        for my $item (@$loop) {
                            my $id    = ref($item) eq 'HASH' ? ($item->{id} || $item->{playlist} || $item->{cmd}) : $item;
                            my $title = ref($item) eq 'HASH' ? ($item->{title} || $item->{name} || $id) : $id;
                            if ($id) {
                                my $clean_k = _cleanDynamicId($id);
                                my $clean_t = _cleanDynamicTitle($title);
                                my $already_present = 0;
                                for my $k (keys %dynamic_playlists) {
                                    if (_matchesDynamicId($k, $id) || 
                                        ($clean_t ne '' && _cleanDynamicTitle($dynamic_playlists{$k}->{title}) eq $clean_t)) {
                                        $already_present = 1;
                                        if ($id =~ /^(dplccustom_|sqlplaylist_)/i && $dynamic_playlists{$k}->{id} !~ /^(dplccustom_|sqlplaylist_)/i) {
                                            $dynamic_playlists{$k}->{id} = $id;
                                        }
                                        last;
                                    }
                                }
                                unless ($already_present) {
                                    my $entry_key = $clean_k || lc($id);
                                    $dynamic_playlists{$entry_key} = {
                                        id       => $id,
                                        title    => "$title ($id)",
                                        clean_id => $clean_k,
                                    };
                                }
                            }
                        }
                    }
                }
            }
        }
    };

    # 3. Direct Perl module examination for active Dynamic Playlists
    eval {
        require Slim::Utils::PluginManager;
        for my $pkg ('Plugins::DynamicPlayLists::Plugin', 'Plugins::DynamicPlaylistCreator::Plugin', 'Plugins::SQLPlayList::Plugin') {
            if (Slim::Utils::PluginManager->isEnabled($pkg) || eval "require $pkg; 1") {
                if ($pkg->can('getPlaylists')) {
                    my $client = eval { Slim::Player::Client::getFirst() };
                    my $list = eval { $pkg->getPlaylists($client) };
                    if ($list && ref($list) eq 'ARRAY') {
                        for my $item (@$list) {
                            my $id = ref($item) eq 'HASH' ? ($item->{id} || $item->{name}) : $item;
                            my $name = ref($item) eq 'HASH' ? ($item->{title} || $item->{name} || $id) : $id;
                            if ($id) {
                                my $clean_k = _cleanDynamicId($id);
                                my $clean_t = _cleanDynamicTitle($name);
                                my $already_present = 0;
                                for my $k (keys %dynamic_playlists) {
                                    if (_matchesDynamicId($k, $id) || 
                                        ($clean_t ne '' && _cleanDynamicTitle($dynamic_playlists{$k}->{title}) eq $clean_t)) {
                                        $already_present = 1;
                                        if ($id =~ /^(dplccustom_|sqlplaylist_)/i && $dynamic_playlists{$k}->{id} !~ /^(dplccustom_|sqlplaylist_)/i) {
                                            $dynamic_playlists{$k}->{id} = $id;
                                        }
                                        last;
                                    }
                                }
                                unless ($already_present) {
                                    my $entry_key = $clean_k || lc($id);
                                    $dynamic_playlists{$entry_key} = {
                                        id       => $id,
                                        title    => "$name ($id)",
                                        clean_id => $clean_k,
                                    };
                                }
                            }
                        }
                    }
                }
            }
        }
    };

    # 4. Include currently configured manual playlist preference so it is NEVER lost,
    # but ONLY if not already matching an existing scanned playlist!
    for my $z_pref ('dynamic_playlist_z1', 'dynamic_playlist_z2') {
        my $saved = $prefs->get($z_pref);
        if ($saved && $saved ne '' && $saved ne '__CUSTOM__') {
            my $already_present = 0;
            for my $k (keys %dynamic_playlists) {
                if (_matchesDynamicId($k, $saved) || _matchesDynamicId($dynamic_playlists{$k}->{id}, $saved)) {
                    $already_present = 1;
                    last;
                }
            }
            unless ($already_present) {
                my $display = $saved;
                $display =~ s/\.(sql|dpl|xml)$//i;
                $display =~ s/^(dplccustom_|dplcustom_|dplusercustom_|sqlplaylist_|dynamicplaylist_|custom_|dplc_|dpl_|sql_)//i;
                $display = ucfirst($display);
                my $clean_k = _cleanDynamicId($saved) || lc($saved);
                $dynamic_playlists{$clean_k} = {
                    id       => $saved,
                    title    => "$display ($saved)",
                    clean_id => $clean_k,
                };
            }
        }
    }

    # 5. Fallback presets ONLY if NO custom or scanned dynamic playlists were found anywhere
    if (scalar(keys %dynamic_playlists) == 0) {
        my @fallback_presets = (
            { id => 'dplccustom_topliedjes', title => 'Topliedjes (dplccustom_topliedjes)' },
            { id => 'randomtracks',           title => 'Willekeurige nummers (Random Tracks)' },
            { id => 'toprated',               title => 'Hoogst gewaardeerd (Top Rated)' },
            { id => 'forgottenfavorites',     title => 'Vergeten favorieten (Forgotten Favorites)' },
            { id => 'unplayedtracks',         title => 'Nog niet afgespeeld (Unplayed Tracks)' },
        );
        for my $p (@fallback_presets) {
            $dynamic_playlists{_cleanDynamicId($p->{id}) || lc($p->{id})} = $p;
        }
    }

    # 6. Comprehensive deduplication pass: Guarantee ZERO duplicate entries
    my %seen_id;
    my %seen_title;
    my @deduped;

    for my $p (values %dynamic_playlists) {
        next unless $p && ref($p) eq 'HASH' && $p->{id};
        my $clean_id = _cleanDynamicId($p->{id});
        my $clean_title = _cleanDynamicTitle($p->{title} || $p->{id});

        next if ($clean_id ne '' && $seen_id{$clean_id}++);
        next if ($clean_title ne '' && $seen_title{$clean_title}++);

        $seen_id{$clean_id} = 1 if $clean_id ne '';
        $seen_title{$clean_title} = 1 if $clean_title ne '';
        push @deduped, $p;
    }

    my @sorted = sort { lc($a->{title}) cmp lc($b->{title}) } @deduped;
    $cached_dynamic_playlists = \@sorted;
    $last_dynamic_scan = $now;
    return $cached_dynamic_playlists;
}

# AJAX endpoint to return playlists JSON for dynamic button refresh
sub getPlaylistsAjax {
    my ($classOrClient, $params, $callback, $httpClient, $response) = @_;

    # Force immediate re-scan when button is clicked
    my $playlists = getAvailablePlaylists(1);
    my $dynamic_playlists = getAvailableDynamicPlaylists(1);

    my $has_dpl_plugin = 0;
    eval {
        require Slim::Utils::PluginManager;
        $has_dpl_plugin = Slim::Utils::PluginManager->isEnabled('Plugins::DynamicPlayLists::Plugin') ? 1 : 0;
    };

    my $json_text = eval {
        require JSON::XS;
        JSON::XS::encode_json({
            success => 1,
            playlists => $playlists,
            dynamic_playlists => $dynamic_playlists,
            dpl_plugin_installed => $has_dpl_plugin,
        });
    } || eval {
        require JSON;
        JSON::encode_json({
            success => 1,
            playlists => $playlists,
            dynamic_playlists => $dynamic_playlists,
            dpl_plugin_installed => $has_dpl_plugin,
        });
    } || '{"success":1,"playlists":[],"dynamic_playlists":[]}';

    # Resolve response object
    if (!defined $response && defined $httpClient && eval { $httpClient->can('content_type') }) {
        $response = $httpClient;
    }

    if (defined $response && ref($response) && eval { $response->can('content_type') }) {
        $response->content_type('application/json; charset=utf-8');
        eval { $response->header('Cache-Control' => 'no-cache, no-store, must-revalidate'); };
        eval { $response->header('Pragma' => 'no-cache'); };
    }

    if (ref($callback) eq 'CODE') {
        return $callback->($classOrClient, $params, \$json_text, $httpClient, $response);
    }

    return \$json_text;
}

# AJAX endpoint to detect Marantz receiver model and current sound mode capabilities
sub detectReceiverAjax {
    my ($classOrClient, $params, $callback, $httpClient, $response) = @_;

    my $ip = (defined $params && $params->{ip}) ? $params->{ip} : $prefs->get('ip');
    my $port = (defined $params && $params->{port}) ? $params->{port} : ($prefs->get('port') || '8080');

    $ip =~ s/^\s+|\s+$//g if defined $ip;
    $ip =~ s{^https?://}{}i if defined $ip;
    $ip =~ s{/.*$}{} if defined $ip;

    $port =~ s/^\s+|\s+$//g if defined $port;
    $port =~ s/[^0-9]//g if defined $port;
    $port ||= '8080';

    my $sound_modes = getDefaultSoundModesZ1();

    my $send_json = sub {
        my $data = shift;
        my $json_text = eval {
            require JSON::XS;
            JSON::XS::encode_json($data);
        } || eval {
            require JSON;
            JSON::encode_json($data);
        } || '{"success":0}';

        if (!defined $response && defined $httpClient && eval { $httpClient->can('content_type') }) {
            $response = $httpClient;
        }

        if (defined $response && ref($response) && eval { $response->can('content_type') }) {
            $response->content_type('application/json; charset=utf-8');
            eval { $response->header('Cache-Control' => 'no-cache, no-store, must-revalidate'); };
            eval { $response->header('Pragma' => 'no-cache'); };
        }

        if (ref($callback) eq 'CODE') {
            return $callback->($classOrClient, $params, \$json_text, $httpClient, $response);
        }

        return \$json_text;
    };

    unless ($ip) {
        return $send_json->({
            success     => 0,
            error       => 'Geen IP-adres geconfigureerd in instellingen',
            sound_modes => $sound_modes,
        });
    }

    my $url_status = "http://$ip:$port/goform/formMainZone_MainZoneXmlStatusLite.xml";

    eval {
        require Slim::Networking::SimpleAsyncHTTP;
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $res = shift;
                my $content = eval { $res->content() } || eval { $res->result() } || '';

                my $power = 'UNKNOWN';
                if ($content =~ /<ZonePower>(?:<value>)?([^<]+)/i || $content =~ /<Power>(?:<value>)?([^<]+)/i) {
                    $power = uc($1);
                }

                my $surround = '';
                if ($content =~ /<selectSurround>(?:<value>)?([^<]+)/i || $content =~ /<SurroundMode>(?:<value>)?([^<]+)/i) {
                    $surround = uc($1);
                    $surround =~ s/^\s+|\s+$//g;
                }

                my $model = 'Marantz / Denon AVR';
                if ($content =~ /<ModelName>(?:<value>)?([^<]+)/i || $content =~ /<DeviceModel>(?:<value>)?([^<]+)/i) {
                    $model = $1;
                    $model =~ s/^\s+|\s+$//g;
                }

                my $detected_cmd = 'MSSTEREO';
                if ($surround) {
                    if ($surround =~ /PURE.*DIRECT/i || $surround eq 'PURE DIRECT') {
                        $detected_cmd = 'MSPURE DIRECT';
                    } elsif ($surround =~ /DIRECT/i) {
                        $detected_cmd = 'MSDIRECT';
                    } elsif ($surround =~ /(?:MCH|MULTI|ALL).*STEREO/i || $surround eq 'MULTI CH STEREO' || $surround eq 'MCH STEREO') {
                        $detected_cmd = 'MSMCH STEREO';
                    } elsif ($surround =~ /DOLBY/i) {
                        $detected_cmd = 'MSDOLBY DIGITAL';
                    } elsif ($surround =~ /NEURAL/i || $surround eq 'DTS SURROUND') {
                        $detected_cmd = 'MSDTS SURROUND';
                    } elsif ($surround =~ /VIRTUAL/i) {
                        $detected_cmd = 'MSVIRTUAL';
                    } elsif ($surround =~ /STEREO/i) {
                        $detected_cmd = 'MSSTEREO';
                    } else {
                        $detected_cmd = "MS$surround";
                    }
                }

                $send_json->({
                    success            => 1,
                    ip                 => $ip,
                    port               => $port,
                    model              => $model,
                    power              => $power,
                    current_sound_mode => $surround || 'Stereo',
                    detected_cmd       => $detected_cmd,
                    sound_modes        => $sound_modes,
                });
            },
            sub {
                my ($http, $err) = @_;
                $send_json->({
                    success     => 0,
                    error       => $err || 'Verbinding time-out of receiver onbereikbaar',
                    ip          => $ip,
                    port        => $port,
                    sound_modes => $sound_modes,
                });
            },
            { timeout => 3 }
        );
        $http->get($url_status);
    };

    if ($@) {
        return $send_json->({
            success     => 0,
            error       => "HTTP fout: $@",
            sound_modes => $sound_modes,
        });
    }
}

# Non-blocking page render: zero network delays, instant load time
sub beforeRender {
    my ($class, $params) = @_;

    $params->{sources_z1} = [ @{ getDefaultSourcesZ1() } ];
    $params->{sources_z2} = [ @{ getDefaultSourcesZ2() } ];
    $params->{sound_modes_z1} = [ @{ getDefaultSoundModesZ1() } ];
    $params->{room_presets_z1} = [ @{ getDefaultRoomPresetsZ1() } ];

    # Ensure currently configured sound mode is retained in dropdown even if custom
    my $current_sm_z1 = $prefs->get('sound_mode_z1');
    if ($current_sm_z1 && !grep { $_->{value} eq $current_sm_z1 } @{$params->{sound_modes_z1}}) {
        unshift @{$params->{sound_modes_z1}}, { value => $current_sm_z1, name => "$current_sm_z1 (Aangepast)", desc => 'Aangepaste geluidsmodus' };
    }

    # Ensure currently configured room preset is retained in dropdown even if custom
    my $current_rp_z1 = $prefs->get('room_preset_z1');
    if ($current_rp_z1 && !grep { $_->{value} eq $current_rp_z1 } @{$params->{room_presets_z1}}) {
        unshift @{$params->{room_presets_z1}}, { value => $current_rp_z1, name => "$current_rp_z1 (Aangepast)", desc => 'Aangepaste kalibratie preset' };
    }

    # Standard Playlists discovery
    my $playlists = getAvailablePlaylists();
    $params->{available_playlists} = $playlists;

    # Dynamic Playlists (v4.7.1) discovery
    my $dynamic_playlists = getAvailableDynamicPlaylists();
    $params->{available_dynamic_playlists} = [ @$dynamic_playlists ];

    my $has_dpl_plugin = 0;
    eval {
        require Slim::Utils::PluginManager;
        $has_dpl_plugin = Slim::Utils::PluginManager->isEnabled('Plugins::DynamicPlayLists::Plugin') ? 1 : 0;
    };
    $params->{dpl_plugin_installed} = $has_dpl_plugin;

    # Ensure currently configured dynamic playlists are retained even if temporarily offline
    my $cur_dpl_z1 = $prefs->get('dynamic_playlist_z1');
    if ($cur_dpl_z1 && $cur_dpl_z1 ne '' && $cur_dpl_z1 ne '__CUSTOM__') {
        unless (grep { _matchesDynamicId($_->{id}, $cur_dpl_z1) } @{$params->{available_dynamic_playlists}}) {
            my $disp = $cur_dpl_z1;
            $disp =~ s/\.(sql|dpl|xml)$//i;
            $disp =~ s/^(dplccustom_|dplcustom_|dplusercustom_|sqlplaylist_|dynamicplaylist_|custom_|dplc_|dpl_|sql_)//i;
            $disp = ucfirst($disp);
            unshift @{$params->{available_dynamic_playlists}}, { id => $cur_dpl_z1, title => "$disp ($cur_dpl_z1)" };
        }
    }

    my $cur_dpl_z2 = $prefs->get('dynamic_playlist_z2');
    if ($cur_dpl_z2 && $cur_dpl_z2 ne '' && $cur_dpl_z2 ne '__CUSTOM__') {
        unless (grep { _matchesDynamicId($_->{id}, $cur_dpl_z2) } @{$params->{available_dynamic_playlists}}) {
            my $disp = $cur_dpl_z2;
            $disp =~ s/\.(sql|dpl|xml)$//i;
            $disp =~ s/^(dplccustom_|dplcustom_|dplusercustom_|sqlplaylist_|dynamicplaylist_|custom_|dplc_|dpl_|sql_)//i;
            $disp = ucfirst($disp);
            unshift @{$params->{available_dynamic_playlists}}, { id => $cur_dpl_z2, title => "$disp ($cur_dpl_z2)" };
        }
    }

    # Ensure currently configured playlists are retained even if temporarily offline
    my $cur_pl_z1 = $prefs->get('playlist_z1');
    if ($cur_pl_z1 && !grep { $_->{id} eq $cur_pl_z1 } @{$params->{available_playlists}}) {
        my $display_z1 = $cur_pl_z1;
        $display_z1 =~ s{^.*/}{};
        unshift @{$params->{available_playlists}}, { id => $cur_pl_z1, title => "$display_z1 (Opgeslagen)", url => $cur_pl_z1 };
    }

    my $cur_pl_z2 = $prefs->get('playlist_z2');
    if ($cur_pl_z2 && !grep { $_->{id} eq $cur_pl_z2 } @{$params->{available_playlists}}) {
        my $display_z2 = $cur_pl_z2;
        $display_z2 =~ s{^.*/}{};
        unshift @{$params->{available_playlists}}, { id => $cur_pl_z2, title => "$display_z2 (Opgeslagen)", url => $cur_pl_z2 };
    }

    # Ensure currently configured source is retained in dropdown even if custom
    my $current_z1 = $prefs->get('source_z1');
    if ($current_z1 && !grep { $_->{value} eq $current_z1 } @{$params->{sources_z1}}) {
        unshift @{$params->{sources_z1}}, { value => $current_z1, name => $current_z1 };
    }

    my $current_z2 = $prefs->get('source_z2');
    if ($current_z2 && !grep { $_->{value} eq $current_z2 } @{$params->{sources_z2}}) {
        unshift @{$params->{sources_z2}}, { value => $current_z2, name => $current_z2 };
    }

    # Discover and list currently connected LMS players for 1-click selection
    my @players;
    my %seen_macs;

    if (eval { require Slim::Player::Client; 1; }) {
        for my $c (Slim::Player::Client::clients()) {
            next unless $c;
            my $mac = lc($c->id() || '');
            $mac =~ s/[^a-f0-9]//g;
            next unless $mac;
            $seen_macs{$mac} = 1;
            my $name = eval { $c->name() } || $mac;
            my $display_mac = join(':', $mac =~ /../g);
            push @players, {
                id   => $display_mac,
                name => "$name ($display_mac)",
            };
        }
    }

    # If a previously configured MAC is currently offline/turned off, preserve it in the dropdown
    for my $k ('mac_z1', 'mac_z2') {
        my $saved = $prefs->get($k);
        if ($saved) {
            my $clean = lc($saved);
            $clean =~ s/[^a-f0-9]//g;
            if ($clean && !$seen_macs{$clean}) {
                my $display = join(':', $clean =~ /../g);
                push @players, {
                    id   => $display,
                    name => "$display (Offline / Opgeslagen)",
                };
                $seen_macs{$clean} = 1;
            }
        }
    }

    # Precalculate selection matching in Perl for 100% reliable matching regardless of case/format
    my $cur_mac_z1 = lc($prefs->get('mac_z1') || '');
    $cur_mac_z1 =~ s/[^a-f0-9]//g;
    my $cur_mac_z2 = lc($prefs->get('mac_z2') || '');
    $cur_mac_z2 =~ s/[^a-f0-9]//g;

    for my $p (@players) {
        my $clean = lc($p->{id});
        $clean =~ s/[^a-f0-9]//g;
        $p->{selected_z1} = ($cur_mac_z1 && $clean eq $cur_mac_z1) ? 1 : 0;
        $p->{selected_z2} = ($cur_mac_z2 && $clean eq $cur_mac_z2) ? 1 : 0;
    }

    $params->{available_players} = \@players;
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

        # Sanitize MAC addresses
        for my $mac_key ('pref_mac_z1', 'pref_mac_z2') {
            if (defined $params->{$mac_key}) {
                $params->{$mac_key} =~ s/^\s+|\s+$//g;
                # Discard special placeholder values
                if ($params->{$mac_key} eq '__MANUAL__') {
                    $params->{$mac_key} = '';
                }
            }
        }
    }

    my $res = $class->SUPER::handler($client, $params, $callback, @args);

    if ($params->{'saveSettings'}) {
        eval {
            require Plugins::MarantzHTTP::Plugin;
            Plugins::MarantzHTTP::Plugin::checkAndManagePolling();
            Plugins::MarantzHTTP::Plugin::pollActiveMarantzZones();
        };
    }

    return $res;
}

1;
