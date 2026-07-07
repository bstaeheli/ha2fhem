use strict;
use warnings;
use Test::More;
use lib 'fhem/lib';
use FHEM::HA2FHEM::Filter;

*da = \&FHEM::HA2FHEM::Filter::device_allowed;
*ca = \&FHEM::HA2FHEM::Filter::class_allowed;

# no filters -> everything allowed
ok(da(undef, undef, 'roomba1', 'Roomba'), 'no filters');

# include by id / by name
ok(da('roomba1', undef, 'roomba1', 'Roomba'),  'include by id');
ok(da('Roomba', undef, 'roomba1', 'Roomba'),   'include by name');
ok(!da('other', undef, 'roomba1', 'Roomba'),   'include misses');
ok(da('a,roomba1 b', undef, 'roomba1', undef), 'include list, comma+space');

# exclude wins
ok(!da('roomba1', 'roomba1', 'roomba1', 'Roomba'), 'exclude beats include');
ok(!da(undef, 'Roomba', 'roomba1', 'Roomba'),      'exclude by name');

# classes
ok(ca(undef, 'vacuum'),           'no class filter');
ok(ca('vacuum cover', 'vacuum'),  'class included');
ok(!ca('cover', 'vacuum'),        'class excluded');
ok(ca('cover', 'sensor'),         'sensor always passes');
ok(ca('cover', 'binary_sensor'),  'binary_sensor always passes');

done_testing();
