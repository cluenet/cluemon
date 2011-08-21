#!/bin/bash
<<"EOF"
setup.sh - Setup script for Nagios

SOURCE
Git repo: https://github.com/cluenet/cluemon
Issues: https://github.com/cluenet/cluemon/issues

AUTHOR
Damian Zaremba <damian@damianzaremba.co.uk>.

CHANGE LOG
* v0.1 - 14 Aug 2011
	- Initial version

LICENSE
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
EOF

cd "/tmp/";
echo "Downloading code";
wget "http://downloads.sourceforge.net/project/nagios/nagios-3.x/nagios-3.3.1/nagios-3.3.1.tar.gz?r=http%3A%2F%2Fwww.nagios.org%2Fdownload%2Fcore%2Fthanks%2F&ts=1313039358&use_mirror=dfn" -O nagios-3.3.1.tar.gz;

wget "http://downloads.sourceforge.net/project/nagiosplug/nagiosplug/1.4.15/nagios-plugins-1.4.15.tar.gz?r=http%3A%2F%2Fsourceforge.net%2Fprojects%2Fnagiosplug%2Ffiles%2F&ts=1313039215&use_mirror=kent" -O nagios-plugins-1.4.15.tar.gz;

wget "http://downloads.sourceforge.net/project/nagiosgraph/nagiosgraph/1.4.4/nagiosgraph-1.4.4.tar.gz?r=http%3A%2F%2Fsourceforge.net%2Fprojects%2Fnagiosgraph%2Ffiles%2F&ts=1313040777&use_mirror=puzzle" -O nagiosgraph-1.4.4.tar.gz;

if [ ! -f "nagios-3.3.1.tar.gz" ];
then
	echo "Failed to download nagios core";
	exit 1;
fi

if [ ! -f "nagios-plugins-1.4.15.tar.gz" ];
then
	echo "Failed to download nagios plugins";
	exit 1;
fi

if [ ! -f "nagiosgraph-1.4.4.tar.gz" ];
then
	echo "Failed to download nagios graph";
	exit 1;
fi

echo "Extracting source code";
mkdir "nagios-3.3.1"
tar -xvf nagios-3.3.1.tar.gz -C nagios-3.3.1;
if [ "$?" -ne "0" ];
then
	echo "Failed to extract nagios core";
	exit 2;
fi

mkdir "nagios-plugins-1.4.15"
tar -xvf nagios-plugins-1.4.15.tar.gz -C nagios-plugins-1.4.15;
if [ "$?" -ne "0" ];
then
	echo "Failed to extract nagios plugins";
	exit 2;
fi

mkdir "nagiosgraph-1.4.4"
tar -xvf nagiosgraph-1.4.4.tar.gz -C nagiosgraph-1.4.4;
if [ "$?" -ne "0" ];
then
	echo "Failed to extract nagios graph";
	exit 2;
fi

echo "Installing requirements";
apt-get install -y make gcc g++ libgd2-xpm libgd2-xpm-dev libgd2-xpm \
	libpng12-dev libjpeg62-dev libgd-tools libpng3-dev rrdtool perl \
	perl-base perl-modules libcalendar-simple-perl libgd-gd2-perl perlmagick \
	librrds-perl liburi-perl;

echo "Creating user/group";
id nagios > /dev/null 2>&1;
if [ "$?" -eq "0" ];
then
	echo "Nagios user already exists, ABORTING!";
	exit 3;
fi

adduser --system --home=/usr/local/nagios --shell=/bin/false \
	--disabled-password --disabled-login nagios;

echo "Compiling nagios core";
cd 'nagios-3.3.1';
./configure --prefix=/usr/local/nagios --enable-event-broker \
	--enable-statuswrl --enable-statusmap --with-nagios-user=nagios \
	--with-nagios-group=nagios --with-command-user=nagios \
	--with-command-group=nagios;
make all;
make install;
make install-init;
make install-commandmode;
make install-exfoliation;
cd ..;

echo "Compiling nagios plugins";
cd nagios-plugins-1.4.15;
./configure --prefix=/usr/local/nagios/ --enable-perl-modules \
	--with-nagios-user=nagios --with-nagios-group=nagios \
	--without-world-permissions --with-ipv6;
make;
make install;
cd ..;

echo "Compiling nagios graph";
cd nagiosgraph-1.4.4;
sed -i 's|/opt/nagiosgraph/etc|/usr/local/nagios/etc/nagiosgraph/|g'; cgi/*.cgi lib/insert.pl
cp lib/insert.pl /usr/local/nagios/libexec
cp cgi/*.cgi /usr/local/nagios/sbin

cp share/nagiosgraph.css /usr/local/nagios/share
cp share/nagiosgraph.js /usr/local/nagios/share
cp share/graph.gif /usr/local/nagios/share/images/action.gif

sed -i 's|/nagiosgraph/nagiosgraph.js|/nagios/nagiosgraph.js|' share/nagiosgraph.ssi
cp share/nagiosgraph.ssi /usr/local/nagios/share/ssi/common-header.ssi
cd ..;

echo "Installing configs";
rm -rf /usr/local/nagios/etc/*;
cp -vr nagios-etc/* /usr/local/nagios/etc/;

echo "Installing scripts";
chown nagios:nagios nagios-bin/rebuild_nagios.pl
chmod 750 nagios-bin/rebuild_nagios.pl
cp -av nagios-bin/rebuild_nagios.pl /usr/local/nagios/bin/;

chown nagios:nagios nagios-bin/nagiosbot.py
chmod 750 nagios-bin/nagiosbot.py
cp -av nagios-bin/nagiosbot.py /usr/local/nagios/bin/;

chown nagios:nagios nagios-libexec/*
chmod 750 nagios-libexec/*
cp -av nagios-libexec/* /usr/local/nagios/libexec/

echo "Installing crontab";
echo '0 * * * * /usr/local/bin/rebuild_nagios.pl' | \
	crontab -u nagios -;

echo "Adding nagiosbot to supervisord";
cat > /etc/supervisor/conf.d/nagiosbot.conf <<"EOF"
[program:nagiosbot]
command=python /usr/local/nagios/bin/nagiosbot.py
directory=/usr/local/nagios/bin/
user=nagios
autostart=true
autorestart=true
stdout_logfile=/usr/local/nagios/var/nagiosbot.log
redirect_stderr=true
stopsignal=QUIT
EOF

echo "Adding nagios to apache";
cat > /etc/apache2/sites-enabled/nagios <<"EOF"
# Rewrite HTTP to HTTPS
<VirtualHost *:80>
	ServerName monitoring.cluenet.org
	ServerAdmin damian@cluenet.org
	DocumentRoot "/var/www/monitoring"

	# Redirect all traffic to https
	RewriteEngine on
	RewriteCond %{HTTPS} off
	RewriteRule (.*) https://monitoring.cluenet.org/ [L,R=301]
</VirtualHost>

# Deal with nagios traffic on ssl
<VirtualHost *:443>
	ServerName monitoring.cluenet.org
	ServerAdmin damian@cluenet.org
	DocumentRoot "/var/www/monitoring"

	# Enable ssl
	SSLEngine on
	SSLCipherSuite ALL:!ADH:!EXPORT56:RC4+RSA:+HIGH:+MEDIUM:+LOW:+SSLv2:+EXP

	# SSL cert files
	SSLCertificateFile /etc/apache2/nagios.crt
	SSLCertificateKeyFile /etc/apache2/nagios.key

	# /nagios/cgi-bin
	ScriptAlias /nagios/cgi-bin /usr/local/nagios/sbin
	<Directory "/usr/local/nagios/sbin">
		Options ExecCGI
		AllowOverride None
		Order allow,deny
		Allow from all

		# Auth users against krb
		AuthType Kerberos
		AuthName "Cluemon - use your LDAP details"
		KrbAuthRealms CLUENET.ORG
		KrbServiceName http
		KrbMethodNegotiate on
		KrbMethodK5Passwd on
		Krb5Keytab /etc/apache2/http2.keytab
		KrbSaveCredentials On
		Require valid-user
	</Directory>

	# /nagios
	Alias /nagios /usr/local/nagios/share
	<Directory "/usr/local/nagios/share">
		Options None
		AllowOverride None
		Order allow,deny
		Allow from all

		# Auth users against krb
		AuthType Kerberos
		AuthName "Cluemon - use your LDAP details"
		KrbAuthRealms CLUENET.ORG
		KrbServiceName http
		KrbMethodNegotiate on
		KrbMethodK5Passwd on
		Krb5Keytab /etc/apache2/http2.keytab
		KrbSaveCredentials On
		Require valid-user
	</Directory>
</VirtualHost>
EOF
/etc/init.d/apache2 restart

echo "Running rebuild";
/usr/local/bin/rebuild_nagios.pl;
