# See bottom of file for license and copyright information
package Foswiki::Configure::Wizards::AutoConfigureEmail;

=begin TML

---++ package Foswiki::Configure::Wizards::AutoConfigureEmail

Wizard to try to autoconfigure email.

=cut

use strict;
use warnings;

use Foswiki::Configure::Wizard ();
our @ISA = ('Foswiki::Configure::Wizard');

use constant DEBUG_SSL => 1;

use Foswiki::IP qw/$IPv6Avail :regexp :info/;

# N.B. Below the block comment are not enabled placeholders
# Search order (specify hash key):
my @mtas = (qw/mailwrapper ssmtp sendmail/);
#<<<
my %mtas = (
    sendmail => {
        name => 'sendmail',                 # Display name
        file => 'sendmail',                 # Executable file to look for in PATH
        regexp =>                           # Regexp to match basename from alias
          qr/^(?:sendmail\.)?sendmail$/,
        flags => '-t -oi -oeq',             # Flags used for sending mail
        debug => '-X /dev/stderr',          # Additional flags to enable debug logs
    },
    ssmtp => {
        name   => 'sSMTP',
        file   => 'ssmtp',
        regexp => qr/^(?:sendmail\.)?ssmtp$/,
        flags  => '-t -oi -oeq',
        debug  => '-v',
    },
    mailwrapper => {
        name   => 'mailwrapper',
        file   => 'mailwrapper',
        regexp => qr/^mailwrapper$/,
        code   =>                           # Callout to find actual program
         sub { return _mailwrapperConfig( @_ ); },
    },
# Below this comment, the keys aren't in @mtas, and hence aren't used (yet).  The data
# is almost certainly wrong - these are simply placeholders.
# As these are investigated, validated, add the keys to @mtas and move above this line.

    postfix => {
        name   => 'sendmail',
        file   => 'postfix',
        regexp => qr/^(?:sendmail\.)?postfix$/,
        flags  => '',
        debug  => '', #?? -v??
    },
    qmail => {
        name   => 'qmail',
        file   => 'qmail',
        regexp => qr/^(?:sendmail\.)?qmail$/,
        flags  => '',
        debug  => '',
    },
    exim => {
        name   => 'Exim',
        file   => 'exim',
        regexp => qr/^(?:sendmail\.)?exim$/,
        flags  => '',
        debug  => '-v',
    },

    # ... etc
);
#>>>

use constant ACCEPTMSG =>
  "Configuration accepted. Next step: Setup and test {WebMasterEmail}.";

# WIZARD
sub autoconfigure {
    my ( $this, $reporter ) = @_;

    if ( $Foswiki::cfg{Email}{EnableSMIME} ) {
        my ( $certFile, $keyFile ) = (
            $Foswiki::cfg{Email}{SmimeCertificateFile},
            $Foswiki::cfg{Email}{SmimeKeyFile},
        );
        unless ( $certFile && $keyFile ) {
            ( $certFile, $keyFile ) = (
                '$Foswiki::cfg{DataDir}/SmimeCertificate.pem',
                '$Foswiki::cfg{DataDir}/SmimePrivateKey.pem',
            );
        }
        Foswiki::Configure::Load::expandValue($certFile);
        Foswiki::Configure::Load::expandValue($keyFile);

        unless ( $certFile && $keyFile && -r $certFile && -r $keyFile ) {
            $reporter->WARN( <<NOCERT );
You nave configured Foswiki to send S/MIME signed e-mail.
To do this, either Certificate and Key files must be provided, or a self-signed certificate can be generated.
To generate a self-signed certificate or generate a signing request, use the button next to the {WebmasterName} setting.
Because no certificate is present, S/MIME has been disabled to allow basic autoconfiguration to continue.
NOCERT
            $Foswiki::cfg{Email}{EnableSMIME} = 0;
            $reporter->CHANGED('{Email}{EnableSMIME}');
        }
    }

    my $ok = 0;
    unless ( $Foswiki::cfg{Email}{MailMethod} eq 'MailProgram' ) {
        my $perlAvail = eval "require Net::SMTP";
        if ($perlAvail) {
            $ok = _autoconfigPerl($reporter);
            unless ($ok) {
                $reporter->NOTE(
"$Foswiki::cfg{Email}{MailMethod} configuration failed. Falling back to mail program."
                );
            }
        }
        else {
            $ok = 0;
            $reporter->NOTE("Net::SMTP is not available: $@");
        }
    }

    if ( !$ok && _autoconfigProgram($reporter) ) {
        $ok = 1;
        if ( $Foswiki::cfg{Email}{MailMethod} ne 'MailProgram' ) {
            $Foswiki::cfg{Email}{MailMethod} = 'MailProgram';
            $reporter->CHANGED('{Email}{MailMethod}');
        }
    }

    if ( !$ok ) {
        $reporter->ERROR(
            'Mail configuration failed. Foswiki will not be able to send mail.'
        );
        if ( $Foswiki::cfg{EnableEmail} ) {
            $Foswiki::cfg{EnableEmail} = 0;
            $reporter->CHANGED('{EnableEmail}');
        }
    }
    elsif ( !$Foswiki::cfg{EnableEmail} ) {
        $Foswiki::cfg{EnableEmail} = 1;
        $reporter->CHANGED('{EnableEmail}');
    }
}

# Return 0 on failure
# $perlAvail = 0 if not available, -1 if tried and failed, 1 if tried and OK
sub _autoconfigProgram {
    my ($reporter) = @_;

    $reporter->NOTE("Attempting to configure a mailer program");

    require Cwd;
    require File::Basename;

    my ( $mailp, $mailargs );
    my $path = $ENV{PATH};

    # First, try special heuristics

    foreach my $mta (@mtas) {
        my $cfg = $mtas{$mta} or next;
        my $test = $cfg->{code};
        next unless ($test);
        ( $mailp, $mailargs ) = $test->($cfg);
        delete $mtas{$mta};
        next unless ($mailp);

        my ( $prog, $ppath ) = File::Basename::fileparse($mailp);
        $path = "$ppath:$path" if ($ppath);
        $mailp = $prog;
    }

    # Next, look for each mta on path
    # Identify it by it's realpath (/etc/alternatives...)

    unless ($mailp) {
        foreach my $mta (@mtas) {
            my $cfg = $mtas{$mta} or next;
            foreach my $p ( split( /:/, $path ) ) {
                if ( -x "$p/$cfg->{file}" ) {
                    my $prog = Cwd::realpath("$p/$cfg->{file}");
                    if ( ( File::Basename::fileparse($prog) )[0] =~
                        $cfg->{regexp} )
                    {
                        _setMailProgram( $cfg, $p, $reporter );
                        return 1;    # OK
                    }
                }
            }
        }

        # Not found, must map /usr/sbin/sendmail to the tool
        $reporter->NOTE(
            'Unable to locate a known external mail program, trying sendmail');

        $mailp = 'sendmail';
    }

    foreach my $p ( '/usr/sbin', split( /:/, $path ) ) {
        if ( -x "$p/$mailp" ) {
            $mailp =
              ( File::Basename::fileparse( Cwd::realpath("$p/$mailp") ) )[0];
            foreach my $mta (@mtas) {
                my $cfg = $mtas{$mta} or next;
                if ( $mailp =~ $cfg->{regexp} ) {
                    $cfg->{flags} = '' unless ( defined $cfg->{flags} );
                    $cfg->{flags} = "$mailargs $cfg->{flags}"
                      if ( defined $mailargs );
                    _setMailProgram( $cfg, $p, $reporter );
                    return 1;    # OK
                }
            }
            $reporter->NOTE("Unable to identify $p/$mailp.");
        }
    }

    return 0;                    # failed
}

# mailwrapper uses a config file
# look for the traditional 'sendmail' verb
# return program and its args - wrapper prepends
# these to the "user" args.

sub _mailwrapperConfig {
    my $cfg = shift;

    open( my $cnf, '<', '/etc/mail/mailer.conf' )
      or return;
    while (<$cnf>) {
        next if (/^\s*#/);
        s/^\s+//g;
        chomp;
        my ( $cmd, $prog, $args ) = split( /\s+/, $_, 3 );
        if ( $cmd && $cmd eq 'sendmail' ) {
            close $cnf;
            return ( $prog, $args );
        }
    }
    close $cnf;
    return;
}

sub _sniffSELinux {
    my $reporter = shift;
    no warnings 'exec';

    my $selStatus = system("selinuxenabled");
    unless ( $selStatus == -1
        || ( ( $selStatus >> 8 ) && !( $selStatus & 127 ) ) )
    {
        $reporter->NOTE(<<SELINUX);
SELinux appears to be enabled on your system.
Please ensure that the SELinux policy permits SMTP connections from webserver processes to at least one of these tcp ports: 587, 465 or 25.  Also ensure that your e-mail client is permitted to be run under your webserver, and that it is permitted access to its configuration data and temporary files in this security context.
Check the audit log for specific errors, as policies vary.
SELINUX
        return 1;
    }
    return 0;
}

sub _setMailProgram {
    my ( $cfg, $path, $reporter ) = @_;

    $reporter->NOTE(<<ID);
Identified $cfg->{name} ( =$path/$cfg->{file}= ) as your mail program
ID

    _setConfig( $reporter, '{SMTP}{Debug}',       0 );
    _setConfig( $reporter, '{Email}{MailMethod}', 'MailProgram' );
    _setConfig( $reporter,
        '{MailProgram}', "$path/$cfg->{file} $cfg->{flags}" );
    _setConfig( $reporter, '{SMTP}{DebugFlags}', $cfg->{debug} );
    _setConfig( $reporter, '{EnableEmail}',      1 );
    _setConfig( $reporter, '{SMTP}{MAILHOST}',
        ' ---- Unused when MailProgram selected ---' );

    # MailProgram probes don't send mail, so just a generic message if
    # isSELinux is enabled.
    _sniffSELinux($reporter);

    $reporter->NOTE(ACCEPTMSG);
}

# autoconfig loosely parallels Net.pm
# Setup the best available connection to the e-mail server

# autoconfiguration for Net::SMTP

# Global variables (yes, really. Barf.)

our (
    $host,     $hInfo,     $port,       $hello,
    $inAuth,   $noconnect, $allconnect, $tlog,
    $tlsSsl,   $startTls,  $verified,   @sslopts,
    @sockopts, %systemAuthMethods,
);
our $pad = ' ' x length('Net::SMTpXXX ');

# Return 0 on failure
sub _autoconfigPerl {
    my ($reporter) = @_;

    $SIG{__DIE__} = sub {
        Carp::confess($@);
    };

    $reporter->NOTE("Attempting to configure Net::SMTP");

    my $trySSL = 1;

    my $IOHandleAvail = eval "require IO::Handle";
    if ($@) {
        $reporter->NOTE(
            "IO::Handle is required to auto configure Net::SMTP mail");
        return 0;
    }

    eval "require Net::SSLeay";
    if ($@) {
        $reporter->NOTE(
"Net::SSLeay is required to auto configure Net::SMTP mail over SSL - trying plain SMTP"
        );
        $trySSL = 0;
    }
    else {
        eval "require IO::Socket::SSL";
        if ($@) {
            $reporter->NOTE(
"IO::Socket::SSL is required to auto configure Net::SMTP mail over SSL"
            );
            $trySSL = 0;
        }
    }

    IO::Socket::SSL->import('debug2') if ( $trySSL && DEBUG_SSL );

    # Enable IPv6 if it's available

    @Net::SMTP::ISA = (
        grep( $_ !~ /^IO::Socket::I(?:NET|P)$/, @Net::SMTP::ISA ),
        'IO::Socket::IP'
    ) if ($IPv6Avail);

    $host = $Foswiki::cfg{SMTP}{MAILHOST};
    unless ( $host && $host !~ /^ ---/ ) {
        $reporter->NOTE("{SMTP}{MAILHOST} must be specified to use Net::SMTP");
        return 0;
    }

    $hInfo = hostInfo($host);
    if ( $hInfo->{error} ) {
        $reporter->( "{SMTP}{MAILHOST} is not valid " . $hInfo->{error} );
        return 0;
    }
    $host = $hInfo->{name};

    my @addrs;
    if ($IPv6Avail) {

        # IO::Socket::IP will handle multiple addresses/address families
        # in the right order if we pass $host, but passing the list lets
        # us log which addresses work and which don't.
        push @addrs, @{ $hInfo->{addrs} };
    }
    else {
        # Net::SMTP will iterate
        @addrs = @{ $hInfo->{v4addrs} };
        if ( @{ $hInfo->{v6addrs} } ) {
            $reporter->NOTE(
"$host has an IPv6 address, but IO::Socket::IP is not installed.  IPv6 can not be used."
            );
        }
    }
    unless (@addrs) {
        $reporter->NOTE(
            "{SMTP}{MAILHOST} $host is invalid: server has no IP address");
        return 0;
    }

    my @options = (
        Debug   => 1,
        Host    => [@addrs],
        Timeout => ( @addrs >= 2 ? 10 : 30 ),
    );

    if ( ( $hello = $Foswiki::cfg{SMTP}{SENDERHOST} ) ) {
        push @options, Hello => ($hello);
    }
    else {
        require Net::Domain;
        $hello = Net::Domain::hostfqdn();
        $hello = "[$hello]"
          if ( $hello =~ /^(?:$IPv4Re|$IPv6ZidRe)$/ );
        push @options, Hello => $hello;
    }

    $inAuth     = 0;
    $noconnect  = 1;
    $allconnect = 1;

    my $log = bless {},
      'Foswiki::Configure::Wizards::AutoConfigureEmail::Mailer';

    # Get SSL options common to all secure connection methods

    my @methods;
    my $sslNoVerify;
    my $sslVerify;

    if ($trySSL) {
        ( $sslNoVerify, $sslVerify ) = _setupSSLoptions( $log, $reporter );

        # Connection methods in priority order
        @methods = (qw/starttls-v starttls tls-v tls ssl-v ssl smtp/);
    }
    else {
        @methods = (qw/smtp/);
    }

    # Configuration data for each method.  Ports in priority order.

    my $sockSSLisa = [
        grep( $_ !~ /^IO::Socket::I(?:NET|P)$/, @Net::SMTP::ISA ),
        'IO::Socket::SSL'
    ];

    my %config = (
        starttls => {
            ports    => [qw/submission(587) smtp(25)/],
            method   => 'Net::SMTP (STARTTLS)',
            isa      => [@Net::SMTP::ISA],
            ssl      => [ SSL_version => 'TLSv1' ],
            starttls => 1,
        },
        tls => {
            ports  => [qw/smtps(465)/],
            method => 'Net::SMTP (TLS)',
            isa    => $sockSSLisa,
            ssl    => [ SSL_version => 'TLSv1' ],
        },
        ssl => {
            ports  => [qw/smtps(465)/],
            method => 'Net::SMTP (SSL)',
            isa    => $sockSSLisa,
            ssl    => [ SSL_version => 'SSLv3' ],
        },
        smtp => {
            ports  => [qw/submission(587) smtp(25)/],
            method => 'Net::SMTP',
            isa    => [@Net::SMTP::ISA],
        },
    );
    @Net::SMTP::ISA = 'Foswiki::Configure::Wizards::AutoConfigureEmail::SSL';

    # Generate configurations with peer verification

    if ($trySSL) {
        foreach my $method (@methods) {
            if ( $method =~ /^(.*)-v$/ ) {
                if (@$sslVerify) {
                    die "Invalid config for $method\n"
                      unless ( exists $config{$1} );

                    $config{$method} = { %{ $config{$1} } };
                    $config{$method}{ssl} =
                      [ @{ $config{$method}{ssl} }, @$sslVerify ];
                    $config{$method}{id} = uc($1) . " WITH host verification";
                    $config{$method}{verify} = 1;
                }
                else {
                    delete $config{$method};
                }
            }
        }
    }

    # Generate methods without peer verification

    foreach my $method (@methods) {
        next unless ( exists $config{$method} );
        next if ( !$trySSL && exists $config{$method}{ssl} );
        if ( $method !~ /-v$/ && exists $config{$method}{ssl} ) {
            push @{ $config{$method}{ssl} }, @$sslNoVerify;
            $config{$method}{id} = uc($method) . " with NO host verification";
        }
    }

    # If port forced, try to find name.
    # The smtp names are secondary for some traditional ports, so
    # use the primary for those.  For others, consult /etc/services.

    $port = $hInfo->{port};
    if ( $port && $port =~ /^\d+$/ ) {
        my $name = {
            25  => 'smtp(25)',
            587 => 'submission(587)',
            465 => 'smtps(465)',
        }->{$port};
        unless ( defined $name ) {
            $name = getservbyport( $port, 'tcp' );

            #            $name = "$name($port)" if ( defined $name );
            if ( defined $name ) {
                $name = "$name($port)";
                $name =~ /^(.*)$/;
                $name = $1;
            }
        }
        $port = $name if ( defined $name );
    }

    # Authentication data

    my $username = $Foswiki::cfg{SMTP}{Username};
    $username = '' unless ( defined $username );
    my $password = $Foswiki::cfg{SMTP}{Password};
    $password = '' unless ( defined $password );

    # SSL logging -- N.B. fd 2 is NOT STDERR from here down

    open( my $stderr, ">&STDERR" ) or die "STDERR: $!\n";
    close STDERR;
    open( my $fd2, ">/dev/null" ) or die "fd2: $!\n";
    $tlog = '';
    open( STDERR, '+>>', \$tlog ) or die "SSL logging: $!\n";
    STDERR->autoflush(1);

    # Loop over methods - output @use if one succeeds

    my @use;
  METHOD:
    foreach my $method (@methods) {
        my $cfg = $config{$method};
        next unless ($cfg);

        my @ports = $port ? ($port) : @{ $cfg->{ports} };

        # Manage carp in libnet with debug > 0
        # This gives us hidden errors such as Timeout, EOF,
        # and unsupported commands.

        local $SIG{__WARN__} = sub {
            my $msg = $_[0];
            $msg =~ s/^.*GLOB\(0x[[:xdigit:]]+\): //;
            if (0) {    # Turn on for debuging
                Carp::confess($msg);
            }
            else {
                $msg =~ s/ at .*$//ms;
            }
            chomp $msg;
            $tlog .= "${pad}Failed: $msg\n";
            return undef;
        };

        # IGNORE SIGPIPE caused by errors that cause Net::Cmd to close
        # the TCP connection - then write to it.
        local $SIG{PIPE} = 'IGNORE';

        foreach our $port (@ports) {
            $tlsSsl  = $cfg->{ssl};
            @sslopts = $tlsSsl ? ( @$tlsSsl, SSL_verifycn_name => $host, ) : ();
            $tlsSsl  = 0
              if ( $startTls = $cfg->{starttls} );

            @Foswiki::Configure::Wizards::AutoConfigureEmail::SSL::ISA =
              @{ $cfg->{isa} };

            $tlog =
                "${pad}Testing "
              . ( $cfg->{id} || uc($method) ) . " on "
              . (
                  $port =~ /^\d+$/           ? "port $port\n"
                : $port =~ /^(.*)\((\d+)\)$/ ? "$1 port ($2)\n"
                : "$port port\n"
              );
            $verified = $cfg->{verify} || -1;

            my $smtp =
              Foswiki::Configure::Wizards::AutoConfigureEmail::Mailer->new(
                @options, Port => $port );
            unless ($smtp) {
                next;
            }
            if ($tlsSsl) {
                $tlog .= $pad
                  . (
                      $verified < 0 ? "Server verification is disabled"
                    : $verified     ? "Server certificate verified"
                    : "Unable to verify server certificate"
                  ) . "\n";
                if ( $verified == 0 ) {
                    $smtp->close;
                    next;
                }
            }
            if ($startTls) {
                next unless ( $smtp->starttls( $log, $reporter ) );
            }
            @use = ( $cfg, $port );
            push @use, $smtp->testServer( $host, $username, $password );
            $smtp->quit;

            last METHOD if ( $use[2] >= 0 );
            $tlog .= $use[3];
            @use = ();
        }
    }
    close STDERR;
    close $fd2;
    open( STDERR, '>&', $stderr ) or die "stderr:$!\n";
    close $stderr;
    $reporter->NOTE($tlog);

    unless (@use) {
        _diagnoseFailure( $noconnect, $allconnect, $reporter );
        return 0;
    }

    #  @use[ cfg, port, authOK, authMsg ]
    if ( $use[2] == 0 ) {    # Incomplete
        $reporter->NOTE(
"This configuration appears to be acceptable, but testing is incomplete."
        );
        $reporter->NOTE( $use[3] );
        return 0;
    }
    if ( $use[2] == 1 || $use[2] == 4 ) {    # OK, Not required
        $reporter->NOTE( $use[3], ACCEPTMSG );
    }
    elsif ( $use[2] == 2 ) {                 # Bad credentials
            # Authentication failed, perl is OK, don't try program.
        $reporter->NOTE( $use[3] );
    }
    else {    # Other failure
        $reporter->NOTE( $use[3] );
        $reporter->NOTE(
"Although a connection was established with $host on port $use[1], it did not accept mail."
        );
        return 0;
    }

    $use[1] =~ s/^.*\((\d+)\)$/$1/;
    $host = "[$host]" if ( $hInfo->{ipv6addr} );
    my $cfg = $use[0];

    _setConfig( $reporter, '{SMTP}{Debug}',       0 );
    _setConfig( $reporter, '{Email}{MailMethod}', $cfg->{method} );
    _setConfig( $reporter, '{SMTP}{SENDERHOST}',  $hello );
    _setConfig( $reporter, '{SMTP}{Username}',    $username );
    _setConfig( $reporter, '{SMTP}{Password}',    $password );
    _setConfig( $reporter, '{SMTP}{MAILHOST}',    $host . ':' . $use[1] );
    _setConfig( $reporter, '{Email}{SSLVerifyServer}', ( $cfg->{verify} || 0 ) )
      if ( $cfg->{ssl} );

    return 1;
}

sub _setConfig {

    #my ($reporter, $setting, $value) = @_;

    eval( '$Foswiki::cfg' . $_[1] . ' = ' . '"' . $_[2] . '"' );
    $_[0]->CHANGED( $_[1] );
    return;
}

# Support routines

sub _diagnoseFailure {
    my ( $noconnect, $allconnect, $reporter ) = @_;

    my $isSELinux = _sniffSELinux($reporter);

    # If no connection went through, there's probably a block
    if ($noconnect) {
        my $mess =
"No connection was established on any port, so if the e-mail server is up, it is likely that a firewall";
        $mess .= "and/or SELINUX" if ($isSELinux);
        $mess .= " is blocking TCP connections to e-mail submission ports.";

        $reporter->NOTE($mess);
        return;
    }

    # Some worked, some didn't
    unless ($allconnect) {
        my $mess =
"At least one connection was blocked, but others succeeded.  It is possible that that a firewall";
        $mess .= "and/or SELINUX" if ($isSELinux);
        $mess .=
          " is blocking TCP connections to some e-mail submission port(s).
However, only one connection type needs to work, so you should focus on the\
issues logged on the ports where connections succeeded.";

        $reporter->NOTE($mess);
        return;
    }

    # All connections worked, but the protocol didn't.

    $reporter->NOTE(<<"SMTP");
Although all connections were successful, the service is not speaking SMTP.
The most likely causes are that the server uses a non-standard port for SMTP,
or your configuration erroneously specifies a non-SMTP port.  Check your
configuration; then check with your server support.
SMTP
}

# Compute SSL options lists for both peer verification on and off.
# If on is disabled, its list will be empty.

sub _setupSSLoptions {
    my ( $log, $reporter ) = @_;

    # Baseline: must trap errors to get accurate error reporting

    my @sslCommon = (
        SSL_error_trap => sub {
            my ( $sock, $msg ) = @_;
            if ( $sock->connected ) {
                $tlog .=
                    $pad
                  . "Failed to initialize SSL with "
                  . $sock->peerhost . ':'
                  . $sock->peerport
                  . " - $msg"
                  if ($verified);
            }
            else {
                $tlog .= "SSL error while not connected - $msg";
            }
            $sock->close;
            return;
        },
    );

    # Client verification data

    if (   $Foswiki::cfg{Email}{SSLClientCertFile}
        || $Foswiki::cfg{Email}{SSLClientKeyFile} )
    {
        my ( $certFile, $keyFile ) = (
            $Foswiki::cfg{Email}{SSLClientCertFile},
            $Foswiki::cfg{Email}{SSLClientKeyFile}
        );
        Foswiki::Configure::Load::expandValue($certFile);
        Foswiki::Configure::Load::expandValue($keyFile);

        if ( $certFile && $keyFile ) {
            push @sslCommon,
              (
                SSL_use_cert  => 1,
                SSL_cert_file => $certFile,
                SSL_key_file  => $keyFile
              );
            if ( $Foswiki::cfg{Email}{SSLClientKeyPassword} ) {
                push @sslCommon, SSL_passwd_cb => sub {
                    return $Foswiki::cfg{Email}{SSLClientKeyPassword};
                };
            }
        }
        else {
            $reporter->WARN(
"Client verification requires both {Email}{SSLClientCertFile} and {Email}{SSLClientKeyFile} to be set."
            );
        }
    }

    # SSL options lists with and without peer verification

    my ( @sslVerify, @sslNoVerify );
    @sslNoVerify =
      ( @sslCommon, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE() );

    if ( $Foswiki::cfg{Email}{SSLVerifyServer} ) {
        my ( $file, $path ) =
          ( $Foswiki::cfg{Email}{SSLCaFile}, $Foswiki::cfg{Email}{SSLCaPath} );
        Foswiki::Configure::Load::expandValue($file);
        Foswiki::Configure::Load::expandValue($path);

        if ( $file || $path ) {
            push @sslVerify, (
                @sslCommon,
                SSL_verify_mode     => IO::Socket::SSL::SSL_VERIFY_PEER(),
                SSL_verify_scheme   => undef,
                SSL_verify_callback => sub {
                    my ( $ok, $ctx, $names, $errs, $peerCert ) = @_;

                    return
                      Foswiki::Configure::Wizards::AutoConfigureEmail::SSL::sslVerifyCert(
                        $log, $ok, $ctx, $peerCert );
                },
                SSL_ca_file => $file || undef,
                SSL_ca_path => $path || undef,
            );

            if ( $Foswiki::cfg{Email}{SSLCheckCRL} ) {
                ( $file, $path ) = (
                    $Foswiki::cfg{Email}{SSLCrlFile},
                    $Foswiki::cfg{Email}{SSLCaPath}
                );
                Foswiki::Configure::Load::expandValue($file);
                Foswiki::Configure::Load::expandValue($path);

                if ( $file || $path ) {
                    push @sslVerify, SSL_check_crl => 1;
                    push @sslVerify, SSL_crl_file  => $file
                      if ($file);
                }
                else {
                    $reporter->WARN(
"{Email}{SSLCheckCRL} requires CRL verification but neither {Email}{SSLCrlFile} nor {Email}{SSLCaPath} is set."
                    );
                }
            }
        }
        else {
            $reporter->WARN(
"{Email}{SSLVerifyServer} requires host verification but neither {Email}{SSLCaFile} nor {Email}{SSLCaPath} is set."
            );
        }
    }

    return ( [@sslNoVerify], [@sslVerify] );
}

# Net::SMTP extensions
#
# Package for extended logging

package Foswiki::Configure::Wizards::AutoConfigureEmail::Mailer;

require MIME::Base64;

our @ISA = (qw/Net::SMTP/);

sub debug_text {
    my $cmd = shift;
    my $out = shift;

    my $text = join( '', @_ );
    if ($inAuth) {
        if ($out) {
            $text = '*' x ( 8 + int( rand(16) ) )
              unless ( $inAuth++ == 1 );
        }
        else {
            my ( $code, $d, $b64 ) = split( /([ -])/, $text, 2 );
            $code ||= 0;
            if ( $code eq '334' ) {
                $b64 = '' unless ( defined $b64 );
                chomp $b64;
                my $b64text = MIME::Base64::decode_base64($b64);
                my $cont    = "\n${pad}    ";
                my $multi;
                if ( $b64 =~ s/(.{76})/$1$cont/gms ) {
                    $multi = 1;
                }
                if ( $b64text =~ /[[:^print:]]/ ) {
                    my $n = 0;
                    $b64text =~
s/(.)/sprintf('%02x', ord $1) . (++$n % 32 == 0? $cont : ' ')/gmse;
                    $b64text =~ s/([[:xdigit:]]{2}) ([[:xdigit:]]{2})/$1$2/g;
                    if ( $n % 32 ) {
                        chop $b64text;
                        $b64text .= $cont;
                    }
                    unless ( $multi && $b64 =~ /$cont\z/ ) {
                        $b64 .= $cont;
                        $multi = 1;
                    }
                    chop $b64;
                    $b64 .= '[';
                    $b64text =~ s/$cont\z/]/;
                }
                else {
                    if ( $multi && $b64 !~ /$cont\z/ ) {
                        $b64 .= $cont;
                    }
                    if ($multi) {
                        chop $b64;
                    }
                    else {
                        $b64 .= ' ';
                    }
                    $b64text = "[$b64text]";
                }
                $text = join( '', $code, $d, $b64, $b64text );
            }
        }
    }
    return $text;
}

sub debug_print {
    my ( $cmd, $out, $text, $hok ) = @_;

    chomp $text;
    my $tag = $ISA[0] . ( $out ? '>>> ' : '<<< ' );
    $text = $tag
      . join( "\n$tag -- ",
        map $cmd->debug_text( $out, $_ ),
        split( /\r?\n/, $text, -1 ) )
      . "\n";

    $text =~ s/([&'"<>])/'&#'.ord( $1 ) .';'/ge unless ($hok);
    $tlog .= $text;
}

# Package for extended SSL functions

package Foswiki::Configure::Wizards::AutoConfigureEmail::SSL;

our @ISA;

# Intercept new() socket issued by Net::SMTP

sub new {
    my $class = shift;

    @sockopts = ( @_, @sslopts );

    my ( $log, %opts );
    $log = bless {}, $class;
    if ( $tlsSsl || $startTls ) {
        %opts = @sockopts;
        $log->logSSLoptions( \%opts );
    }

    my $sclass =
        $tlsSsl                 ? 'IO::Socket::SSL'
      : $Foswiki::IP::IPv6Avail ? 'IO::Socket::IP'
      :                           'IO::Socket::INET';
    $! = 0;
    $@ = '';
    my $sock = $sclass->new(@sockopts);
    if ($sock) {
        bless $sock, $class;
        $noconnect = 0;
        my $peer = $sock->peerhost . ':' . $sock->peerport;
        if ($tlsSsl) {
            $sock->debug_print( 0,
                    "Connected with $peer using "
                  . $opts{SSL_version} . ' and '
                  . $sock->get_cipher
                  . " encryption\nServer Certificate:\n"
                  . fmtcertnames( $sock->dump_peer_certificate ) );
        }
        else {
            $log->debug_print( 0,
                "Connected with $peer using no encryption\n" );
        }
    }
    else {
        my $peer = $opts{PeerHost}    || $opts{PeerAddr} || '';
        my $port = $opts{PeerService} || $opts{PeerPort} || '';
        $peer = "$peer on $port" if ($port);
        $log->debug_print(
            0,
            "Unable to establish connection with $peer: "
              . (
                     ( ($!) ? $@ || $! : 0 )
                  || ( $tlsSsl && IO::Socket::SSL::errstr() )
              )
              . "\n"
        ) if ($verified);
        $allconnect = 0;
    }
    return $sock;
}

# Log actual SSL options for connection

sub logSSLoptions {
    my $log = shift;
    my ($opts) = @_;

    if ( $opts->{SSL_verify_mode} == IO::Socket::SSL::SSL_VERIFY_NONE() ) {
        $log->debug_print( 1, "SSL peer verification: off\n" );
    }
    else {
        $log->debug_print( 1, "SSL peer verification: on\n" );
        $log->debug_print( 1, "Verify Server CA_File: $opts->{SSL_ca_file}\n" )
          if ( $opts->{SSL_ca_file} );
        $log->debug_print( 1, "Verify Server CA_Path: $opts->{SSL_ca_path}\n" )
          if ( $opts->{SSL_ca_path} );

        if ( $opts->{SSL_check_crl} ) {
            $log->debug_print( 1, "Verify server against CRL: on\n" );
            $log->debug_print( 1,
                "Verify Server CRL CRL_File: $opts->{SSL_crl_file}\n" )
              if ( $opts->{SSL_crl_file} );
        }
        else {
            $log->debug_print( 1, "Verify server against CRL: off\n" );
        }
    }

    if ( $opts->{SSL_use_cert} ) {
        $log->debug_print( 1, "Provide Client Certificate: on\n" );
        $log->debug_print( 1,
            "Client Certificate File: $opts->{SSL_cert_file}\n" )
          if ( $opts->{SSL_cert_file} );
        $log->debug_print( 1,
            "Client Certificate Key File: $opts->{SSL_key_file}\n" )
          if ( $opts->{SSL_key_file} );
        $log->debug_print( 1,
            "Client Certificate key Password: "
              . ( $opts->{SSL_passwd_cb} ? "*****\n" : "None\n" ) );
    }
    else {
        $log->debug_print( 1, "Provide Client Certificate: off\n" );
    }
    return;
}

# STARTTLS connection upgrade

sub starttls {
    my ( $smtp, $log, $reporter ) = @_;

    unless ( defined $smtp->supports('STARTTLS') ) {
        $smtp->quit;
        $reporter->NOTE( $tlog,
            "${pad}STARTTLS is not supported by $host</pre>" );
        return 0;
    }
    unless ( $smtp->command('STARTTLS')->response() == 2 ) {
        $smtp->quit;
        $reporter->NOTE( $tlog . "${pad}STARTTLS command failed</pre>" );
        return 0;
    }

    my $mailobj = ref $smtp;

    unless ( IO::Socket::SSL->start_SSL( $smtp, @sockopts, ) ) {
        $tlog .= $pad . IO::Socket::SSL::errstr() . "\n" if ($verified);
        $reporter->NOTE( $tlog . "${pad}Upgrade to TLS failed</pre>" );

        # Note: The server may still be trying to talk SSL; we can't quit.
        $smtp->close;
        return 0;
    }
    @ISA =
      ( grep( $_ !~ /^IO::Socket::I(?:NET|P)$/, @ISA ), 'IO::Socket::SSL' );
    bless $smtp, $mailobj;
    $smtp->debug_print( 0,
            "Started TLS using "
          . $smtp->get_cipher
          . " encryption\nServer Certificate:\n"
          . fmtcertnames( $smtp->dump_peer_certificate ) );

    $tlog .= $pad
      . (
          $verified < 0 ? "Server verification is disabled"
        : $verified     ? "Server certificate verified"
        : "Unable to verify server certificate"
      ) . "\n";
    if ( $verified == 0 ) {
        $reporter->NOTE( $tlog . '</pre>' );
        $smtp->close;
        return 0;
    }

    unless ( $smtp->hello($hello) ) {
        $reporter->NOTE( $tlog . "${pad}Hello failed</pre>" );
        $smtp->quit();
        return 0;
    }
    return 1;

}

# Handle host verification manually so we can report issues

my %verifyErrors = (
    2 =>
"The issuer of a looked-up certificate could not be found.  This is probably a root certificate that is not in {Email}{SSLCaFile} or {Email}{SSLCaPath}..\n",
    18 => "The server certificate is self-signed, but not trusted.\n"
      . "Verify that it is valid, then add it to {Email}{SSLCaFile} or {Email}{SSLCaPath}\n",
    19 =>
"A self-signed certificate is in the chain, but that certificate is not trusted.\n"
      . "Verify that it is valid, then add it to {Email}{SSLCaFile} or {Email}{SSLCaPath}\n",
    20 =>
"The issuer's certificate could not be found.  The server may not be providing an intermediate CA certificate, or if the issuer is a root CA, the root certificate is not in {Email}{SSLCaFile} or {Email}{SSLCaPath}.\n",
    21 =>
"The server only provided one certificate, and it's issuer is not trusted\n"
      . "The server may need to supply intermediate CA certificates, use a trusted CA, or you may need to add the issuer certificate to {Email}{SSLCaFile} or {Email}{SSLCaPath}\n",
    22 =>
"The chain of certificates required to validate this server is more than 20 deep.  The certificate chain is too expensive to verify.",
    24 =>
"An intermediate or root certificate must be a CA certificate, and must be authorized to issue server certificates.\n"
      . "A certificate was encountered that failed one of these tests.\n",
    26 => "The server certificate is not authorized to identify a TLS Server\n",
    27 =>
      "The root CA is not marked trusted for issuing TLS server certificates\n",
    28 => "The root CA does not allow TLS server certificates\n",
);

sub sslVerifyCert {
    my ( $log, $ok, $ctx, $peerCert ) = @_;

    # A server must have a certificate, so this shouldn't happen.

    unless ( $ctx && $peerCert ) {
        $log->debug_print( 0, "Verify:   No certificate was supplied" );
        return 0;
    }

    # Get certificate at current level of chain
    # Note: The chain is built from the server up to the root,
    #       then verified from the root down to the server.
    #       Depth increases from 0 (the server) to n (the root)

    my $cert  = Net::SSLeay::X509_STORE_CTX_get_current_cert($ctx);
    my $error = Net::SSLeay::X509_STORE_CTX_get_error($ctx);
    my $depth = Net::SSLeay::X509_STORE_CTX_get_error_depth($ctx);

    my $issuerName =
      Net::SSLeay::X509_NAME_oneline(
        Net::SSLeay::X509_get_issuer_name($cert) );
    my $subjectName =
      Net::SSLeay::X509_NAME_oneline(
        Net::SSLeay::X509_get_subject_name($cert) );

    if ( $depth > 20 ) {
        $error = 22;    #X509_V_ERR_CERT_CHAIN_TOO_LONG
        Net::SSLeay::X509_STORE_CTX_set_error( $ctx, $error );
        $ok = 0;
    }
    if ($ok) {
        $verified = 1 if ( $verified < 0 );
        $log->debug_print( 0,
            "Verified: " . fmtcertnames( "$subjectName\n", 'Verified: ', -4 ) );

        if ( $depth == 0 ) {
            my $host = {@sockopts}->{SSL_verifycn_name};

            my $rv = IO::Socket::SSL::verify_hostname_of_cert(
                $host,
                $peerCert,
                {
                    check_cn         => 'when_only',
                    wildcards_in_alt => 'leftmost',
                    wildcards_in_cn  => 'leftmost',
                }
            );
            if ($rv) {
                $log->debug_print( 0,
                    "Verified: $host is a subject of this certificate\n" );
            }
            else {
                $verified = $ok = 0;
                my $msg =
"Verify:   $host is not a commonName or subjectAltName of this certificate\n";
                my $indent = ' ' x ( length('Verify:   ') - length(' -- ') );
                my @alt = Net::SSLeay::X509_get_subjectAltNames($peerCert);
                if (@alt) {
                    $msg .= "${indent}Certificate subjectAltName"
                      . ( @alt != 1 ? 's' : '' ) . ":\n";
                    while (@alt) {
                        my ( $type, $name ) = splice( @alt, 0, 2 );
                        if ( $type == IO::Socket::SSL::GEN_IPADD() ) {
                            if ( length($name) == 16 ) {
                                eval {
                                    require Socket;
                                    $name =
                                      Socket::inet_ntop( Socket::AF_INET6(),
                                        $name );
                                    return $name;
                                };
                                $name = 'IPv6 address' unless ( defined $name );
                            }
                            elsif ( length($name) == 4 ) {
                                require Socket;
                                $name = Socket::inet_ntoa($name);
                            }
                            else {
                                $name = "Unknown IP address";
                            }
                            $msg .= "${indent}    IP: $name\n";
                        }
                        elsif ( $type == IO::Socket::SSL::GEN_DNS() ) {
                            $msg .= "${indent}    DNS: $name\n";
                        }
                    }
                }
                $log->debug_print( 0, $msg );
            }
        }
    }
    else {
        $verified = 0;
        my $msg =
            "Verify:   "
          . Net::SSLeay::X509_verify_cert_error_string($error) . "\n"
          . fmtcertnames(
            "Subject Name: $subjectName\nIssuer  Name: $issuerName\n")
          . ( $verifyErrors{$error} || '' );
        $log->debug_print( 0, $msg, 0 );

        my $port = $port;
        $port = $1 if ( $port =~ m,\((\d+)\)$, );
        $msg =
"Verify:   The server certificate may be viewed with the openssl command\n<i>openssl s_client -connect $host:$port"
          . ( $startTls ? " -starttls smtp" : '' )
          . " -showcerts</i>\n"
          . "The <i>openssl verify</i> command may provide more information.\n";
        $log->debug_print( 0, $msg, 1 );
    }
    return $ok;
}

# Return enhanced status code if available

sub rspCode {
    my $smtp = shift;

    my $code = $smtp->code;
    if ( $code =~ /^[245]/ && defined $smtp->supports('ENHANCEDSTATUSCODES') ) {
        my $msg = $smtp->message;
        if ( $msg =~ /^([245]\.\d{1,3}\.\d{1,3})\b/ ) {
            return ( $code, $1 );
        }
    }
    return ( $code, '' );
}

# Test server to determine authentication requirements
# Ensures it will relay.

sub testServer {
    my $smtp = shift;
    my ( $host, $username, $password ) = @_;
    shift;

    # Attempt a DSN-style send to another domain.
    # If authentication is required to relay, the
    # server will indicate that here.  If not,
    # authentication is not required.
    # The session is reset so no mail is actually sent.

    my ( $fromTestAddr, $toTestAddr ) =
      (qw/postmaster@example.net postmaster@example.com/);
    my ( @code, $requires );

    my $noAuthOk = $smtp->mail($fromTestAddr) && $smtp->to($toTestAddr);
    unless ($noAuthOk) {
        @code = $smtp->rspCode;
        $smtp->reset;

        # 530 5.7.0 Auth req 540/550 5.7.1 no relay
        if ( !( $code[0] =~ /^5[345]0$/ || $code[1] =~ /^(?:5\.7\.[01])$/ ) ) {
            $tlog .=
"${pad}Message setup failed, but authentication was not requested.\n";
            return ( -1, '' );
        }
    }
    if ($noAuthOk) {
        $smtp->reset;
        my $m = "${pad}Authentication is not required";
        unless ( $username || $password ) {
            $m .= ".";
            @_[ 0, 1 ] = ( '', '' );
            return ( 4, "$m\n" );
        }
        $m .=
", but you have configured credentials.\n${pad}If you do not want to use these credentials, remove them from the configuration.\n${pad}Attempting to authenticate.\n";
        $tlog .= $m;
        $requires = 'supports';
    }
    else {
        $requires = 'requires';
    }

    # Get authentication methods server offers

    my $serverAuth;
    if (   !defined( $serverAuth = $smtp->supports('AUTH') )
        || !length $serverAuth )
    {
        if ($noAuthOk) {
            @_[ 0, 1 ] = ( '', '' );
            return ( 4,
"${pad}Server does not offer authentication.  Please remove the credentials.\n"
            );
        }
        if ( defined $hInfo->{port} ) {
            if ( $tlsSsl || $startTls ) {
                return ( 3,
"Authentication is required by $host, but not offered, although this is a secure connection.  Try removing the port specification in {SMTP}{MAILHOST} to allow testing other ports, or obtain the correct port number from the operators of $host\n"
                );
            }
            return ( 3,
"Authentication is required by $host, but not offered.  This is not a secure connection, which can cause this condition.  Secure connection methods have already been tested.  Try removing the port specification in {SMTP}{MAILHOST} to allow testing other ports, or obtain the correct port number from the operators of $host\n"
            );
        }

        $tlog .=
          "${pad}Authentication is required by $host, but not offered.\n";
        return ( -1, '' );
    }

    # Find intersection with methods we support

    my @serverAuth = split( /\s+/, $serverAuth );
    my $ok = 0;

    # Obtain and cache system's authentication methods.

    %systemAuthMethods = ( none => 1, map { uc($_) => 1 } $smtp->authValid() )
      unless ( keys %systemAuthMethods );

    foreach my $method (@serverAuth) {
        if ( $systemAuthMethods{ uc($method) } ) {
            $ok = 1;
            last;
        }
    }
    unless ($ok) {
        $tlog .=
"${pad}You can proceed without authentication by removing the credentials.\n"
          if ($noAuthOk);

        return ( 3,
"<strong>$host</strong> $requires authentication, but your system doesn't support any authentication methods.  Either Authen::SASL is not installed, or it is not in \@INC.\n"
        ) unless (@serverAuth);
        return ( 3,
"<strong>$host</strong> $requires authentication, but will not accept any authentication method that your system supports.<pre>$host will accept "
              . ( @serverAuth > 1 ? "these methods: " : "only:" )
              . join( ', ', sort @serverAuth )
              . "\nYour system supports: "
              . join( ', ', sort grep $_ ne 'none', keys %systemAuthMethods )
              . ".\nEither the server needs to be reconfigured to accept one of these methods, or you need to install a SASL::Authen module for a mechanism that the server will accept.\n"
        );
    }

    # See if we have credentials to use

    unless ( length $username && length $password ) {
        return (
            0,
            'Unable to test authentication: '
              . (
                  length $username ? "Password is"
                : length $password ? "Username is"
                : "Username and password are"
              )
              . " required.\n"
        );
    }

    # Provide the credentials and see if they are accepted.

    local $inAuth = 1;
    unless ( $smtp->auth( $username, $password ) ) {
        @code = $smtp->rspCode;

        # 535 5.7.8 Authentication credentials invalid

        if ( ( $code[0] =~ /^535$/ || $code[1] =~ /^(?:5\.7\.8)$/ ) ) {
            return (
                2,
                "$host rejected the supplied username and password.
Please verify that configured username and password are valid for $host.\n"
            );
        }

        # 454 4.7.0 Temporary authentication failure
        if ( ( $code[0] =~ /^454$/ || $code[1] =~ /^(?:4\.7\.0)$/ ) ) {
            return ( 3,
"$host is unable to validate your credentials at this time.  Please try again later.\n"
            );
        }

        return ( 0, "Authentication failed\n" );
    }
    $inAuth = 0;

    # Retry the null DSN

    $ok = $smtp->mail($fromTestAddr) && $smtp->to($toTestAddr);
    $smtp->reset;
    if ($ok) {
        return ( 1,
            "${pad}$host is willing to accept mail with these credentials.\n" );
    }

    # Demanded authentication, but won't accept mail.

    return (
        3,
"$host accepted username and password, but will not accept mail with these credentials.<br />
It probably needs to be configured to accept mail from your system, or your system may need a different (probably static) IP address, or it may be on a block list.  The preceding log should provide more detail."
    );
}

# Return list of mechanisms that this system supports.
# These are implemented by Authen::SASL plugins, which
# live in @INC/Authen/SASL and its perl directory.
# There may be duplicates, but that's handled by the
# caller.

sub authValid {
    my $smtp = shift;

    my @auths;
    foreach my $path (@INC) {
        my $authdir = "$path/Authen/SASL";
        next unless ( -d "$path/Authen/SASL" );
        push @auths, $smtp->authScan($authdir);
        push @auths, $smtp->authScan("$authdir/Perl");
    }
    return @auths;
}

# Find Auth::SASL mechanism (method) modules
# The are filenames in all upper case, plus
# digits and underscore.

sub authScan {
    my $smtp = shift;
    my ($path) = @_;

    my @found;
    opendir( my $dh, $path ) or return @found;
    while ( defined( my $file = readdir($dh) ) ) {
        next if ( $file =~ /^\./ );
        next unless ( $file =~ /^([A-Z0-9_]+)\.pm$/ );
        push @found, $1;
    }
    closedir $dh;
    return @found;
}

# Format certificate names for display

sub fmtcertnames {
    my ( $names, $label, $offset ) = @_;

    my $out = '';
    my $wrap =
      ( ' ' x ( length( $label || 'Subject Name: ' ) + ( $offset || 0 ) ) );

    foreach my $name ( split( /\n/, $names ) ) {
        my @parts = split( m~/~, $name );
        my $line = '';
        while (@parts) {
            my $part = shift @parts;
            next unless ( defined $part );
            while ( length( $line . $part ) < 80 ) {
                $line .= "$part/";
                $part = shift @parts;
                last unless ( defined $part );
            }
            if ( defined $part ) {
                if ( length($line) ) {
                    $line =~ s~/$~~;
                    $out .= "$line\n";
                    $line = "$wrap/$part/";
                }
                else {
                    $out .= "$part\n";
                    if (@parts) {
                        $line = "$wrap/";
                    }
                    else {
                        $line = '';
                        last;
                    }
                }
            }
        }
        chomp $line;
        $out .= "$line\n" if ( length($line) );
        $out =~ s~/\Z~~;
    }

    return $out;
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2014 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
