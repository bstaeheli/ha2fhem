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
# Setters (set map) arrive in Phase 2.
our %PROFILES = (
    vacuum => {
        # per CONTRACT.md, vacuum.mqtt state schema
        state_keys => [qw(state battery_level fan_speed docked charging error)],
    },
);

sub known_profile { return exists $PROFILES{ $_[0] } }

sub is_main_component {
    my ($component) = @_;
    return $component ne 'sensor' && $component ne 'binary_sensor';
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
