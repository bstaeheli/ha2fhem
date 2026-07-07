use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Profiles;

*sc = \&FHEM::HA2FHEM::Profiles::set_commands;

sub entity {
    my (%over) = @_;
    return {
        state_topic => 'ha2fhem/devices/roomba1/vacuum/state',
        config      => { %over },
    };
}

# non-vacuum -> no setters
is_deeply(sc('sensor', entity()), {}, 'non-vacuum has no setters');

# no supported_features -> everything exposed
my $set = sc('vacuum', entity());
is_deeply(
    [ sort keys %$set ],
    [qw(clean_spot dock fan_speed locate pause return_to_base send_command start stop)],
    'missing supported_features exposes everything'
);
is($set->{start}{payload}, 'start', 'fixed payload');
is($set->{start}{topic}, 'ha2fhem/devices/roomba1/vacuum/set',
    'topic fallback derived from state_topic');

# dock alias: same topic/payload as return_to_base
is_deeply($set->{dock}, $set->{return_to_base}, 'dock aliases return_to_base');
is($set->{dock}{payload}, 'return_to_base', 'dock payload is return_to_base');

# restricted supported_features
$set = sc('vacuum', entity(supported_features => [qw(start stop)]));
is_deeply(
    [ sort keys %$set ],
    [qw(start stop)],
    'restricted supported_features only exposes start/stop'
);
ok(!exists $set->{pause},          'pause gated out');
ok(!exists $set->{dock},           'dock gated out');
ok(!exists $set->{return_to_base}, 'return_to_base gated out');
ok(!exists $set->{fan_speed},      'fan_speed gated out');

# fan_speed: config list vs default
$set = sc('vacuum', entity(supported_features => ['fan_speed']));
is($set->{fan_speed}{widget}, 'min,medium,high,max', 'fan_speed default list');
is($set->{fan_speed}{arg}, 1, 'fan_speed payload comes from the set argument');
is($set->{fan_speed}{topic}, 'ha2fhem/devices/roomba1/vacuum/set_fan_speed',
    'fan_speed topic fallback');

$set = sc('vacuum', entity(
    supported_features => ['fan_speed'],
    fan_speed_list      => [qw(quiet eco turbo)],
));
is($set->{fan_speed}{widget}, 'quiet,eco,turbo', 'fan_speed list from config');

# send_command
$set = sc('vacuum', entity(supported_features => ['send_command']));
ok(exists $set->{send_command}, 'send_command exposed');
is($set->{send_command}{arg}, 1, 'send_command payload comes from the set arguments');
is($set->{send_command}{topic}, 'ha2fhem/devices/roomba1/vacuum/send_command',
    'send_command topic fallback');

# topic fallback derivation with a non-default prefix
$set = sc('vacuum', {
    state_topic => 'myhome/devices/roomba1/vacuum/state',
    config      => {},
});
is($set->{start}{topic}, 'myhome/devices/roomba1/vacuum/set',
    'topic fallback honours a non-default prefix');

# discovery config overrides win over the fallback
$set = sc('vacuum', entity(
    command_topic       => 'custom/cmd',
    set_fan_speed_topic => 'custom/fan',
    send_command_topic  => 'custom/send',
    supported_features  => [qw(start fan_speed send_command)],
));
is($set->{start}{topic}, 'custom/cmd', 'command_topic override');
is($set->{fan_speed}{topic}, 'custom/fan', 'set_fan_speed_topic override');
is($set->{send_command}{topic}, 'custom/send', 'send_command_topic override');

done_testing();
