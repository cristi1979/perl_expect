#!/usr/bin/perl

# yum install -y perl-Expect perl-Net-OpenSSH perl-Log-Log4perl

use warnings;
use strict;
$| = 1;
$SIG{__WARN__} = sub { die @_ };

use Cwd 'abs_path';
use File::Basename;
use lib ( fileparse( abs_path($0), qr/\.[^.]*/ ) )[1] . "lib";

use Net::OpenSSH;
use Expect;
use Data::Dumper;
use File::Find qw(finddepth);
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init(
	{
		level  => $DEBUG,
		utf8   => 1,
		layout => '[%p %d] %m{chomp}%n'
	}
);

my $timeout   = 30;
my $root_path = "/root/root/";
my $prompt    = '\[root\@.* ~\]\s*#\s*$';
my @files;
finddepth(
	sub {
		return if ( $_ eq '.' || $_ eq '..' || -d $_ );
		push @files, $File::Find::name;
	},
	$root_path
) if -d $root_path;

sub read_file {
	my $file_name = shift;
	my $text;
	{
		local $/ = undef;
		open FILE, "<", $file_name or die $!;
		$text = <FILE>;
		close(FILE);
	}
	return $text;
}

sub print_expect {
	my $expect = shift;
	return Dumper( $expect->before(), $expect->match(), $expect->after() );
}

sub write_file_remote {
	my ( $expect, $text, $name ) = @_;
	$expect->send("rm -f /tmp/.$name.swp /tmp/$name; vi /tmp/$name\n");
	$expect->expect(5);
	$expect->send("i\n");
	$expect->expect( 5, [qr/-- INSERT --/] )
	  or LOGDIE "___Timeout2!" . print_expect($expect);
	print "we are in insert mode now\n";
	$expect->send($text);
	## send escape , wait and send save
	$expect->send("\033");
	$expect->expect(5);
	$expect->send(":wq\n");
	$expect->expect( 5,
		[ qr/$prompt/ => sub { print "Have prompt. done writing\n"; } ],
	) or LOGDIE "___Timeout3!" . print_expect($expect);
	print "\t*** Done writing file $name\n";
}

sub make_sudo {
	my ( $expect, $user, $pass ) = @_;
	my $return = 0;

	$expect->expect(
		$timeout,
		[
			qr/runasroot:/ => sub {
				INFO "Logging in.\n";
				shift->send("$pass\n");
				exp_continue;
			  }
		],
		[ qr/Sorry/ => sub { LOGDIE "Login failed" . print_expect($expect) } ],
		[
			qr/$prompt/ => sub {
				INFO "Have prompt\n";
				if ( !$return ) {
					$return = 1;
					shift->send("echo logged in\n");
					exp_continue;
				}
			  }
		],
	) or LOGDIE "___Timeout!";
	LOGDIE "Can't sudo.\n" if !$return;
}

sub expect_commands {
	my ( $expect, $cmd ) = @_;
	my $res;

	# $Expect::Exp_Internal = 1;
	# $expect->exp_internal(1);
	# $expect->debug(3);

	$expect->send("$cmd\n");
	$expect->expect(
		$timeout,
		[
			qr/$prompt/ =>
			  sub { INFO "\t done cmd $cmd\n"; $expect->send("echo \$?\n"); }
		],
	) or LOGDIE "___Timeout for cmd $cmd!";
	my $output = print_expect($expect);
	$expect->expect(
		$timeout,
		[
			qr/$prompt/ => sub {
				$res = $expect->before();
				$res =~ s/\r//gs;
				use charnames ':full';
				$res =~ s/^echo \$\?\n([0-9])+\n(\N{ESCAPE}.*)?$/$1/sm;
				$res += 0;
			  }
		],
	) or LOGDIE "___Timeout for cmd $cmd!";
	ERROR "Cmd $cmd failed with exit status $res.\n$output\n"
	  if !defined $res || $res;
	INFO $output;
	$expect->clear_accum();
	return $res;
}

sub ssh_commands {
	my ( $ssh, $cmd ) = @_;
	my $output = $ssh->capture($cmd);
	my $res    = $? >> 8;
	$ssh->error || $res
	  and ERROR "remote command failed with status $res: $cmd.\n"
	  . $ssh->error . "\n"
	  . Dumper( $cmd, $output );
	INFO "\t done cmd $cmd\n";
	INFO Dumper( $cmd, $output );
	return $res;
}

sub connect_as_root {
	my $host = shift;
	INFO "*************** NEW HOST $host";
	my ( $ssh, $user, $pass, $key );
	my $all_user_pass = [ [ "user1", "pass1" ], [ "user2", "pass2" ] ];
	my $all_user_key = [ [ "user1", "/root/.ssh/sdt_user.pem" ] ];

	foreach my $user_pass (@$all_user_pass) {
		( $user, $pass ) = ( $user_pass->[0], $user_pass->[1] );
		INFO "Trying user $user.\n";
		$ssh = Net::OpenSSH->new(
			$host,
			master_opts => [
				-o => "UserKnownHostsFile=/dev/null",
				-o => "StrictHostKeyChecking=no"
			],
			user    => $user,
			passwd  => $pass,
			timeout => $timeout
		);
		last if !$ssh->error;
	}

	if ( !defined $ssh or $ssh->error ) {
		foreach my $user_key (@$all_user_key) {
			( $user, $key ) = ( $user_key->[0], $user_key->[1] );
			INFO "Trying user $user.\n";
			$ssh = Net::OpenSSH->new(
				$host,
				master_opts => [
					-o => "UserKnownHostsFile=/dev/null",
					-o => "StrictHostKeyChecking=no"
				],
				user    => $user,
				key_path=> $key,
				timeout => $timeout
			);
			last if !$ssh->error;
		}
	}

	LOGDIE "Can't connect to $host.\n" if !defined $ssh or $ssh->error;
	INFO "Connected to $host.\n";
	my ( $run_cmd_function, $worker ) = ( \&ssh_commands, $ssh );
	if ( $user ne "root" ) {
		my ( $pty, $pid ) = $ssh->open2pty(
			{ stderr_to_stdout => 1 }, 'sudo',
			-p => 'runasroot:',
			'su', '-'
		) or return "failed to attempt su: $!\n";
		my $expect = Expect->init($pty);
		make_sudo( $expect, $user, $pass );
		( $run_cmd_function, $worker ) = ( \&expect_commands, $expect );
	}
	return ( $ssh, $run_cmd_function, $worker );
}

sub fork_function {
	my ( $nr_threads, $work_pool, $function, @function_args ) = @_;
	use POSIX ":sys_wait_h";
	INFO "Start forking.\n";
	my $running;
	my $total_nr = scalar @$work_pool;
	my $crt_nr   = 0;
	my @thread   = ( 1 .. $nr_threads );
	while (1) {
		my $crt_thread = shift @thread if scalar @$work_pool;
		if ( defined $crt_thread ) {

			# 	    my $value = sort keys %$work_pool;
			my $value = shift @$work_pool;
			$crt_nr++;
			INFO "** new thread $crt_nr of $total_nr for $value\n";
			my $pid = fork();
			if ( !defined($pid) ) {
				LOGDIE "Can't fork.\n";
			}
			elsif ( $pid == 0 ) {
				open STDOUT, '>', "foo.$value.out";
				open STDERR, '>', "foo.$value.out";
				INFO "Start fork function $value.\n";
				my $ret = $function->( $value, @function_args );
				exit $ret;
			}
			$running->{$pid}->{'thread'} = $crt_thread;
			$running->{$pid}->{'val'}    = $value;

			# 	    delete $work_pool->{$value};
		}
		## clean done children
		my $pid = waitpid( -1, WNOHANG );
		my $exit_status = $? >> 8;
		if ( $pid > 0 ) {
			INFO "++ thread for "
			  . $running->{$pid}->{'val'}
			  . " (pid $pid) died, with status=$exit_status: reapead.\n";
			push @thread, $running->{$pid}->{'thread'};
			delete $running->{$pid};
		}
		## don't sleep if not all threads are running and we still have work to do
		sleep 1 if !( scalar @thread && scalar @$work_pool );
		## if no threads are working and there is no more work to be done
		last if scalar @thread == $nr_threads && scalar @$work_pool == 0;
	}
}

my @hosts = (
	qw/
host1
host2
	  /
);


sub run_puppet {
        my ( $ssh, $run_cmd_function, $worker ) = @_;
        my $ret;
        &$run_cmd_function( $worker, "puppet agent -t" );
}


sub run_remote_commands {
	my $host = shift;
	my ( $ssh, $run_cmd_function, $worker ) = connect_as_root($host);
        run_puppet( $ssh, $run_cmd_function, $worker );
	INFO "******** AAAAAALLLLLL OK ***************\n";
	return 0;
}

fork_function( 1, \@hosts, \&run_remote_commands );

exit 1;
