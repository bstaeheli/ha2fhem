use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';

# Bridge.pm reaches into main:: at runtime only, so the FHEM API it touches
# can be stubbed here. This is the first test to exercise Bridge.pm itself
# rather than one of the pure parsing modules.
my @published;
my @logged;
BEGIN {
    *main::IOWrite    = sub { push @published, [ @_[ 1 .. $#_ ] ]; return; };
    *main::Log3       = sub { push @logged, $_[2]; return; };
    *main::IsDisabled = sub { return $main::disabled{ $_[0] } ? 1 : 0; };
}
our %disabled;

use FHEM::HA2FHEM::Bridge;

sub bridge { return { NAME => 'ha2fhem_bridge', IODev => 'MqttBroker' } }

*Set = \&FHEM::HA2FHEM::Bridge::Set;

# rescan publishes the HA birth message, which is what makes the HA-side
# integration republish every discovery config and state (see CONTRACT.md).
@published = ();
my $ret = Set(bridge(), 'ha2fhem_bridge', 'rescan');
is($ret, undef, 'rescan returns no error');
is(scalar @published, 1, 'rescan publishes exactly once');
is_deeply($published[0], [ 'publish', 'homeassistant/status online' ],
    'rescan publishes online to the HA status topic');

# unknown command must offer rescan so FHEMWEB renders the button
@published = ();
$ret = Set(bridge(), 'ha2fhem_bridge', 'bogus');
like($ret, qr/^Unknown argument bogus/, 'unknown command rejected');
like($ret, qr/\brescan:noArg\b/,        'rescan offered as noArg');
is(scalar @published, 0, 'unknown command publishes nothing');

# no command at all behaves like an unknown one, it must not publish
@published = ();
$ret = Set(bridge(), 'ha2fhem_bridge');
like($ret, qr/^Unknown argument/, 'missing command rejected');
is(scalar @published, 0, 'missing command publishes nothing');

# a disabled bridge must stay silent on the broker
@published = ();
$disabled{ha2fhem_bridge} = 1;
Set(bridge(), 'ha2fhem_bridge', 'rescan');
is(scalar @published, 0, 'disabled bridge does not publish');
delete $disabled{ha2fhem_bridge};

done_testing();
