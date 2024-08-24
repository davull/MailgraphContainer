#!/usr/bin/perl -w

# mailgraph -- postfix mail traffic statistics
# copyright (c) 2000-2007 ETH Zurich
# copyright (c) 2000-2007 David Schweikert <david@schweikert.ch>
# released under the GNU General Public License
# with dkim-, dmarc, spf-patch Sebastian van de Meer <kernel-error@kernel-error.de>

use RRDs;
use POSIX qw(uname);

my $VERSION = "1.14";

my $host              = (POSIX::uname())[1];
my $scriptname        = 'mailgraph.cgi';
my $xpoints           = 900;
my $points_per_sample = 3;
my $ypoints           = 200;
my $ypoints_spf       = $ypoints;
my $ypoints_err       = $ypoints;
my $ypoints_dmarc     = $ypoints;
my $ypoints_dkim      = $ypoints;
my $ypoints_dovecot   = $ypoints;

my $rrd               = 'rrd/mailgraph.rrd';
my $rrd_virus         = 'rrd/mailgraph_virus.rrd';
my $rrd_dovecot	      = 'rrd/mailgraph_dovecot.rrd';
my $tmp_dir           = 'images';

my @graphs = (
	{ title => 'Last Day',     seconds => 3600 * 24,          },
	{ title => 'Last Week',    seconds => 3600 * 24 * 7,      },
	{ title => 'Last 2 Weeks', seconds => 3600 * 24 * 7 * 2,  },
	{ title => 'Last Month',   seconds => 3600 * 24 * 31,     },
	{ title => 'Last 2 Month', seconds => 3600 * 24 * 31 * 2, },
	{ title => 'Last Year',    seconds => 3600 * 24 * 365,    },
	{ title => 'Last 2 Years', seconds => 3600 * 24 * 365 * 2 },
);

my %color = (
	sent                 => '000099', # rrggbb in hex
	received             => '009900',
	spfnone              => '000AAA',
	spffail              => '12FF0A',
	spfpass              => 'D15400',
	dmarcnone            => 'FFFF00',
	dmarcfail            => 'FF00EA',
	dmarcpass            => '00FFD5',
	dkimnone             => '3013EC',
	dkimfail             => '006B3A',
	dkimpass             => '491503',
	rejected             => 'AA0000', 
	bounced              => '000000',
	virus                => 'DDBB00',
	spam                 => '999999',
	dovecotloginsuccess  => '999999',
	dovecotloginfailed   => '006400',
);

sub rrd_graph(@)
{
	my ($range, $file, $ypoints, $verticalLabel, @rrdargs) = @_;
	my $step = $range * $points_per_sample / $xpoints;
	# choose carefully the end otherwise rrd will maybe pick the wrong RRA:
	my $end  = time; $end -= $end % $step;
	my $date = localtime(time);
	$date =~ s|:|\\:|g unless $RRDs::VERSION < 1.199908;

	my ($graphret,$xs,$ys) = RRDs::graph($file,
		'--imgformat', 'PNG',
		'--width', $xpoints,
		'--height', $ypoints,
		'--start', "-$range",
		'--end', $end,
		'--vertical-label', $verticalLabel,
		'--lower-limit', 0,
		'--units-exponent', 0, # don't show milli-messages/s
		'--lazy',
		'--color', 'SHADEA#ffffff',
		'--color', 'SHADEB#ffffff',
		'--color', 'BACK#ffffff',

		$RRDs::VERSION < 1.2002 ? () : ( '--slope-mode'),

		@rrdargs,

		'COMMENT:['.$date.']\r',
	);

	my $ERR=RRDs::error;
	die "ERROR: $ERR\n" if $ERR;
}

# sent/received
sub graph($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints, "msgs/min",
		"DEF:sent=$rrd:sent:AVERAGE",
		"DEF:msent=$rrd:sent:MAX",
		"CDEF:rsent=sent,60,*",
		"CDEF:rmsent=msent,60,*",
		"CDEF:dsent=sent,UN,0,sent,IF,$step,*",
		"CDEF:ssent=PREV,UN,dsent,PREV,IF,dsent,+",
		"AREA:rsent#$color{sent}:Sent    ",
		'GPRINT:ssent:MAX:total\: %8.0lf msgs',
		'GPRINT:rsent:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmsent:MAX:max\: %4.0lf msgs/min\l',

		"DEF:recv=$rrd:recv:AVERAGE",
		"DEF:mrecv=$rrd:recv:MAX",
		"CDEF:rrecv=recv,60,*",
		"CDEF:rmrecv=mrecv,60,*",
		"CDEF:drecv=recv,UN,0,recv,IF,$step,*",
		"CDEF:srecv=PREV,UN,drecv,PREV,IF,drecv,+",
		"LINE2:rrecv#$color{received}:Received",
		'GPRINT:srecv:MAX:total\: %8.0lf msgs',
		'GPRINT:rrecv:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmrecv:MAX:max\: %4.0lf msgs/min\l',
	);
}

# error
sub graph_err($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_err, "msgs/min",
		"DEF:bounced=$rrd:bounced:AVERAGE",
		"DEF:mbounced=$rrd:bounced:MAX",
		"CDEF:rbounced=bounced,60,*",
		"CDEF:dbounced=bounced,UN,0,bounced,IF,$step,*",
		"CDEF:sbounced=PREV,UN,dbounced,PREV,IF,dbounced,+",
		"CDEF:rmbounced=mbounced,60,*",
		"AREA:rbounced#$color{bounced}:Bounced ",
		'GPRINT:sbounced:MAX:total\: %8.0lf msgs',
		'GPRINT:rbounced:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmbounced:MAX:max\: %4.0lf msgs/min\l',

		"DEF:virus=$rrd_virus:virus:AVERAGE",
		"DEF:mvirus=$rrd_virus:virus:MAX",
		"CDEF:rvirus=virus,60,*",
		"CDEF:dvirus=virus,UN,0,virus,IF,$step,*",
		"CDEF:svirus=PREV,UN,dvirus,PREV,IF,dvirus,+",
		"CDEF:rmvirus=mvirus,60,*",
		"STACK:rvirus#$color{virus}:Viruses ",
		'GPRINT:svirus:MAX:total\: %8.0lf msgs',
		'GPRINT:rvirus:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmvirus:MAX:max\: %4.0lf msgs/min\l',

		"DEF:spam=$rrd_virus:spam:AVERAGE",
		"DEF:mspam=$rrd_virus:spam:MAX",
		"CDEF:rspam=spam,60,*",
		"CDEF:dspam=spam,UN,0,spam,IF,$step,*",
		"CDEF:sspam=PREV,UN,dspam,PREV,IF,dspam,+",
		"CDEF:rmspam=mspam,60,*",
		"STACK:rspam#$color{spam}:Spam    ",
		'GPRINT:sspam:MAX:total\: %8.0lf msgs',
		'GPRINT:rspam:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspam:MAX:max\: %4.0lf msgs/min\l',

		"DEF:rejected=$rrd:rejected:AVERAGE",
		"DEF:mrejected=$rrd:rejected:MAX",
		"CDEF:rrejected=rejected,60,*",
		"CDEF:drejected=rejected,UN,0,rejected,IF,$step,*",
		"CDEF:srejected=PREV,UN,drejected,PREV,IF,drejected,+",
		"CDEF:rmrejected=mrejected,60,*",
		"LINE2:rrejected#$color{rejected}:Rejected",
		'GPRINT:srejected:MAX:total\: %8.0lf msgs',
		'GPRINT:rrejected:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmrejected:MAX:max\: %4.0lf msgs/min\l',

	);
}

# spf
sub graph_spf($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_spf, "msgs/min",
		"DEF:spfpass=$rrd:spfpass:AVERAGE",
		"DEF:mspfpass=$rrd:spfpass:MAX",
		"CDEF:rspfpass=spfpass,60,*",
		"CDEF:dspfpass=spfpass,UN,0,spfpass,IF,$step,*",
		"CDEF:sspfpass=PREV,UN,dspfpass,PREV,IF,dspfpass,+",
		"CDEF:rmspfpass=mspfpass,60,*",
		"AREA:rspfpass#$color{spfpass}:SPF pass",
		'GPRINT:sspfpass:MAX:total\: %8.0lf msgs',
		'GPRINT:rspfpass:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspfpass:MAX:max\: %4.0lf msgs/min\l',
	
		"DEF:spfnone=$rrd:spfnone:AVERAGE",
		"DEF:mspfnone=$rrd:spfnone:MAX",
		"CDEF:rspfnone=spfnone,60,*",
		"CDEF:dspfnone=spfnone,UN,0,spfnone,IF,$step,*",
		"CDEF:sspfnone=PREV,UN,dspfnone,PREV,IF,dspfnone,+",
		"CDEF:rmspfnone=mspfnone,60,*",
		"STACK:rspfnone#$color{spfnone}:SPF none",
		'GPRINT:sspfnone:MAX:total\: %8.0lf msgs',
		'GPRINT:rspfnone:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspfnone:MAX:max\: %4.0lf msgs/min\l',

		"DEF:spffail=$rrd:spffail:AVERAGE",
		"DEF:mspffail=$rrd:spffail:MAX",
		"CDEF:rspffail=spffail,60,*",
		"CDEF:dspffail=spffail,UN,0,spffail,IF,$step,*",
		"CDEF:sspffail=PREV,UN,dspffail,PREV,IF,dspffail,+",
		"CDEF:rmspffail=mspffail,60,*",
		"LINE2:rspffail#$color{spffail}:SPF fail",
		'GPRINT:sspffail:MAX:total\: %8.0lf msgs',
		'GPRINT:rspffail:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmspffail:MAX:max\: %4.0lf msgs/min\l',
	);
}

# dmarc
sub graph_dmarc($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_dmarc, "msgs/min",
		"DEF:dmarcpass=$rrd:dmarcpass:AVERAGE",
		"DEF:mdmarcpass=$rrd:dmarcpass:MAX",
		"CDEF:rdmarcpass=dmarcpass,60,*",
		"CDEF:ddmarcpass=dmarcpass,UN,0,dmarcpass,IF,$step,*",
		"CDEF:sdmarcpass=PREV,UN,ddmarcpass,PREV,IF,ddmarcpass,+",
		"CDEF:rmdmarcpass=mdmarcpass,60,*",
		"AREA:rdmarcpass#$color{dmarcpass}:DMARC pass",
		'GPRINT:sdmarcpass:MAX:total\: %8.0lf msgs',
		'GPRINT:rdmarcpass:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdmarcpass:MAX:max\: %4.0lf msgs/min\l',
		
		"DEF:dmarcnone=$rrd:dmarcnone:AVERAGE",
		"DEF:mdmarcnone=$rrd:dmarcnone:MAX",
		"CDEF:rdmarcnone=dmarcnone,60,*",
		"CDEF:ddmarcnone=dmarcnone,UN,0,dmarcnone,IF,$step,*",
		"CDEF:sdmarcnone=PREV,UN,ddmarcnone,PREV,IF,ddmarcnone,+",
		"CDEF:rmdmarcnone=mdmarcnone,60,*",
		"STACK:rdmarcnone#$color{dmarcnone}:DMARC none",
		'GPRINT:sdmarcnone:MAX:total\: %8.0lf msgs',
		'GPRINT:rdmarcnone:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdmarcnone:MAX:max\: %4.0lf msgs/min\l',

		"DEF:dmarcfail=$rrd:dmarcfail:AVERAGE",
		"DEF:mdmarcfail=$rrd:dmarcfail:MAX",
		"CDEF:rdmarcfail=dmarcfail,60,*",
		"CDEF:ddmarcfail=dmarcfail,UN,0,dmarcfail,IF,$step,*",
		"CDEF:sdmarcfail=PREV,UN,ddmarcfail,PREV,IF,ddmarcfail,+",
		"CDEF:rmdmarcfail=mdmarcfail,60,*",
		"LINE2:rdmarcfail#$color{dmarcfail}:DMARC fail",
		'GPRINT:sdmarcfail:MAX:total\: %8.0lf msgs',
		'GPRINT:rdmarcfail:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdmarcfail:MAX:max\: %4.0lf msgs/min\l',
	);
}

# dkim
sub graph_dkim($$)
{
	my ($range, $file) = @_;
	my $step = $range*$points_per_sample/$xpoints;
	rrd_graph($range, $file, $ypoints_dkim, "msgs/min",
		"DEF:dkimpass=$rrd:dkimpass:AVERAGE",
		"DEF:mdkimpass=$rrd:dkimpass:MAX",
		"CDEF:rdkimpass=dkimpass,60,*",
		"CDEF:ddkimpass=dkimpass,UN,0,dkimpass,IF,$step,*",
		"CDEF:sdkimpass=PREV,UN,ddkimpass,PREV,IF,ddkimpass,+",
		"CDEF:rmdkimpass=mdkimpass,60,*",
		"AREA:rdkimpass#$color{dkimpass}:DKIM pass",
		'GPRINT:sdkimpass:MAX:total\: %8.0lf msgs',
		'GPRINT:rdkimpass:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdkimpass:MAX:max\: %4.0lf msgs/min\l',
		
		"DEF:dkimnone=$rrd:dkimnone:AVERAGE",
		"DEF:mdkimnone=$rrd:dkimnone:MAX",
		"CDEF:rdkimnone=dkimnone,60,*",
		"CDEF:ddkimnone=dkimnone,UN,0,dkimnone,IF,$step,*",
		"CDEF:sdkimnone=PREV,UN,ddkimnone,PREV,IF,ddkimnone,+",
		"CDEF:rmdkimnone=mdkimnone,60,*",
		"STACK:rdkimnone#$color{dkimnone}:DKIM none",
		'GPRINT:sdkimnone:MAX:total\: %8.0lf msgs',
		'GPRINT:rdkimnone:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdkimnone:MAX:max\: %4.0lf msgs/min\l',

		"DEF:dkimfail=$rrd:dkimfail:AVERAGE",
		"DEF:mdkimfail=$rrd:dkimfail:MAX",
		"CDEF:rdkimfail=dkimfail,60,*",
		"CDEF:ddkimfail=dkimfail,UN,0,dkimfail,IF,$step,*",
		"CDEF:sdkimfail=PREV,UN,ddkimfail,PREV,IF,ddkimfail,+",
		"CDEF:rmdkimfail=mdkimfail,60,*",
		"LINE2:rdkimfail#$color{dkimfail}:DKIM fail",
		'GPRINT:sdkimfail:MAX:total\: %8.0lf msgs',
		'GPRINT:rdkimfail:AVERAGE:avg\: %5.2lf msgs/min',
		'GPRINT:rmdkimfail:MAX:max\: %4.0lf msgs/min\l',
	);
}

# dovecot
sub graph_dovecot($$)
{
	my ($range, $file) = @_;
	my $step = $range * $points_per_sample / $xpoints;
	
	rrd_graph($range, $file, $ypoints_dovecot, "logins/min",
		"DEF:dovecotloginsuccess=$rrd_dovecot:dovecotloginsuccess:AVERAGE",
		"DEF:mdovecotloginsuccess=$rrd_dovecot:dovecotloginsuccess:MAX",
		"CDEF:rdovecotloginsuccess=dovecotloginsuccess,60,*",
		"CDEF:ddovecotloginsuccess=dovecotloginsuccess,UN,0,dovecotloginsuccess,IF,$step,*",
		"CDEF:sdovecotloginsuccess=PREV,UN,ddovecotloginsuccess,PREV,IF,ddovecotloginsuccess,+",
		"CDEF:rmdovecotloginsuccess=mdovecotloginsuccess,60,*",
		"AREA:rdovecotloginsuccess#$color{dovecotloginsuccess}:Dovecot logins successful",
		'GPRINT:sdovecotloginsuccess:MAX:total\: %8.0lf logins',
		'GPRINT:rdovecotloginsuccess:AVERAGE:avg\: %5.2lf logins/min',
		'GPRINT:rmdovecotloginsuccess:MAX:max\: %4.0lf logins/min\l',

		"DEF:dovecotloginfailed=$rrd_dovecot:dovecotloginfailed:AVERAGE",
		"DEF:mdovecotloginfailed=$rrd_dovecot:dovecotloginfailed:MAX",
		"CDEF:rdovecotloginfailed=dovecotloginfailed,60,*",
		"CDEF:ddovecotloginfailed=dovecotloginfailed,UN,0,dovecotloginfailed,IF,$step,*",
		"CDEF:sdovecotloginfailed=PREV,UN,ddovecotloginfailed,PREV,IF,ddovecotloginfailed,+",
		"CDEF:rmdovecotloginfailed=mdovecotloginfailed,60,*",
		"LINE2:rdovecotloginfailed#$color{dovecotloginfailed}:Dovecot logins failed    ",
		'GPRINT:sdovecotloginfailed:MAX:total\: %8.0lf logins',
		'GPRINT:rdovecotloginfailed:AVERAGE:avg\: %5.2lf logins/min',
		'GPRINT:rmdovecotloginfailed:MAX:max\: %4.0lf logins/min\l',
	);
}

sub print_html()
{
	print "Content-Type: text/html\n\n";

	print <<HEADER;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>Mail statistics for $host</title>
  <meta http-equiv="Refresh" content="300" />
  <meta http-equiv="Pragma" content="no-cache" />
  <link rel="stylesheet" href="mailgraph.css" type="text/css" />
</head>
<body>
HEADER

	print "<h1>Mail statistics for $host</h1>\n";

	print "<ul id=\"jump\">\n";
	for my $n (0..$#graphs) {
		print "  <li><a href=\"#G$n\">$graphs[$n]{title}</a>&nbsp;</li>\n";
	}
	print "</ul>\n";

	for my $n (0..$#graphs) {
		print "<h2 id=\"G$n\">$graphs[$n]{title}</h2>\n";
		print "<p>\n";
		print "  <img src=\"$scriptname?${n}-n\" alt=\"mailgraph\"/><br/>\n"; # sent/received
		print "  <img src=\"$scriptname?${n}-e\" alt=\"mailgraph\"/><br/>\n"; # errors
		print "  <img src=\"$scriptname?${n}-s\" alt=\"mailgraph\"/><br/>\n"; # spf
		print "  <img src=\"$scriptname?${n}-d\" alt=\"mailgraph\"/><br/>\n"; # dmarc
		print "  <img src=\"$scriptname?${n}-k\" alt=\"mailgraph\"/><br/>\n"; # dkim
		print "  <img src=\"$scriptname?${n}-v\" alt=\"mailgraph\"/><br/>\n"; # dovecot
		print "</p>\n";
	}

	print <<FOOTER;
  <hr/>
  <a href="http://mailgraph.schweikert.ch/">Mailgraph</a> $VERSION by <a href="http://david.schweikert.ch/">David Schweikert</a>
</body>
</html>
FOOTER
}

sub send_image($)
{
	my ($file)= @_;

	-r $file or do {
		print "Content-type: text/plain\n\nERROR: can't find $file\n";
		exit 1;
	};

	print "Content-type: image/png\n";
	print "Content-length: ".((stat($file))[7])."\n";
	print "\n";
	open(IMG, $file) or die;
	my $data;
	print $data while read(IMG, $data, 16384)>0;
}

sub main()
{
	my $uri = $ENV{REQUEST_URI} || '';
	$uri =~ s/\/[^\/]+$//;
	$uri =~ s/\//,/g;
	$uri =~ s/(\~|\%7E)/tilde,/g;
	mkdir $tmp_dir, 0777 unless -d $tmp_dir;
	mkdir "$tmp_dir/$uri", 0777 unless -d "$tmp_dir/$uri";

	my $img = $ENV{QUERY_STRING};
	if(defined $img and $img =~ /\S/) {
		if($img =~ /^(\d+)-n$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1.png";
			graph($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-e$/) {
			my $file = "$tmp_dir/$uri/mailgraph_$1_err.png";
			graph_err($graphs[$1]{seconds}, $file);
			send_image($file);
		}
		elsif($img =~ /^(\d+)-s$/) {
 			my $file = "$tmp_dir/$uri/mailgraph_$1_spf.png";
 			graph_spf($graphs[$1]{seconds}, $file);
 			send_image($file);
 		}
		elsif($img =~ /^(\d+)-d$/) {
 			my $file = "$tmp_dir/$uri/mailgraph_$1_dmarc.png";
 			graph_dmarc($graphs[$1]{seconds}, $file);
 			send_image($file);
 		}
		elsif($img =~ /^(\d+)-k$/) {
 			my $file = "$tmp_dir/$uri/mailgraph_$1_dkim.png";
 			graph_dkim($graphs[$1]{seconds}, $file);
 			send_image($file);
 		}
		elsif($img =~ /^(\d+)-v$/) {
 			my $file = "$tmp_dir/$uri/mailgraph_$1_dovecot.png";
 			graph_dovecot($graphs[$1]{seconds}, $file);
 			send_image($file);
 		}
		else {
			die "ERROR: invalid argument\n";
		}
	}
	else {
		print_html;
	}
}

main;
