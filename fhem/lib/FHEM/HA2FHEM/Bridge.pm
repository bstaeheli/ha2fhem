###############################################################################
# ha2fhem — bridge (parent) module logic
# Consumes ha2fhem MQTT discovery + state via MQTT2_CLIENT dispatch,
# creates/removes HA2FHEM_CLIENT children, routes state to them.
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Bridge;

use strict;
use warnings;

use FHEM::HA2FHEM::Discovery;
use FHEM::HA2FHEM::Filter;
use FHEM::HA2FHEM::Profiles;

sub Initialize {
    my ($hash) = @_;
    $hash->{Match}    = '^autocreate=';
    $hash->{DefFn}    = 'FHEM::HA2FHEM::Bridge::Define';
    $hash->{UndefFn}  = 'FHEM::HA2FHEM::Bridge::Undef';
    $hash->{ParseFn}  = 'FHEM::HA2FHEM::Bridge::Parse';
    $hash->{AttrList} = 'topicPrefix includeDevices excludeDevices '
                      . 'includeClasses disable:0,1 '
                      . $main::readingFnAttributes;
    return;
}

sub Define {
    my ($hash, $def) = @_;
    my ($name, $type) = split m{\s+}, $def;

    $main::modules{HA2FHEM_BRIDGE}{defptr}{$name} = $hash;
    $hash->{devices} = {};    # device_id => { entities => { key => entity } }

    ::readingsSingleUpdate($hash, 'state', 'defined', 0);
    _setupIO($hash, 0);
    return;
}

sub Undef {
    my ($hash) = @_;
    delete $main::modules{HA2FHEM_BRIDGE}{defptr}{ $hash->{NAME} };
    ::RemoveInternalTimer($hash);
    return;
}

# AssignIoPort only picks IOs whose Clients list contains our TYPE, so the
# clientOrder registration must happen BEFORE the assignment. May not be
# possible while FHEM is still booting (IO not defined yet) -> retry.
sub _setupIO {
    my ($hash, $tries) = @_;
    my $name = $hash->{NAME};

    if (!$hash->{IODev}) {
        my $wish = ::AttrVal($name, 'IODev', '');
        my @ios = $wish ne '' ? ($wish)
                : grep { ($main::defs{$_}{TYPE} // '') =~ /^MQTT2_(CLIENT|SERVER)$/ }
                  sort keys %main::defs;
        _registerClientOrder($name, $_) for @ios;
        ::AssignIoPort($hash);
    }
    my $io = $hash->{IODev};

    if (!$io) {
        if ($tries < 24) {
            ::InternalTimer(::gettimeofday() + 5,
                sub { _setupIO($hash, $tries + 1) }, $hash);
        } else {
            ::Log3($name, 1, "$name: no MQTT2_CLIENT IODev found, giving up. "
                 . "Define one and set 'attr $name IODev <it>'.");
        }
        return;
    }

    my $ioName = $io->{NAME};

    # MQTT2 matches ignoreRegexp UNanchored against "topic:value" — without
    # the ^...: anchors it would also kill discovery configs, whose JSON
    # value contains the command topics.
    my $prefix = ::AttrVal($name, 'topicPrefix', 'ha2fhem');
    if (::AttrVal($ioName, 'ignoreRegexp', '') !~ /\Q$prefix\E/) {
        ::Log3($name, 2, "$name: recommend echo guard on $ioName: "
             . "attr $ioName ignoreRegexp ^$prefix/devices/[^/]+/[^/]+/(set|set_fan_speed|send_command):");
    }

    ::readingsSingleUpdate($hash, 'state', 'active', 1);
    return;
}

sub _registerClientOrder {
    my ($name, $ioName) = @_;
    return if !$main::defs{$ioName};
    my $co = ::AttrVal($ioName, 'clientOrder', '');
    return if $co =~ /\bHA2FHEM_BRIDGE\b/;
    $co = $co eq ''
        ? 'HA2FHEM_BRIDGE MQTT2_DEVICE MQTT_GENERIC_BRIDGE'
        : "HA2FHEM_BRIDGE $co";
    ::CommandAttr(undef, "$ioName clientOrder $co");
    ::Log3($name, 3, "$name: registered HA2FHEM_BRIDGE in clientOrder of $ioName");
    return;
}

###############################################################################
# Dispatch entry: msg = "autocreate=<ac>\0<cid>\0<topic>\0<value>"
# Return: child names (consumed), "" (consumed, quiet), () (not ours).
sub Parse {
    my ($iohash, $msg) = @_;

    $msg =~ s/^autocreate=[^\0]*\0//;
    my ($cid, $topic, $value) = split /\0/, $msg, 3;
    return () if !defined $topic;

    my @found;
    my $consumed = 0;

    for my $bname (keys %{ $main::modules{HA2FHEM_BRIDGE}{defptr} }) {
        my $bridge = $main::modules{HA2FHEM_BRIDGE}{defptr}{$bname};
        next if !$bridge->{IODev} || $bridge->{IODev} != $iohash;
        next if ::IsDisabled($bname);

        my $prefix = ::AttrVal($bname, 'topicPrefix', 'ha2fhem');
        next if $topic !~ m{^\Q$prefix\E/};
        $consumed = 1;

        if ($topic =~ m{^\Q$prefix\E/discovery/}) {
            push @found, _handleDiscovery($bridge, $prefix, $topic, $value);
        }
        elsif ($topic =~ m{^\Q$prefix\E/devices/([^/]+)/availability$}) {
            push @found, _updateChild($bridge, $1, undef, 'availability', $value);
        }
        elsif ($topic =~ m{^\Q$prefix\E/devices/([^/]+)/([^/]+)/state$}) {
            push @found, _handleState($bridge, $1, $2, $value);
        }
        elsif ($topic =~ m{^\Q$prefix\E/status$}) {
            ::readingsSingleUpdate($bridge, 'peer', $value, 1);
        }
        # own command topics (.../set etc.) are ignored here on purpose
    }

    return () if !$consumed;
    return @found ? @found : ('');
}

sub _handleDiscovery {
    my ($bridge, $prefix, $topic, $value) = @_;
    my $bname = $bridge->{NAME};

    if (!defined $value || $value eq '') {
        return _handleDiscoveryDelete($bridge, $prefix, $topic);
    }

    my ($entity, $err) =
        FHEM::HA2FHEM::Discovery::parse_config($prefix, $topic, $value);
    if (!$entity) {
        ::Log3($bname, 2, "$bname: $err");
        return ();
    }

    my $did = $entity->{device_id};
    if (!FHEM::HA2FHEM::Filter::device_allowed(
            ::AttrVal($bname, 'includeDevices', undef),
            ::AttrVal($bname, 'excludeDevices', undef),
            $did, $entity->{device_name})) {
        ::Log3($bname, 4, "$bname: device $did filtered (include/excludeDevices)");
        return ();
    }

    $bridge->{devices}{$did}{entities}{ $entity->{entity_key} } = $entity;
    $bridge->{devices}{$did}{name} = $entity->{device_name};

    my $chash = $main::modules{HA2FHEM_CLIENT}{defptr}{$did};
    if (!$chash
        && FHEM::HA2FHEM::Profiles::is_main_component($entity->{component})
        && FHEM::HA2FHEM::Filter::class_allowed(
               ::AttrVal($bname, 'includeClasses', undef),
               $entity->{component})) {
        $chash = _createChild($bridge, $did, $entity);
    }
    return $chash ? ($chash->{NAME}) : ();
}

sub _handleDiscoveryDelete {
    my ($bridge, $prefix, $topic) = @_;
    my $bname = $bridge->{NAME};

    my (undef, $object_id) =
        FHEM::HA2FHEM::Discovery::parse_delete_topic($prefix, $topic);
    return () if !$object_id;

    for my $did (keys %{ $bridge->{devices} }) {
        my $entities = $bridge->{devices}{$did}{entities};
        for my $key (keys %$entities) {
            next if $entities->{$key}{object_id} ne $object_id;
            delete $entities->{$key};
            ::Log3($bname, 4, "$bname: removed entity $object_id of $did");
            if (!%$entities) {
                delete $bridge->{devices}{$did};
                my $chash = $main::modules{HA2FHEM_CLIENT}{defptr}{$did};
                if ($chash) {
                    ::Log3($bname, 3,
                        "$bname: deleting child $chash->{NAME} ($did, no entities left)");
                    ::CommandDelete(undef, $chash->{NAME});
                }
            }
            return ();
        }
    }
    return ();
}

sub _createChild {
    my ($bridge, $did, $entity) = @_;
    my $bname = $bridge->{NAME};

    my $cname = ::makeDeviceName('ha2fhem_' . $entity->{device_name});
    my $err = ::CommandDefine(undef, "$cname HA2FHEM_CLIENT $did");
    if ($err) {
        ::Log3($bname, 1, "$bname: cannot create child $cname: $err");
        return;
    }
    ::CommandAttr(undef, "$cname room HA2FHEM");
    my $chash = $main::defs{$cname};
    $chash->{bridge} = $bname;
    $chash->{IODev}  = $bridge->{IODev};
    ::Log3($bname, 3, "$bname: created child $cname for HA device $did "
         . "($entity->{component})");
    return $chash;
}

sub _handleState {
    my ($bridge, $did, $entity_key, $value) = @_;

    my $entity  = $bridge->{devices}{$did}{entities}{$entity_key};
    my $component = $entity ? $entity->{component} : '';
    my $is_main = $entity
        ? FHEM::HA2FHEM::Profiles::is_main_component($component)
        : 0;

    my $readings = FHEM::HA2FHEM::Profiles::state_readings(
        $component, $entity_key, $is_main, $value);
    return _updateChild($bridge, $did, $readings);
}

# _updateChild($bridge, $device_id, \%readings [, $single_name, $single_val])
sub _updateChild {
    my ($bridge, $did, $readings, $sname, $sval) = @_;

    my $chash = $main::modules{HA2FHEM_CLIENT}{defptr}{$did};
    return () if !$chash;

    $readings //= { $sname => $sval };
    return () if !%$readings;

    ::readingsBeginUpdate($chash);
    for my $r (sort keys %$readings) {
        ::readingsBulkUpdate($chash, $r, $readings->{$r});
    }
    ::readingsEndUpdate($chash, 1);
    return ($chash->{NAME});
}

1;
