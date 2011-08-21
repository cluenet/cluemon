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

# Socket we need for irc notifications
use IO::Socket;

# We like valid emails
use Email::Valid;

# LWP is an awesome HTTP client
use LWP::UserAgent;
use HTTP::Request;

# YAML is pretty
use YAML;

# Mediawiki breaks YAML in YAML so we use XML :(
use XML::Simple;

# Good for debugging
use Data::Dumper;

=head1 NAME
rebuild_nagios.pl - A script to rebuild the nagios configs for ClueNet

=head1 OVERVIEW
This script does the following (in order):
1) Gets a list of active servers from ldap
2) Gets the server config from ldap if it exists
3) Merges the LDAP and WIKI info
4) Writes out the host config
5) Writes out the services config
6) Writes out the contacts config
7) Performs a config validation check
8) Asks nagios to reload
9) Restarts nagios if the reload failed

The script should be run by cron every hour (or w/e you want).
It uses flock to ensure the script doesn"t make a mess by running at the same time.

=head1 SOURCE
Git repo: https://github.com/cluenet/cluemon
Issues: https://github.com/cluenet/cluemon/issues

=head1 AUTHOR
Damian Zaremba <damian@damianzaremba.co.uk>.

=head1 CHANGE LOG
* v0.1 - 15 Aug 2011
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

config_dir - The directory to write the NAGIOS configs into
cgf_config - Path to the NAGIOS cgi.cfg file
wiki_url - Base URL of the wiki (with an ending slash)
relay_port - Port to relay IRC stuff too
admins - Array of ClueNet/Monitoring admins

=cut

# Config stuff
my $config = {
	config_dir => "/usr/local/nagios/etc/cluenet/",
	cgi_config => "/usr/local/nagios/etc/cgi.cfg",
	wiki_url => "http://cluenet.org/cluewiki/api.php",
	relay_port => 3843,
	admins => [
		"damian",
		"rsmithy",
		"cobi",
		"crispy",
	],
};
my $VERSION = "0.1";

# Stuff we need everywhere
our($logger, $ldap);

=head1 METHODS

=head2 pretty_time
Returns a pretty timestamp

=head3 Arguments
Takes no arguments.

=head3 Returns
Returns a string of the timestamp.

=cut

sub pretty_time {
	return POSIX::strftime("%d/%m/%Y %H:%M:%S\n", localtime);
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
	if( !open($lock_fh, ">", $config->{"config_dir"} . "/rebuild.flock") ) {
		$logger->fatal("Cannot open file handler on " . $config->{"config_dir"} . "/rebuild.flock");
		exit(4);
	}

	if( !flock($lock_fh, LOCK_EX) ) {
		$logger->fatal("Process appears to be running already");
		exit(4);
	}

	# Error if there was no config_dir specified in the config
	if( ! defined( $config->{"config_dir"} ) ) {
		$logger->fatal("No config_dir was specified");
		exit(3);
	}

	# Error if there was no cgi_config specified in the config
	if( ! defined( $config->{"cgi_config"} ) ) {
		$logger->fatal("No cgi_config was specified");
		exit(3);
	}

	# Error if there was no wiki_url specified in the config
	if( ! defined( $config->{"wiki_url"} ) ) {
		$logger->fatal("No wiki_url was specified");
		exit(3);
	}

	# Error if there was no relay_port specified in the config
	if( ! defined( $config->{"relay_port"} ) ) {
		$logger->fatal("No relay_port was specified");
		exit(3);
	}

	# Error if there was no admins specified in the config
	if( ! defined( $config->{"admins"} ) ) {
		$logger->fatal("No admins where specified");
		exit(3);
	}

	# Try and connect to ldap
	$ldap = Net::LDAP->new("ldap.cluenet.org", timeout => 10);

	# Error if the ldap connection failed
	if( ! defined( $ldap ) ) {
		$logger->fatal("Could not connect to ldap: $@");
		exit(2);
	}

	# Update the admins
	update_admins();

	# Get the servers info
	my $servers = get_servers();

	# Get the users info
	my $users = get_users($servers);

	clear_configs();
	write_configs($servers, $users);
	reload_nagios();

	if( !flock($lock_fh, LOCK_UN) ) {
		$logger->error("Could not unlock rebuild.flock file");
		notify_irc("Could not unlock rebuild.flock file: $!");
	}
	close($lock_fh);
}

=head2 notify_irc
Relays a message to the nagiosbot socket.
This allows us to notify admins of issues in a nice clean way.

=head3 Arguments
message - The message to send to IRC (this will be trimmed if too long)

=head3 Returns
Returns nothing.

=cut

sub notify_irc {
	my $message = shift;

	# Check we have a message to send
	if( ! $message ) {
		$logger->error("No message supplied for IRC relay");
		return;
	}

	# Try and open up a socket to the relay port
	my $socket = IO::Socket::INET->new(
		PeerAddr => "127.0.0.1",
		PeerPort => $config->{"relay_port"},
		Proto => "udp",
	);

	# Error if we couldn"t open the socket
	if( ! defined( $socket ) ) {
		$logger->error("Could not open socket for IRC relay: $@");
		return;
	}

	# Stick on the rebuild tag - this is so the bot knows where it came from
	$message = "rebuild||~||" . $message;

	# Try and send the message, if not throw back an error
	if( ! $socket->send( $message ) ) {
		$logger->error("Could not send message to IRC relay: $!");
		return;
	} else {
		$logger->info("'" . $message . "' sent to IRC relay");
		return;
	}
}

=head2 get_users
Pull the user data from LDAP and builds their configs.

=head3 Arguments
servers - hash of server configs (so we can pull what users to build)

=head3 Returns
Returns a hash of the users we should make configs for.

=cut

sub get_users {
	my $servers = shift;
	my $users_config = {};

	for my $hostname ( keys(%$servers) ) {
		my $server = $servers->{$hostname};

		if( !defined( $users_config->{$server->{"owner"}} ) ) {
			$users_config->{$server->{"owner"} . "@CLUENET.ORG"} = {
				username => $server->{"owner"},
				dummy => 1,
			};

			$users_config->{$server->{"owner"} . "-" . $server->{"name"}} = {
				username => $server->{"owner"},
				server => $server->{"name"}
			};
		}

		if( $server->{"admins"} ) {
			for my $username ( @{ $server->{"admins"} } ) {
				if( !defined( $users_config->{$hostname} ) ) {
					$users_config->{$username . "@CLUENET.ORG"} = {
						username => $username,
						dummy => 1,
					};

					$users_config->{$username . "-" . $server->{"name"}} = {
						username => $username,
						server => $server->{"name"}
					};
				}
			}
		}
	}

	for my $username ( keys(%$users_config) ) {
		my $ldap_user_config = {};
		my $user = $users_config->{$username};

		my $mesg = $ldap->search(
			filter => "(&(!(|(objectClass=suspendedUser)(objectClass=deletedUser)))(objectClass=person)(uid=" . $user->{"username"} . "))",
			base => "ou=people,dc=cluenet,dc=org",

			# We only need these attrs
			attrs => [
				"mail",
				"gecos",
				"cn",
			],
		);

		for my $user ( $mesg->entries ) {
			$ldap_user_config->{"mail"} = $user->get_value("mail");
			$ldap_user_config->{"gecos"} = $user->get_value("gecos");
			$ldap_user_config->{"cn"} = $user->get_value("cn");

			$ldap_user_config->{"dummy"} = $users_config->{$username}->{"dummy"} if $users_config->{$username}->{"dummy"};
			$ldap_user_config->{"server"} = $users_config->{$username}->{"server"} if $users_config->{$username}->{"server"};
		}

		# Get the wiki_user_config hash from get_config
		my $wiki_user_config = &get_config("User:" . $user->{"username"} . "/cluemon.js");

		# Mash the configs together
		$users_config->{$username} = parse_user_config($wiki_user_config, $ldap_user_config);
	}

	return $users_config;
}

=head2 get_servers
Pulls a list of active servers from LDAP and builds their configs.

=head3 Arguments
Takes no arguments.

=head3 Returns
Returns a hash of the servers we should monitor.

=cut

sub get_servers {
	# Hash that we will fill
	my $servers = {};

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
			"operatingSystem",
			"owner",
			"authorizedAdministrator",
		],
	);

	# Loop though the list of LDAP entries
	for my $server ( $response->entries ) {

		# Check the entry has a CN (sanity check)
		my $cn = $server->get_value("cn");
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

		# Check the server has an owner (sanity check)
		my $owner = $server->get_value("owner");

		# We only want the username so get rid of the container info
		$owner =~ s/uid=(.*),ou=people,dc=cluenet,dc=org/$1/;
		if( !$owner ) {
			# Error and skip if no owner
			$logger->info("Skipping '" . $server->{"asn"}->{"objectName"} . "', no owner found");
			next;
		}

		# Array of admins we will fill
		my $admins = [];

		# Check if we have any authorizedAdministrator entries
		my @authorized_admins = $server->get_value("authorizedAdministrator");
		if( @authorized_admins ) {
			# Loop though the authorizedAdministrator entries
			for my $admin (@authorized_admins) {
				# We only want the username so get rid of the container info
				$admin =~ s/uid=(.*),ou=people,dc=cluenet,dc=org/$1/;

				# Stick the username into the admins array if its not there
				if( !grep(/$admin/, $admins) ) {
					push(@$admins, $admin);
				}
			}
		}

		# Check if there is a custom SSH port set
		my $ssh_port = $server->get_value("sshPort");
		if( !$ssh_port ) {
			# If no ssh port then use 22 (the default)
			$ssh_port = 22;
		}

		# Check what the OS is
		my $os = $server->get_value("operatingSystem");
		if( !$os ) {
			$os = "";
		}

		# Get the server name from the CN
		my $name = lc( $cn );
		$name =~ s/\.cluenet\.org$//;

		# ldap_server_config hash we send to parse_server_config
		my $ldap_server_config = {};
		$ldap_server_config->{"name"} = $name;
		$ldap_server_config->{"ip"} = $ip_address;
		$ldap_server_config->{"ssh_port"} = $ssh_port;
		$ldap_server_config->{"owner"} = $owner;
		$ldap_server_config->{"os"} = $os;
		$ldap_server_config->{"admins"} = $admins;

		# Get the wiki_server_config hash from get_config
		my $wiki_server_config = &get_config("Server:" . $name . "/cluemon");

		# Add this server into the servers hash and assign its value to the parse_server_config hash
		$servers->{$cn} = &parse_server_config($wiki_server_config, $ldap_server_config);
	}

	# Return the servers hash
	return $servers;
}

=head2 get_config
Fetches a servers config over HTTP from the wiki.

=head3 Arguments
server_name - The name of the server (eg Delta)

=head3 Returns
Returns a hash of the config.

=cut

sub get_config {
	# Server name to get the config for
	my $page = shift;

	# Wiki config hash to fill
	my $wiki_config = {};

	# user_agent to make the request with
	my $user_agent = LWP::UserAgent->new(
		timeout => 5,
		agent => "NagiosRebuild/v" . $VERSION,
	);

	# URL to request
	my $url = $config->{"wiki_url"} . "?action=query&prop=revisions&rvprop=content&rvsection=1&format=xml&titles=" . ucfirst( $page );

	# Request object
	my $request_object = HTTP::Request->new(
		GET => $url,
	);

	# Make the request and store the response object
	my $response = $user_agent->request($request_object);

	# Check if we didn"t get a 200OK back
	if ( ! $response->is_success ) {
		$logger->error("Could not get " . $url . ", server returned: " . $response->status_line);

		# Send a notice though to IRC
		notify_irc("Could not get " . $url . ", server returned: " . $response->status_line);
	} else {
		# Everything was good, get the content
		my $raw_data = $response->decoded_content;

		# Data is where we will stick the config
		my $data;

		# Try and load the returned XML
		eval {
			my $xml = new XML::Simple;
			$data = $xml->XMLin($raw_data);
		};

		# If the XML was bad then error
		if( $@ ) {
			$logger->error("Could not process the api data for " . $page . ": " . $@);

			# Send a notice to IRC
			notify_irc("Could not process the api data for " . $page . ": " . $@);
		} else {
			# Check if there is a page revision (config)
			if(
				! defined( $data->{"query"}->{"pages"}->{"page"}->{"revisions"} ) ||
				! defined( $data->{"query"}->{"pages"}->{"page"}->{"revisions"}->{"rev"} ) ||
				! defined( $data->{"query"}->{"pages"}->{"page"}->{"revisions"}->{"rev"}->{"content"} )
			) {
				$logger->info("No config specified at " . $page);
			} else {
				$logger->info("Parsing config specified at " . $page);

				# Assign the actual page content to the raw_data var
				$raw_data = $data->{"query"}->{"pages"}->{"page"}->{"revisions"}->{"rev"}->{"content"};

				# Strip out the header
				$raw_data =~ s/==\s*config\s*==//i;

				# Strip out the pre tags
				$raw_data =~ s/<pre>//;
				$raw_data =~ s/<\/pre>//;

				# Add a newline at the end incase it is missing
				$raw_data .= "\n";

				# Data is where we will stick the config
				my $data;

				# Try and load the YAML
				eval {
					$data = YAML::Load( $raw_data );
				};

				# If the YAML was bad then error
				if( $@ ) {
					$logger->error("Could not process the config for " . $page . ": " . $@);

					# Send a notice to IRC
					notify_irc("Could not process the config for " . $page . ": " . $@);
				} else {
					# YAMl was good
					$wiki_config = $data;
				}
			}
		}
	}

	# Return the wiki_config hash
	return $wiki_config;
}

=head2 parse_user_config
Mashes the wiki and user configs into something we can use.

=head3 Arguments
wiki_user_config - Hash of the configuration from the wiki as returned by get_config
user_config - Hash of some configuration information from ldap as built in get_users

=head3 Returns
Returns a hash of the users config.

=cut

sub parse_user_config {
	my $wiki_user_config = shift;
	my $ldap_user_config = shift;
	my $user_config = {};

	$user_config->{"username"} = $ldap_user_config->{"cn"};
	$user_config->{"full_name"} = $ldap_user_config->{"gecos"};
	$user_config->{"email"} = $ldap_user_config->{"mail"} if $ldap_user_config->{"mail"};
	$user_config->{"alerts"} = {};

	# Check if this is a dummy - if it is we will have nothing to do with getting alerts
	if( !defined( $ldap_user_config->{"dummy"} ) ) {

		# Check if we have any alerts specified and we have a valid server
		if( ref( $wiki_user_config->{"alerts"} ) eq "HASH" && $ldap_user_config->{"server"} ) {
			#
			# Email alerts
			#

			# Check if we have a valid email - we NEED this
			if( $ldap_user_config->{"mail"} && Email::Valid->address( $ldap_user_config->{"mail"} ) ) {

				# Check if we have a setting in the all section
				if(
					$wiki_user_config->{"alerts"} &&
					$wiki_user_config->{"alerts"}->{"all"} &&
					$wiki_user_config->{"alerts"}->{"all"}->{"email"} &&
					$wiki_user_config->{"alerts"}->{"all"}->{"email"} eq "True"
				) {

					# We do have an all setting, now check we don"t have a specified setting set to false
					if (
						!$wiki_user_config->{"alerts"}->{ $ldap_user_config->{"server"} } ||
						!$wiki_user_config->{"alerts"}->{ $ldap_user_config->{"server"} }->{"email"} ||
						$wiki_user_config->{"alerts"}->{ $ldap_user_config->{"server"} }->{"email"} ne "True"
					) {
						$user_config->{"alerts"}->{"email"} = {
							target => $ldap_user_config->{"mail"}
						};
					}
				} else {
					# Check if we have a specific entry for this server as we didn"t have anything under all
					if (
						$wiki_user_config->{"alerts"}->{ $ldap_user_config->{"server"} } &&
						$wiki_user_config->{"alerts"}->{ $ldap_user_config->{"server"} }->{"email"} &&
						$wiki_user_config->{"alerts"}->{ $ldap_user_config->{"server"} }->{"email"} eq "True"
					) {
						$user_config->{"alerts"}->{"email"} = {
							target => $ldap_user_config->{"mail"}
						};
					}
				}
			}
		}
	}

	if( ref( $user_config->{"alerts"} ) ne "HASH" || keys( %{ $user_config->{"alerts"} } ) eq 0 ) {
		delete( $user_config->{"alerts"} );
	}

	return $user_config;
}

=head2 parse_server_config
Merges the wiki and server configs into something we can use.

=head3 Arguments
wiki_server_config - Hash of the configuration from the wiki as returned by get_config
ldap_server_config - Hash of some confiuration information from ldap as built in get_servers

=head3 Returns
Returns a hash of the servers config.

=cut

sub parse_server_config {
	# wiki_server_config from get_servers
	my $wiki_server_config = shift;

	# ldap_server_config from get_config
	my $ldap_server_config = shift;

	# Config hash we will fill
	my $server_config = {};

	$server_config->{"name"} = $ldap_server_config->{"name"};
	$server_config->{"address"} = $ldap_server_config->{"ip"};
	$server_config->{"admins"} = $ldap_server_config->{"admins"};
	$server_config->{"owner"} = $ldap_server_config->{"owner"};
	$server_config->{"services"} = {};

	# Lets use some default guesses
	$server_config->{"services"}->{"ping"} = {};

	if( grep(/windows/i, $ldap_server_config->{"os"}) ) {
		$server_config->{"services"}->{"rdp"} = {};
	} else {
		$server_config->{"services"}->{"ssh"} = {};
	}

	# Check if we have a wiki_server_config to process
	if( ref($wiki_server_config) eq "HASH" && keys( %$wiki_server_config ) > 0) {
		# We have stuff from the wiki... process it cleanly

		if( defined( $wiki_server_config->{"server"} ) ) {
			# We have server stuff to look at, yay

			# Check if there is a check_attempts specified and it is a number
			if( $wiki_server_config->{"server"}->{"check_attempts"} ) {
				$server_config->{"check_attempts"} = $wiki_server_config->{"server"}->{"check_attempts"};
			}

			# Check if there is a notification_interval specified and it is a number
			if( $wiki_server_config->{"server"}->{"notification_interval"} ) {
				$server_config->{"notification_interval"} = $wiki_server_config->{"server"}->{"notification_interval"};
			}
		}

		if( defined( $wiki_server_config->{"services"} ) ) {
			# We have services to look at, yay

			for my $service ( keys(%{ $wiki_server_config->{"services"} }) ) {
				# Wiki service data
				my $sdata = $wiki_server_config->{"services"}->{$service};

				# Strip out anything dodgy looking from the service
				$service =~ s/ /_/;
				$service = lc( $service );

				# Check if we have valid service/sdata
				if( $service && $sdata ) {
					$server_config->{"services"}->{$service} = $sdata;
				}

				# Check if this service is not enabled (used for removing default services)
				# We actually remove all disabled services to save code duplication
				# If there is no enabled specified then we assume it is disabled
				if(
					!$server_config->{"services"}->{$service} || !$sdata->{"enabled"} ||
					(
						$server_config->{"services"}->{$service} &&
						$sdata->{"enabled"} ne "True"
					)
				) {
					delete( $server_config->{"services"}->{$service} );
				}
			}
		}
	}

	# Set the SSH port to what is in ldap
	if( $server_config->{"services"}->{"ssh"} ) {
		$server_config->{"services"}->{"ssh"}->{"port"} = $ldap_server_config->{"ssh_port"};
	}

	# Return the final config hash
	return $server_config;
}

=head2 clear_configs
Clears any existing configs before we overwrite them

=head3 Arguments
Takes no arguments

=head3 Returns
Returns nothing

=cut

sub clear_configs {
	my $cdir = $config->{"config_dir"};
	unlink( glob( $cdir . "/*.cfg" ) );
}

=head2 update_admins
Updates the cgi.cfg file with the monitoring admins.
Basically:
1) Reads the cgi.cfg file
2) Turns $config->{"admins"} into a string of <admin>@CLUENET.ORG,<admin>@CLUENET.ORG
3) Replaces the value for:
* authorized_for_system_information
* authorized_for_configuration_information
* authorized_for_all_service_commands
with the new admin string
4) Writes out the new cgi.cfg file

=head3 Arguments
Takes no arguments

=head3 Returns
Returns nothing.

=cut

sub update_admins {
	my($fh, $data);

	# Try and open the file for reading
	if( !open($fh, "<", $config->{"cgi_config"}) ) {
		$logger->error("Cannot open " . $config->{"cgi_config"} . " for reading: $!");
		exit(3);
	}

	# Write the header
	$data .= "# Managed by rebuild_nagios.pl\n";
	$data .= "# Rebuilt at: " . pretty_time() . "\n\n";

	# Read the lines
	my($key, $value);
	while ( <$fh> ) {
		my $line = $_;

		# If this is not a key=value line then skip it
		if( index($line, "=") eq -1 ) {
			$data .= $line;
		} else {
			# Get key, value
			($key, $value) = split(/=/, $line, 2);

			# Check if we need to update the value
			if(
				$key eq "authorized_for_system_information" ||
				$key eq "authorized_for_configuration_information" ||
				$key eq "authorized_for_all_service_commands"
			) {
				# Set the value to the new admin list
				$value .= join("@CLUENET.ORG,", $config->{"admins"});
			}

			# Add the key=value back to the data
			$data .= $key . "=" . $value;
		}
	}

	# Close the read FH
	close($fh);

	# Try and open the FH for writing
	if( !open($fh, ">", $config->{"cgi_config"}) ) {
		$logger->error("Cannot open " . $config->{"cgi_config"} . " for writing: $!");
		exit(4);
	}

	# Write the data to the file
	print $fh $data;

	# Close the write FH
	close($fh);
}

=head2 write_configs
Writes the nagios configs.

=head3 Arguments
servers - hash of the processed server config
users - hash of the processed user config

=head3 Returns
Returns nothing.

=cut

sub write_configs {
	my $servers = shift;
	my $users = shift;
	my $fh;

	# Service dispatch table
	my $dispatch = {
		ping => \&build_service_ping_config,
		ssh => \&build_service_ssh_config,
		rdp => \&build_service_rdp_config,
	};

	# First we build the contacts file
	my $contacts = "# Managed by rebuild_nagios.pl\n";
	$contacts .= "# Rebuilt at: " . pretty_time() . "\n";

	$logger->info("Starting build_contacts_config");
	$contacts .= &build_contacts_config($users);

	# Write the contacts file
	if( !open($fh, ">", $config->{"config_dir"} . "/contacts.cfg") ) {
		$logger->fatal("Cannot open " . $config->{"config_dir"} . "/contacts.cfg for writing");
		notify_irc("Cannot open " . $config->{"config_dir"} . "/contacts.cfg for writing");
		return;
	}
	print $fh $contacts;
	close($fh);

	# Next we build the hostgroups file
	my $hostgroups = "# Managed by rebuild_nagios.pl\n";
	$hostgroups .= "# Rebuilt at: " . pretty_time() . "\n";

	$logger->info("Starting build_hostgroups_config");
	$hostgroups .= &build_hostgroups_config($servers);

	# Write the hostgroups file
	if( !open($fh, ">", $config->{"config_dir"} . "/hostgroups.cfg") ){
		$logger->fatal("Cannot open " . $config->{"config_dir"} . "/hostgroups.cfg for writing");
		notify_irc("Cannot open " . $config->{"config_dir"} . "/hostgroups.cfg for writing");
		return;
	}
	print $fh $hostgroups;
	close($fh);

	# Now we build each servers file
	for my $server ( keys( %$servers ) ) {
		my $host = "# Managed by rebuild_nagios.pl\n";
		$host .= "# Rebuilt at: " . pretty_time() . "\n";

		# Host definition
		$logger->info("Starting build_host_config for " . $server);
		$host .= &build_host_config($server, $servers->{$server}, $servers->{$server}->{"services"}->{"ping"});

		# Loop though the services adding them
		for my $service ( keys( %{ $servers->{$server}->{"services"} } ) ) {
			# subroutine for this service
			my $sub = "build_service_" . $service . "_config";

			# Service hash
			my $sdata = $servers->{$server}->{"services"}->{$service};

			# check if the service sub exists
			if( !$dispatch->{$service} ) {
				$logger->error("Could not add " . $service . " to " . $server . ": missing sub " . $sub);
				notify_irc("Could not add " . $service . " to " . $server . ": missing sub " . $sub);
			} else {
				# Add the service comment
				$host .= "\n\n# " . $service . "\n";

				# Call the service sub and adds it return data
				$logger->info("Starting build_service_config for " . $service . " (" . $server . ")");
				$host .= $dispatch->{$service}->($server, $sdata);
			}
		}

		if( !open($fh, ">", $config->{"config_dir"} . "/" . $server . ".cfg") ) {
			$logger->fatal("Cannot open " . $config->{"config_dir"} . "/" . $server . ".cfg for writing");
			notify_irc("Cannot open " . $config->{"config_dir"} . "/" . $server . ".cfg for writing");
			return;
		}
		print $fh $host;
		close($fh);
	}
}

=head2 build_hostgroups_config
Builds the hostgroup configuration definitions

=head3 Arguments
servers - Hash of servers

=head3 Returns
String containing the hostgroup definitions

=cut

sub build_hostgroups_config {
	my $servers = shift;
	my $hostgroups_config = "";

	my $groups = ();
	for my $server ( keys( %$servers ) ) {
		$server = $servers->{$server};

		if( !grep( /$server->{"owner"}/, @$groups ) ) {
			push(@$groups, $server->{"owner"});
		}
	}

	for my $owner ( @$groups ) {
		$hostgroups_config .= "\n\n# " . $owner . "\n";
		$hostgroups_config .= "define hostgroup {\n";
		$hostgroups_config .= "\thostgroup_name " . $owner . "_servers\n";
		$hostgroups_config .= "\talias " . $owner . "\"s servers\n";
		$hostgroups_config .= "}\n";
	}

	return $hostgroups_config;
}

=head2 build_contacts_config
Builds the contacts configuration definitions

=head3 Arguments
users - Hash of users

=head3 Returns
String containing the contact definitions

=cut

sub build_contacts_config {
	my $users = shift;
	my $contacts_config = "";

	# Magic contacts
	$contacts_config .= "# __nagiosbot_twitter__\n";
	$contacts_config .= "define contact {\n";
	$contacts_config .= "\tcontact_name __nagiosbot_twitter__\n";
	$contacts_config .= "\talias Twitter relay bot\n";
	$contacts_config .= "\thost_notification_period 24x7\n";
	$contacts_config .= "\tservice_notification_period 24x7\n";
	$contacts_config .= "\thost_notification_commands notify-host-by-twitter\n";
	$contacts_config .= "\tservice_notification_commands notify-service-by-twitter\n";
	$contacts_config .= "\tservice_notification_options w,u,c,r,f,s\n";
	$contacts_config .= "\thost_notification_options d,u,r,f,s\n";
	$contacts_config .= "}\n\n";

	$contacts_config .= "# __nagiosbot_irc__\n";
	$contacts_config .= "define contact {\n";
	$contacts_config .= "\tcontact_name __nagiosbot_irc__\n";
	$contacts_config .= "\talias IRC relay bot\n";
	$contacts_config .= "\thost_notification_period 24x7\n";
	$contacts_config .= "\tservice_notification_period 24x7\n";
	$contacts_config .= "\thost_notification_commands notify-host-by-irc\n";
	$contacts_config .= "\tservice_notification_commands notify-service-by-irc\n";
	$contacts_config .= "\tservice_notification_options w,u,c,r,f,s\n";
	$contacts_config .= "\thost_notification_options d,u,r,f,s\n";
	$contacts_config .= "}\n\n";

	# Actual contacts
	for my $user ( keys(%$users) ) {
		my $udata = $users->{$user};

		$contacts_config .= "# " . $user . "\n";
		$contacts_config .= "define contact {\n";
		$contacts_config .= "\tcontact_name " . $user . "\n";
		$contacts_config .= "\talias " . $udata->{"full_name"} . "\n";
		$contacts_config .= "\thost_notification_period 24x7\n";
		$contacts_config .= "\tservice_notification_period 24x7\n";

		if( $udata->{"email"} ) {
			$contacts_config .= "\t#email " . $udata->{"email"} . "\n";
		}

		if( !$udata->{"alerts"} ) {
			$contacts_config .= "\thost_notification_commands do-nothing-at-all\n";
			$contacts_config .= "\tservice_notification_commands do-nothing-at-all\n";
		} else {
			if( $udata->{"alerts"}->{"email"} && $udata->{"alerts"}->{"email"}->{"target"} ) {
				$contacts_config .= "\thost_notification_commands notify-host-by-email\n";
				$contacts_config .= "\tservice_notification_commands notify-service-by-email\n";
			}
		}

		$contacts_config .= "\tservice_notification_options w,u,c,r,f,s\n";
		$contacts_config .= "\thost_notification_options d,u,r,f,s\n";
		$contacts_config .= "}\n\n";
	}

	return $contacts_config;
}

=head2 build_host_config
Builds the host configuration definition

=head3 Arguments
server - Server name
sdata - Hash of server config
pdata - Hash of the ping service config (or undef)

=head3 Returns
String containing the host definition

=cut

sub build_host_config {
	my $server = shift;
	my $sdata = shift;
	my $pdata = shift;
	my $server_config = "";

	my $check_attempts = 5;
	if( $sdata->{"check_attempts"} && $sdata->{"check_attempts"} =~ /^\d+$/ ) {
		$check_attempts = $sdata->{"check_attempts"};
	}

	my $notification_interval = 0;
	if( $sdata->{"notification_interval"} && $sdata->{"notification_interval"} =~ /^\d+$/ ) {
		$notification_interval = $sdata->{"notification_interval"};
	}

	$server_config .= "define host{\n";
	$server_config .= "\thost_name " . $server . "\n";
	$server_config .= "\talias " . $sdata->{"name"} . "\n";
	$server_config .= "\taddress " . $sdata->{"address"} . "\n";
	$server_config .= "\thostgroups " . $sdata->{"owner"} . "_servers\n";

	$server_config .= "\tmax_check_attempts " . $check_attempts . "\n";
	$server_config .= "\tnotification_interval " . $notification_interval . "\n";
	$server_config .= "\tcheck_period 24x7\n";
	$server_config .= "\tnotification_period 24x7\n";

	if( $pdata ) {
		my $warning_rta = "2000.00";
		if( $pdata->{"warning_rta"} && $pdata->{"warning_rta"} =~ /^\d+$/ ) {
			$warning_rta = $pdata->{"warning_rta"};
		}

		my $warning_pl = "80";
		if( $pdata->{"warning_pl"} && $pdata->{"warning_pl"} =~ /^\d+$/ ) {
			$warning_pl = $pdata->{"warning_pl"};
		}

		my $critical_rta = "7000.00";
		if( $pdata->{"critical_rta"} && $pdata->{"critical_rta"} =~ /^\d+$/ ) {
			$critical_rta = $pdata->{"critical_rta"};
		}

		my $critical_pl = "100";
		if( $pdata->{"critical_pl"} && $pdata->{"critical_pl"} =~ /^\d+$/ ) {
			$critical_pl = $pdata->{"critical_pl"};
		}

		my $packets = "5";
		if( $pdata->{"packets"} && $pdata->{"packets"} =~ /^\d+$/ ) {
			$packets = $pdata->{"packets"};
		}

		$server_config .= "\tcheck_command check_host_alive!";
		$server_config .= $warning_rta . "!" . $warning_pl . "!";
		$server_config .= $critical_rta . "!" . $critical_pl . "!";
		$server_config .= $packets . "\n";
	}

	$server_config .= "\tcontacts ";

	# Owner dummy
	$server_config .= $sdata->{"owner"} . "@CLUENET.ORG, ";

	# Admin dummys
	for my $admin ( @{ $sdata->{"admins"} } ) {
		$server_config .= $admin . "@CLUENET.ORG, ";
	}
	$server_config .= "\n";

	$server_config .= "\tcontact_groups " . $sdata->{"name"} . "_admins\n";
	$server_config .= "}\n\n";

	$server_config .= "# Contact group\n";
	$server_config .= "define contactgroup {\n";
	$server_config .= "\tcontactgroup_name " . $sdata->{"name"} . "_admins\n";
	$server_config .= "\talias " . $sdata->{"name"} . "\"s admins\n";
	$server_config .= "\tmembers __nagiosbot_twitter__, __nagiosbot_irc__, ";

	# Owner contact
	$server_config .= $sdata->{"owner"} . "-" . $sdata->{"name"} . ", ";

	# Admin contacts
	for my $admin ( @{ $sdata->{"admins"} } ) {
		$server_config .= $admin . "-" . $sdata->{"name"} . ", ";
	}
	$server_config .= "\n}\n";

	return $server_config;
}

=head3 parse_service_check_options
Parses the global check options (saves code dublication)

=head3 Arguments
sdata - Service data hash

=head3 Returns
Hash of the parsed service data

=cut

sub parse_service_check_options {
	my $sdata = shift;
	my $sgdata = {};

	$sgdata->{"check_attempts"} = "3";
	if( $sdata->{"check_attempts"} && $sdata->{"check_attempts"} =~ /^\d+$/ ) {
		$sgdata->{"check_attempts"} = $sdata->{"check_attempts"};
	}

	$sgdata->{"check_interval"} = "5";
	if( $sdata->{"check_interval"} && $sdata->{"check_interval"} =~ /^\d+$/ ) {
		$sgdata->{"check_interval"} = $sdata->{"check_interval"};
	}

	$sgdata->{"retry_interval"} = "3";
	if( $sdata->{"retry_interval"} && $sdata->{"retry_interval"} =~ /^\d+$/ ) {
		$sgdata->{"retry_interval"} = $sdata->{"retry_interval"};
	}

	$sgdata->{"notification_interval"} = "0";
	if( $sdata->{"notification_interval"} && $sdata->{"notification_interval"} =~ /^\d+$/ ) {
		$sgdata->{"notification_interval"} = $sdata->{"notification_interval"};
	}

	return $sgdata;
}

=head2 build_service_definition
Builds the service defintion for services (massivly saves code dublication)

=head3 Arguments
hostname - Server this config is for
sdata - Hash of the specified service config
check_comamnd - Check name for this service
check_args - Array of args for this service

=head3 Returns
String containing the service definition

=cut

sub build_service_definition {
	my $hostname = shift;
	my $sdata = shift;
	my $check_command = shift;
	my @check_args= shift;

	my $sgdata = parse_service_check_options($sdata);
	my $service_config = "";

	# Service
	$service_config = "define service {\n";
	$service_config .= "\thost_name " . $hostname . "\n";
	$service_config .= "\tservice_description " . $sdata->{"description"} . "\n";
	$service_config .= "\tnotification_period 24x7\n";
	$service_config .= "\tcheck_period 24x7\n";
	$service_config .= "\tmax_check_attempts " . $sgdata->{"check_attempts"} . "\n";
	$service_config .= "\tcheck_interval " . $sgdata->{"check_interval"} . "\n";
	$service_config .= "\tretry_interval " . $sgdata->{"retry_interval"} . "\n";
	$service_config .= "\tnotification_interval " . $sgdata->{"notification_interval"} . "\n";
	$service_config .= "\tnotification_options w,u,c,r,f,s\n";
	$service_config .= "\tcheck_command " . $check_command . "!";
	$service_config .= join("!", @check_args) . "\n";
	$service_config .= "}\n\n";

	# Service extra info
	$service_config = "define serviceextinfo {\n";
	$service_config .= "\thost_name " . $hostname . "\n";
	$service_config .= "\tservice_description " . $sdata->{"description"} . "\n";
	$service_config .= "\tnotes_url /nagios/cgi-bin/show.cgi?host=$HOSTNAME$&service=$SERVICEDESC$";
	$service_config .= "onMouseOver='showGraphPopup(this)' onMouseOut='hideGraphPopup()'\n";
	$service_config .= "}\n";

	return $service_config;
}

=head2 reload_nagios
Reloads the Nagios config

=head3 Arguments
Takes no arguments.

=head3 Returns
Returns nothing.

=cut

sub reload_nagios {
	my $status = qx(/usr/local/nagios/bin/nagios --verify-config "/usr/local/nagios/etc/nagios.cfg" 2>&1);

	if( "$?" eq 0 ) {
		$logger->info("Nagios config looks valid");

		# Check if we are running
		$status = qx(/etc/init.d/nagios status 2>&1);
		if( "$?" eq 0 ) {
			# Try and do a reload
			$status = qx(/etc/init.d/nagios reload 2>&1);
			if( "$?" eq 0 ) {
				$logger->info("Nagios reloaded");
			} else {
				$logger->fatal("Could not reload nagios:\n" . $status);
				notify_irc("Could not reload nagios");
			}
		} else {
			# Try and do a restart
			$status = qx(/etc/init.d/nagios restart 2>&1);
			if( "$?" eq 0 ) {
				$logger->info("Nagios restarted");
			} else {
				$logger->fatal("Could not restart nagios:\n" . $status);
				notify_irc("Could not restart nagios");
			}
		}
	} else {
		$logger->fatal("Nagios config looks broke:\n" . $status);
		notify_irc("Nagios config looks broke");
	}
}

=head1 SERVICE METHODS
=head2 ssh
SSH header check definition

=head3 Arguments
server - Server this config is for
sdata - Hash of the specified service config

=head3 Returns
String containing the service definition

=cut

sub build_service_ssh_config {
	my $server = shift;
	my $sdata = shift;

	if( ! $sdata->{"description"} || $sdata->{"description"} !~ /^[a-zA-Z0-9_\- ]$/ ) {
		$sdata->{"description"} = "SSH check";
	}

	my $timeout = "5";
	if( $sdata->{"timeout"} && $sdata->{"timeout"} =~ /^\d+$/ ) {
		$timeout = $sdata->{"timeout"};
	}

	my $version = "";
	if( $sdata->{"version"} ) {
		$version = " -r '" . $sdata->{"version"} . "'";
	}

	my $args = [ $timeout, $sdata->{"port"}, $version ];
	return &build_service_definition($server, $sdata, "check_ssh", $args);
}

=head2 ping
PING check

=head3 Arguments
server - Server this config is for
sdata - Hash of the specified service config

=head3 Returns
String containing the service definition

=cut

sub build_service_ping_config {
	my $server = shift;
	my $sdata = shift;

	if( ! $sdata->{"description"} || $sdata->{"description"} !~ /^[a-zA-Z0-9_\- ]$/ ) {
		$sdata->{"description"} = "PING check";
	}

	my $warning_rta = "2000.00";
	if( $sdata->{"warning_rta"} && $sdata->{"warning_rta"} =~ /^\d+$/ ) {
		$warning_rta = $sdata->{"warning_rta"};
	}

	my $warning_pl = "80";
	if( $sdata->{"warning_pl"} && $sdata->{"warning_pl"} =~ /^\d+$/ ) {
		$warning_pl = $sdata->{"warning_pl"};
	}

	my $critical_rta = "7000.00";
	if( $sdata->{"critical_rta"} && $sdata->{"critical_rta"} =~ /^\d+$/ ) {
		$critical_rta = $sdata->{"critical_rta"};
	}

	my $critical_pl = "100";
	if( $sdata->{"critical_pl"} && $sdata->{"critical_pl"} =~ /^\d+$/ ) {
		$critical_pl = $sdata->{"critical_pl"};
	}

	my $packets = "5";
	if( $sdata->{"packets"} && $sdata->{"packets"} =~ /^\d+$/ ) {
		$packets = $sdata->{"packets"};
	}

	my $args = [ $warning_rta, $warning_pl, $critical_rta, $critical_pl, $packets ];
	return &build_service_definition($server, $sdata, "check_ping", $args);
}

=head2 rdp
x224 protocol check definition

=head3 Arguments
server - Server this config is for
sdata - Hash of the specified service config

=head3 Returns
String containing the service definition

=cut

sub build_service_rdp_config {
	my $server = shift;
	my $sdata = shift;

	if( !$sdata->{"description"} || $sdata->{"description"} !~ /^[a-zA-Z0-9_\- ]$/ ) {
		$sdata->{"description"} = "RDP check";
	}

	my $warning_timeout = "5";
	if( $sdata->{"warning_timeout"} && $sdata->{"warning_timeout"} =~ /^\d+$/ ) {
		$warning_timeout = $sdata->{"warning_timeout"};
	}

	my $critical_timeout = "10";
	if( $sdata->{"critical_timeout"} && $sdata->{"critical_timeout"} =~ /^\d+$/ ) {
		$critical_timeout = $sdata->{"critical_timeout"};
	}

	my $args = [ $warning_timeout, $critical_timeout ];
	return &build_service_definition($server, $sdata, "check_x224", $args);
}

# Run the main sub - this does all the magic
if( $< == 0 ) {
	print "Please DO NOT run this as root\n";
	exit(100);
}
run();
