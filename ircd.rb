# IRC server
# (c) Yoann Guillot 2010
# Distributes under the terms of the WtfPLv2

require 'socket'
require 'timeout'
require 'openssl'
require 'digest/md5'

module HasSock
	attr_accessor :ircd, :fd

	def send(*a)
		@fd.write a.join(' ').gsub(/[\r\n]/, '_') << "\r\n"
	end

	# send() with ircd name prefixed
	def sv_send(*a)
		send ":#{@ircd.name} #{a.join(' ')}"
	end
end

# a client connection
class User
	include HasSock

	attr_accessor :nick, :ident, :hostname, :descr
	attr_accessor :mode
	attr_accessor :away
	attr_accessor :connect_time
	# Time.to_f of the last message sent from the user (whois idle)
	attr_accessor :last_active
	# ping timeout parameters
	attr_accessor :last_ping, :last_pong
	# antiflood
	attr_accessor :next_read_time
	# reference to the Server that introduced this nick (nil if local)
	attr_accessor :from_server

	def initialize(ircd, nick, ident, hostname, fd=nil)
		@ircd = ircd
		@nick = nick
		@ident = ident
		@hostname = hostname
		if fd.kind_of? Server
			@from_server = fd
		else
			@fd = fd
		end
		@mode = ''
		@away = nil
		@connect_time = @last_active = @last_ping = @last_pong = Time.now.to_f
		@next_read_time = @last_active - 10
	end

	def local?
		not from_server
	end

	def servername
		local? ? @ircd.name : @from_server.name
	end

	def chans
		@ircd.chans.find_all { |c| c.users.include? self }
	end

	def fqdn
		"#@nick!#@ident@#@hostname"
	end

	def can_read
		if not l = @ircd.fd_gets(fd)
			cleanup
		else
			handle_line(@ircd.split_line(l))
		end
	end

	def cleanup(reason=":#{fqdn} QUIT :Remote host closed the connection")
		@ircd.user.delete_if { |k, v| v == self }
		@ircd.send_visible(self, reason)
		@ircd.clean_chans
		fd.close rescue nil
		fd.to_io.close rescue nil
	end

	def handle_line(l)
		l.shift if l[0] and l[0][0] == ?:	# ignore 'from' from clients
		@next_read_time = Time.now.to_f-10 if @next_read_time < Time.now.to_f-10
		@next_read_time += 2
		handle_command(l)
	end

	def send(*a)
		(fd || from_server.fd).write a.join(' ').gsub(/[\r\n]/, '_') << "\r\n"
	rescue
		puts "#{Time.now} #{fqdn} #{$!} #{$!.message}"
		cleanup ":#{fqdn} QUIT :Broken pipe" if fd
	end

	def send_welcome
		sv_send '001', @nick, ":Welcome to the RB IRC Network #{fqdn}"
		cmd_motd ['MOTD']
		cmd_mode ['MODE', @nick, '+i']
	end
end

# other servers linked to us
class Server
	include HasSock

	attr_accessor :cline
	attr_accessor :name, :descr

	def initialize(ircd, fd, cline)
		@ircd = ircd
		@fd = fd
		@cline = cline
	end

	def self.sconnect(ircd, fd, cline)
		sv = new(ircd, fd, cline)
		sv.sconnect
		sv
	rescue
		puts "#{Time.now} #{$!} #{$!.message}", $!.backtrace, ''
	end

	def sconnect
		send 'PASS', cline[:pass]
		send 'CAPAB', 'SSJOIN', 'NOQUIT', 'NICKIP', "TSMODE#{' DKEY' if @cline[:rc4]}#{' ZIP' if @cline[:zip]}"
		send 'SERVER', @ircd.name, ':ircd.rb'
		if @cline[:zip]
			# drain fd ?
			send 'SVINFO', 'ZIP'
			@fd = ZipIO.new(@fd)
		end
		if @cline[:rc4]
			sconnect_rc4
		end
	end

	def sconnect_rc4
		send 'DKEY INIT'
		loop do
			l = @ircd.fd_gets(@fd)
			break if l.to_s == ''
			p l
		end
		raise	# TODO
	end

	def can_read
		if not l = @ircd.fd_gets(@fd)
			cleanup
		else
			handle_line(@ircd.split_line(l))
		end
	end

	def cleanup
		@ircd.servers.delete self
		oldu = @ircd.users.find_all { |u| u.from_server == self }
		oldu.each { |u| @ircd.user.delete u.nick }
		oldu.each { |u| u.cleanup ":#{u.fqdn} QUIT :srv1 srv2" }
		@ircd.notice_opers("closing cx to server #{@cline[:host]}")
		@fd.to_io.close rescue nil
	end

	def handle_line(l)
		cmd = l[0]
		if l[0] and l[0][0] == ?:
			from = l.shift
		end
		handle_command(l, from)
	end
end

# ports we listen to
class Port
	attr_accessor :ircd
	attr_accessor :fd
	attr_accessor :pline

	def initialize(ircd, fd, pline)
		@ircd = ircd
		@fd = fd
		@pline = pline

		if @pline[:ssl]
			@sslctx = OpenSSL::SSL::SSLContext.new
			@sslctx.key = OpenSSL::PKey::RSA.new(File.open(@ircd.conf.ssl_key_path))
			@sslctx.cert = OpenSSL::X509::Certificate.new(File.open(@ircd.conf.ssl_cert_path))
		end
	end

	def can_read
		Timeout.timeout(2, RuntimeError) {
			afd, sockaddr = @fd.accept
			return if not afd
			afd = accept_ssl(afd) if @pline[:ssl]
			@ircd.pending << Pending.new(ircd, afd, sockaddr, self)
		}
	rescue
		puts "#{Time.now} #{$!} #{$!.message}", $!.backtrace, ''
	end

	def accept_ssl(fd)
		fd = OpenSSL::SSL::SSLSocket.new(fd, @sslctx)
		fd.sync = true
		fd.accept
		fd
	end

	def cleanup
		@ircd.ports.delete self
		@fd.to_io.close rescue nil
	end
end

# a new connection, not yet known to be User or Server
class Pending
	include HasSock

	attr_accessor :rmtaddr, :fromport
	attr_accessor :pass, :user, :nick
	attr_accessor :ident, :hostname
	attr_accessor :last_pong

	def initialize(ircd, fd, rmtaddr, fromport)
		@ircd = ircd
		@fd = fd
		@rmtaddr = rmtaddr
		@fromport = fromport
		@pass = @user = @nick = nil
		@ident = @hostname = nil
		@last_pong = Time.now.to_f
	end

	def can_read
		if not l = @ircd.fd_gets(fd)
			cleanup
		else
			handle_line(@ircd.split_line(l))
		end
	end

	def cleanup
		@ircd.user.delete @nick
		@ircd.pending.delete self
		@fd.close rescue nil
		@fd.to_io.close rescue nil
	end

	def handle_line(l)
		l.shift if l[0] and l[0][0] == ?:	# ignore 'from'
		handle_command(l)
	end

	def check_conn
		return if not @user or not @nick
		wait_hostname
		wait_ident
		clt = User.new(@ircd, @nick, @ident || "~#{@user[1]}", @hostname, @fd)
		clt.descr = @user[4]
		clt.mode << 'S' if @fromport.pline[:ssl]
		@ircd.pending.delete self
		@ircd.user[@nick.downcase] = clt
		clt.send_welcome
	end

	# TODO async dns/ident
	def retrieve_hostname
		@hostname = '0.0.0.0'
		sv_send 'NOTICE', 'AUTH', ':*** Looking up your hostname...'
		pa = @fd.to_io.peeraddr
		@hostname = pa[3]
		Timeout.timeout(2, RuntimeError) {
			@hostname = Socket.gethostbyaddr(@hostname.split('.').map { |i| i.to_i }.pack('C*'))[0]
		}
		sv_send 'NOTICE', 'AUTH', ':*** Found your hostname'
	rescue
		sv_send 'NOTICE', 'AUTH', ':*** Couldn\'t look up your hostname'
	end

	def retrieve_ident
		sv_send 'NOTICE', 'AUTH', ':*** Checking Ident'
		Timeout.timeout(2, RuntimeError) {
			pa = @fd.to_io.peeraddr
			la = @fd.to_io.addr
			ans = TCPSocket.open(pa[3], 113) { |id|
				id.puts "#{pa[1]},#{la[1]}"
				id.gets
			}.chomp.split(':')
			@ident = ans[3] if ans[1] == 'USERID'
		}
		sv_send 'NOTICE', 'AUTH', ':*** Got Ident response'
	rescue
		sv_send 'NOTICE', 'AUTH', ':*** No Ident response', $!.class.name, $!.message
	end

	def wait_hostname
	end

	def wait_ident
	end
end

# a channel
class Channel
	attr_accessor :ircd
	attr_accessor :name
	attr_accessor :topic, :topicwhen, :topicwho
	attr_accessor :key	# mode +k
	attr_accessor :limit	# mode +l
	attr_accessor :mode
	# lists of User (one User can be in multiple lists)
	attr_accessor :users, :ops, :voices
	# list of ban masks { :mask => '*!*@lol.com', :who => 'foo!bar@baz.quux', :when => 1234222343 }
	attr_accessor :bans, :banexcept
	# same as ban masks, with :user instead of :mask (=> User)
	attr_accessor :invites

	def initialize(ircd, name)
		@ircd = ircd
		@name = name
		@mode = ''
		@users = []
		@ops = []
		@voices = []
		@bans = []
		@banexcept = []
		@invites = []
	end

	def banned?(user)
		@bans.find { |b| @ircd.match_mask(b[:mask], user.fqdn) } and
		not @banexcept.find { |e| @ircd.match_mask(e[:mask], user.fqdn) }
	end

	def op?(user)
		@ops.include? user
	end

	def voice?(user)
		@voices.include? user
	end
end

# our server
class Ircd
	# hash nickname.downcase => User
	attr_accessor :user
	# hash chan name.downcase => Channel
	attr_accessor :chan
	# list of Server
	attr_accessor :servers
	# local Ports we listen to
	attr_accessor :ports
	# incoming, non-established connections
	attr_accessor :pending

	attr_accessor :conf, :conffile

	def initialize(conffile=nil)
		@user = {}
		@chan = {}
		@servers = []
		@ports = []
		@pending = []
		@conf = Conf.new
		@conffile = conffile
		@conf.load(@conffile) if @conffile
	end

	def name
		@conf.name
	end

	def descr
		@conf.descr
	end

	def rehash
		puts 'rehash'
		load __FILE__	# reload this source
		conf = Conf.new	# reload the configuration
		conf.load(@conffile)
		@conf = conf	# this allows conf.load to fail/raise without impacting the existing @conf
		startup		# apply conf changes (ports/clines/olines)
	end

	def users
		@user.values.grep(User)
	end

	def local_users
		users.find_all { |u| u.local? }
	end

	def local_users_canread
		tnow = Time.now.to_f
		local_users.find_all { |u| u.next_read_time < tnow }
	end

	def opers
		users.find_all { |u| u.mode.include? 'o' }
	end

	def notice_opers(msg)
		opers.each { |u| u.sv_send('NOTICE', u.nick, ":#{msg}") }
	end

	def chans
		@chan.values
	end

	# one or more Users disconnected, remove them from chans, remove empty chans
	def clean_chans
		users = self.users
		@chan.delete_if { |k, v|
			v.users &= users
			v.ops &= users
			v.voices &= users
			v.users.empty?
		}
	end

	# checks that a nickname is valid (no forbidden characters)
	def check_nickname(n)
		n.length < 32 and n =~ /^[a-z_`\[\]\\{}|\^][a-z_`\[\]\\{}|\^0-9-]*$/i
	end

	def check_channame(n)
		n.length < 32 and n =~ /^[#&][a-z_`\[\]\\{}|\^0-9-]*$/i
	end

	def downcase(str)
		str.tr('A-Z[\\]', 'a-z{|}')
	end

	def find_user(nick) @user[downcase(nick)] end
	def find_chan(name) @chan[downcase(name)] end
	def add_user(user) @user[downcase(user.nick)] = user end
	def add_chan(chan) @chan[downcase(chan.name)] = chan end
	def del_user(user) @user.delete downcase(user.nick) end
	def del_chan(chan) @chan.delete downcase(chan.name) end

	# send a message to all connected servers
	def send_servers(msg)
		servers.each { |s| s.send msg }
	end

	# send a message to all local users that have at least one chan in common with usr
	# also send the message to all servers
	def send_visible(usr, msg)
		send_servers(msg)
		usrs = usr.chans.map { |c| c.users }.flatten.uniq - [usr]
		(usrs & local_users - [usr]).each { |u| u.send msg }
	end

	# send a message to all users of the chan
	# also send the message to all servers unless the chan is local-only (&chan)
	def send_chan(chan, msg)
		send_servers(msg) if chan.name[0] != ?&
		chan.users.dup.each { |u| u.send msg }
	end

	# same as send_chan, but dont send to usr (eg PRIVMSG etc)
	def send_chan_butone(chan, usr, msg)
		send_servers(msg) if chan.name[0] != ?&
		chan.users.dup.each { |u| u.send msg if u != usr }
	end

	# same as send_chan restricted to chanops, but dont send to usr (eg PRIVMSG etc)
	def send_chan_op_butone(chan, usr, msg)
		send_servers(msg) if chan.name[0] != ?&
		chan.ops.dup.each { |u| u.send msg if u != usr }
	end

	# send to all servers + +w users
	def send_wallops(msg)
		send_servers(msg)
		local_users.find_all { |u|
			u.mode.include? 'w' or u.mode.include? 'o'
		}.each { |u| u.send msg }
	end

	# send as notice to all opers/+g users
	def send_global(msg)
		users.find_all { |u|
			u.mode.include? 'g' or u.mode.include? 'o'
		}.each { |u| u.send ":#{name} NOTICE #{u.nick} :*** Global -- #{msg}" }
	end


	def main_loop
		loop { main_loop_iter }
	end

	def startup
		# close old ports no longer in conf (close first to allow reuse)
		@ports.dup.each { |p|
			next if @conf.plines.find { |pp| p.pline == pp }
			p.cleanup
		}

		# open new ports from conf
		@conf.plines.each { |p|
			next if @ports.find { |pp| pp.pline == p }
			fd = TCPServer.open(p[:host], p[:port])
			puts "listening on #{p[:host]}:#{p[:port]}#{' (ssl)' if p[:ssl]}"
			@ports << Port.new(self, fd, p)
		}

		@conf.clines.each { |c|
			next if not c[:port]
			next if @servers.find { |s| s.cline == c }
			fd = TCPSocket.open(p[:host], p[:port])
			if sv = Server.sconnect(self, fd, c)
				@servers << sv
			end
		}
		# opers will squit servers no longer needed
	end

	def main_loop_iter
		check_timeouts
		wait_sockets
	rescue
		puts "#{Time.now} #{$!} #{$!.message}", $!.backtrace, ''
		sleep 0.4
	end

	def check_timeouts
		tnow = Time.now.to_f
		@last_tnow ||= tnow
		return if @last_tnow > tnow - 0.4
		@last_tnow = tnow
		servers.dup.each { |s|
			# TODO
		}
		local_users.dup.each { |u|
			if u.last_pong < tnow - @conf.ping_timeout
				u.send 'ERROR', ":Closing Link: #{u.hostname} (Ping timeout)"
				u.cleanup ":#{u.fqdn} QUIT :Ping timeout"
				next
			end
			if u.last_ping < tnow - @conf.ping_timeout / 2
				u.send 'PING', ":#{name}"
				u.last_ping = tnow
			end
		}
		pending.dup.each { |p|
			if p.last_pong < tnow - @conf.ping_timeout / 2
				p.send 'ERROR', ':Closing Link: 0.0.0.0 (Ping timeout)'
				p.cleanup
				next
			end
		}
	end

	def wait_sockets
		rd, wr = IO.select(rd_socks, nil, nil, 2)
		rd.to_a.each { |fd|
			fd_to_recv(fd).can_read
		}
	end

	# list of sockets we should select(rd)
	def rd_socks
		ports.map { |p| p.fd } +
		servers.map { |s| s.fd } +
		local_users_canread.map { |u| u.fd } +
		pending.map { |p| p.fd }
	end

	# fd => Client/Server/Port
	def fd_to_recv(fd)
		(ports + servers + local_users + pending).find { |o| fd == o.fd or fd == o.fd.to_io }	# SSL => no to_io
	end

	# read a line byte by byte
	def fd_gets(fd, maxlen=512)
		l = ''
		while fd.respond_to?(:pending) ? fd.pending : IO.select([fd], nil, nil, 0)	# yay OpenSSL
			return if not c = fd.read(1)
			return if l.length > maxlen*8
			break if c == "\n"
			l << c
		end
		l[0, maxlen]
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

	# match irc masks ('foo@lol*.com')
	def match_mask(mask, str)
		downcase(str) =~ /^#{Regexp.escape(downcase(mask)).gsub('\\?', '.').gsub('\\*', '.*')}$/
	end

	# match irc OPER password against hash
	def check_oper_pass(pass, hash)
		salt_a, hash_a = hash.split('$')

		salt = salt_a.unpack('m*').first

		md5 = pass
		(1<<14).times { md5 = Digest::MD5.digest(salt+md5) }
		md5_a = [salt[0, 2] + md5].pack('m*').chomp

		md5_a == hash_a
	end

	def self.run(conffile='conf')
		ircd = new(conffile)
		ircd.startup
		trap('HUP') { ircd.rehash }
		ircd.main_loop
	end

	def self.run_bg(conffile='conf', logfile='log')
		File.open(logfile, 'a') {}
		ircd = new(conffile)	# abort now if there is an error in the conf
		ircd.startup
		if pid = Process.fork
			puts "Running in background, pid #{pid}"
			return
		end

		$stdout.reopen File.open(logfile, 'a')
		$stderr.reopen $stdout
		trap('HUP') { ircd.rehash }
		ircd.main_loop
		exit!
	end
end

# set of configuration parameters
class Conf
	# our server name
	attr_accessor :name, :descr
	# list of { :host => '1.2.3.4', :port => 6667, :ssl => true }
	attr_accessor :plines
	# list of { :nick => 'lol' (OPER command param), :mask => '*!blabla@*', :pass => '123$1azde2', :mode => 'oOaARD' }
	attr_accessor :olines
	# list of { :host => '1.2.3.4', :port => 42, :pass => 'secret', :rc4 => true, :zip => true }
	attr_accessor :clines

	attr_accessor :ping_timeout
	attr_accessor :motd_path
	attr_accessor :ssl_key_path, :ssl_cert_path
	attr_accessor :user_chan_limit	# max chan per user
	attr_accessor :max_chan_mode_cmd	# max chan mode change per /mode command

	def initialize
		@plines = []
		@olines = []
		@clines = []

		# config elements that have no corresponding line in the conf
		# edit this file to change values
		# if you change a value in your startup script with ircd.conf.bla = 42, this will be forgotten when rehashing !
		@motd_path = 'motd'
		@ping_timeout = 180
		@ssl_key_path = 'ssl_key.pem'
		@ssl_cert_path = 'ssl_cert.pem'
		@user_chan_limit = 25
		@max_chan_mode_cmd = 6
	end

	def load(filename)
		File.read(filename).each_line { |l|
			l = l.strip
			case l[0]
			when ?N; n, @name, @descr = l.split(':', 3)
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
		@plines << p
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

	# O:bob:*!lol@*.foo.com:123$azU2/h:OaARD
	def parse_o_line(l)
		o = {}
		fu = split_ipv6(l)
		fu.shift	# 'O'
		o[:nick] = fu.shift
		o[:mask] = fu.shift
		o[:pass] = fu.shift
		o[:mode] = fu.shift
		@olines << o
	end
end

load File.join(File.dirname(__FILE__), 'crypto.rb')
load File.join(File.dirname(__FILE__), 'ircd_commands.rb')
