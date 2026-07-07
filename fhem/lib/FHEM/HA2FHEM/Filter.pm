###############################################################################
# ha2fhem — device/class filters (pure, unit-testable)
# (c) 2026 ha2fhem contributors, GPL-2.0
###############################################################################
package FHEM::HA2FHEM::Filter;

use strict;
use warnings;

# device_allowed($includeDevices, $excludeDevices, $device_id, $device_name)
# Lists are comma- or space-separated; an item matches on exact device_id or
# exact device name. Empty include list = all devices.
sub device_allowed {
    my ($include, $exclude, $device_id, $device_name) = @_;

    my $match = sub {
        my ($list) = @_;
        return 0 if !defined $list || $list =~ /^\s*$/;
        for my $item (split /[,\s]+/, $list) {
            next if $item eq '';
            return 1 if $item eq $device_id
                     || (defined $device_name && $item eq $device_name);
        }
        return 0;
    };

    return 0 if $match->($exclude);
    return 1 if !defined $include || $include =~ /^\s*$/;
    return $match->($include);
}

# class_allowed($includeClasses, $component)
# Empty list = all classes. sensor/binary_sensor are never gating: they only
# attach to devices whose main entity passed, so they are always allowed here.
sub class_allowed {
    my ($classes, $component) = @_;
    return 1 if !defined $classes || $classes =~ /^\s*$/;
    return 1 if $component eq 'sensor' || $component eq 'binary_sensor';
    return scalar grep { $_ eq $component } split /[,\s]+/, $classes;
}

1;
