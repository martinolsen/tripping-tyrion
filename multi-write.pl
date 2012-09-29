#!/usr/bin/env perl
use strict;
use warnings;

use POSIX ":sys_wait_h";

my $IGNORE_PERMISSIONS = 0;

sub udev_info {
    my ($file) = @_;

    my $output = `udevadm info -q property -n $file`;

    my %info;

    for my $line (split "\n" => $output) {
        my ($key, $value) = split '=' => $line;

        $info{$key} = $value;
    }

    return \%info;
}

sub usb_drives {
    # TODO - will break when devices are named /dev/sd..\d+ or something else
    return grep {
        $_->{DEVTYPE} eq 'disk' and $_->{ID_BUS} eq 'usb'
    } map { udev_info($_) } glob '/dev/sd?';
}

sub select_iso {
    print "Enter ISO file: ";

    chomp(my $file = <STDIN>);

    return $file;
}

sub drive_name {
    my ($drive) = @_;

    return $drive->{ID_VENDOR} . ' ' . $drive->{ID_MODEL} . ' (' . $drive->{DEVNAME} . ')';
}

sub select_drives {
    my @drives = usb_drives();

    print "Available USB drives:\n";

    my $i = 1;
    for my $drive (@drives) {
        my $name = drive_name($drive);

        print " [$i] $name\n";
    } continue { $i++ }

    print "Please enter drive numbers separated by comma, or press enter key for all: ";

    chomp(my $selection = <STDIN>);

    unless($selection) {
        print "All drives selected.";
        return \@drives;
    }

    my @selected = map {
        die "invalid selection '$_'\n" unless($_ =~ m/^\d+$/ and exists $drives[$_ - 1]);

        $drives[$_ - 1];
    } split ',' => $selection;

    return \@selected;
}


# Select ISO file, if not given in argument
my $iso = $ARGV[0];

$iso = select_iso() unless(defined $iso);

die 'cannot read file ' . $iso . "\n" unless(-r $iso);

print "ISO: $iso\n";

# Select destination drives, if not given in arguments
my $drives = [ @ARGV[1 .. $#ARGV] ];

unless(@$drives) {
    $drives = select_drives();
}

map {
    die "cannot write to device $_" unless($IGNORE_PERMISSIONS or -w $_)
} map { $_->{DEVNAME} } @$drives;

# TODO - confirm
print "\n\nWRITING $iso TO " . join(', ' => map { $_->{DEVNAME} } @$drives) . "!\n\n";

my $yn = '';
until($yn =~ m/yes/i) {
    print "Are you sure? [yes/no] "; $yn = <STDIN>
}

print "Writing...\n";

# Write!
my %dd_pids;
my %dd_outputs;

for my $drive (@$drives) {
    pipe(READER, WRITER) || die "pipe(): $!";

    unless(my $pid = fork) {
        close READER || die "close(): $!";
        open STDERR, ">&WRITER" || die "open(): $!";

        my $output = $drive->{DEVNAME};

        $SIG{PIPE} = sub { warn "PIPE broken in $pid" };

        exec('dd', 'bs=1K', "if=$iso", "of=$output");
    } else {
        die "fork(): $!" unless(defined $pid);

        close WRITER;

        $dd_pids{$pid} = $drive;
        open($dd_outputs{$pid}, "<&READER") || die "open(): $!";
    }
}

sleep 1; # TODO - wait a short while to allow children to spin spawn

my $size = (-s $iso) / 1024;

while(keys %dd_pids) {
    for my $pid (keys %dd_pids) {
        if(waitpid $pid, WNOHANG) {
            if($?) {
                warn $dd_pids{$pid}->{DEVNAME} . " failed! (code: $?)\n";
            } else {
                print $dd_pids{$pid}->{DEVNAME} . " is done!\n";
            }

            close $dd_outputs{$pid};

            delete $dd_outputs{$pid};
            delete $dd_pids{$pid};

            next;
        }

        if(kill SIGUSR1 => $pid) {
            my $fh = $dd_outputs{$pid};
            my $line = readline $fh;

            $line = readline $fh until($line =~ m/\d+\+\d+ records out/);
            chomp($line);

            my ($count) = $line =~ m/(\d+)\+/;

            my $progress = int(($count / $size) * 100);
            print $dd_pids{$pid}->{DEVNAME} . " is $progress% done...\n"
                unless($progress == 100);
        }
    }

    sleep 1;
}
