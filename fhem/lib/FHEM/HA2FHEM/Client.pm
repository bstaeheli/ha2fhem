###############################################################################
# ha2fhem — client (child) module logic
# One instance per HA device; readings are written by the bridge.
# Setters resolve the device's main entity from the bridge registry and
# publish via the bridge's IODev.
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Client;

use strict;
use warnings;

use FHEM::HA2FHEM::Profiles;

sub Initialize {
    my ($hash) = @_;
    $hash->{DefFn}    = 'FHEM::HA2FHEM::Client::Define';
    $hash->{UndefFn}  = 'FHEM::HA2FHEM::Client::Undef';
    $hash->{SetFn}    = 'FHEM::HA2FHEM::Client::Set';
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

sub Set {
    my ($hash, $name, $cmd, @args) = @_;
    return if ::IsDisabled($name);
    $cmd //= '';

    my ($bridge, $entity) = _resolve($hash);
    return "$name: no entity known yet (no discovery received)" if !$entity;

    my $commands = FHEM::HA2FHEM::Profiles::set_commands($entity->{component}, $entity);

    if (!exists $commands->{$cmd}) {
        my $list = join ' ', map {
            $commands->{$_}{widget} ? "$_:$commands->{$_}{widget}" : "$_:noArg"
        } sort keys %$commands;
        return "Unknown argument $cmd, choose one of $list";
    }

    my $c = $commands->{$cmd};
    $hash->{IODev} = $bridge->{IODev} if !$hash->{IODev} && $bridge->{IODev};
    return "$name: no IODev (bridge not connected)" if !$hash->{IODev};

    my $payload = $c->{arg} ? join(' ', @args) : $c->{payload};
    return "$name: $cmd needs an argument" if $c->{arg} && $payload eq '';
    ::IOWrite($hash, 'publish', "$c->{topic} $payload");
    return;
}

# _resolve($hash) -> ($bridge, $entity) — $entity is the device's main
# component entity, or undef if none discovered yet. Freshly created children
# carry $hash->{bridge}; children re-defined from fhem.cfg after a restart
# don't, so fall back to scanning bridges for one that owns DEVICE_ID.
sub _resolve {
    my ($hash) = @_;
    my $device_id = $hash->{DEVICE_ID};

    my $bridge = $main::modules{HA2FHEM_BRIDGE}{defptr}{ $hash->{bridge} // '' };
    if (!$bridge || !$bridge->{devices}{$device_id}) {
        ($bridge) = grep { $_->{devices}{$device_id} }
            values %{ $main::modules{HA2FHEM_BRIDGE}{defptr} };
    }
    return (undef, undef) if !$bridge;

    my $entities = $bridge->{devices}{$device_id}{entities} // {};
    for my $key (keys %$entities) {
        return ($bridge, $entities->{$key})
            if FHEM::HA2FHEM::Profiles::is_main_component($entities->{$key}{component});
    }
    return ($bridge, undef);
}

1;
