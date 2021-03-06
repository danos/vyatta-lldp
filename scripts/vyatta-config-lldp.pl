#!/usr/bin/perl
#
# Module: vyatta-config-lldp.pl
# 
# **** License ****
#
# Copyright (c) 2019, AT&T Intellectual Property.
# All rights reserved.
#
# Copyright (c) 2014-2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: April 2010
# Description: Script to configure lldpd
# 
# **** End License ****
#

use Getopt::Long;
use POSIX;
use File::Basename;

use lib '/opt/vyatta/share/perl5';
use Vyatta::Config;
use Vyatta::Backplane qw(get_backplane_intfs);

use warnings;
use strict;

my $daemon   = '/usr/sbin/lldpd';
my $control  = '/usr/sbin/lldpctl';
my $lldpcli  = '/usr/sbin/lldpcli';
my $pid_file = '/var/run/lldpd.pid';
my $chroot_dir = '/var/run/lldpd';

my %loc_tags = (
    "0" => "language",
    "1" => "country-subdivision",
    "2" => "county",
    "3" => "city",
    "4" => "city-division",
    "5" => "block",
    "6" => "street",
    "16" => "direction",
    "17" => "trailing-street-suffix",
    "18" => "street-suffix",
    "19" => "number",
    "20" => "number-suffix",
    "21" => "landmark",
    "22" => "additional",
    "23" => "name",
    "24" => "zip",
    "25" => "building",
    "26" => "unit",
    "27" => "floor",
    "28" => "room",
    "29" => "place-type",
    "128" => "script"
);


sub is_running {
    if (-f $pid_file) {
	my $pid = `cat $pid_file`;
	chomp $pid;
	my $ps = `ps -p $pid -o comm=`;

	if (defined($ps) && $ps ne "") {
	    return 1;
	} 
    }
    return 0;
}

sub get_vyatta_platform {
    
    my $platform = 'Vyatta Router';
    my $cmd;
    
    $cmd = 'dmidecode -s system-manufacturer';
    my $manu = `$cmd`;
    chomp $manu;
    if (defined $manu and $manu =~ /Vyatta/) {
        $cmd = 'dmidecode -s system-product-name';
        my $product = `$cmd`;
        chomp $product;
        if (defined $product) {
            if ($product =~ /Vyatta/) {
                return $product;
            } else {
                return "Vyatta $product";
            }
        }
    } else {
        $cmd = 'dmidecode -s processor-version';
        my $product = `$cmd`;
        chomp $product;
        if (defined $product) {
            # leave out $product for now since it's 
            # often not a friendly format such as:
            # Vyatta Router (Pentium(R) Pro?00000000000000000000000000000000?0
            return "Vyatta Router";
        }        
    }

    return $platform;
}

sub get_vyatta_version {
    
    my $version = 'vyatta unknown';

    my $filename = '/opt/vyatta/etc/version';
    open(my $FILE, '<', $filename) or die "Error: read [$filename] $!";

    while (<$FILE>) {
        if (/^Description:\s+(.*)$/) {
            close($FILE);
            return $1;
        }
    }
    close($FILE);
    return $version;
}

sub get_options {
    
    my $opts = '';
    my $config = new Vyatta::Config;

    $config->setLevel('service lldp'); 
    $opts .= '-v ' if $config->exists('listen-vlan');

    my $addr = $config->returnValue('management-address');
    if (defined $addr) {
        $opts .= "-m $addr ";
    }
    
    my $snmp = $config->exists('snmp enable');
    if (defined $snmp){
      $config->setLevel('');
      my $sys_snmp = $config->exists('service snmp');
      if (!defined $sys_snmp){
        die  "SNMP must be configured to enable LLDP SNMP\n";
      }
      $config->setLevel('service lldp'); 
      $opts .= "-x ";  
    }

    $config->setLevel('service lldp legacy-protocols'); 
    $opts .= '-c ' if $config->exists('cdp');
    $opts .= '-e ' if $config->exists('edp');
    $opts .= '-f ' if $config->exists('fdp');
    $opts .= '-s ' if $config->exists('sonmp');

    return $opts;
}

sub vyatta_lldp_set_location_intf_lldpcli {
    my ($intf) = shift;

    my ($rc, $cmd) = (0, '');
    my $config = new Vyatta::Config;

    my $ctxt = "configure";
    if ($intf ne 'all') {
        $ctxt .= " ports $intf";
    }
    $ctxt .= " med location";

    my $path = "service lldp interface $intf";
    $config->setLevel($path); 
    return 0 if ! $config->exists('location');

    $config->setLevel("$path location"); 
    if ($config->exists('civic-based')) {
        $config->setLevel("$path location civic-based"); 
        my $cc = $config->returnValue('country-code');
        if (! defined($cc)) {
            print "Error: must define lldp country-code\n";
            exit 1;
        }

        $ctxt .= " address country $cc";

        my @ca_types = $config->listNodes('ca-type');
        if (scalar(@ca_types) < 1) {
            print "Error: must define at least 1 ca-type\n";
            exit 1;
        }

        foreach my $ca_type (@ca_types) {
            $config->setLevel("$path location civic-based ca-type $ca_type"); 
            my $ca_val = $config->returnValue('ca-value');
            if (! defined $ca_val) {
                print "Error: must define ca-value for [$ca_type]\n";
                exit 1;
            }
            $ctxt .= " $loc_tags{$ca_type} \"$ca_val\"";
        }
        $ctxt .= "\n";

    } elsif ($config->exists('elin')) {

        my $elin = $config->returnValue('elin');
        $ctxt .= " elin $elin\n";

    } elsif ($config->exists('coordinate-based')) {
        $config->setLevel("$path location coordinate-based"); 
        my $alt = $config->returnValue('altitude');
        my $lat = $config->returnValue('latitude');
        my $long = $config->returnValue('longitude');
        my $datum = $config->returnValue('datum');

        $ctxt .= " coordinate";
        if ($lat =~ /^([-+]?[0-9]*\.?[0-9]+)([nNwWsSeE])$/) {
            my $c = uc($2);
            $ctxt .= " latitude $1$c";
        } else {
            print "Error: invalid coordinate format[$lat]\n";
            exit 1;
        }

        if ($long =~ /^([-+]?[0-9]*\.?[0-9]+)([nNwWsSeE])$/) {
            my $c = uc($2);
            $ctxt .= " longitude $1$c";
        } else {
            print "Error: invalid coordinate format[$long]\n";
 	    exit 1;
        }

        $alt = 0 if ! defined $alt;
        $ctxt .= " altitude $alt m";

        if (! defined $datum) {
            $datum = "WGS84";
        }
 
        if ($datum eq 'MLLW') {        
            $datum = "NAD83/MLLW";
        } 

        $ctxt .= " datum $datum";
	    
    }

    $cmd = "$lldpcli $ctxt";
    $rc = system($cmd);
    if ($rc != 0) {
       # commit shouldn't fail just because couldn't set location
       print "Warning: error setting location on [$intf]\n";
    }
}

sub vyatta_lldp_set_location_intf {
    my ($intf) = shift;

    my ($rc, $cmd) = (0, '');
    my $config = new Vyatta::Config;

    my $path = "service lldp interface $intf";
    $config->setLevel($path); 
    return 0 if ! $config->exists('location');

    $config->setLevel("$path location"); 
    if ($config->exists('civic-based')) {
        $config->setLevel("$path location civic-based"); 
        my $cc = $config->returnValue('country-code');
        if (! defined($cc)) {
            print "Error: must define lldp country-code\n";
            exit 1;
        }
        $cmd = "$control -L \"2:$cc";
        my @ca_types = $config->listNodes('ca-type');
        if (scalar(@ca_types) < 1) {
            print "Error: must define at least 1 ca-type\n";
            exit 1;
        }
        foreach my $ca_type (@ca_types) {
            $config->setLevel("$path location civic-based ca-type $ca_type"); 
            my $ca_val = $config->returnValue('ca-value');
            if (! defined $ca_val) {
                print "Error: must define ca-value for [$ca_type]\n";
                exit 1;
            }
            $cmd .= ":$ca_type:$ca_val";
        }
        $cmd .= "\"";
    } elsif ($config->exists('elin')) {
        my $elin = $config->returnValue('elin');
        $cmd = "$control -L \"3:$elin\" ";
    } elsif ($config->exists('coordinate-based')) {
        $config->setLevel("$path location coordinate-based"); 
        my $alt = $config->returnValue('altitude');
        my $lat = $config->returnValue('latitude');
        my $long = $config->returnValue('longitude');
        my $datum = $config->returnValue('datum');
        $cmd = "$control -L \"1:";
        foreach my $x ($lat, $long) {
            if ($x =~ /^([-+]?[0-9]*\.?[0-9]+)([nNwWsSeE])$/) {
                my $c = uc($2);
                $cmd .= "$1:$c:"
            } else {
                print "Error: invalid coordinate format[$x]\n"
            }
        }
        $alt = 0 if ! defined $alt;
        $cmd .= "$alt:m:";
        if (! defined $datum) {
            $datum = "1";
        } elsif ($datum eq "WGS84") {
            $datum = "1";
        } elsif ($datum eq 'NAD83') {
            $datum = "2";
        } elsif ($datum eq 'MLLW') {        
            $datum = "3";
        } else {
            $datum = "3";
        }
        $cmd .= "$datum\"";
    }

    if ($intf ne 'all') {
        $cmd .= " $intf";
    }

    $rc = system($cmd);
    if ($rc != 0) {
        # commit shouldn't fail just because couldn't set location
        print "Warning: error setting location on [$intf]\n";
    }
}

sub vyatta_lldp_set_location {
    
    my $config = new Vyatta::Config;
    $config->setLevel('service lldp'); 
    my @intfs = $config->listNodes('interface');
    return 0 if scalar(@intfs) < 1;
    return 0 if $config->exists('disable');

    my %intfs_map = map { $_ => 1 } @intfs;

    sleep(1);  # daemon needs to be started before issuing control calls

    my $rc = 0;
    if ($intfs_map{'all'}) {
        if (-e $lldpcli) {
            vyatta_lldp_set_location_intf_lldpcli('all');
        } else {
            vyatta_lldp_set_location_intf('all');
        }
    }

    foreach my $intf (@intfs) {
        next if $intf eq 'all';  # already handled
        if (-e $lldpcli) {
            vyatta_lldp_set_location_intf_lldpcli($intf);
        } else {
            vyatta_lldp_set_location_intf($intf);
        }
    }
}

sub get_interface_list {

    my $intf_string = undef;
    my $disable_cnt = 0;

    my $bpifs = get_backplane_intfs();
    if (scalar(@$bpifs) > 0) {
        $intf_string = "-I *";

        foreach my $bpif (@$bpifs) {
            $intf_string .= ",!$bpif";
            $disable_cnt++;
        }
    }

    my $config = new Vyatta::Config;
    $config->setLevel('service lldp'); 
    my @intfs = $config->listNodes('interface');
    return $intf_string if scalar(@intfs) < 1;

    foreach my $intf (@intfs) {
        $config->setLevel("service lldp interface $intf"); 
        my $disable = $config->exists('disable');
        if ($intf eq 'all') {
            if (defined $disable) {
                print "Ingoring 'disable' on keyword 'all'\n";
            }
        } else {
            if (defined $disable) {
                if ($disable_cnt < 1) {
                    $intf_string = "-I *";
                }
                $disable_cnt++;
                $intf_string .= ",!$intf";
            }
        }
    }
    return $intf_string;
}

sub vyatta_enable_lldp {


    my ($cmd, $rc) = ('', '');
    
    if (! -e $chroot_dir) {
        mkdir $chroot_dir;
    }
    if (is_running()) {
        vyatta_disable_lldp();
    }

    print "Starting lldpd...\n";

    my $plat = get_vyatta_platform();
    my $ver  = get_vyatta_version();
    my $opts = get_options();
    my $descr = "$plat running on $ver";
    my $intfs = get_interface_list();

    $cmd = "$daemon $opts -M4 -S \"$descr\" -P $plat ";
    $cmd .= $intfs if defined $intfs;
    $rc = system($cmd);

    vyatta_lldp_set_location();

    return $rc;
}

sub vyatta_disable_lldp {
    my ($intf) = @_;
    print "Stopping lldpd...\n";

    if (! is_running()) {
        print "Warning: lldpd not running.\n";
        exit 0;
    }

    my $pid = `cat $pid_file`;
    chomp $pid;
    my $rc = system("kill $pid");

    return $rc;
}


#
# main
#

my ($action);

GetOptions("action=s"    => \$action,
) or usage();

die "Must define action\n" if ! defined $action;

my $rc = 1;
$rc =  vyatta_enable_lldp()  if $action eq 'enable';
$rc =  vyatta_disable_lldp() if $action eq 'disable';

exit $rc;

# end of file
