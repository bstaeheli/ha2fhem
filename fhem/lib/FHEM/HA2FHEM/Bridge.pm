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
use FHEM::HA2FHEM::Discovery::Generic;
use FHEM::HA2FHEM::Filter;
use FHEM::HA2FHEM::Profiles;

sub Initialize {
    my ($hash) = @_;
    $hash->{Match}    = '^autocreate=';
    $hash->{DefFn}    = 'FHEM::HA2FHEM::Bridge::Define';
    $hash->{UndefFn}  = 'FHEM::HA2FHEM::Bridge::Undef';
    $hash->{ParseFn}  = 'FHEM::HA2FHEM::Bridge::Parse';
    $hash->{AttrList} = 'topicPrefix genericDiscoveryPrefix includeDevices '
                      . 'excludeDevices includeClasses disable:0,1 '
                      . $main::readingFnAttributes;
    return;
}

sub Define {
    my ($hash, $def) = @_;
    my ($name, $type) = split m{\s+}, $def;

    $main::modules{HA2FHEM_BRIDGE}{defptr}{$name} = $hash;
    $hash->{devices} = {};    # device_id => { entities => { key => entity } }
    $hash->{topics}  = {};    # topic => [ [device_id, entity_key, kind], ... ]
                               # (generic discovery only; kind: state|availability)

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
             . "attr $ioName ignoreRegexp ^$prefix/devices/[^/]+/[^/]+/(set|set_fan_speed|send_command|set_position):");
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

        my $prefix  = ::AttrVal($bname, 'topicPrefix', 'ha2fhem');
        my $gprefix = ::AttrVal($bname, 'genericDiscoveryPrefix', '');

        if ($topic =~ m{^\Q$prefix\E/}) {
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
        # genericDiscoveryPrefix is empty (feature off) by default: the
        # bridge must never take over z2m/Tasmota devices silently.
        elsif ($gprefix ne '' && $topic =~ m{^\Q$gprefix\E/[^/]+/(?:[^/]+/)?[^/]+/config$}) {
            $consumed = 1;
            push @found, _handleGenericDiscovery($bridge, $gprefix, $topic, $value);
        }
        elsif ($gprefix ne '' && $bridge->{topics}{$topic}) {
            $consumed = 1;
            push @found, _handleGenericTopic($bridge, $topic, $value);
        }
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
    return _registerEntity($bridge, $entity);
}

sub _handleDiscoveryDelete {
    my ($bridge, $prefix, $topic) = @_;

    my (undef, $object_id) =
        FHEM::HA2FHEM::Discovery::parse_delete_topic($prefix, $topic);
    return () if !$object_id;
    return _removeEntityByObjectId($bridge, $object_id);
}

# genericDiscoveryPrefix topics: <gprefix>/<component>/[<node_id>/]<object_id>/config
sub _handleGenericDiscovery {
    my ($bridge, $gprefix, $topic, $value) = @_;
    my $bname = $bridge->{NAME};

    if (!defined $value || $value eq '') {
        return _handleGenericDiscoveryDelete($bridge, $gprefix, $topic);
    }

    my ($entity, $err) =
        FHEM::HA2FHEM::Discovery::Generic::parse_config($gprefix, $topic, $value);
    if (!$entity) {
        ::Log3($bname, 2, "$bname: $err");
        return ();
    }

    # ponytail: stage 1 (#17) covers switch/light/cover as main entities,
    # plus sensor/binary_sensor attaching to them like our own discovery.
    # vacuum and everything else are stage 2 (#20).
    my $component = $entity->{component};
    if ($component ne 'sensor' && $component ne 'binary_sensor'
        && !($component eq 'switch' || $component eq 'light' || $component eq 'cover')) {
        ::Log3($bname, 4, "$bname: generic component $component not yet "
             . "supported (stage 1: switch/light/cover), ignored");
        return ();
    }

    my @found = _registerEntity($bridge, $entity);
    # index topics only for entities that survived the device filter —
    # otherwise every foreign z2m/Tasmota device would leak into the index
    _registerGenericTopics($bridge, $entity)
        if $bridge->{devices}{ $entity->{device_id} }
        && $bridge->{devices}{ $entity->{device_id} }{entities}{ $entity->{entity_key} };
    return @found;
}

sub _handleGenericDiscoveryDelete {
    my ($bridge, $gprefix, $topic) = @_;

    my (undef, $object_id) =
        FHEM::HA2FHEM::Discovery::Generic::parse_delete_topic($gprefix, $topic);
    return () if !$object_id;
    return _removeEntityByObjectId($bridge, $object_id);
}

# _registerEntity(\%entity) — shared by ha2fhem-native and generic discovery:
# apply include/excludeDevices, store the entity, autocreate the child.
sub _registerEntity {
    my ($bridge, $entity) = @_;
    my $bname = $bridge->{NAME};

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

# _removeEntityByObjectId($object_id) — shared by ha2fhem-native and generic
# discovery delete (empty payload on a discovery config topic).
sub _removeEntityByObjectId {
    my ($bridge, $object_id) = @_;
    my $bname = $bridge->{NAME};

    for my $did (keys %{ $bridge->{devices} }) {
        my $entities = $bridge->{devices}{$did}{entities};
        for my $key (keys %$entities) {
            next if $entities->{$key}{object_id} ne $object_id;
            delete $entities->{$key};
            _unregisterGenericTopics($bridge, $did, $key);
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

sub _registerGenericTopics {
    my ($bridge, $entity) = @_;
    my $did = $entity->{device_id};
    my $key = $entity->{entity_key};

    # re-announcements (birth republish, z2m restart) must not stack up
    # duplicate index entries
    _unregisterGenericTopics($bridge, $did, $key);

    push @{ $bridge->{topics}{ $entity->{state_topic} } }, [$did, $key, 'state'];

    my $atopic = $entity->{config}{availability_topic};
    push @{ $bridge->{topics}{$atopic} }, [$did, $key, 'availability']
        if defined $atopic && $atopic ne '';
    return;
}

sub _unregisterGenericTopics {
    my ($bridge, $did, $key) = @_;
    for my $topic (keys %{ $bridge->{topics} }) {
        my $list = $bridge->{topics}{$topic};
        @$list = grep { !($_->[0] eq $did && $_->[1] eq $key) } @$list;
        delete $bridge->{topics}{$topic} if !@$list;
    }
    return;
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

# generic (topic-index) dispatch: one MQTT topic can carry several entities
# (z2m publishes one shared JSON per device), so replay the message once per
# registration.
sub _handleGenericTopic {
    my ($bridge, $topic, $value) = @_;

    my @found;
    for my $reg (@{ $bridge->{topics}{$topic} // [] }) {
        my ($did, $key, $kind) = @$reg;
        push @found, $kind eq 'availability'
            ? _handleGenericAvailability($bridge, $did, $key, $value)
            : _handleGenericState($bridge, $did, $key, $value);
    }
    return @found;
}

sub _handleGenericState {
    my ($bridge, $did, $key, $value) = @_;
    my $bname  = $bridge->{NAME};
    my $entity = $bridge->{devices}{$did}{entities}{$key};
    return () if !$entity;

    my $is_main = FHEM::HA2FHEM::Profiles::is_main_component($entity->{component});
    my ($readings, $warning) =
        FHEM::HA2FHEM::Discovery::Generic::state_reading($entity, $is_main, $value);
    ::Log3($bname, 3, "$bname: $warning") if $warning;
    return _updateChild($bridge, $did, $readings);
}

sub _handleGenericAvailability {
    my ($bridge, $did, $key, $value) = @_;
    my $entity = $bridge->{devices}{$did}{entities}{$key};
    my $mapped = $entity
        ? FHEM::HA2FHEM::Discovery::Generic::availability_value($entity->{config}, $value)
        : $value;
    return _updateChild($bridge, $did, undef, 'availability', $mapped);
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
