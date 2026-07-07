###############################################################################
# ha2fhem — client (child) module logic
# One instance per HA device; readings are written by the bridge.
# Setters come with Phase 2 (profiles gain a set map).
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Client;

use strict;
use warnings;

sub Initialize {
    my ($hash) = @_;
    $hash->{DefFn}    = 'FHEM::HA2FHEM::Client::Define';
    $hash->{UndefFn}  = 'FHEM::HA2FHEM::Client::Undef';
    $hash->{AttrList} = 'disable:0,1 ' . $main::readingFnAttributes;
    return;
}

sub Define {
    my ($hash, $def) = @_;
    my ($name, $type, $device_id) = split m{\s+}, $def;
    return 'Usage: define <name> HA2FHEM_CLIENT <ha_device_id>'
        if !defined $device_id || $device_id eq '';

    $hash->{DEVICE_ID} = $device_id;
    $main::modules{HA2FHEM_CLIENT}{defptr}{$device_id} = $hash;
    ::readingsSingleUpdate($hash, 'state', 'defined', 0);
    return;
}

sub Undef {
    my ($hash) = @_;
    delete $main::modules{HA2FHEM_CLIENT}{defptr}{ $hash->{DEVICE_ID} }
        if defined $hash->{DEVICE_ID};
    return;
}

1;
