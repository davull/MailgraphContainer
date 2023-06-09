#!/usr/bin/perl -w

# mailgraph -- an rrdtool frontend for mail statistics
# copyright (c) 2000-2007 ETH Zurich
# copyright (c) 2000-2007 David Schweikert <david@schweikert.ch>
# released under the GNU General Public License
# with dkim-, dmarc, spf-patch Sebastian van de Meer <kernel-error@kernel-error.de>

######## Parse::Syslog 1.09 (automatically embedded) ########
package Parse::Syslog;
use Carp;
use Symbol;
use Time::Local;
use IO::File;
use strict;
use vars qw($VERSION);
my %months_map = (
    'Jan' => 0, 'Feb' => 1, 'Mar' => 2,
    'Apr' => 3, 'May' => 4, 'Jun' => 5,
    'Jul' => 6, 'Aug' => 7, 'Sep' => 8,
    'Oct' => 9, 'Nov' =>10, 'Dec' =>11,
    'jan' => 0, 'feb' => 1, 'mar' => 2,
    'apr' => 3, 'may' => 4, 'jun' => 5,
    'jul' => 6, 'aug' => 7, 'sep' => 8,
    'oct' => 9, 'nov' =>10, 'dec' =>11,
);
sub is_dst_switch($$$)
{
    my ($self, $t, $time) = @_;
    # calculate the time in one hour and see if the difference is 3600 seconds.
    # if not, we are in a dst-switch hour
    # note that right now we only support 1-hour dst offsets
    # cache the result
    if(defined $self->{is_dst_switch_last_hour} and
        $self->{is_dst_switch_last_hour} == $t->[3]<<5+$t->[2]) {
        return @{$self->{is_dst_switch_result}};
    }
    # calculate a number out of the day and hour to identify the hour
    $self->{is_dst_switch_last_hour} = $t->[3]<<5+$t->[2];
    # calculating hour+1 (below) is a problem if the hour is 23. as far as I
    # know, nobody does the DST switch at this time, so just assume it isn't
    # DST switch if the hour is 23.
    if($t->[2]==23) {
        @{$self->{is_dst_switch_result}} = (0, undef);
        return @{$self->{is_dst_switch_result}};
    }
    # let's see the timestamp in one hour
    # 0: sec, 1: min, 2: h, 3: day, 4: month, 5: year
    my $time_plus_1h = timelocal($t->[0], $t->[1], $t->[2]+1, $t->[3], $t->[4], $t->[5]);
    if($time_plus_1h - $time > 4000) {
        @{$self->{is_dst_switch_result}} = (3600, $time-$time%3600+3600);
    }
    else {
        @{$self->{is_dst_switch_result}} = (0, undef);
    }
    return @{$self->{is_dst_switch_result}};
}
# fast timelocal, cache minute's timestamp
# don't cache more than minute because of daylight saving time switch
# 0: sec, 1: min, 2: h, 3: day, 4: month, 5: year
sub str2time($$$$$$$$)
{
    my $self = shift @_;
    my $GMT = pop @_;
    my $lastmin = $self->{str2time_lastmin};
    if(defined $lastmin and
        $lastmin->[0] == $_[1] and
        $lastmin->[1] == $_[2] and
        $lastmin->[2] == $_[3] and
        $lastmin->[3] == $_[4] and
        $lastmin->[4] == $_[5])
    {
        $self->{last_time} = $self->{str2time_lastmin_time} + $_[0];
        return $self->{last_time} + ($self->{dst_comp}||0);
    }
    my $time;
    if($GMT) {
        $time = timegm(@_);
    }
    else {
        $time = timelocal(@_);
    }
    # compensate for DST-switch
    # - if a timewarp is detected (1:00 -> 1:30 -> 1:00):
    # - test if we are in a DST-switch-hour
    # - compensate if yes
    # note that we assume that the DST-switch goes like this:
    # time   1:00  1:30  2:00  2:30  2:00  2:30  3:00  3:30
    # stamp   1     2     3     4     3     3     7     8  
    # comp.   0     0     0     0     2     2     0     0
    # result  1     2     3     4     5     6     7     8
    # old Time::Local versions behave differently (1 2  5 6 5 6 7 8)
    if(!$GMT and !defined $self->{dst_comp} and
        defined $self->{last_time} and
        $self->{last_time}-$time > 1200 and
        $self->{last_time}-$time < 3600)
    {
        my ($off, $until) = $self->is_dst_switch(\@_, $time);
        if($off) {
            $self->{dst_comp} = $off;
            $self->{dst_comp_until} = $until;
        }
    }
    if(defined $self->{dst_comp_until} and $time > $self->{dst_comp_until}) {
        delete $self->{dst_comp};
        delete $self->{dst_comp_until};
    }
    $self->{str2time_lastmin} = [ @_[1..5] ];
    $self->{str2time_lastmin_time} = $time-$_[0];
    $self->{last_time} = $time;
    return $time+($self->{dst_comp}||0);
}
sub _use_locale($)
{
    use POSIX qw(locale_h strftime);
    my $old_locale = setlocale(LC_TIME);
    for my $locale (@_) {
        croak "new(): wrong 'locale' value: '$locale'" unless setlocale(LC_TIME, $locale);
        for my $month (0..11) {
            $months_map{strftime("%b", 0, 0, 0, 1, $month, 96)} = $month;
        }
    }
    setlocale(LC_TIME, $old_locale);
}
sub new($$;%)
{
    my ($class, $file, %data) = @_;
    croak "new() requires one argument: file" unless defined $file;
    %data = () unless %data;
    if(not defined $data{year}) {
        $data{year} = (localtime(time))[5]+1900;
    }
    $data{type} = 'syslog' unless defined $data{type};
    $data{_repeat}=0;
    if(UNIVERSAL::isa($file, 'IO::Handle')) {
        $data{file} = $file;
    }
    elsif(UNIVERSAL::isa($file, 'File::Tail')) {
        $data{file} = $file;
        $data{filetail}=1;
    }
    elsif(! ref $file) {
        if($file eq '-') {
            my $io = new IO::Handle;
            $data{file} = $io->fdopen(fileno(STDIN),"r");
        }
        else {
            $data{file} = new IO::File($file, "<");
            defined $data{file} or croak "can't open $file: $!";
        }
    }
    else {
        croak "argument must be either a file-name or an IO::Handle object.";
    }
    if(defined $data{locale}) {
        if(ref $data{locale} eq 'ARRAY') {
            _use_locale @{$data{locale}};
        }
        elsif(ref $data{locale} eq '') {
            _use_locale $data{locale};
        }
        else {
            croak "'locale' parameter must be scalar or array of scalars";
        }
    }
    return bless \%data, $class;
}
sub _year_increment($$)
{
    my ($self, $mon) = @_;
    # year change
    if($mon==0) {
        $self->{year}++ if defined $self->{_last_mon} and $self->{_last_mon} == 11;
        $self->{enable_year_decrement} = 1;
    }
    elsif($mon == 11) {
        if($self->{enable_year_decrement}) {
            $self->{year}-- if defined $self->{_last_mon} and $self->{_last_mon} != 11;
        }
    }
    else {
        $self->{enable_year_decrement} = 0;
    }
    $self->{_last_mon} = $mon;
}
sub _next_line($)
{
    my $self = shift;
    my $f = $self->{file};
    if(defined $self->{filetail}) {
        return $f->read;
    }
    else {
        return $f->getline;
    }
}
sub _next_syslog($)
{
    my ($self) = @_;
    while($self->{_repeat}>0) {
        $self->{_repeat}--;
        return $self->{_repeat_data};
    }
    my $file = $self->{file};
    line: while(defined (my $str = $self->_next_line)) {
        # date, time and host 
        $str =~ /^
            (\S{3})\s+(\d+)      # date  -- 1, 2
            \s
            (\d+):(\d+):(\d+)    # time  -- 3, 4, 5
            (?:\s<\w+\.\w+>)?    # FreeBSD's verbose-mode
            \s
            ([-\w\.\@:]+)        # host  -- 6
            \s+
            (?:\[LOG_[A-Z]+\]\s+)?  # FreeBSD
            (.*)                 # text  -- 7
            $/x or do
        {
            warn "WARNING: line not in syslog format: $str";
            next line;
        };
        my $mon = $months_map{$1};
        defined $mon or croak "unknown month $1\n";
        $self->_year_increment($mon);
        # convert to unix time
        my $time = $self->str2time($5,$4,$3,$2,$mon,$self->{year}-1900,$self->{GMT});
        if(not $self->{allow_future}) {
            # accept maximum one day in the present future
            if($time - time > 86400) {
                warn "WARNING: ignoring future date in syslog line: $str";
                next line;
            }
        }
        my ($host, $text) = ($6, $7);
        # last message repeated ... times
        if($text =~ /^(?:last message repeated|above message repeats) (\d+) time/) {
            next line if defined $self->{repeat} and not $self->{repeat};
            next line if not defined $self->{_last_data}{$host};
            $1 > 0 or do {
                warn "WARNING: last message repeated 0 or less times??\n";
                next line;
            };
            $self->{_repeat}=$1-1;
            $self->{_repeat_data}=$self->{_last_data}{$host};
            return $self->{_last_data}{$host};
        }
        # marks
        next if $text eq '-- MARK --';
        # some systems send over the network their
        # hostname prefixed to the text. strip that.
        $text =~ s/^$host\s+//;
        # discard ':' in HP-UX 'su' entries like this:
        # Apr 24 19:09:40 remedy : su : + tty?? root-oracle
        $text =~ s/^:\s+//;
        $text =~ /^
            ([^:]+?)        # program   -- 1
            (?:\[(\d+)\])?  # PID       -- 2
            :\s+
            (?:\[ID\ (\d+)\ ([a-z0-9]+)\.([a-z]+)\]\ )?   # Solaris 8 "message id" -- 3, 4, 5
            (.*)            # text      -- 6
            $/x or do
        {
            warn "WARNING: line not in syslog format: $str";
            next line;
        };
        if($self->{arrayref}) {
            $self->{_last_data}{$host} = [
                $time,  # 0: timestamp 
                $host,  # 1: host      
                $1,     # 2: program   
                $2,     # 3: pid       
                $6,     # 4: text      
                ];
        }
        else {
            $self->{_last_data}{$host} = {
                timestamp => $time,
                host      => $host,
                program   => $1,
                pid       => $2,
                msgid     => $3,
                facility  => $4,
                level     => $5,
                text      => $6,
            };
        }
        return $self->{_last_data}{$host};
    }
    return undef;
}
sub _next_metalog($)
{
    my ($self) = @_;
    my $file = $self->{file};
    line: while(my $str = $self->_next_line) {
	# date, time and host 
	$str =~ /^
            (\S{3})\s+(\d+)   # date  -- 1, 2
            \s
            (\d+):(\d+):(\d+) # time  -- 3, 4, 5
	                      # host is not logged
            \s+
            (.*)              # text  -- 6
            $/x or do
        {
            warn "WARNING: line not in metalog format: $str";
            next line;
        };
        my $mon = $months_map{$1};
        defined $mon or croak "unknown month $1\n";
        $self->_year_increment($mon);
        # convert to unix time
        my $time = $self->str2time($5,$4,$3,$2,$mon,$self->{year}-1900,$self->{GMT});
	my $text = $6;
        $text =~ /^
            \[(.*?)\]        # program   -- 1
           	             # no PID
	    \s+
            (.*)             # text      -- 2
            $/x or do
        {
	    warn "WARNING: text line not in metalog format: $text ($str)";
            next line;
        };
        if($self->{arrayref}) {
            return [
                $time,  # 0: timestamp 
                'localhost',  # 1: host      
                $1,     # 2: program   
                undef,  # 3: (no) pid
                $2,     # 4: text
                ];
        }
        else {
            return {
                timestamp => $time,
                host      => 'localhost',
                program   => $1,
                text      => $2,
            };
        }
    }
    return undef;
}
sub next($)
{
    my ($self) = @_;
    if($self->{type} eq 'syslog') {
        return $self->_next_syslog();
    }
    elsif($self->{type} eq 'metalog') {
        return $self->_next_metalog();
    }
    croak "Internal error: unknown type: $self->{type}";
}

#####################################################################
#####################################################################
#####################################################################

use RRDs;

use strict;
use File::Tail;
use Getopt::Long;
use POSIX 'setsid';

my $VERSION = "1.14";

# config
my $rrdstep = 60;
my $xpoints = 540;
my $points_per_sample = 3;

my $daemon_logfile = '/var/log/mailgraph.log';
my $daemon_pidfile = '/var/run/mailgraph.pid';
my $daemon_rrd_dir = '/var/log';

# global variables
my $logfile;
my $rrd          = "mailgraph.rrd";
my $rrd_virus    = "mailgraph_virus.rrd";
my $rrd_dovecot  = "mailgraph_dovecot.rrd";
my $year;
my $this_minute;
my %sum = (
	sent => 0,
	received => 0,
	bounced => 0,
	rejected => 0,
	spfnone => 0, 
	spffail => 0, 
	spfpass => 0,
	dmarcnone => 0, 
	dmarcfail => 0, 
	dmarcpass => 0, 
	dkimnone => 0, 
	dkimfail => 0, 
	dkimpass => 0, 
	virus => 0,
	spam => 0,
	dovecotloginsuccess => 0,
	dovecotloginfailed => 0);
my $rrd_inited=0;

my %opt = ();

# prototypes
sub daemonize();
sub process_line($);
sub event_sent($);
sub event_received($);
sub event_bounced($);
sub event_rejected($);
sub event_virus($);
sub event_spam($);
sub event_spfnone($);
sub event_spffail($);
sub event_spfpass($);
sub event_dmarcnone($);
sub event_dmarcfail($);
sub event_dmarcpass($);
sub event_dkimnone($);
sub event_dkimfail($);
sub event_dkimpass($);
sub event_dovecotloginsuccess($);
sub event_dovecotloginfailed($);
sub init_rrd($);
sub update($);

sub usage
{
	print "usage: mailgraph [*options*]\n\n";
	print "  -h, --help         display this help and exit\n";
	print "  -v, --verbose      be verbose about what you do\n";
	print "  -V, --version      output version information and exit\n";
	print "  -c, --cat          causes the logfile to be only read and not monitored\n";
	print "  -l, --logfile f    monitor logfile f instead of /var/log/syslog\n";
	print "  -t, --logtype t    set logfile's type (default: syslog)\n";
	print "  -y, --year         starting year of the log file (default: current year)\n";
	print "      --host=HOST    use only entries for HOST (regexp) in syslog\n";
	print "  -d, --daemon       start in the background\n";
	print "  --daemon-pid=FILE  write PID to FILE instead of /var/run/mailgraph.pid\n";
	print "  --daemon-rrd=DIR   write RRDs to DIR instead of /var/log\n";
	print "  --daemon-log=FILE  write verbose-log to FILE instead of /var/log/mailgraph.log\n";
	print "  --ignore-localhost ignore mail to/from localhost (used for virus scanner)\n";
	print "  --ignore-host=HOST ignore mail to/from HOST regexp (used for virus scanner)\n";
	print "  --only-mail-rrd    update only the mail rrd\n";
	print "  --only-virus-rrd   update only the virus rrd\n";
	print "  --rrd-name=NAME    use NAME.rrd and NAME_virus.rrd for the rrd files\n";
	print "  --rbl-is-spam      count rbl rejects as spam\n";
	print "  --virbl-is-virus   count virbl rejects as viruses\n";

	exit;
}

sub main
{
	Getopt::Long::Configure('no_ignore_case');
	GetOptions(\%opt, 'help|h', 'cat|c', 'logfile|l=s', 'logtype|t=s', 'version|V',
		'year|y=i', 'host=s', 'verbose|v', 'daemon|d!',
		'daemon_pid|daemon-pid=s', 'daemon_rrd|daemon-rrd=s',
		'daemon_log|daemon-log=s', 'ignore-localhost!', 'ignore-host=s@',
		'only-mail-rrd', 'only-virus-rrd', 'rrd_name|rrd-name=s',
		'rbl-is-spam', 'virbl-is-virus'
		) or exit(1);
	usage if $opt{help};

	if($opt{version}) {
		print "mailgraph $VERSION by david\@schweikert.ch\n";
		exit;
	}

	$daemon_pidfile = $opt{daemon_pid} if defined $opt{daemon_pid};
	$daemon_logfile = $opt{daemon_log} if defined $opt{daemon_log};
	$daemon_rrd_dir = $opt{daemon_rrd} if defined $opt{daemon_rrd};
	$rrd            = $opt{rrd_name}.".rrd" if defined $opt{rrd_name};
	$rrd_virus      = $opt{rrd_name}."_virus.rrd" if defined $opt{rrd_name};
	$rrd_dovecot    = $opt{rrd_name}."_dovecot.rrd" if defined $opt{rrd_name};

	# compile --ignore-host regexps
	if(defined $opt{'ignore-host'}) {
		for my $ih (@{$opt{'ignore-host'}}) {
			push @{$opt{'ignore-host-re'}}, qr{\brelay=[^\s,]*$ih}i;
		}
	}

	if($opt{daemon} or $opt{daemon_rrd}) {
		chdir $daemon_rrd_dir or die "mailgraph: can't chdir to $daemon_rrd_dir: $!";
		-w $daemon_rrd_dir or die "mailgraph: can't write to $daemon_rrd_dir\n";
	}

	daemonize if $opt{daemon};

	my $logfile = defined $opt{logfile} ? $opt{logfile} : '/var/log/syslog';
	my $file;
	if($opt{cat}) {
		$file = $logfile;
	}
	else {
		$file = File::Tail->new(name=>$logfile, tail=>-1);
	}
	my $parser = new Parse::Syslog($file, year => $opt{year}, arrayref => 1,
		type => defined $opt{logtype} ? $opt{logtype} : 'syslog');

	if(not defined $opt{host}) {
		while(my $sl = $parser->next) {
			process_line($sl);
		}
	}
	else {
		my $host = qr/^$opt{host}$/i;
		while(my $sl = $parser->next) {
			process_line($sl) if $sl->[1] =~ $host;
		}
	}
}

sub daemonize()
{
	open STDIN, '/dev/null' or die "mailgraph: can't read /dev/null: $!";
	if($opt{verbose}) {
		open STDOUT, ">>$daemon_logfile"
			or die "mailgraph: can't write to $daemon_logfile: $!";
	}
	else {
		open STDOUT, '>/dev/null'
			or die "mailgraph: can't write to /dev/null: $!";
	}
	defined(my $pid = fork) or die "mailgraph: can't fork: $!";
	if($pid) {
		# parent
		open PIDFILE, ">$daemon_pidfile"
			or die "mailgraph: can't write to $daemon_pidfile: $!\n";
		print PIDFILE "$pid\n";
		close(PIDFILE);
		exit;
	}
	# child
	setsid			or die "mailgraph: can't start a new session: $!";
	open STDERR, '>&STDOUT' or die "mailgraph: can't dup stdout: $!";
}

sub init_rrd($)
{
	my $m = shift;
	my $rows = $xpoints/$points_per_sample;
	my $realrows = int($rows*1.1); # ensure that the full range is covered
	my $day_steps = int(3600*24 / ($rrdstep*$rows));
	# use multiples, otherwise rrdtool could choose the wrong RRA
	my $week_steps = $day_steps*7;
	my $month_steps = $week_steps*5;
	my $year_steps = $month_steps*12;

	# mail rrd
	if(! -f $rrd and ! $opt{'only-virus-rrd'}) {
		RRDs::create($rrd, '--start', $m, '--step', $rrdstep,
				'DS:sent:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:recv:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:bounced:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:rejected:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:spfnone:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:spffail:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:spfpass:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dmarcnone:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dmarcfail:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dmarcpass:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dkimnone:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dkimfail:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dkimpass:ABSOLUTE:'.($rrdstep*2).':0:U',
				"RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
				"RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
				"RRA:AVERAGE:0.5:$month_steps:$realrows", # month
				"RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
				"RRA:MAX:0.5:$day_steps:$realrows",   # day
				"RRA:MAX:0.5:$week_steps:$realrows",  # week
				"RRA:MAX:0.5:$month_steps:$realrows", # month
				"RRA:MAX:0.5:$year_steps:$realrows",  # year
				);
		$this_minute = $m;
	}
	elsif(-f $rrd) {
		$this_minute = RRDs::last($rrd) + $rrdstep;
	}

	# virus rrd
	if(! -f $rrd_virus and ! $opt{'only-mail-rrd'}) {
		RRDs::create($rrd_virus, '--start', $m, '--step', $rrdstep,
				'DS:virus:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:spam:ABSOLUTE:'.($rrdstep*2).':0:U',
				"RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
				"RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
				"RRA:AVERAGE:0.5:$month_steps:$realrows", # month
				"RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
				"RRA:MAX:0.5:$day_steps:$realrows",   # day
				"RRA:MAX:0.5:$week_steps:$realrows",  # week
				"RRA:MAX:0.5:$month_steps:$realrows", # month
				"RRA:MAX:0.5:$year_steps:$realrows",  # year
				);
	}
	elsif(-f $rrd_virus and ! defined $rrd_virus) {
		$this_minute = RRDs::last($rrd_virus) + $rrdstep;
	}

	# dovecot rrd
	if(! -f $rrd_dovecot and ! $opt{'only-mail-rrd'}) {
		RRDs::create($rrd_dovecot, '--start', $m, '--step', $rrdstep,
				'DS:dovecotloginsuccess:ABSOLUTE:'.($rrdstep*2).':0:U',
				'DS:dovecotloginfailed:ABSOLUTE:'.($rrdstep*2).':0:U',
				"RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
				"RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
				"RRA:AVERAGE:0.5:$month_steps:$realrows", # month
				"RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
				"RRA:MAX:0.5:$day_steps:$realrows",       # day
				"RRA:MAX:0.5:$week_steps:$realrows",      # week
				"RRA:MAX:0.5:$month_steps:$realrows",     # month
				"RRA:MAX:0.5:$year_steps:$realrows",      # year
				);
	}
	elsif(-f $rrd_dovecot and ! defined $rrd_dovecot) {
		$this_minute = RRDs::last($rrd_dovecot) + $rrdstep;
	}

	$rrd_inited=1;
}

sub process_line($)
{
	my $sl = shift;
	my $time = $sl->[0];
	my $prog = $sl->[2];
	my $text = $sl->[4];

	# dovecot
	if ( $prog eq 'dovecot' ) {
		if($text =~ /imap-login: Login/) {
			event($time, 'dovecotloginsuccess');
		}
		elsif($text =~ /unknown user/) {
			event($time, 'dovecotloginfailed');
		}
	}
	# spf
	elsif ( $prog eq 'policyd-spf' ) {
		if ($text =~/Received-SPF: None/) {
			event($time, 'spfnone');
		}
		elsif ($text =~/Received-SPF: Neutral/) {
			event($time, 'spfnone');
		}
		elsif ($text =~/Received-SPF: Pass/) {
			event($time, 'spfpass');
		}
		elsif ($text =~/Received-SPF:/) {
			event($time, 'spffail');
		}
	}
	# postfix
	elsif($prog =~ /^postfix\/(.*)/) {
		my $prog = $1;
		if($prog eq 'smtp') {
			if($text =~ /\bstatus=sent\b/) {
				return if $opt{'ignore-localhost'} and
					$text =~ /\brelay=[^\s\[]*\[127\.0\.0\.1\]/;
				if(defined $opt{'ignore-host-re'}) {
					for my $ih (@{$opt{'ignore-host-re'}}) {
						warn "MATCH! $text\n" if $text =~ $ih;
						return if $text =~ $ih;
					}
				}
				event($time, 'sent');
			}
			elsif($text =~ /\bstatus=bounced\b/) {
				event($time, 'bounced');
			}
		}
		elsif($prog eq 'local') {
			if($text =~ /\bstatus=bounced\b/) {
				event($time, 'bounced');
			}
		}
		elsif($prog eq 'smtpd') {
			if($text =~ /^[0-9A-Z]+: client=(\S+)/) {
				my $client = $1;
				return if $opt{'ignore-localhost'} and
					$client =~ /\[127\.0\.0\.1\]$/;
				return if $opt{'ignore-host'} and
					$client =~ /$opt{'ignore-host'}/oi;
				event($time, 'received');
			}
			elsif($opt{'virbl-is-virus'} and $text =~ /^(?:[0-9A-Z]+: |NOQUEUE: )?reject: .*: 554.* blocked using virbl.dnsbl.bit.nl/) {
				event($time, 'virus');
			}
			elsif($opt{'rbl-is-spam'} and $text    =~ /^(?:[0-9A-Z]+: |NOQUEUE: )?reject: .*: 554.* blocked using/) {
				event($time, 'spam');
			}
			elsif($text =~ /^(?:[0-9A-Z]+: |NOQUEUE: )?reject: /) {
				event($time, 'rejected');
			}
			elsif($text =~ /^(?:[0-9A-Z]+: |NOQUEUE: )?milter-reject: /) {
				if($text =~ /Blocked by SpamAssassin/) {
					event($time, 'spam');
				}
				else {
					event($time, 'rejected');
				}
			}
		}
		elsif($prog eq 'error') {
			if($text =~ /\bstatus=bounced\b/) {
				event($time, 'bounced');
			}
		}
		elsif($prog eq 'cleanup') {
			if($text =~ /^[0-9A-Z]+: (?:reject|discard): /) {
				event($time, 'rejected');
			}
		}
	}
	# sendmail
	elsif($prog eq 'sendmail' or $prog eq 'sm-mta') {
		if($text =~ /\bmailer=local\b/ ) {
			event($time, 'received');
		}
                elsif($text =~ /\bmailer=relay\b/) {
                        event($time, 'received');
                }
		elsif($text =~ /\bstat=Sent\b/ ) {
			event($time, 'sent');
		}
                elsif($text =~ /\bmailer=esmtp\b/ ) {
                        event($time, 'sent');
                }
		elsif($text =~ /\bruleset=check_XS4ALL\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\blost input channel\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\bruleset=check_rcpt\b/ ) {
			event($time, 'rejected');
		}
                elsif($text =~ /\bstat=virus\b/ ) {
                        event($time, 'virus');
                }
		elsif($text =~ /\bruleset=check_relay\b/ ) {
			if (($opt{'virbl-is-virus'}) and ($text =~ /\bivirbl\b/ )) {
				event($time, 'virus');
			} elsif ($opt{'rbl-is-spam'}) {
				event($time, 'spam');
			} else {
				event($time, 'rejected');
			}
		}
		elsif($text =~ /\bsender blocked\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\bsender denied\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\brecipient denied\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\brecipient unknown\b/ ) {
			event($time, 'rejected');
		}
		elsif($text =~ /\bUser unknown$/i ) {
			event($time, 'bounced');
		}
		elsif($text =~ /\bMilter:.*\breject=55/ ) {
			event($time, 'rejected');
		}
	}
	# exim
	elsif($prog eq 'exim') {
		if($text =~ /^[0-9a-zA-Z]{6}-[0-9a-zA-Z]{6}-[0-9a-zA-Z]{2} <= \S+/) {
			event($time, 'received');
		}
		elsif($text =~ /^[0-9a-zA-Z]{6}-[0-9a-zA-Z]{6}-[0-9a-zA-Z]{2} => \S+/) {
			event($time, 'sent');
		}
		elsif($text =~ / rejected because \S+ is in a black list at \S+/) {
			if($opt{'rbl-is-spam'}) {
				event($time, 'spam');
			} else {
				event($time, 'rejected');
			}
		}
		elsif($text =~ / rejected RCPT \S+: (Sender verify failed|Unknown user)/) {
			event($time, 'rejected');
		}
	}
	# amavis
	elsif($prog eq 'amavis' || $prog eq 'amavisd') {
		if(   $text =~ /^\([\w-]+\) (Passed|Blocked) SPAM(?:MY)?\b/) {
			if($text !~ /\btag2=/) { # ignore new per-recipient log entry (2.2.0)
				event($time, 'spam'); # since amavisd-new-2004xxxx
			}
		}
		elsif($text =~ /^\([\w-]+\) (Passed|Not-Delivered)\b.*\bquarantine spam/) {
			event($time, 'spam'); # amavisd-new-20030616 and earlier
		}
		elsif($text =~ /^\([\w-]+\) (Passed |Blocked )?INFECTED\b/) {
			if($text !~ /\btag2=/) {
				event($time, 'virus');# Passed|Blocked inserted since 2004xxxx
			}
		}
		elsif($text =~ /^\([\w-]+\) (Passed |Blocked )?BANNED\b/) {
			if($text !~ /\btag2=/) {
			       event($time, 'virus');
			}
		}
		elsif($text =~ /^Virus found\b/) {
			event($time, 'virus');# AMaViS 0.3.12 and amavisd-0.1
		}
	}
	elsif($prog eq 'vagatefwd') {
		# Vexira antivirus (old)
		if($text =~ /^VIRUS/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'hook') {
		# Vexira antivirus
		if($text =~ /^\*+ Virus\b/) {
			event($time, 'virus');
		}
		# Vexira antispam
		elsif($text =~ /\bcontains spam\b/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'avgatefwd' or $prog eq 'avmailgate.bin') {
		# AntiVir MailGate
		if($text =~ /^Alert!/) {
			event($time, 'virus');
		}
		elsif($text =~ /blocked\.$/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'avcheck') {
		# avcheck
		if($text =~ /^infected/) {
			event($time, 'virus');
		}
	}
	# spamd
	elsif($prog eq 'spamd') {
		if($text =~ /^(?:spamd: )?identified spam/) {
			event($time, 'spam');
		}
		# ClamAV SpamAssassin-plugin
		elsif($text =~ /(?:result: )?CLAMAV/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'dspam') {
		if($text =~ /spam detected from/) {
			event($time, 'spam');
		}
		elsif($text =~ /infected message from/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'spamproxyd' or $prog eq 'spampd') {
		if($text =~ /^\s*SPAM/ or $text =~ /^identified spam/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'drweb-postfix') {
		# DrWeb
		if($text =~ /infected/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'BlackHole') {
		if($text =~ /Virus/) {
			event($time, 'virus');
		}
		if($text =~ /(?:RBL|Razor|Spam)/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'MailScanner') {
		if($text =~ /(Virus Scanning: Found)/ ) {
			event($time, 'virus');
		}
		elsif($text =~ /Bounce to/ ) {
			event($time, 'bounced');
		}
		elsif($text =~ /^Spam Checks: Found ([0-9]+) spam messages/) {
			my $cnt = $1;
			for (my $i=0; $i<$cnt; $i++) {
				event($time, 'spam');
			}
		}
	}
	elsif($prog eq 'clamsmtpd') {
		if($text =~ /status=VIRUS/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'clamav-milter') {
		if($text =~ /Intercepted/) {
			event($time, 'virus');
		}
		if($text =~ /infected/) {
			event($time, 'virus');
		}
		elsif($text =~ /Message.*infected by/) {
			event($time, 'virus');
		}
	}
	elsif ($prog eq 'smtp-vilter') {
		if ($text =~ /clamd: found/) {
			event($time, 'virus');
		}
	}
	# dmarc
 	elsif ($prog eq 'opendmarc') {
 		if ($text =~ /pass/) {
 			event($time, 'dmarcpass');
 		}
 		elsif($text =~ /none/) {
 			event($time, 'dmarcnone');
 		}
 		elsif($text =~ /fail/) {
 			event($time, 'dmarcfail');
 		}
		else {
			print "unknown prog: $prog, text: $text \n";
		}
 	}
	# dkim
 	elsif ($prog eq 'opendkim') {
 		if ($text =~ /DKIM verification successful/) {
 			event($time, 'dkimpass');
 		}
 		elsif($text =~ /no signature data/) {
 			event($time, 'dkimnone');
 		}
 		elsif($text =~ /bad signature data/) {
 			event($time, 'dkimfail');
 		}
		else {
			print "unknown prog: $prog, text: $text \n";
		}
 	}
	elsif($prog eq 'avmilter') {
		# AntiVir Milter
		if($text =~ /^Alert!/) {
			event($time, 'virus');
		}
		elsif($text =~ /blocked\.$/) {
			event($time, 'virus');
		}
	}
	elsif($prog eq 'bogofilter') {
		if($text =~ /Spam/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'filter-module') {
		if($text =~ /\bspam_status\=(?:yes|spam)/) {
			event($time, 'spam');
		}
	}
	elsif($prog eq 'sta_scanner') {
		if($text =~ /^[0-9A-F]+: virus/) {
			event($time, 'virus');
		}
	}
	else {
		#print "unknown prog: $prog, text: $text \n";
	}
}

sub event($$)
{
	my ($t, $type) = @_;
	update($t) and $sum{$type}++;
}

# returns 1 if $sum should be updated
sub update($)
{
	my $t = shift;
	my $m = $t - $t%$rrdstep;
	init_rrd($m) unless $rrd_inited;
	return 1 if $m == $this_minute;
	return 0 if $m < $this_minute;

	print "update $this_minute:$sum{sent}:$sum{received}:$sum{bounced}:$sum{rejected}:$sum{spfnone}:$sum{spffail}:$sum{spfpass}:$sum{dmarcnone}:$sum{dmarcfail}:$sum{dmarcpass}:$sum{dkimnone}:$sum{dkimfail}:$sum{dkimpass}:$sum{virus}:$sum{spam}:$sum{dovecotloginsuccess}:$sum{dovecotloginfailed}\n" if $opt{verbose};
	
	RRDs::update $rrd, "$this_minute:$sum{sent}:$sum{received}:$sum{bounced}:$sum{rejected}:$sum{spfnone}:$sum{spffail}:$sum{spfpass}:$sum{dmarcnone}:$sum{dmarcfail}:$sum{dmarcpass}:$sum{dkimnone}:$sum{dkimfail}:$sum{dkimpass}" unless $opt{'only-virus-rrd'};
	RRDs::update $rrd_virus, "$this_minute:$sum{virus}:$sum{spam}" unless $opt{'only-mail-rrd'};
	RRDs::update $rrd_dovecot , "$this_minute:$sum{dovecotloginsuccess}:$sum{dovecotloginfailed}" unless $opt{'only-mail-rrd'};
	
	if($m > $this_minute+$rrdstep) {
		for(my $sm=$this_minute+$rrdstep;$sm<$m;$sm+=$rrdstep) {
			print "update $sm:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0 (SKIP)\n" if $opt{verbose};
			RRDs::update $rrd, "$sm:0:0:0:0:0:0:0:0:0:0:0:0:0" unless $opt{'only-virus-rrd'};
			RRDs::update $rrd_virus, "$sm:0:0" unless $opt{'only-mail-rrd'};
			RRDs::update $rrd_dovecot, "$sm:0:0" unless $opt{'only-mail-rrd'};
		}
	}

	$this_minute = $m;
	$sum{sent}=0;
	$sum{received}=0;
	$sum{bounced}=0;
	$sum{rejected}=0;
	$sum{spfnone}=0;
	$sum{spffail}=0;
	$sum{spfpass}=0;
	$sum{dmarcnone}=0;
	$sum{dmarcfail}=0;
	$sum{dmarcpass}=0;
	$sum{dkimnone}=0;
	$sum{dkimfail}=0;
	$sum{dkimpass}=0;
	$sum{virus}=0;
	$sum{spam}=0;
	$sum{dovecotloginsuccess}=0;
	$sum{dovecotloginfailed}=0;
	return 1;
}

main;

__END__

=head1 NAME

mailgraph.pl - rrdtool frontend for mail statistics

=head1 SYNOPSIS

B<mailgraph> [I<options>...]

     --man          show man-page and exit
 -h, --help         display this help and exit
     --version      output version information and exit
 -h, --help         display this help and exit
 -v, --verbose      be verbose about what you do
 -V, --version      output version information and exit
 -c, --cat          causes the logfile to be only read and not monitored
 -l, --logfile f    monitor logfile f instead of /var/log/syslog
 -t, --logtype t    set logfile's type (default: syslog)
 -y, --year         starting year of the log file (default: current year)
     --host=HOST    use only entries for HOST (regexp) in syslog
 -d, --daemon       start in the background
 --daemon-pid=FILE  write PID to FILE instead of /var/run/mailgraph.pid
 --daemon-rrd=DIR   write RRDs to DIR instead of /var/log
 --daemon-log=FILE  write verbose-log to FILE instead of /var/log/mailgraph.log
 --ignore-localhost ignore mail to/from localhost (used for virus scanner)
 --ignore-host=HOST ignore mail to/from HOST regexp (used for virus scanner)
 --only-mail-rrd    update only the mail rrd
 --only-virus-rrd   update only the virus rrd
 --rrd-name=NAME    use NAME.rrd and NAME_virus.rrd for the rrd files
 --rbl-is-spam      count rbl rejects as spam
 --virbl-is-virus   count virbl rejects as viruses

=head1 DESCRIPTION

This script does parse syslog and updates the RRD database (mailgraph.rrd) in
the current directory.

=head2 Log-Types

The following types can be given to --logtype:

=over 10

=item syslog

Traditional "syslog" (default)

=item metalog

Metalog (see http://metalog.sourceforge.net/)

=back

=head1 COPYRIGHT

Copyright (c) 2000-2007 by ETH Zurich
Copyright (c) 2000-2007 by David Schweikert

=head1 LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=head1 AUTHOR

S<David Schweikert E<lt>david@schweikert.chE<gt>>

=cut

# vi: sw=8
