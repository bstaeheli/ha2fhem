###############################################################################
# ha2fhem — thin stub, all logic in FHEM::HA2FHEM::Bridge
# https://codeberg.org/bstaeheli/ha2fhem — GPL-2.0
###############################################################################
package main;

use strict;
use warnings;

use FHEM::HA2FHEM::Bridge;

sub HA2FHEM_BRIDGE_Initialize { goto &FHEM::HA2FHEM::Bridge::Initialize }

1;

=pod

=item summary    bridge consuming ha2fhem MQTT discovery, creates HA2FHEM_CLIENT devices
=item summary_DE Bridge fuer ha2fhem MQTT Discovery, erzeugt HA2FHEM_CLIENT Geraete

=begin html

<a id="HA2FHEM_BRIDGE"></a>
<h3>HA2FHEM_BRIDGE</h3>
<ul>
  Consumes ha2fhem MQTT discovery and state messages (published by the
  <b>ha2fhem</b> Home Assistant integration) via an MQTT2_CLIENT and creates
  one HA2FHEM_CLIENT device per Home Assistant device.
  See <a href="https://codeberg.org/bstaeheli/ha2fhem">the project page</a>.
  <br><br>

  <a id="HA2FHEM_BRIDGE-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; HA2FHEM_BRIDGE</code><br>
    Requires a defined MQTT2_CLIENT (selected via IODev, automatic if there
    is only one). The bridge registers itself in the IO's clientOrder.
  </ul><br>

  <a id="HA2FHEM_BRIDGE-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a id="HA2FHEM_BRIDGE-attr-topicPrefix">topicPrefix</a><br>
      MQTT topic prefix, default <code>ha2fhem</code>.</li>
    <li><a id="HA2FHEM_BRIDGE-attr-includeDevices">includeDevices</a><br>
      Comma/space separated HA device ids or names. Empty = all.</li>
    <li><a id="HA2FHEM_BRIDGE-attr-excludeDevices">excludeDevices</a><br>
      Devices to skip; wins over includeDevices.</li>
    <li><a id="HA2FHEM_BRIDGE-attr-includeClasses">includeClasses</a><br>
      Comma/space separated components (e.g. <code>vacuum cover</code>).
      Empty = all. sensor/binary_sensor always follow their device.</li>
  </ul>
</ul>

=end html

=cut
