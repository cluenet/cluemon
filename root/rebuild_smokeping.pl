#!/usr/bin/env perl
# We want to know if stuff is going to explode in our face
use warnings;
use strict;

# Awesome logging
use Log::Log4perl;

# For strftime
use POSIX qw(strftime);

# For flock
use Fcntl qw(:flock);

# We like LDAP
use Net::LDAP;

# For checking if stuff has changed
use Digest::MD5;

# Good for debugging
use Data::Dumper;

=head1 NAME
rebuild_smokeping.pl - A script to rebuild the smokeping config for ClueNet

=head1 OVERVIEW
This script grabs the list of active servers and adds them into SmokePing for monitoring

The script should be run by cron every hour (or w/e you want).
It uses flock to ensure the script doesn"t make a mess by running at the same time.

=head1 SOURCE
Git repo: https://github.com/cluenet/cluemon
Issues: https://github.com/cluenet/cluemon/issues

=head1 AUTHOR
Damian Zaremba <damian@damianzaremba.co.uk>.

=head1 CHANGE LOG
* v0.1 - 22 Aug 2011
	- Initial version

=head1 LICENSE
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

=head1 CONFIG

Hash of our config values

=head2 Required options

config_file - The file to write the servers into
tmp_dir - The dir we stick temporary stuff in 

=cut

# Config stuff
my $config = {
	config_file => "/etc/smokeping/config.d/cluenet",
	tmp_dir => "/var/run",
};
my $VERSION = "0.1";

# Stuff we need everywhere
our($logger, $ldap);

=head1 METHODS

=head2 hexdigest_file
Gets the MD5 digest of a files contents

=head3 Arguments
file_path - Path to file

=head3 Returns
String containing the MD5 digest

=cut

sub hexdigest_file {
	open(my $fh, shift);
	binmode($fh);
	my $checksum = Digest::MD5->new->addfile(*$fh)->hexdigest;
	close($fh);
	return $checksum;
}

=head2 run
Sets up everything and kicks off the process.

=head3 Arguments
Takes no arguments.

=head3 Returns
Returns nothing.

=cut

sub run {
	# Setup the logger object
	Log::Log4perl->easy_init();
	$logger = Log::Log4perl->get_logger();

	# Error if we couldn"t initialize the logger oject
	if( ! defined( $logger ) ) {
		print "!!! Could not init logger !!!\n";
		exit(1);
	}

	# Try and get a lock
	my $lock_fh;
	if( !open($lock_fh, ">", $config->{"tmp_dir"} . "/smokeping_rebuild.flock") ) {
		$logger->fatal("Cannot open file handler on " . $config->{"tmp_dir"} . "/smokeping_rebuild.flock");
		exit(4);
	}

	if( !flock($lock_fh, LOCK_EX) ) {
		$logger->fatal("Process appears to be running already");
		exit(4);
	}

	# Error if there was no config_file specified in the config
	if( ! defined( $config->{"config_file"} ) ) {
		$logger->fatal("No config_file was specified");
		exit(3);
	}

	# Try and connect to ldap
	$ldap = Net::LDAP->new("ldap.cluenet.org", timeout => 10);

	# Error if the ldap connection failed
	if( ! defined( $ldap ) ) {
		$logger->fatal("Could not connect to ldap: $@");
		exit(2);
	}

	# Get the servers info
	$logger->info("Starting get_servers");
	my $servers = get_servers();

	# Get the current file hash
	my $oldhash = hexdigest_file( $config->{"config_file"} );

	# Write the config
	$logger->info("Starting write_config");
	write_config($servers);

	# Check the new hash against the old hash
	my $newhash = hexdigest_file( $config->{"config_file"} );

	# Check if we need to rebuild
	if( $newhash ne $oldhash ) {
		# Rebuild
		$logger->info("Starting reload_smokeping");
		reload_smokeping();

		if( !flock($lock_fh, LOCK_UN) ) {
			$logger->error("Could not unlock smokeping_rebuild.flock file");
			notify_irc("Could not unlock smokeping_rebuild.flock file: $!");
		}
		close($lock_fh);
	} else {
		$logger->info("No reload required");
	}
}

=head2 get_servers
Pulls a list of active servers and builds a hash of their configs

=head3 Arguments
Takes no arguments.

=head3 Returns
Returns a hash of the servers we should monitor.

=cut

sub get_servers {
	# Array we will fill
	my $servers = ();

	# Get all active servers from LDAP
	my $response = $ldap->search(
		filter => "(&(objectClass=server)(isActive=TRUE))",
		base => "ou=servers,dc=cluenet,dc=org",

		# We only need these attrs
		attrs => [
			"cn",
			"ipAddress",
			"ipv6Address",
			"ipHostNumber",
		],
	);

	# Loop though the list of LDAP entries
	for my $server ( $response->entries ) {

		# Check the entry has a CN (sanity check)
		my $cn = lc($server->get_value("cn"));
		if( !$cn ) {
			# Error and skip if no cn
			$logger->info("Skipping '" . $server->{"asn"}->{"objectName"} . "', no CN found");
			next;
		}

		# Check the entry has an ipAddress specified
		my $ip_address = $server->get_value("ipAddress");
		if( !$ip_address ) {

			# If no ipAddress try and get the ipHostNumber
			$ip_address = $server->get_value("ipHostNumber");
			if( !$ip_address || $ip_address eq "0.0.0.0" ) {

				# If no ipAddress or ipHostNumber then try and get the ipv6Address
				$ip_address = $server->get_value("ipv6Address");
				if( !$ip_address ) {
					# No ip address found, skip
					$logger->info("Skipping '" . $server->{"asn"}->{"objectName"} . "', no IP address found");
					next;
				}
			}
		}

		# Get the server name from the CN
		my $name = lc( $cn );
		$name =~ s/\.cluenet\.org$//;

		my $server_config = {};
		$server_config->{"hostname"} = $cn;
		$server_config->{"name"} = $name;
		$server_config->{"ip"} = $ip_address;

		# Add this server into the servers array
		push(@$servers, $server_config);
	}

	# Return the servers hash
	return $servers;
}

=head2 write_config
Writes the smokeping config.

=head3 Arguments
servers - hash of the processed server config

=head3 Returns
Returns nothing.

=cut

sub write_config {
	my $servers = shift;
	my $fh;

	# Open the file handle
	if( !open($fh, ">", $config->{"config_file"}) ) {
		$logger->fatal("Cannot open " . $config->{"config_dir"} . " for writing");
		return;
	}

	print $fh "+ Servers\n";
	print $fh "menu = ClueNet Server Latency\n";
	print $fh "title = ClueNet :: Server Latency\n\n";

	for my $server ( @{$servers} ) {
		$logger->info("Adding '" . $server->{'name'} . "' to the config file");
		print $fh "++ " . $server->{'name'} . "\n";
		print $fh "menu = " . $server->{'name'} . "\n";
		print $fh "title = " . $server->{'hostname'} . "\n";
		print $fh "host = " . $server->{'ip'} . "\n\n";
	}

	close($fh);
}

=head2 reload_smokeping
Reloads the smokeping deamon.

=head3 Arguments
Takes no arguments.

=head3 Returns
Returns nothing.

=cut

sub reload_smokeping {
	my $status = qx(/usr/sbin/smokeping --check);

	if( "$?" eq 0 ) {
		$logger->info("smokeping config looks valid");

		# Try and do a reload
		$status = qx(/etc/init.d/smokeping reload 2>&1);
		if( "$?" eq 0 ) {
			$logger->info("smokeping reloaded");
		}

		# Check we are running
		$status = qx(/etc/init.d/smokeping status 2>&1);
		if( "$?" ne 0 ) {
			$logger->info("smokeping not running");

			# Try and start smokeping
			$status = qx(/etc/init.d/smokeping start 2>&1);
			if( "$?" eq 0 ) {
				$logger->info("smokeping started");
			} else {
				$logger->fatal("Could not start smokeping:\n" . $status);
			}
		}
	} else {
		$logger->fatal("smokeping config looks broke:\n" . $status);
	}
}

# Run the main sub
run();
