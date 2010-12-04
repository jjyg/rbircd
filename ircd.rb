# IRC server
# (c) Yoann Guillot 2010
# Distributes under the terms of the WtfPLv2

require 'socket'
require 'openssl'

# a client connection
class User
	# file descriptor
	attr_accessor :fd
	attr_accessor :nick, :ident, :hostname
	attr_accessor :mode
	# list of Channel
	attr_accessor :channels
	# Time.to_f of the last message sent from the user (whois idle)
	attr_accessor :last_active
	attr_accessor :last_ping, :last_pong
	# reference to the Server that introduced this nick (nil if local)
	attr_accessor :from_server

	def initialize(nick, ident, hostname, fd=nil)
		@nick = nick
		@ident = ident
		@hostname = hostname
		if fd.kind_of? Server
			@from_server = fd
		else
			@fd = fd
		end
		@mode = ''
		@channels = []
		@last_active = @last_ping = @last_pong = Time.now.to_f
	end

	def fqdn
		"#@nick!#@ident@#@host"
	end

	def can_read(ircd)
		if not l = ircd.fd_gets(fd)
			cleanup(ircd)
		else
			handle_line(ircd, ircd.split_line(l))
		end
	end

	def cleanup(ircd)
		ircd.user.delete_if { |k, v| v == self }
		ircd.clean_chans
	end

	def handle_line(ircd, l)
		l.shift if l[0] and l[0][0] == ?:	# ignore 'from' from clients
		handle_command(ircd, l)
	end
end

# a channel
class Channel
	attr_accessor :name
	attr_accessor :topic, :topicdate, :topicwho
	attr_accessor :key
	attr_accessor :mode
	# lists of User (one User can be in multiple lists)
	attr_accessor :users, :ops, :voices
	# list of bans (masks, Strings)
	attr_accessor :bans

	def initialize(name)
		@name = name
		@mode = ''
		@users = []
		@ops = []
		@voices = []
		@bans = []
	end
end

# other servers linked to us
class Server
	attr_accessor :fd
	attr_accessor :cline

	def initialize(fd, cline)
		@fd = fd
		@cline = cline
	end

	def self.sconnect(ircd, fd, cline)
		fd.puts "PASS #{cline[:pass]}"
		fd.puts "CAPAB SSJOIN NOQUIT NICKIP TSMODE#{' DKEY' if cline[:rc4]}#{' ZIP' if cline[:zip]}"
		fd.puts "SERVER #{ircd.conf.name} :ircd.rb"
		if cline[:zip]
			# drain fd ?
			fd.puts "SVINFO ZIP" if cline[:zip]
			fd = ZipIO.new(fd) if cline[:zip]
		end
		Server.new(fd, cline)
	end

	def can_read(ircd)
		if not l = ircd.fd_gets(fd)
			cleanup(ircd)
		else
			handle_line(ircd, ircd.split_line(l))
		end
	end

	def cleanup(ircd)
		ircd.servers.delete self
		ircd.notice_opers("closing cx to server #{@cline[:host]}")
		# TODO send QUIT :him us to all users ?
		ircd.user.delete_if { |k, v| v.from_server == self }
		ircd.clean_chans
	end

	def handle_line(ircd, l)
		cmd = l[0]
		if l[0] and l[0][0] == ?:
			from = l.shift
		end
		handle_command(ircd, l, from)
	end
end

# ports we listen to
class Port
	attr_accessor :fd
	attr_accessor :descr

	def initialize(fd, descr)
		@fd = fd
		@descr = descr

		if @descr[:ssl]
			sslkey = OpenSSL::PKey::RSA.new(512)
			sslcert = OpenSSL::X509::Certificate.new
			sslcert.not_before = Time.now
			sslcert.not_after = Time.now + 3600 * 24 * 365 * 10
			sslcert.public_key = sslkey.public_key
			sslcert.sign(sslkey, OpenSSL::Digest::SHA1.new)
			@sslctx = OpenSSL::SSL::SSLContext.new
			@sslctx.key = sslkey
			@sslctx.cert = sslcert
		end
	end

	def can_read(ircd)
		Timeout.timeout(4, RuntimeError) {
			afd, sockaddr = @fd.accept
			return if not afd
			afd = accept_ssl(afd) if @descr[:ssl]
			ircd.pending << Pending.new(afd, sockaddr, self)
		}
	rescue
	end

	def accept_ssl(fd)
		fd = OpenSSL::SSL::SSLSocket.new(fd, @sslctx)
		fd.sync = true
		fd.accept
		fd
	end
end

class Pending
	attr_accessor :fd
	attr_accessor :rmtaddr, :fromport

	def initialize(fd, rmtaddr, fromport)
		@fd = fd
		@rmtaddr = rmtaddr
		@fromport = fromport
p "Pending", @rmtaddr
	end

	def can_read(ircd)
		if not l = ircd.fd_gets(fd)
			cleanup(ircd)
		else
			handle_line(ircd, ircd.split_line(l))
		end
	end
end


# our server
class Ircd
	# hash nickname => User
	attr_accessor :user
	# hash chan name => Channel
	attr_accessor :channel
	# list of Server
	attr_accessor :servers
	# local Ports we listen to
	attr_accessor :ports
	# incoming, non-established connections
	attr_accessor :pending

	attr_accessor :conf, :conffile

	def initialize(conffile=nil)
		@user = {}
		@channel = {}
		@servers = []
		@ports = []
		@pending = []
		@conf = Conf.new
		@conffile = conffile
		@conf.load(@conffile) if @conffile
	end

	def rehash
		load __FILE__
		conf = Conf.new
		conf.load(@conffile)
		@conf = conf
		startup
	end

	def users
		@user.values
	end

	def local_users
		users.find_all { |u| not u.from_server }
	end

	def opers
		users.find_all { |u| u.mode.include? 'o' }
	end

	def channels
		@channel.values
	end

	# one or more Users disconnected, remove them from chans, remove empty chans
	def clean_chans
		users = users
		channel.delete_if { |k, v|
			v.users &= users
			v.ops &= users
			v.voices &= users
			v.users.empty?
		}
	end

	def main_loop
		startup
		loop { main_loop_iter }
	end

	def startup
		@conf.ports.each { |p|
			next if @ports.find { |pp| pp.descr == p }
			fd = TCPServer.open(p[:host], p[:port])
			@ports << Port.new(fd, p)
		}

		@conf.clines.each { |c|
			next if not c[:port]
			next if @servers.find { |s| s.cline == c }
			fd = TCPSocket.open(p[:host], p[:port])
			if sv = Server.sconnect(self, fd, c)
				@servers << sv
			end
		}
	end

	def main_loop_iter
		check_timeouts
		wait_sockets
	rescue Exception
		puts Time.now, $!, $!.message, $!.backtrace, ''
		sleep 0.1
	end

	def check_timeouts
		tnow = Time.now.to_f
		@last_tnow ||= tnow
		return if @last_tnow > tnow - 1
		@last_tnow = tnow
		local_users.each { |u|

		}
	end

	def wait_sockets
		rd, wr = IO.select(rd_socks, nil, nil, 2)
		rd.to_a.each { |fd|
			c = fd_to_recv(fd)
			c.can_read(self)
		}
	end

	# list of sockets we should select(rd)
	def rd_socks
		ports.map { |p| p.fd } +
		servers.map { |s| s.fd } +
		local_users.map { |u| u.fd } +
		pending.map { |p| p.fd }
	end

	# fd => Client/Server/Port
	def fd_to_recv(fd)
		(ports + servers + local_users + pending).find { |o| fd == o.fd.to_io }
	end

	# read a line byte by byte
	def fd_gets(fd)
		l = ''
		while IO.select([fd], nil, nil, 0)
			return if not c = fd.read(1)
			break if c == "\n"
			l << fd.read(1)
		end
		l
	end

	# ":abc d e f :g h"  =>  [":abc", "d", "e", "f", "g h"]
	def split_line(l)
		l = l.chomp
		lsplit = l.split
		return [] if lsplit.empty?
		if last = lsplit[1..-1].find { |e| e[0] == ?: }
			lsplit = l.split(/\s+/, lsplit.index(last)+1)
			lsplit[-1] = lsplit[-1][1..-1]
		end
		lsplit
	end

	def match_mask(mask, str)
		str =~ /^#{Regexp.escape(mask).gsub('\\?', '.').gsub('\\*', '.*')}$/i
	end
end

# set of configuration parameters
class Conf
	# our server name
	attr_accessor :name
	# list of { :host => '1.2.3.4', :port => 6667, :ssl => true }
	attr_accessor :ports
	# list of { :mask => '*!blabla', :pass => '1ade2c39af8a83', :mode => 'oOaARD' }
	attr_accessor :olines
	# list of { :host => '1.2.3.4', :port => 42, :pass => 'secret', :crypt => true, :zip => true }
	attr_accessor :clines

	def initialize
		@ports = []
		@olines = []
		@clines = []
	end

	def load(filename)
		File.read(filename).each_line { |l|
			l = l.strip
			case l[0]
			when ?N; @name = l.split(':')[1]
			when ?P; parse_p_line(l)
			when ?C; parse_c_line(l)
			when ?O; parse_o_line(l)
			when ?#
			when nil
			else raise "Unknown configuration line #{l.inspect}"
			end
		}
	end

	# split a line at :, except inside [] (for ipv6 numeric addrs)
	def split_ipv6(l)
		ret = []
		cur = ''
		inv6 = false
		l.split('').each { |c|
			case c
			when '['
				raise '[[ fail' if inv6
				inv6 = true
			when ']'
				raise ']] fail' if not inv6
				inv6 = false
			when ':'
				if inv6
					cur << c
				else
					ret << cur
					cur = ''
				end
			else
				cur << c
			end
		}
		ret << cur if cur != ''
		raise '[ fail' if inv6
		ret
	end

	# P:127.0.0.1:7000:SSL
	# P:[123::456:789]:6667
	def parse_p_line(l)
		p = {}
		fu = split_ipv6(l)
		fu.shift	# 'P'
		p[:host] = fu.shift
		p[:port] = fu.shift.to_i
		raise "P:host:port:opts" if p[:port] == 0
		while e = fu.shift
			case e
			when 'SSL'; p[:ssl] = true
			when '', nil
			else raise "P:host:port:[SSL]"
			end
		end
		@ports << p
	end

	# C:127.0.0.1:7001:RC4:ZIP:1200	# active connection from us, delay = 1200s
	# C:127.0.0.2::RC4		# passive cx (listen only)
	def parse_c_line(l)
		c = {}
		fu = split_ipv6(l)
		fu.shift	# 'C'
		c[:host] = fu.shift
		c[:port] = fu.shift.to_i
		c[:pass] = fu.shift

		if c[:port] == 0
			c.delete :port
		else
			c[:delay] = 1200
		end

		while e = fu.shift
			case e
			when 'RC4'; p[:rc4] = true
			when 'ZIP'; p[:zip] = true
			when /^\d+$/; p[:delay] = e.to_i
			when '', nil
			else raise "C:host:[port]:pass:[RC4]:[ZIP]:[delay]"
			end
		end
		@clines << c
	end

	# O:lol@foo.*.com:$123$abcd5salt:OaARD
	def parse_o_line(l)
		o = {}
		fu = split_ipv6(l)
		fu.shift	# 'O'
		o[:mask] = fu.shift
		o[:pass] = fu.shift
		o[:mode] = fu.shift
		@olines << o
	end
end

load File.join(File.dirname(__FILE__), 'crypto.rb')
load File.join(File.dirname(__FILE__), 'ircd_commands.rb')
