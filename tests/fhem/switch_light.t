use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Profiles;

*sc = \&FHEM::HA2FHEM::Profiles::set_commands;

sub entity {
    my ($state_topic, %over) = @_;
    return {
        state_topic => $state_topic,
        config      => { %over },
    };
}

for my $component (qw(switch light)) {
    my $state_topic = "ha2fhem/devices/dev1/$component/state";

    my $set = sc($component, entity($state_topic));
    is_deeply(
        [ sort keys %$set ],
        [qw(off on)],
        "$component: on/off always exposed (no supported_features published)"
    );
    is($set->{on}{payload}, 'ON', "$component: on payload");
    is($set->{off}{payload}, 'OFF', "$component: off payload");
    is($set->{on}{topic}, "ha2fhem/devices/dev1/$component/set",
        "$component: set topic fallback derived from state_topic");
    is($set->{off}{topic}, "ha2fhem/devices/dev1/$component/set",
        "$component: off shares the same set topic");

    # discovery config command_topic override wins over the fallback
    $set = sc($component, entity($state_topic, command_topic => 'custom/cmd'));
    is($set->{on}{topic}, 'custom/cmd', "$component: command_topic override");
    is($set->{off}{topic}, 'custom/cmd', "$component: command_topic override (off)");
}

# cover/vacuum regression: untouched by the switch/light additions
my $cover = sc('cover', entity('ha2fhem/devices/blind1/cover/state'));
is_deeply(
    [ sort keys %$cover ],
    [qw(close open pct stop)],
    'cover unchanged after switch/light additions'
);

my $vacuum = sc('vacuum', entity('ha2fhem/devices/roomba1/vacuum/state'));
is_deeply(
    [ sort keys %$vacuum ],
    [qw(clean_spot dock fan_speed locate pause return_to_base send_command start stop)],
    'vacuum unchanged after switch/light additions'
);

done_testing();
