#!/usr/bin/env perl
use strict; use warnings;
use threads;
use threads::shared;

use POSIX ":sys_wait_h";

my $BLOCK_SIZE = 1024;

my $running :shared = 1;

my @to_worker :shared;
my @from_worker :shared;

my $worker = threads->create(\&start_worker)->detach;

#####################
###  UTILS        ###
#####################

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

#####################
###  GUI  Thread  ###
#####################

sub select_iso {
    my ($parent, $file, $callback) = @_;

    my $fileselect = $parent->FileSelect(
        -title => 'Select ISO',
        -directory => $ENV{HOME},
        -filter => '*.iso',
    );

    $file = $fileselect->Show unless($file);

    return undef unless($file);
    return $callback->($parent, $file) if($callback);
    return $file;
}

sub select_devices {
    my ($parent, $file, $callback) = @_;

    return unless($file);

    my $window = $parent->Toplevel(
        -title => 'Select devices',
    );

    $window->OnDestroy(sub { $parent->destroy });

    $window->Label(-text => "Please select devices to write $file to:")->pack;

    my %selected;

    my $button = $window->Button(
        -text => 'Write!',
        -state => 'disabled',
        -command => sub {
            $window->Busy(-recurse => 1);
            $callback->($window, $file, \%selected) if($callback);
            $window->Unbusy(-recurse => 1);
        },
    );

    for my $drive (usb_drives()) {
        $window->Checkbutton(
            -text => $drive->{ID_VENDOR} . ' ' . $drive->{ID_MODEL} . ' (' . $drive->{DEVNAME} . ')',
            -command => sub {
                if(exists $selected{$drive->{DEVNAME}}) {
                    delete $selected{$drive->{DEVNAME}}
                } else {
                    $selected{$drive->{DEVNAME}} = $drive->{ID_VENDOR} . ' ' . $drive->{ID_MODEL} . ' (' . $drive->{DEVNAME} . ')';
                }

                my $state = scalar(keys %selected) ? 'normal' : 'disabled';
                $button->configure(-state => $state);
            },
        )->pack;
    }

    $button->pack;
}

sub write_iso {
    my ($parent, $file, $devices) = @_;

    my $window = $parent->Toplevel(
        -title => "Writing '$file' to devices " . join(', ' => keys %$devices),
    );

    $window->transient($parent);
    $window->protocol('WM_DELETE_WINDOW' => sub {});

    $window->Label(-text => "Writing '$file':")->pack;

    my $frame = $window->Frame;

    $frame->gridColumnconfigure(0, -weight => 0);
    $frame->gridColumnconfigure(1, -weight => 1);

    my %progress_bars;

    my $i = 0;
    for my $key (keys %$devices) {
        my $label = $frame->Label(
            -text => $devices->{$key},
        )->grid( -column => 0, -row => $i );;

        my $progress_frame = $frame->Frame;

        $progress_bars{$key} = $progress_frame->ProgressBar(
            -from => 0,
            -to => 100,
        )->pack(-expand => 1, -fill => 'x');

        $progress_frame->grid( -column => 1, -row => $i, -sticky => 'we' );
    } continue { $i++ }

    $frame->pack(-fill => 'x');
    $window->update;

    for my $key (keys %$devices) {
        push @to_worker, "$file\t$key";
    }

    while(keys %progress_bars) {
        while(scalar @from_worker) {
            my ($key, $progress) = split "\t" => pop @from_worker;

            if($progress =~ /^\d+$/) {
                $progress_bars{$key}->value($progress);
                $progress_bars{$key}->update;
            } elsif($progress eq 'done') {
                my $parent = $progress_bars{$key}->parent;

                map { $_->destroy } $parent->children;

                $parent->Label(-text => 'Done!')->pack;
                $parent->update;

                delete $progress_bars{$key};
            } else { # Is a errror!
                my $parent = $progress_bars{$key}->parent;

                map { $_->destroy } $parent->children;

                my (undef, $code) = split '-' => $progress;

                $parent->Label(-text => "Error (code: $code)")->pack;
                $parent->update;

                delete $progress_bars{$key};
            }
        }

        sleep 3;
    }

    $window->destroy;
}

sub gui {
    eval {
        require Tk;
        require Tk::Dialog;
        require Tk::FileSelect;
        require Tk::ProgressBar;
    };

    die "could not load Tk: $@" if $@;

    my $mw = MainWindow->new();
    $mw->withdraw;

    # TODO - $mw->protocol('WM_DELETE_WINDOW', \&ExitApplication);

    my $iso = select_iso($mw, $ARGV[0]) or return;

    select_devices($mw, $iso, \&write_iso);

    Tk::MainLoop();
}

#####################
### Worker Thread ###
#####################

sub start_worker {
    my %jobs;

    my $last_check = time;

    while($running) {
        while(scalar @to_worker) {
            my ($file, $dev) = split "\t" => pop @to_worker;

            die "already writing to $dev!" if(exists $jobs{$dev});

            $jobs{$dev} = fork_job($file, $dev);
        }

        if(keys %jobs and (my $current_time = time) > $last_check + 5) {
            for my $key (keys %jobs) {
                delete $jobs{$key} unless(update_job($jobs{$key}));
            }

            $last_check = time;
        }

        sleep 1;
    }
}

sub fork_job {
    my ($file, $dev) = @_;

    my %job = (
        file => $file,
        size => -s $file,
        dev => $dev,
    );

    pipe(READER, WRITER) || die "pipe(): $!";

    unless(my $pid = fork) {
        local $SIG{USR1} = 'IGNORE';

        close READER || die "close(): $!";
        open STDERR, ">&WRITER" || die "open(): $!";

        exec('/bin/dd', "bs=$BLOCK_SIZE", "if=$file", "of=$dev")
            or die "exec(): $!";
    } else {
        die "fork(): $!" unless(defined $pid);

        close WRITER;

        $job{pid} = $pid;
        open($job{output}, "<&READER") || die "open(): $!";

        sleep 1; # XXX - sometimes (see strace(1) output) SIGUSR1 is not properly ignored
    }

    return \%job;
}

sub update_job {
    my ($job) = shift;

    if(waitpid $job->{pid}, WNOHANG) {
        if($?) {
            push @from_worker, $job->{dev} . "\tfail-$?";
        } else {
            push @from_worker, $job->{dev} . "\tdone";
        }

        close $job->{output} || die "close(): $!";

        return undef;
    }

    return 1 unless(kill(SIGUSR1 => $job->{pid}) > 0);

    my $line = '';
    until($line =~ m/\d+\+\d+ records out/) {
        $line = readline $job->{output};

        unless(defined $line) {
            my ($dev, $pid) = ($job->{dev}, $job->{pid});

            warn "could not read progress for '$dev' in process \#$pid";
            return 1;
        }
    }
    chomp($line);

    my ($count) = $line =~ m/(\d+)\+/;

    my $progress = int(($count / ($job->{size} / $BLOCK_SIZE)) * 100);

    push @from_worker, $job->{dev} . "\t$progress";

    return 1;
}

#####################
###    MAIN       ###
#####################

gui();
