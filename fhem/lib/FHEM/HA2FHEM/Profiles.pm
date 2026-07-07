###############################################################################
# ha2fhem — device-class profile registry (pure, unit-testable)
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Profiles;

use strict;
use warnings;
use JSON::PP ();

# One entry per HA component we treat as a device's "main" (controllable)
# entity. sensor/binary_sensor are never main; they attach as readings.
our %PROFILES = (
    vacuum => {
        # per CONTRACT.md, vacuum.mqtt state schema
        state_keys => [qw(state battery_level fan_speed docked charging error)],
    },
);

# vacuum set commands: FHEM set name => { feature, payload }.
# feature is the HA supported_features entry gating the setter; dock is an
# alias for return_to_base (same feature, same topic, same payload).
our %VACUUM_COMMANDS = (
    start          => { feature => 'start',       payload => 'start' },
    stop           => { feature => 'stop',        payload => 'stop' },
    pause          => { feature => 'pause',       payload => 'pause' },
    return_to_base => { feature => 'return_home', payload => 'return_to_base' },
    dock           => { feature => 'return_home', payload => 'return_to_base' },
    locate         => { feature => 'locate',      payload => 'locate' },
    clean_spot     => { feature => 'clean_spot',  payload => 'clean_spot' },
);

sub known_profile { return exists $PROFILES{ $_[0] } }

sub is_main_component {
    my ($component) = @_;
    return $component ne 'sensor' && $component ne 'binary_sensor';
}

# set_commands($component, $entity) -> hashref of FHEM set name => spec.
# spec is { topic, payload } for fixed-payload commands, or
# { topic, arg => 1 [, widget] } where the payload is the user's set argument
# (fan_speed gets a widget => "min,medium,..." set-list suffix).
# Gated on discovery config supported_features (array of HA feature names);
# missing/absent supported_features exposes everything. Non-vacuum -> {}.
sub set_commands {
    my ($component, $entity) = @_;
    return {} if $component ne 'vacuum';

    my $config   = $entity->{config} // {};
    my $features = $config->{supported_features};
    my $gate     = ref $features eq 'ARRAY';
    my %has      = $gate ? map { $_ => 1 } @$features : ();

    my $base = $entity->{state_topic};
    $base =~ s{/state$}{};

    my %set;
    for my $name (keys %VACUUM_COMMANDS) {
        my $cmd = $VACUUM_COMMANDS{$name};
        next if $gate && !$has{ $cmd->{feature} };
        $set{$name} = {
            topic   => $config->{command_topic} // "$base/set",
            payload => $cmd->{payload},
        };
    }

    if (!$gate || $has{fan_speed}) {
        my $list = $config->{fan_speed_list};
        $list = [qw(min medium high max)] if ref $list ne 'ARRAY' || !@$list;
        $set{fan_speed} = {
            topic  => $config->{set_fan_speed_topic} // "$base/set_fan_speed",
            arg    => 1,
            widget => join(',', @$list),
        };
    }

    if (!$gate || $has{send_command}) {
        $set{send_command} = {
            topic => $config->{send_command_topic} // "$base/send_command",
            arg   => 1,
        };
    }

    return \%set;
}

# state_readings($component, $entity_key, $is_main, $payload)
# -> hashref of reading => value.
# Contract: payloads are pre-rendered, flat (max 1 level) JSON or one plain
# value. Main entity keys map to readings directly; other entities get an
# <entity_key>_ prefix (plain value -> reading <entity_key>).
sub state_readings {
    my ($component, $entity_key, $is_main, $payload) = @_;
    $payload //= '';

    if ($payload =~ /^\s*\{/) {
        my $data = eval { JSON::PP::decode_json($payload) };
        return {} if !$data || ref $data ne 'HASH';
        my $prefix = $is_main ? '' : "${entity_key}_";
        my %r;
        for my $k (keys %$data) {
            $r{"$prefix$k"} = _scalar($data->{$k});
        }
        return \%r;
    }

    my $name = $is_main ? 'state' : $entity_key;
    return { $name => $payload };
}

sub _scalar {
    my ($v) = @_;
    return ''      if !defined $v;
    return ($v ? 'true' : 'false') if JSON::PP::is_bool($v);
    # nested structures: keep as JSON string (contract says max 1 level,
    # but never silently drop data)
    return JSON::PP::encode_json($v) if ref $v;
    return "$v";
}

1;
