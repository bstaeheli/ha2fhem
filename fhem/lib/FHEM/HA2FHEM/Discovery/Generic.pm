###############################################################################
# ha2fhem — generic (standard HA MQTT discovery) config parsing, pure module.
# Consumes discovery configs published by third parties (zigbee2mqtt,
# Tasmota, ESPHome, ...) — arbitrary state/command topics, abbreviated keys,
# value_templates. Normalizes them into the same entity shape produced by
# FHEM::HA2FHEM::Discovery::parse_config, so Bridge/Profiles/Client treat a
# generic entity exactly like one of ours.
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Discovery::Generic;

use strict;
use warnings;
use JSON::PP ();

use FHEM::HA2FHEM::Profiles;

# Official HA MQTT discovery abbreviations, restricted to the fields our
# profiles (switch/light/cover) and their attached sensor/binary_sensor
# readings actually consume, plus availability/device/common metadata.
# Unknown/unlisted keys pass through unchanged (per stage-1 scope, #17).
our %ABBREV = (
    atype             => 'automation_type',
    avty              => 'availability',
    avty_mode         => 'availability_mode',
    avty_t            => 'availability_topic',
    avty_tpl          => 'availability_template',
    bri_cmd_t         => 'brightness_command_topic',
    bri_cmd_tpl       => 'brightness_command_template',
    bri_scl           => 'brightness_scale',
    bri_stat_t        => 'brightness_state_topic',
    bri_val_tpl       => 'brightness_value_template',
    clrm              => 'color_mode',
    clrm_stat_t       => 'color_mode_state_topic',
    clrm_val_tpl      => 'color_mode_value_template',
    cmd_t             => 'command_topic',
    cmd_tpl           => 'command_template',
    dev               => 'device',
    dev_cla           => 'device_class',
    ent_cat           => 'entity_category',
    ent_pic           => 'entity_picture',
    exp_aft           => 'expire_after',
    fx_cmd_t          => 'effect_command_topic',
    fx_list           => 'effect_list',
    fx_stat_t         => 'effect_state_topic',
    fx_val_tpl        => 'effect_value_template',
    frc_upd           => 'force_update',
    ic                => 'icon',
    json_attr_t       => 'json_attributes_topic',
    json_attr_tpl     => 'json_attributes_template',
    max_mirs          => 'max_mireds',
    min_mirs          => 'min_mireds',
    obj_id            => 'object_id',
    on_cmd_type       => 'on_command_type',
    opt               => 'optimistic',
    pl                => 'payload',
    pl_avail          => 'payload_available',
    pl_cls            => 'payload_close',
    pl_not_avail      => 'payload_not_available',
    pl_off            => 'payload_off',
    pl_on             => 'payload_on',
    pl_open           => 'payload_open',
    pl_stop           => 'payload_stop',
    pos_clsd          => 'position_closed',
    pos_open          => 'position_open',
    pos_t             => 'position_topic',
    pos_tpl           => 'position_template',
    ret               => 'retain',
    set_pos_t         => 'set_position_topic',
    set_pos_tpl       => 'set_position_template',
    stat_cla          => 'state_class',
    stat_clsd         => 'state_closed',
    stat_closing      => 'state_closing',
    stat_off          => 'state_off',
    stat_on           => 'state_on',
    stat_open         => 'state_open',
    stat_opening      => 'state_opening',
    stat_stopped      => 'state_stopped',
    stat_t            => 'state_topic',
    stat_tpl          => 'state_template',
    stat_val_tpl      => 'state_value_template',
    sug_dsp_prc       => 'suggested_display_precision',
    sup_clrm          => 'supported_color_modes',
    sup_feat          => 'supported_features',
    tilt_clsd_val     => 'tilt_closed_value',
    tilt_cmd_t        => 'tilt_command_topic',
    tilt_cmd_tpl      => 'tilt_command_template',
    tilt_max          => 'tilt_max',
    tilt_min          => 'tilt_min',
    tilt_opnd_val     => 'tilt_opened_value',
    tilt_opt          => 'tilt_optimistic',
    tilt_status_t     => 'tilt_status_topic',
    tilt_status_tpl   => 'tilt_status_template',
    uniq_id           => 'unique_id',
    unit_of_meas      => 'unit_of_measurement',
    val_tpl           => 'value_template',
);

our %DEVICE_ABBREV = (
    cns => 'connections',
    cu  => 'configuration_url',
    hw  => 'hw_version',
    ids => 'identifiers',
    mf  => 'manufacturer',
    mdl => 'model',
    sa  => 'suggested_area',
    sn  => 'serial_number',
    sw  => 'sw_version',
);

our %AVAILABILITY_ABBREV = (
    t            => 'topic',
    pl_avail     => 'payload_available',
    pl_not_avail => 'payload_not_available',
);

# expand_abbreviations($config) -> new hashref, long-form keys.
# Pure: expands top-level, device.*, and availability[].* abbreviated keys;
# resolves the "~" base-topic shortcut (leading/trailing "~" in any
# top-level or availability[] string value); then folds a single
# availability[] entry into flat availability_topic/payload_available/
# payload_not_available so downstream code only deals with one shape.
sub expand_abbreviations {
    my ($config) = @_;
    return {} if ref $config ne 'HASH';

    my %out;
    for my $k (keys %$config) {
        $out{ $ABBREV{$k} // $k } = $config->{$k};
    }

    if (ref $out{device} eq 'HASH') {
        my %dev;
        for my $k (keys %{ $out{device} }) {
            $dev{ $DEVICE_ABBREV{$k} // $k } = $out{device}{$k};
        }
        $out{device} = \%dev;
    }

    if (ref $out{availability} eq 'ARRAY') {
        $out{availability} = [
            map {
                my $item = $_;
                ref $item eq 'HASH'
                    ? { map { ( $AVAILABILITY_ABBREV{$_} // $_ ) => $item->{$_} } keys %$item }
                    : $item;
            } @{ $out{availability} }
        ];
    }

    _substitute_base(\%out, $out{'~'}) if defined $out{'~'} && $out{'~'} ne '';
    delete $out{'~'};

    _flatten_availability(\%out);

    return \%out;
}

# "~" replaces the first or last character of any topic-ish string value
# with the base topic (HA MQTT discovery "~" shortcut). Recurses into
# availability[] entries (the only nested array of topic-bearing hashes we
# normalize in stage 1).
sub _substitute_base {
    my ($hashref, $base) = @_;
    for my $k (keys %$hashref) {
        my $v = $hashref->{$k};
        next if $k eq '~';
        if (defined $v && !ref $v && $v ne '') {
            if (substr($v, 0, 1) eq '~') {
                $hashref->{$k} = $base . substr($v, 1);
            }
            elsif (substr($v, -1) eq '~') {
                $hashref->{$k} = substr($v, 0, -1) . $base;
            }
        }
        elsif (ref $v eq 'ARRAY') {
            for my $item (@$v) {
                _substitute_base($item, $base) if ref $item eq 'HASH';
            }
        }
    }
    return;
}

sub _flatten_availability {
    my ($config) = @_;
    return if defined $config->{availability_topic};
    return if ref $config->{availability} ne 'ARRAY' || !@{ $config->{availability} };

    my $first = $config->{availability}[0];
    return if ref $first ne 'HASH';

    $config->{availability_topic}     = $first->{topic};
    $config->{payload_available}     //= $first->{payload_available};
    $config->{payload_not_available} //= $first->{payload_not_available};
    return;
}

# availability_value($config, $raw_payload) -> 'online' | 'offline' | $raw_payload
# Maps the vendor's raw availability payload onto our online/offline contract
# values; unrecognized payloads pass through unchanged (never crash/drop).
sub availability_value {
    my ($config, $raw) = @_;
    $config //= {};

    # modern z2m publishes bridge availability as JSON {"state":"online"} —
    # unwrap before comparing (caught live on a real broker 2026-07-09)
    if (defined $raw && $raw =~ /^\s*\{/) {
        my $data = eval { JSON::PP::decode_json($raw) };
        $raw = $data->{state} if ref $data eq 'HASH' && defined $data->{state};
    }

    my $avail_on  = $config->{payload_available}     // 'online';
    my $avail_off = $config->{payload_not_available}  // 'offline';
    return 'online'  if defined $raw && $raw eq $avail_on;
    return 'offline' if defined $raw && $raw eq $avail_off;
    return $raw;
}

# parse_config($genericPrefix, $topic, $payload) -> ($entity, undef) | (undef, $err)
# Topic shape: <gprefix>/<component>/[<node_id>/]<object_id>/config
# $entity shape matches FHEM::HA2FHEM::Discovery::parse_config exactly:
#   { component, object_id, device_id, entity_key, device_name, unique_id,
#     state_topic, config }
sub parse_config {
    my ($gprefix, $topic, $payload) = @_;

    my ($component, undef, $object_id) =
        $topic =~ m{^\Q$gprefix\E/([^/]+)/(?:([^/]+)/)?([^/]+)/config$}
        or return (undef, "not a generic discovery config topic: $topic");

    my $raw = eval { JSON::PP::decode_json($payload) };
    return (undef, "invalid JSON in generic discovery config for $object_id: $@")
        if !$raw || ref $raw ne 'HASH';

    my $config = expand_abbreviations($raw);

    my $state_topic = $config->{state_topic};
    return (undef, "generic discovery config $object_id: missing state_topic")
        if !defined $state_topic || $state_topic eq '';

    my $device      = ref $config->{device} eq 'HASH' ? $config->{device} : {};
    my $device_id   = _device_id($device, $object_id);
    my $device_name = (defined $device->{name} && $device->{name} ne '')
                     ? $device->{name} : $device_id;
    my $unique_id   = $config->{unique_id} // $object_id;
    my $entity_key  = _entity_key($unique_id, $device_name);

    return ({
        component   => $component,
        object_id   => $object_id,
        device_id   => $device_id,
        entity_key  => $entity_key,
        device_name => $device_name,
        unique_id   => $unique_id,
        state_topic => $state_topic,
        config      => $config,
    }, undef);
}

# object_id of a delete message (empty payload): just the topic match.
sub parse_delete_topic {
    my ($gprefix, $topic) = @_;
    my ($component, undef, $object_id) =
        $topic =~ m{^\Q$gprefix\E/([^/]+)/(?:([^/]+)/)?([^/]+)/config$}
        or return;
    return ($component, $object_id);
}

# device_id := slug of device.identifiers[0]; fallback device name;
# fallback object_id.
sub _device_id {
    my ($device, $object_id) = @_;
    my $ids = $device->{identifiers};
    my $raw;
    if (ref $ids eq 'ARRAY' && @$ids) {
        $raw = $ids->[0];
    }
    elsif (defined $ids && !ref $ids && $ids ne '') {
        $raw = $ids;
    }
    elsif (defined $device->{name} && $device->{name} ne '') {
        $raw = $device->{name};
    }
    else {
        $raw = $object_id;
    }
    return _slug($raw);
}

# entity_key := slug of unique_id, with a leading "<device_name>_" prefix
# stripped (Tasmota/ESPHome-style unique_ids are device-name-prefixed;
# z2m's are MAC-based and never match, so nothing is stripped there).
sub _entity_key {
    my ($unique_id, $device_name) = @_;
    my $key     = _slug($unique_id);
    my $dprefix = _slug($device_name);
    return $key if $dprefix eq '';
    return $1 if $key =~ /^\Q$dprefix\E_(.+)$/;
    return $key;
}

sub _slug {
    my ($s) = @_;
    return '' if !defined $s || $s eq '';
    $s = lc "$s";
    $s =~ s/[^a-z0-9]+/_/g;
    $s =~ s/^_+//;
    $s =~ s/_+$//;
    return $s;
}

# tier1_pluck($value_template) -> \@path | undef
# Recognizes only the plain "{{ value_json.a.b }}" / "{{ value_json }}"
# shape (JSON dot-path pluck). Anything else (filters, functions, jinja
# control flow) is tier 2/3 (#20) and returns undef.
sub tier1_pluck {
    my ($template) = @_;
    return undef if !defined $template || $template eq '';
    return undef if $template !~ /^\{\{\s*value_json((?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\}\}$/;
    my $path = $1 // '';
    return [] if $path eq '';
    my @parts = split /\./, $path;
    shift @parts if @parts && $parts[0] eq '';
    return \@parts;
}

sub extract_json_path {
    my ($data, $path) = @_;
    my $v = $data;
    for my $p (@$path) {
        return undef if ref $v ne 'HASH' || !exists $v->{$p};
        $v = $v->{$p};
    }
    return $v;
}

# state_reading($entity, $is_main, $payload) -> (\%readings, $warning)
# Without a value_template: existing state_readings behavior (reused, not
# duplicated). With a tier-1 value_template: single reading named
# entity_key ('state' for the main entity), plucked from the JSON payload.
# A non-tier-1 template returns no readings plus a warning naming the
# entity + template (log it at level 3, do not crash) — tier 2/3 is #20.
sub state_reading {
    my ($entity, $is_main, $payload) = @_;

    my $tpl = $entity->{config}{value_template};
    if (!defined $tpl || $tpl eq '') {
        return (FHEM::HA2FHEM::Profiles::state_readings(
            $entity->{component}, $entity->{entity_key}, $is_main, $payload), undef);
    }

    my $path = tier1_pluck($tpl);
    if (!$path) {
        return ({}, "generic entity $entity->{entity_key}: value_template "
                   . "'$tpl' is not a supported tier-1 pluck, field skipped");
    }

    my $data = eval { JSON::PP::decode_json($payload) };
    return ({}, undef) if !$data || ref $data ne 'HASH';

    my $v = @$path ? extract_json_path($data, $path) : $data;
    return ({}, undef) if !defined $v;

    my $name = $is_main ? 'state' : $entity->{entity_key};
    return ({ $name => FHEM::HA2FHEM::Profiles::_scalar($v) }, undef);
}

1;
