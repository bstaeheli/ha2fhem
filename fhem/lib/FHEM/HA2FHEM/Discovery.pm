###############################################################################
# ha2fhem — HA discovery config parsing (pure, unit-testable)
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Discovery;

use strict;
use warnings;
use JSON::PP ();

# Parse one discovery config message.
#   parse_config($topicPrefix, $topic, $payload)
# $topic is the full topic. Returns ($entity, undef) on success,
# (undef, $error) on failure. $entity:
#   { component, object_id, device_id, entity_key, device_name,
#     unique_id, state_topic, config }
sub parse_config {
    my ($prefix, $topic, $payload) = @_;

    my ($component, $object_id) =
        $topic =~ m{^\Q$prefix\E/discovery/([^/]+)/([^/]+)/config$}
        or return (undef, "not a discovery config topic: $topic");

    my $config = eval { JSON::PP::decode_json($payload) };
    return (undef, "invalid JSON in discovery config for $object_id: $@")
        if !$config || ref $config ne 'HASH';

    my $unique_id = $config->{unique_id}
        or return (undef, "discovery config $object_id: missing unique_id");

    my $identifiers = $config->{device}{identifiers};
    return (undef, "discovery config $object_id: missing device.identifiers")
        if ref $identifiers ne 'ARRAY' || !@$identifiers;

    my ($device_id) = $identifiers->[0] =~ m{^ha2fhem_(.+)$}
        or return (undef, "discovery config $object_id: "
                 . "device.identifiers[0] must start with ha2fhem_");

    my ($entity_key) = $unique_id =~ m{^ha2fhem_\Q$device_id\E_(.+)$}
        or return (undef, "discovery config $object_id: unique_id must be "
                 . "ha2fhem_${device_id}_<entity_key>");

    my $state_topic = $config->{state_topic}
        or return (undef, "discovery config $object_id: missing state_topic");

    # hard rule: state topics must not live under the discovery prefix
    return (undef, "discovery config $object_id: state_topic must not start "
          . "with the discovery prefix")
        if $state_topic =~ m{^\Q$prefix\E/discovery/};

    return ({
        component   => $component,
        object_id   => $object_id,
        device_id   => $device_id,
        entity_key  => $entity_key,
        device_name => $config->{device}{name} // $device_id,
        unique_id   => $unique_id,
        state_topic => $state_topic,
        config      => $config,
    }, undef);
}

# object_id of a delete message (empty payload): just the topic match.
sub parse_delete_topic {
    my ($prefix, $topic) = @_;
    my ($component, $object_id) =
        $topic =~ m{^\Q$prefix\E/discovery/([^/]+)/([^/]+)/config$}
        or return;
    return ($component, $object_id);
}

1;
