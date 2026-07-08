use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Profiles;

*sc = \&FHEM::HA2FHEM::Profiles::set_commands;

sub entity {
    my (%over) = @_;
    return {
        state_topic => 'ha2fhem/devices/blind1/cover/state',
        config      => { %over },
    };
}

# no supported_features -> everything exposed
my $set = sc('cover', entity());
is_deeply(
    [ sort keys %$set ],
    [qw(close open pct stop)],
    'missing supported_features exposes everything'
);
is($set->{open}{payload}, 'OPEN', 'open payload');
is($set->{close}{payload}, 'CLOSE', 'close payload');
is($set->{stop}{payload}, 'STOP', 'stop payload');
is($set->{open}{topic}, 'ha2fhem/devices/blind1/cover/set',
    'set topic fallback derived from state_topic');

# pct widget + topic fallback
is($set->{pct}{arg}, 1, 'pct payload comes from the set argument');
is($set->{pct}{widget}, 'slider,0,1,100', 'pct widget');
is($set->{pct}{topic}, 'ha2fhem/devices/blind1/cover/set_position',
    'set_position topic fallback');

# restricted supported_features
$set = sc('cover', entity(supported_features => [qw(open close)]));
is_deeply(
    [ sort keys %$set ],
    [qw(close open)],
    'restricted supported_features only exposes open/close'
);
ok(!exists $set->{stop}, 'stop gated out');
ok(!exists $set->{pct},  'pct gated out');

$set = sc('cover', entity(supported_features => ['set_position']));
is_deeply([ sort keys %$set ], [qw(pct)], 'set_position feature only exposes pct');

# discovery config overrides win over the fallback
$set = sc('cover', entity(
    command_topic       => 'custom/cmd',
    set_position_topic  => 'custom/pos',
    supported_features  => [qw(open set_position)],
));
is($set->{open}{topic}, 'custom/cmd', 'command_topic override');
is($set->{pct}{topic}, 'custom/pos', 'set_position_topic override');

# vacuum stays byte-identical after the data-driven restructure
*svac = \&FHEM::HA2FHEM::Profiles::set_commands;
my $vac = svac('vacuum', {
    state_topic => 'ha2fhem/devices/roomba1/vacuum/state',
    config      => {},
});
is_deeply(
    [ sort keys %$vac ],
    [qw(clean_spot dock fan_speed locate pause return_to_base send_command start stop)],
    'vacuum unchanged: missing supported_features exposes everything'
);

done_testing();
