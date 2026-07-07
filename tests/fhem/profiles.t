use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Profiles;

*sr = \&FHEM::HA2FHEM::Profiles::state_readings;

ok(FHEM::HA2FHEM::Profiles::known_profile('vacuum'), 'vacuum profile exists');
ok(FHEM::HA2FHEM::Profiles::is_main_component('vacuum'), 'vacuum is main');
ok(!FHEM::HA2FHEM::Profiles::is_main_component('sensor'), 'sensor is not');

# CONTRACT.md example payload, main entity
my $r = sr('vacuum', 'vacuum', 1,
    '{"state":"docked","battery_level":82,"fan_speed":"max","docked":true,"charging":true}');
is_deeply($r, {
    state         => 'docked',
    battery_level => 82,
    fan_speed     => 'max',
    docked        => 'true',
    charging      => 'true',
}, 'vacuum state json -> readings, no prefix, bools stringified');

# non-main entity: json gets entity_key prefix
$r = sr('sensor', 'battery', 0, '{"value":82}');
is_deeply($r, { battery_value => 82 }, 'non-main json prefixed');

# non-main plain value -> reading named entity_key
$r = sr('sensor', 'bin_full', 0, 'true');
is_deeply($r, { bin_full => 'true' }, 'plain value non-main');

# main plain value -> reading "state"
$r = sr('vacuum', 'vacuum', 1, 'cleaning');
is_deeply($r, { state => 'cleaning' }, 'plain value main -> state');

# broken json -> no readings, no crash
$r = sr('vacuum', 'vacuum', 1, '{broken');
is_deeply($r, {}, 'broken json ignored');

# nested value survives as JSON string (never silently dropped)
$r = sr('vacuum', 'vacuum', 1, '{"segments":{"1":"kitchen"}}');
is_deeply($r, { segments => '{"1":"kitchen"}' }, 'nested kept as json string');

done_testing();
