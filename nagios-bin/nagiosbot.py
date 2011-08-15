#!/usr/bin/env python
'''
nagiosbot.py - IRC relay bot for Nagios

SOURCE
Git repo: https://github.com/cluenet/cluemon
Issues: https://github.com/cluenet/cluemon/issues

AUTHOR
Damian Zaremba <damian@damianzaremba.co.uk>.

CHANGE LOG
* v0.1 - 14 Aug 2011
  - Initial version

=head1 LICENSE
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
'''
from twisted.internet.protocol import DatagramProtocol
from twisted.words.protocols import irc
from twisted.internet import protocol, reactor
import os
import logging
import random

'''
Add the following into the nagios commands file:
define command{
        command_name notify-service-by-irc
        command_line /bin/echo "service||~||$NOTIFICATIONTYPE$||~||$HOSTNAME$||~||$SERVICEDESC$||~||$SERVICESTATE$||~||$SERVICEOUTPUT$" | socat - UDP:localhost:3843
}

define command{
        command_name notify-host-by-irc
        command_line /bin/echo "host||~||$NOTIFICATIONTYPE$||~||$HOSTNAME$||~||$HOSTSTATE$||~||$HOSTOUTPUT$" | socat - UDP:localhost:3843
}

Then in the contact template add:
service_notification_commands notify-service-by-irc
host_notification_commands notify-host-by-irc
'''

IRC_SERVER = 'irc.cluenet.org'
IRC_PORT = 6667
IRC_CHANNELS = {
	'#nagios': {
		#'password: '',
		#'modes': ['a', 'o',],
	},
}

IRC_USER = "Nagios"
IRC_NS_PASS = False

IRC_OPER_USER = False
IRC_OPER_PASS = False

NAGIOS_PORT = 3843
NAGIOS_NOTIFICATION_COLORS = {
	'PROBLEM': '\x0304',
	'RECOVERY': '\x0309',
	'ACKNOWLEDGEMENT': '\x0306',
	'FLAPPINGSTART': '\x0305',
	'FLAPPINGSTOP': '\x0312',
	'FLAPPINGDISABLED': '\x0301',
	'DOWNTIMESTART': '\x0313',
	'DOWNTIMEEND': '\x0311',
	'DOWNTIMECANCELLED': '\x0301',
}
NAGIOS_HOST_COLORS = {
	'UP': '\x0309',
	'DOWN': '\x0304',
	'UNREACHABLE': '\x0307',
}
NAGIOS_SERVICE_COLORS = {
	'OK': '\x0309',
	'WARNING': '\x0307',
	'UNKNOWN': '\x0314',
	'CRITICAL': '\x0304',
}

logging.basicConfig()
logger = logging.getLogger('NagiosBot')
logger.setLevel(logging.DEBUG)

class NagiosListener(DatagramProtocol):
	def __init__(self):
		self.callback = None
	
	def datagramReceived(self, data, (host, port)):
		logger.info("Listener got connection from %s:%d" % (host, port))
		self.callback(host, data)

class NagiosBotProtocol(irc.IRCClient):
	nickname = IRC_USER
	channels = {}

	def __init__(self, channels):
		self.channels = channels

	def NagiosListener_callback(self, host, data):
		processed_data = data.strip("\n").strip("\r").replace("\n", "\\n").replace("\r", "\\r").strip()
		pdparts = processed_data.split("||~||")
		message = ""

		# Service alert
		if pdparts[0] == 'service':
			# NOTIFICATIONTYPE
			if pdparts[1] in NAGIOS_NOTIFICATION_COLORS:
				color = NAGIOS_NOTIFICATION_COLORS[pdparts[1]]
			else:
				color = ""
			message += color + pdparts[1] + color

			# HOSTNAME
			message += " \x0306[[\x0306\x0301%s\x0301\x0306]]\x0306 " % pdparts[2]

			# SERVICEDESC
			message += "\x0301%s\x0301 " % pdparts[3]

			# SERVICESTATE
			if pdparts[4] in NAGIOS_SERVICE_COLORS:
				color = NAGIOS_SERVICE_COLORS[pdparts[4]]
			else:
				color = ""
			message += color + pdparts[4] + color

			# SERVICEOUTPUT
			message += " \x0301%s\x0301" % pdparts[5]

		elif pdparts[0] == 'host':
			# NOTIFICATIONTYPE
			if pdparts[1] in NAGIOS_NOTIFICATION_COLORS:
				color = NAGIOS_NOTIFICATION_COLORS[pdparts[1]]
			else:
				color = ""
			message += color + pdparts[1] + color

			# HOSTNAME
			message += " \x0306[[\x0306\x0301%s\x0301\x0306]]\x0306 " % pdparts[2]

			# HOSTSTATE
			if pdparts[3] in NAGIOS_HOST_COLORS:
				color = NAGIOS_HOST_COLORS[pdparts[3]]
			else:
				color = ""
			message += color + pdparts[3] + color

			# HOSTOUTPUT
			message += " \x0301%s\x0301" % pdparts[4]
		elif pdparts[0] == 'rebuild':
			message += "\x0306[[\x0306\x03015REBUILD\x0301\x0306]]\x0306 "
			message += ' '.join(pdparts[1:])
		else:
			logger.error("Unknown message type:\n%s" % processed_data)
			return

		print message
		for channel in self.channels:
			print "Sending to %s" % channel
			logger.debug('Sending "%s" to %s' % (message, channel))
			self.msg(channel, message)

	def signedOn(self):
		self.factory.NagiosCallback.callback = self.NagiosListener_callback

		logger.debug("Setting ourselves to +B")
		self.mode(self.nickname, True, 'B', user=self.nickname)

		logger.debug("Identifying ourselves to nickserv")
		self.msg("NickServ", "IDENTIFY %s" % IRC_NS_PASS)

		logger.debug("Opering up")
		self.sendLine("oper %s %s" % (IRC_OPER_USER, IRC_OPER_PASS))

		# We can't join until we are open (channel restriction stuff)
		for channel in self.channels:
			if 'password' in self.channels[channel]:
				logger.info("Joining %s (%s)" % (channel, self.channels[channel]['password']))
				self.join(channel, password)
			else:
				logger.info("Joining %s" % channel)
				self.join(channel)

			if 'modes' in self.channels[channel]:
				for mode in self.channels[channel]['modes']:
					logger.info('Setting %s on %s' % (mode, channel))
					self.mode(channel, True, mode, user=self.nickname)
		logger.info("Signed on")

	def joined(self, channel):
		logger.info("Joined %s" % channel)
	
	def kickedFrom(self, channel, kicker, message):
		self.channels.remove(channel)
		logger.info("Kicked from %s" % channel)

	def alterCollidedNick(self, nickname):
		nickname = "%s-%d" % (nickname, random.randint(5, 20))
		return nickname

class NagiosBot(protocol.ReconnectingClientFactory):
	protocol = NagiosBotProtocol

	def __init__(self, channels, NagiosCallback):
		self.channels = channels
		self.NagiosCallback = NagiosCallback

	def buildProtocol(self, addr):
		p = self.protocol(self.channels)
		p.factory = self
		self.resetDelay()
		return p

	def clientConnectionLost(self, connector, reason):
		logger.critical("Lost connection (%s)... trying reconnect" % reason)
		protocol.ReconnectingClientFactory.clientConnectionLost(self, connector, reason)

	def clientConnectionFailed(self, connector, reason):
		logger.critical("Could not connect: %s" % reason)
		protocol.ReconnectingClientFactory.clientConnectionFailed(self, connector, reason)

if __name__ == '__main__':
	NagiosCallback = NagiosListener()
	NagiosBotFactory = NagiosBot(IRC_CHANNELS, NagiosCallback)
	reactor.connectTCP(IRC_SERVER, IRC_PORT, NagiosBotFactory)
	reactor.listenUDP(NAGIOS_PORT, NagiosCallback)
	reactor.run()
