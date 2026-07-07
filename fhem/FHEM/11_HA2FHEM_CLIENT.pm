###############################################################################
# ha2fhem — thin stub, all logic in FHEM::HA2FHEM::Client
# https://codeberg.org/bstaeheli/ha2fhem — GPL-2.0
###############################################################################
package main;

use strict;
use warnings;

use FHEM::HA2FHEM::Client;

sub HA2FHEM_CLIENT_Initialize { goto &FHEM::HA2FHEM::Client::Initialize }

1;

=pod

=item summary    one Home Assistant device, created by HA2FHEM_BRIDGE
=item summary_DE ein Home-Assistant-Geraet, erzeugt durch HA2FHEM_BRIDGE

=begin html

<a id="HA2FHEM_CLIENT"></a>
<h3>HA2FHEM_CLIENT</h3>
<ul>
  Represents one Home Assistant device. Created automatically by
  <a href="#HA2FHEM_BRIDGE">HA2FHEM_BRIDGE</a> from ha2fhem MQTT discovery;
  all entities of the HA device appear as readings. Read-only in Phase 1 —
  set commands arrive with Phase 2.
  <br><br>

  <a id="HA2FHEM_CLIENT-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; HA2FHEM_CLIENT &lt;ha_device_id&gt;</code><br>
    Normally done by the bridge, not by hand.
  </ul>
</ul>

=end html

=cut
