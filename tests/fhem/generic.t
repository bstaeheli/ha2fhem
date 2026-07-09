use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Discovery::Generic;
use JSON::PP qw(encode_json);

my $GP = 'homeassistant';

###############################################################################
# abbreviation expansion, incl. "~" substitution both ends
###############################################################################
{
    my $expanded = FHEM::HA2FHEM::Discovery::Generic::expand_abbreviations({
        '~'      => 'zigbee2mqtt/kitchen_light',
        stat_t   => '~',            # leading "~" -> whole value replaced
        cmd_t    => '~/set',        # leading "~"
        json_attr_t => 'attrs/~',   # trailing "~"
        avty_t   => 'zigbee2mqtt/bridge/state',
        pl_avail => 'online',
        pl_not_avail => 'offline',
        val_tpl  => '{{ value_json.state }}',
        pl_on    => 'ON',
        pl_off   => 'OFF',
        uniq_id  => 'abc123',
        dev      => { ids => ['abc'], mf => 'IKEA', mdl => 'X', sw => '1.0' },
        pos_t    => 'x/pos',
        set_pos_t => 'x/set_pos',
    });

    is($expanded->{state_topic}, 'zigbee2mqtt/kitchen_light',
        'stat_t expanded + leading ~ substituted (whole value)');
    is($expanded->{command_topic}, 'zigbee2mqtt/kitchen_light/set',
        'cmd_t expanded + leading ~ substituted');
    is($expanded->{json_attributes_topic}, 'attrs/zigbee2mqtt/kitchen_light',
        'json_attr_t expanded + trailing ~ substituted');
    is($expanded->{availability_topic}, 'zigbee2mqtt/bridge/state', 'avty_t expanded');
    is($expanded->{payload_available}, 'online', 'pl_avail expanded');
    is($expanded->{payload_not_available}, 'offline', 'pl_not_avail expanded');
    is($expanded->{value_template}, '{{ value_json.state }}', 'val_tpl expanded');
    is($expanded->{payload_on}, 'ON', 'pl_on expanded');
    is($expanded->{payload_off}, 'OFF', 'pl_off expanded');
    is($expanded->{unique_id}, 'abc123', 'uniq_id expanded');
    is($expanded->{position_topic}, 'x/pos', 'pos_t expanded');
    is($expanded->{set_position_topic}, 'x/set_pos', 'set_pos_t expanded');
    is_deeply($expanded->{device}{identifiers}, ['abc'], 'dev/ids expanded');
    is($expanded->{device}{manufacturer}, 'IKEA', 'dev/mf expanded');
    is($expanded->{device}{model}, 'X', 'dev/mdl expanded');
    is($expanded->{device}{sw_version}, '1.0', 'dev/sw expanded');
    ok(!exists $expanded->{'~'}, '~ key itself removed');

    # unknown abbreviation passes through unchanged
    my $passthrough = FHEM::HA2FHEM::Discovery::Generic::expand_abbreviations({
        some_totally_unknown_field => 'x',
    });
    is($passthrough->{some_totally_unknown_field}, 'x', 'unknown key passes through unchanged');
}

###############################################################################
# availability as an array (long or abbreviated) folds into flat fields
###############################################################################
{
    my $expanded = FHEM::HA2FHEM::Discovery::Generic::expand_abbreviations({
        state_topic  => 'x/state',
        availability => [ { t => 'x/avail', pl_avail => 'Online', pl_not_avail => 'Offline' } ],
    });
    is($expanded->{availability_topic}, 'x/avail', 'availability[] topic folded (abbrev keys)');
    is($expanded->{payload_available}, 'Online', 'availability[] payload_available folded');
    is($expanded->{payload_not_available}, 'Offline', 'availability[] payload_not_available folded');
}

###############################################################################
# device_id / entity_key normalization (via parse_config, blackbox like
# discovery.t tests FHEM::HA2FHEM::Discovery::parse_config)
###############################################################################
{
    my ($e, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/switch/sonoff_basic_1/config",
        encode_json({
            uniq_id => 'sonoff_basic_relay_switch',
            name    => 'Sonoff Basic Relay',
            stat_t  => 'sonoff_basic_1/POWER',
            cmd_t   => 'sonoff_basic_1/cmnd/POWER',
            dev     => { ids => ['sonoff_basic_1'], name => 'Sonoff Basic Relay' },
        }));
    is($err, undef, 'tasmota-style switch: no error');
    is($e->{device_id}, 'sonoff_basic_1', 'device_id from device.identifiers[0], slugged');
    is($e->{entity_key}, 'switch',
        'entity_key: device-name prefix stripped from unique_id');

    # fallback: no device.identifiers -> device name
    ($e, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/switch/plugA/config",
        encode_json({
            state_topic => 'x/state',
            device      => { name => 'Plug A' },
        }));
    is($err, undef, 'no identifiers: no error');
    is($e->{device_id}, 'plug_a', 'device_id falls back to slugged device name');
    is($e->{entity_key}, 'pluga', 'entity_key falls back to object_id slug (no unique_id)');

    # fallback: no device dict at all -> object_id
    ($e, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/switch/bare_plug/config",
        encode_json({ state_topic => 'x/state' }));
    is($err, undef, 'no device dict: no error');
    is($e->{device_id}, 'bare_plug', 'device_id falls back to object_id');
    is($e->{device_name}, 'bare_plug', 'device_name falls back to device_id');

    # missing state_topic -> error
    (undef, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/switch/x/config", encode_json({}));
    like($err, qr/missing state_topic/, 'missing state_topic rejected');

    # node_id segment (component/node_id/object_id/config) parses fine
    ($e, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/sensor/node1/temp/config",
        encode_json({ state_topic => 'x/state' }));
    is($err, undef, 'node_id segment: no error');
    is($e->{component}, 'sensor', 'node_id segment: component parsed');
    is($e->{object_id}, 'temp', 'node_id segment: object_id parsed (node_id ignored)');

    # delete topic parse
    my ($c, $o) = FHEM::HA2FHEM::Discovery::Generic::parse_delete_topic($GP,
        "$GP/switch/sonoff_basic_1/config");
    is($c, 'switch', 'delete component');
    is($o, 'sonoff_basic_1', 'delete object_id');

    # wrong topic
    (undef, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP, 'other/topic', '{}');
    like($err, qr/not a generic discovery config topic/, 'wrong topic rejected');

    # invalid json
    (undef, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/switch/x/config", '{broken');
    like($err, qr/invalid JSON/, 'invalid json rejected');
}

###############################################################################
# real-shaped zigbee2mqtt light discovery config: abbreviated keys, shared
# state topic, val_tpl -> feeds set_commands with pl_on/pl_off overrides,
# tier-1 pluck, availability mapping, non-tier-1 template skipped
###############################################################################
{
    my $light_payload = encode_json({
        '~'          => 'zigbee2mqtt/kitchen_light',
        name         => 'Kitchen Light',
        uniq_id      => '0x00158d0001dc4b21_light_zigbee2mqtt',
        dev          => {
            ids  => ['0x00158d0001dc4b21'],
            name => 'kitchen_light',
            mf   => 'IKEA',
            mdl  => 'TRADFRI bulb E27 W opal 1000lm',
        },
        stat_t       => '~',
        cmd_t        => '~/set',
        avty_t       => 'zigbee2mqtt/bridge/state',
        pl_avail     => 'online',
        pl_not_avail => 'offline',
        val_tpl      => '{{ value_json.state }}',
        pl_on        => 'ON_CUSTOM',
        pl_off       => 'OFF_CUSTOM',
        schema       => 'json',
    });
    my ($light, $err) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/light/kitchen_light/config", $light_payload);
    is($err, undef, 'z2m light: no error');
    is($light->{component}, 'light', 'z2m light: component');
    is($light->{device_id}, '0x00158d0001dc4b21', 'z2m light: device_id slug');
    is($light->{state_topic}, 'zigbee2mqtt/kitchen_light', 'z2m light: state_topic via ~');
    is($light->{config}{command_topic}, 'zigbee2mqtt/kitchen_light/set',
        'z2m light: command_topic via ~');

    # normalized entity feeds set_commands with pl_on/pl_off overrides
    my $set = FHEM::HA2FHEM::Profiles::set_commands('light', $light);
    is($set->{on}{payload}, 'ON_CUSTOM', 'set_commands honors payload_on override');
    is($set->{off}{payload}, 'OFF_CUSTOM', 'set_commands honors payload_off override');
    is($set->{on}{topic}, 'zigbee2mqtt/kitchen_light/set', 'set_commands uses command_topic');

    # a sibling entity sharing the SAME state topic (z2m one-JSON-per-device)
    my $sensor_payload = encode_json({
        '~'     => 'zigbee2mqtt/kitchen_light',
        name    => 'Kitchen Light Linkquality',
        uniq_id => 'kitchen_light_linkquality',
        dev     => { ids => ['0x00158d0001dc4b21'], name => 'kitchen_light' },
        stat_t  => '~',
        val_tpl => '{{ value_json.linkquality }}',
        unit_of_meas => 'lqi',
    });
    my ($sensor, $serr) = FHEM::HA2FHEM::Discovery::Generic::parse_config($GP,
        "$GP/sensor/kitchen_light_linkquality/config", $sensor_payload);
    is($serr, undef, 'z2m linkquality sensor: no error');
    is($sensor->{entity_key}, 'linkquality',
        'z2m sensor entity_key: device-name prefix stripped');
    is($sensor->{state_topic}, 'zigbee2mqtt/kitchen_light',
        'z2m sensor shares the light state topic');

    # tier-1 pluck from a z2m state JSON: each entity's template extracts
    # its own reading from the SAME shared payload
    my $shared_state = encode_json({ state => 'ON', brightness => 200, linkquality => 60 });

    my ($light_readings, $lwarn) =
        FHEM::HA2FHEM::Discovery::Generic::state_reading($light, 1, $shared_state);
    is($lwarn, undef, 'light tier-1 pluck: no warning');
    is_deeply($light_readings, { state => 'ON' }, 'light tier-1 pluck: main -> "state" reading');

    my ($sensor_readings, $swarn) =
        FHEM::HA2FHEM::Discovery::Generic::state_reading($sensor, 0, $shared_state);
    is($swarn, undef, 'sensor tier-1 pluck: no warning');
    is_deeply($sensor_readings, { linkquality => 60 },
        'sensor tier-1 pluck: non-main -> entity_key reading');

    # availability payload mapping
    is(FHEM::HA2FHEM::Discovery::Generic::availability_value($light->{config}, 'online'),
        'online', 'availability: payload_available -> online');
    is(FHEM::HA2FHEM::Discovery::Generic::availability_value($light->{config}, 'offline'),
        'offline', 'availability: payload_not_available -> offline');
    is(FHEM::HA2FHEM::Discovery::Generic::availability_value($light->{config}, 'weird'),
        'weird', 'availability: unrecognized payload passes through unchanged');
    is(FHEM::HA2FHEM::Discovery::Generic::availability_value(
            $light->{config}, '{"state":"online"}'),
        'online', 'availability: z2m JSON {"state":"online"} unwrapped');
    is(FHEM::HA2FHEM::Discovery::Generic::availability_value(
            $light->{config}, '{"state":"offline"}'),
        'offline', 'availability: z2m JSON {"state":"offline"} unwrapped');

    # non-tier-1 template: skipped, no crash, warning names entity + template
    my $filtered = {
        %$light,
        entity_key => 'temp',
        config => { %{ $light->{config} },
            value_template => '{{ value_json.temperature | round(1) }}' },
    };
    my ($fr, $fwarn) = FHEM::HA2FHEM::Discovery::Generic::state_reading(
        $filtered, 0, encode_json({ temperature => 21.456 }));
    is_deeply($fr, {}, 'non-tier-1 template: no readings, no crash');
    like($fwarn, qr/temp/, 'non-tier-1 template: warning names the entity');
    like($fwarn, qr/\Qvalue_json.temperature | round(1)\E/,
        'non-tier-1 template: warning names the template');
}

###############################################################################
# tier-1 pluck helper: dot paths, whole-payload, non-tier-1 shapes
###############################################################################
{
    is_deeply(FHEM::HA2FHEM::Discovery::Generic::tier1_pluck('{{ value_json.a }}'),
        ['a'], 'tier1_pluck: single key');
    is_deeply(FHEM::HA2FHEM::Discovery::Generic::tier1_pluck('{{value_json.a.b}}'),
        ['a', 'b'], 'tier1_pluck: dot path, no spaces');
    is_deeply(FHEM::HA2FHEM::Discovery::Generic::tier1_pluck('{{ value_json }}'),
        [], 'tier1_pluck: bare value_json (whole payload)');
    is(FHEM::HA2FHEM::Discovery::Generic::tier1_pluck('{{ value_json.a | int }}'),
        undef, 'tier1_pluck: filter -> not tier-1');
    is(FHEM::HA2FHEM::Discovery::Generic::tier1_pluck("{{ states('sensor.x') }}"),
        undef, 'tier1_pluck: function call -> not tier-1');
    is(FHEM::HA2FHEM::Discovery::Generic::tier1_pluck(undef), undef,
        'tier1_pluck: undef template -> undef, no crash');

    is_deeply(FHEM::HA2FHEM::Discovery::Generic::extract_json_path(
        { a => { b => 42 } }, ['a', 'b']), 42, 'extract_json_path: nested');
    is(FHEM::HA2FHEM::Discovery::Generic::extract_json_path(
        { a => 1 }, ['a', 'b']), undef, 'extract_json_path: missing nested key -> undef');
}

###############################################################################
# without a value_template: falls back to existing state_readings behavior
###############################################################################
{
    my $entity = {
        component  => 'switch',
        entity_key => 'switch',
        config     => {},
    };
    my ($r, $warn) = FHEM::HA2FHEM::Discovery::Generic::state_reading($entity, 1, 'ON');
    is($warn, undef, 'no value_template: no warning');
    is_deeply($r, { state => 'ON' }, 'no value_template: existing state_readings behavior');
}

done_testing();
