use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Discovery;
use JSON::PP qw(encode_json);

my $P = 'ha2fhem';

sub cfg {
    my (%over) = @_;
    return encode_json({
        unique_id   => 'ha2fhem_roomba1_vacuum',
        state_topic => 'ha2fhem/devices/roomba1/vacuum/state',
        device      => { identifiers => ['ha2fhem_roomba1'], name => 'Roomba' },
        %over,
    });
}
my $T = "$P/discovery/vacuum/roomba1_vacuum/config";

# happy path
my ($e, $err) = FHEM::HA2FHEM::Discovery::parse_config($P, $T, cfg());
is($err, undef, 'no error');
is($e->{component},   'vacuum',  'component');
is($e->{device_id},   'roomba1', 'device_id');
is($e->{entity_key},  'vacuum',  'entity_key');
is($e->{device_name}, 'Roomba',  'device_name');

# device_id containing underscores stays intact
($e, $err) = FHEM::HA2FHEM::Discovery::parse_config($P,
    "$P/discovery/vacuum/my_bot_2_vacuum/config",
    cfg(unique_id => 'ha2fhem_my_bot_2_vacuum',
        device => { identifiers => ['ha2fhem_my_bot_2'] }));
is($err, undef, 'underscore device ok');
is($e->{device_id},  'my_bot_2', 'underscore device_id');
is($e->{entity_key}, 'vacuum',   'underscore entity_key');

# hard rule: state topic under discovery prefix rejected
(undef, $err) = FHEM::HA2FHEM::Discovery::parse_config($P, $T,
    cfg(state_topic => "$P/discovery/nope"));
like($err, qr/must not start with the discovery prefix/, 'state topic rule');

# invalid json
(undef, $err) = FHEM::HA2FHEM::Discovery::parse_config($P, $T, '{broken');
like($err, qr/invalid JSON/, 'invalid json');

# missing unique_id
(undef, $err) = FHEM::HA2FHEM::Discovery::parse_config($P, $T,
    encode_json({ state_topic => 'x', device => { identifiers => ['ha2fhem_a'] } }));
like($err, qr/missing unique_id/, 'missing unique_id');

# wrong topic
(undef, $err) = FHEM::HA2FHEM::Discovery::parse_config($P, 'other/topic', cfg());
like($err, qr/not a discovery config topic/, 'wrong topic');

# delete topic parse
my ($c, $o) = FHEM::HA2FHEM::Discovery::parse_delete_topic($P, $T);
is($c, 'vacuum', 'delete component');
is($o, 'roomba1_vacuum', 'delete object_id');

done_testing();
