#!/usr/bin/env perl
use strict;
use File::Path;
use Net::LDAP;
use Data::Dumper;

# Config stuff
my $base_dir = "/usr/local/nagios/etc/cluenet/";

# Main code
my $ldap = Net::LDAP->new("ldap.cluenet.org", timeout => 30);
if(!$ldap) {
	print "Could not connect to ldap\n";
}

print "Clearing current configs\n";
rmtree($base_dir);
mkdir($base_dir);

my @admins = ();
my @owners = ();
my $mesg = $ldap->search(
	filter => "(&(objectClass=server)(isActive=TRUE))",
	base => "ou=servers,dc=cluenet,dc=org"
);
my @entries = $mesg->entries;

print "Starting server configs\n";
foreach (@entries) {	
	my $entry = $_;
	print "Starting " . $entry->get_value('cn') . "\n";

	my $hostname = $entry->get_value('cn');
	if(!$hostname) {
		print "Skipping - missing hostname\n";
		next;
	}

	my $servername = $hostname;
	$servername =~ s/\.cluenet\.org$//;

	my $owner = $entry->get_value('owner');
	$owner =~ s/uid=(.*),ou=people,dc=cluenet,dc=org/$1/;

	if(!$owner) {
		print "Skipping - missing owner\n";
		next;
	}

	my $ip_address = $entry->get_value('ipAddress');
	if(!$ip_address) {
		print "Skipping - missing ip address\n";
		next;
	}

	my $ssh_port = $entry->get_value('sshPort');

	my $description = $entry->get_value('description');
	if(!$description) {
		$description = "";
	}

	my $os = $entry->get_value('operatingSystem');
	if(!$os) {
		$os = 'linux'; # windows sux
	}

	open(FH, ">", "$base_dir/$hostname.cfg");
	# Write the host out
	print FH <<EOS;
define host {
	host_name $hostname
	alias $servername
	address $ip_address
	hostgroups $owner\_servers
	max_check_attempts 5
	notification_interval 0
	check_command check-host-alive
	check_period 24x7
	contacts $owner
	contact_groups $servername\_admins
	notification_period 24x7
}

EOS
;

	# Write out the services
	# - I'd like these to be ldap attributes but I'm not sure how we can do shit for now so hardcoding
	print "Adding ping check\n";
	print FH <<EOS;
define service {
	host_name $hostname
	service_description PING check
	notification_period 24x7
	check_period 24x7    
	max_check_attempts 3
	normal_check_interval 5
	retry_check_interval 1
	notification_interval 30
	notification_options w,u,c,r,f,s
	check_command check_ping!100.0,20%!500.00,60%
}

define serviceextinfo {
	host_name $hostname
	service_description PING check
	notes_url /nagiosgraph/cgi-bin/show.cgi?host=\$HOSTNAME\$&service=\$SERVICEDESC\$
}

EOS
;

	if(grep(/windows/i, $os)) {

	} else {
		if($ssh_port) {
			print "Adding SSH check on port $ssh_port\n";
			print FH <<EOS;
define service {
	host_name $hostname
	service_description SSH running on port $ssh_port
	notification_period 24x7
	check_period 24x7    
	max_check_attempts 3
	normal_check_interval 5
	retry_check_interval 1
	notification_interval 30
	notification_options w,u,c,r,f,s
	check_command check_ssh!$ssh_port
}

#define serviceextinfo {
#	host_name $hostname
#	service_description SSH running on port $ssh_port
#	notes_url /nagiosgraph/cgi-bin/show.cgi?host=\$HOSTNAME\$&service=\$SERVICEDESC\$
#}

EOS
;
		} else {
			print "Skipping ssh check - no port specified\n";
		}
	}

	# Write out the contact group
	print "Writing out the contact group\n";

	my $members = "";
	foreach($entry->get_value('authorizedAdministrator')) {
		my $user = $_;
		$user =~ s/uid=(.*),ou=people,dc=cluenet,dc=org/$1/;
		$members = $members . ", " . $user;

		if(!grep(/$user/, @admins)) {
			push(@admins, $user);
		}
	}

	print FH <<EOS;
define contactgroup {
	contactgroup_name $servername\_admins
	alias $hostname admins
	members __nagiosbot_twitter__,__nagiosbot_irc__$members
}

EOS
;

	# Push admins and owner into admins array
	if(!grep(/$owner/, @admins)) {
		push(@admins, $owner);
	}

	if(!grep(/$owner/, @owners)) {
		push(@owners, $owner);
	}

	close(FH);
	print "Done " . $entry->get_value('cn') . "\n";
}
print "Finished server configs\n";

print "Starting user config\n";
open(FH, ">", "$base_dir/users.cfg");
print "Adding __nagiosbot_twitter__\n";
print FH <<EOS;
define contact {
	contact_name __nagiosbot_twitter__
	alias Nagios twitter relay bot
	host_notification_period 24x7
	service_notification_period 24x7
	host_notification_commands notify-host-by-twitter
	service_notification_commands notify-service-by-twitter
	service_notification_options w,u,c,r,f,s
	host_notification_options d,u,r,f,s
}
EOS
;

print "Adding __nagiosbot_irc__\n";
print FH <<EOS;
define contact {
	contact_name __nagiosbot_irc__
	alias Nagios IRC relay bot
	host_notification_period 24x7
	service_notification_period 24x7
	host_notification_commands notify-host-by-irc
	service_notification_commands notify-service-by-irc
	service_notification_options w,u,c,r,f,s
	host_notification_options d,u,r,f,s
}
EOS
;

foreach(@admins) {
	print "Adding user $_ \n";
	print FH <<EOS;
define contact {
	contact_name $_
	host_notification_period 24x7
	service_notification_period 24x7
	host_notification_commands notify-host-by-email
	service_notification_commands notify-service-by-email
EOS
;

	my $mesg = $ldap->search(
		filter => "(&(objectClass=person)(uid=" . $_ . "))",
		base => "ou=people,dc=cluenet,dc=org"
	);

	foreach($mesg->entries) {
		my $entry = $_;

		my $gecos = $entry->get_value('gecos');
		if($gecos) {
			print FH "\talias $gecos\n";
		}

		my $mail = $entry->get_value('mail');
		if($mail) {
			print FH "#\temail $mail\n";
		}
	}
	print FH <<EOS;
}

EOS
;
}

foreach(@owners) {
	print FH <<EOS;
define hostgroup {
	hostgroup_name $_\_servers
	alias $_\'s servers
}

EOS
;
}

close(FH);
print "Finished user config\n";

print "Reloading\n";
`/etc/init.d/nagios reload`
