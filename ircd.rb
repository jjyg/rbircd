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
		msg = a.join(' ').gsub(/[\r\n]/, '_') << "\r\n"
		puts "< #{msg}" if $DEBUG
		@fd.write msg
	rescue
		puts "#{Time.now} hs.send #{self.class} #{respond_to?(:fqdn) ? fqdn : self} #{$!.class} #{$!.message}", $!.backtrace, ''
		$stdout.flush
		cleanup if respond_to?(:cleanup)
		raise
	end

	# send() with ircd name prefixed
	def sv_send(*a)
		send ":#{@ircd.name} #{a.join(' ')}"
	end
end

# a client connection
class User
	include HasSock

	attr_accessor :nick, :ident, :hostname, :descr, :ip
	attr_accessor :mode, :mode_d
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
	attr_accessor :ts
	attr_accessor :servername, :serverdescr

	def initialize(ircd, nick, ident, hostname, fd=nil)
		@ircd = ircd
		@nick = nick
		@ident = ident
		@hostname = hostname
		if fd.kind_of? Server
			@from_server = fd
			@servername = fd.name
			@serverdescr = fd.descr
		else
			@fd = fd
			@servername = @ircd.name
			@serverdescr = @ircd.descr
		end
		@mode = ''
		@away = nil
		@connect_time = @last_active = @last_ping = @last_pong = Time.now.to_f
		@next_read_time = @last_active - 10
	end

	def local?
		not from_server
	end

	def serverhops
		(!from_server) ? 1 :
		@from_server.name == @servername ? 2 :
		@from_server.servers.find { |s| s[:name] == @servername }[:hops]
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
	rescue
		puts "#{Time.now} user.canread #{fqdn} #{$!.class} #{$!.message} #{l.inspect}", $!.backtrace, ''
		$stdout.flush
	end

	def cleanup(reason=":#{fqdn} QUIT :Remote host closed the connection", sendservers = true, cleanchans = true)
		@ircd.del_user(self)
		@ircd.send_servers(reason.sub(/^(:\S+)!\S*/, '\\1')) if sendservers
		@ircd.send_visible_local(self, reason)
		@ircd.clean_chans if cleanchans
		if fd
			@fd.close rescue nil
			@fd.to_io.close rescue nil
		end
	end

	def handle_line(l)
		l.shift if l[0] and l[0][0] == ?:	# ignore 'from' from clients
		@next_read_time = Time.now.to_f-10 if @next_read_time < Time.now.to_f-10
		@next_read_time += 2
		handle_command(l)
	end

	def send(*a)
		msg = a.join(' ').gsub(/[\r\n]/, '_') << "\r\n"
		puts "< #{msg}" if $DEBUG
		(fd || from_server.fd).write msg
	rescue
		puts "#{Time.now} user.send #{fqdn} #{$!.class} #{$!.message}", $!.backtrace, ''
		$stdout.flush
		cleanup ":#{fqdn} QUIT :Broken pipe" if fd
	end

	def send_welcome
		sv_send '001', @nick, ":Welcome to the #{@ircd.conf.network_name} IRC Network #{fqdn}"
		sv_send '002', @nick, ":Your host is #{@ircd.name}, running version #{@ircd.version}"
		sv_send '003', @nick, ":This server was created #{@ircd.creation_time}"
		umodes = 'igwoaSrd'.unpack('C*').sort.pack('C*')
		cmodes = 'beIklovrcimnpstS'.unpack('C*').sort.pack('C*')
		sv_send '004', @nick, "#{@ircd.name} #{@ircd.version} #{umodes} #{cmodes}"
		#:sv.moo.net 005 x NETWORK=moo.net SAFELIST MAXBANS=100 MAXCHANNELS=100 CHANNELLEN=32 KICKLEN=307 NICKLEN=30 TOPICLEN=307 MODES=6 CHANTYPES=# CHANLIMIT=#:100 PREFIX=(ov)@+ STATUSMSG=@+ :are available on this server
		#:sv.moo.net 005 x CASEMAPPING=ascii WATCH=128 SILENCE=10 ELIST=cmntu EXCEPTS INVEX CHANMODES=beI,k,jl,cimMnOprRst MAXLIST=b:100,e:45,I:45 TARGMAX=DCCALLOW:,JOIN:,KICK:4,KILL:20,NOTICE:20,PART:,PRIVMSG:20,WHOIS:,WHOWAS: :are available on this server
		sv_send '005', @nick, "NETWORK=#{@ircd.conf.network_name} CHANNELLEN=#{@ircd.conf.max_channame_len} " +
			"NICKLEN=#{@ircd.conf.max_nickname_len} MODES=#{@ircd.conf.max_chan_mode_cmd} CHANTYPES=#& " +
			"CHANLIMIT=#:100 PREFIX=(ov)@+ CASEMAPPING=ascii :available on this server"
		cmd_motd ['MOTD']
		cmd_mode ['MODE', @nick, '+i']
		send ":#@nick MODE #@nick :+S" if @mode.include? 'S'
	end
end

# other servers linked to us
class Server
	include HasSock

	attr_accessor :cline, :capab
	attr_accessor :name, :descr
	attr_accessor :last_ping, :last_pong
	# remote servers behind this connection, :name, :hops, :descr
	attr_accessor :servers

	def initialize(ircd, fd, cline)
		@ircd = ircd
		@fd = fd
		@cline = cline
		@name = cline[:name]
		@last_ping = @last_pong = Time.now.to_f
		@servers = []
	end

	def self.sconnect(ircd, cline)
		ircd.send_global("Routing - connection from #{ircd.name} to #{cline[:name]} activated")
		pend = Timeout.timeout(4) {
			sock = TCPSocket.open(cline[:host], cline[:port])
			if cline[:ssl]
				sock = OpenSSL::SSL::SSLSocket.new(sock, OpenSSL::SSL::SSLContext.new)
				sock.sync = true
				sock.connect
				def sock.pending; @rbuffer.to_s.length + super() end
			end
			Pending.new(ircd, sock)
		}
		pend.sconnect(cline)
		ircd.pending << pend
	rescue Timeout::Error
		ircd.send_global "Routing - connection to #{cline[:name]} timed out"
	rescue
		puts "#{Time.now} sv.sconnect #{cline[:name]} #{$!.class} #{$!.message}", $!.backtrace, ''
		$stdout.flush
		ircd.send_global "Routing - connection to #{cline[:name]} refused (#{$!.message})"
	end

	def can_read
		if not l = @ircd.fd_gets(@fd, 4096)
			cleanup
		else
			handle_line(@ircd.split_line(l))
		end
	rescue
		puts "#{Time.now} sv.canread #{@name} #{$!.class} #{$!.message} #{l.inspect}", $!.backtrace, ''
		$stdout.flush
	end

	def cleanup
		if defined?(@cleaningup) and @cleaningup
			puts "#{Time.now} recursive sv cleanup", caller
			return
		end
		@cleaningup = true
		puts "#{Time.now} sv #{@name} cleanup"
		@ircd.servers.delete self
		oldu = @ircd.users.find_all { |u| u.from_server == self }
		oldu.each { |u| @ircd.del_user u }
		@ircd.notice_opers("closing cx to server #{@cline[:host]}")
		oldu.each { |u| u.cleanup ":#{u.fqdn} QUIT :#{@ircd.name} #{name}", true, false }
		@ircd.clean_chans
		@fd.to_io.close rescue nil
		@cleaningup = false
	end

	def handle_line(l)
		cmd = l[0]
		if l[0] and l[0][0] == ?:
			from = l.shift
		end
		handle_command(l, from)
	end

	# 1024bit strong prime from bahamut, reportedly from ipsec
	def dkey_param_prime
		0xF488FD584E49DBCD20B49DE49107366B336C380D451D0F7C88B31C7C5B2D8EF6F3C923C043F0A55B188D8EBB558CB85D38D334FD7C175743A31D186CDE33212CB52AFF3CE1B1294018118D7C84A70A72D686C40319C807297ACA950CD9969FABD00A509B0246D3083D66A45D419F9C7CBD894B221926BAABA25EC355E92F78C7
	end
	def dkey_param_generator
		2
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
			kp = @pline[:ssl_key]  || @ircd.conf.ssl_key_path
			cp = @pline[:ssl_cert] || @ircd.conf.ssl_cert_path
			@sslctx.key  = File.open(kp, 'rb') { |fd| OpenSSL::PKey::RSA.new(fd) }
			@sslctx.cert = File.open(cp, 'rb') { |fd| OpenSSL::X509::Certificate.new(fd) }
		end
	end

	def can_read
		Timeout.timeout(2) {
			afd = @fd.accept
			return if not afd
			afd = accept_ssl(afd) if @pline[:ssl]
			@ircd.pending << Pending.new(ircd, afd, self)
		}
	rescue Timeout::Error, OpenSSL::SSL::SSLError
		# dont care
	rescue
		puts "#{Time.now} port.canread #{@pline[:host]} #{@pline[:port]} #{$!.class} #{$!.message}", $!.backtrace, ''
		$stdout.flush
	end

	def accept_ssl(fd)
		fd = OpenSSL::SSL::SSLSocket.new(fd, @sslctx)
		# YAY OPEN FUCKING SSL
		class << fd
			def pending
				@rbuffer.to_s.length + super()
			end
		end
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

	attr_accessor :fromport
	attr_accessor :pass, :user, :nick, :capab, :cline
	attr_accessor :ident, :hostname, :ip
	attr_accessor :last_pong

	def initialize(ircd, fd, fromport=nil)
		@ircd = ircd
		@fd = fd
		@fromport = fromport
		@pass = @user = @nick = nil
		@ident = nil
		@hostname = '0.0.0.0'
		@last_pong = Time.now.to_f
		@cline = nil
	end

	def can_read
		if not l = @ircd.fd_gets(fd)
			cleanup
		else
			handle_line(@ircd.split_line(l))
		end
	rescue
		puts "#{Time.now} pend.canread #{@nick} #{@hostname} #{$!.class} #{$!.message} #{l.inspect}", $!.backtrace, ''
		$stdout.flush
	end

	def cleanup
		@ircd.del_user self if @nick
		@ircd.pending.delete self
		@fd.close rescue nil
		@fd.to_io.close rescue nil
	end

	def handle_line(l)
		l.shift if l[0] and l[0][0] == ?:	# ignore 'from'
		handle_command(l)
	end

	# check if a client connection has completed
	def check_conn
		return if not @user or not @nick
		ident = @ident || "~#{@user[1]}"
		hostname = @hostname
		if @ircd.conf.user_pass and @pass != @ircd.conf.user_pass
			puts "#{Time.now} bad password from #{@nick}!#{ident}@#{hostname}"
			# sv_send "bad pass"
			cleanup
			return
		end
		if @ircd.conf.cloak_users
			hostname = Digest::MD5.hexdigest(hostname).downcase[0, 16] + '.fu'
		end
		clt = User.new(@ircd, @nick, ident[0, 10], hostname, @fd)
		clt.ip = @ip
		clt.descr = @user[4]
		clt.ts = Time.now.to_i
		clt.mode << 'S' if @fromport.pline[:ssl]
		@ircd.del_user clt
		@ircd.pending.delete self
		@ircd.add_user clt
		@ircd.servers.each { |s| s.send_nick_full(clt) }
		clt.send_welcome
	end

	# TODO async dns/ident
	def retrieve_hostname(verb=true)
		sv_send 'NOTICE', 'AUTH', ':*** Looking up your hostname...' if verb
		pa = @fd.to_io.peeraddr
		@ip = @hostname = pa[3]
		Timeout.timeout(2, RuntimeError) {
			raw = @hostname.split('.').map { |i| i.to_i }.pack('C*')
			if pa[0] =~ /INET6/
				raw = @hostname.split(':')
				raw[raw.index('')] = [''] * (9 - raw.length) if raw.index('')
				raw = raw.flatten.map { |s| s.to_i(16) }.pack('n*')
			end
			@hostname = Socket.gethostbyaddr(raw)[0]
		}
		sv_send 'NOTICE', 'AUTH', ':*** Found your hostname' if verb
	rescue
		sv_send 'NOTICE', 'AUTH', ':*** Couldn\'t look up your hostname' if verb
	end

	def retrieve_ident(verb=true)
		sv_send 'NOTICE', 'AUTH', ':*** Checking Ident' if verb
		Timeout.timeout(2, RuntimeError) {
			pa = @fd.to_io.peeraddr
			la = @fd.to_io.addr
			ans = TCPSocket.open(pa[3], 113) { |id|
				id.puts "#{pa[1]},#{la[1]}"
				id.gets
			}.chomp.split(':')
			@ident = ans[3] if ans[1] == 'USERID'
		}
		sv_send 'NOTICE', 'AUTH', ':*** Got Ident response' if verb
	rescue
		sv_send 'NOTICE', 'AUTH', ':*** No Ident response', $!.class.name, $!.message if verb
	end

	def sconnect(cline)
		@cline = cline

		send 'PASS', @cline[:pass], ':TS'
		send 'CAPAB', 'SSJOIN', 'NOQUIT', 'NICKIP', 'BURST', 'TS3', "TSMODE#{' DKEY' if @cline[:rc4]}#{' ZIP' if @cline[:zip]}"
		send 'SERVER', @ircd.name, ":#{@ircd.descr}"
		send 'SVINFO', 3, 3, 0, ":#{Time.now.to_i}"
	end

	def check_server_conn
		if not @cline
			cline = @ircd.conf.clines.find { |c|
				c[:pass] == @pass and
				@ircd.streq(c[:name], @server[1]) and
				@ircd.match_mask(c[:host], @hostname)
			}
			if not cline
				@ircd.send_global "Link #@ident!#@hostname dropped (No C-line)"
				send 'ERROR', ":Closing Link: #@ident!#@hostname (No C-line)"
				cleanup
				return
			end

			sconnect cline
		else
			if @cline[:pass] != @pass or not @ircd.streq(@cline[:name], @server[1])
				@ircd.send_global "Link #@ident!#@hostname dropped (No C-line)"
				send 'ERROR', ":Closing Link: #@ident!#@hostname (No C-line)"
				cleanup
				return
			end
		end

		@ircd.pending.delete self
		s = Server.new(ircd, @fd, @cline)
		s.descr = @server[-1]
		s.capab = @capab
		@ircd.servers << s
		s.setup_cx
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
	attr_accessor :bans, :banexcept, :invexcept
	# same as ban masks, with :user instead of :mask (=> User)
	attr_accessor :invites
	attr_accessor :ts

	def initialize(ircd, name)
		@ircd = ircd
		@name = name
		@mode = ''
		@users = []
		@ops = []
		@voices = []
		@bans = []
		@banexcept = []
		@invexcept = []
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
	attr_accessor :whowas

	attr_accessor :conf, :conffile

	def initialize(conffile=nil)
		@user = {}
		@chan = {}
		@servers = []
		@ports = []
		@pending = []
		@whowas = []
		@conf = Conf.new
		@conffile = conffile
		@conf.load(@conffile) if @conffile
		@clines_timeout = @conf.clines.map { |c| { :last_try_sconnect => Time.now.to_f, :cline => c } if c[:port] }.compact if @conffile
	end

	def creation_time
		@creation_time ||= Time.now
	end

	def name
		@conf.name
	end

	def descr
		@conf.descr
	end

	def version
		"rbircd-0.0.28"
	end

	def rehash
		puts "#{Time.now} rehash"
		load __FILE__	# reload this source
		conf = Conf.new	# reload the configuration
		conf.load(@conffile)
		if @conf.logfile
			$stdout.flush ; $stdout.fsync
			$stderr.flush ; $stderr.fsync
			$stdout.reopen File.open(@conf.logfile, 'a')
			$stderr.reopen $stdout
			conf.logfile = @conf.logfile
		end
		@conf = conf	# this allows conf.load to fail/raise without impacting the existing @conf
		@clines_timeout = @conf.clines.map { |c| { :last_try_sconnect => Time.now.to_f, :cline => c } if c[:port] }.compact
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
		return if n =~ /^(nick|chan|oper)serv$/
		n.length < conf.max_nickname_len and n =~ /^[a-z_`\[\]\\{}|\^][a-z_`\[\]\\{}|\^0-9-]*$/i
	end

	def check_channame(n)
		n.length < conf.max_channame_len and n =~ /^[#&][^\0\r\n\x07 ,]*$/
	end

	def downcase(str)
		str.tr('A-Z[\\]', 'a-z{|}')
	end

	def streq(s1, s2)
		downcase(s1) == downcase(s2)
	end

	def find_user(nick) u = @user[downcase(nick)]; u if u.kind_of?(User) end
	def find_chan(name) @chan[downcase(name)] end
	def add_user(user)
		if old = @user[downcase(user.nick)]
			old.send 'ERROR :Closing Link: 0.0.0.0 (Overridden)'
			old.cleanup
		end
	       	@user[downcase(user.nick)] = user
	end
	def add_chan(chan) @chan[downcase(chan.name)] = chan end
	def del_user(user) add_whowas(@user.delete(downcase(user.nick))) end
	def del_chan(chan) @chan.delete downcase(chan.name) end

	# return the list of [nick ident host '*' descr srv time] where nick == n
	def findall_whowas(n)
		@whowas.find_all { |w| streq(w[0], n) }
	end

	def add_whowas(u)
		return if not u.kind_of? User

		# enforce @whowas limits
		tnow = Time.now.to_i
		@whowas.shift while @whowas.length >= @conf.whowas[:maxlen]
		@whowas.shift while @whowas.first and @whowas.first[-1] < tnow - @conf.whowas[:maxage]
		lst = findall_whowas(u.nick)
		@whowas.delete lst.first if lst.length >= @conf.whowas[:maxdup]

		@whowas << [u.nick, u.ident, u.hostname, '*', u.descr, u.servername, tnow]
	end

	# send a message to all connected servers
	def send_servers(msg)
		servers.each { |s| s.send msg }
	end

	# send a message to all local users that have at least one chan in common with usr
	def send_visible_local(usr, msg)
		usrs = usr.chans.map { |c| c.users }.flatten.uniq - [usr]
		(usrs & local_users).each { |u| u.send msg }
	end

	# send a message to all users of the chan
	# also send the message to all servers unless the chan is local-only (&chan)
	def send_chan(chan, msg)
		send_servers(msg.sub(/^(:\S*)!\S*/, '\\1')) if chan.name[0] != ?&
		send_chan_local(chan, msg)
	end

	def send_chan_local(chan, msg)
		(chan.users & local_users).each { |u| u.send msg }
	end

	# same as send_chan, but dont send to usr (eg PRIVMSG etc)
	def send_chan_butone(chan, usr, msg)
		send_servers(msg.sub(/^(:\S*)!\S*/, '\\1')) if chan.name[0] != ?&
		(chan.users & local_users).each { |u| u.send msg if u != usr }
	end

	# same as send_chan restricted to chanops, but dont send to usr (eg PRIVMSG etc)
	def send_chan_op_butone(chan, usr, msg)
		send_servers(msg.sub(/^(:\S*)!\S*/, '\\1')) if chan.name[0] != ?&
		(chan.ops & local_users).each { |u| u.send msg if u != usr }
	end

	# send to all servers + +w users
	def send_wallops(msg)
		send_servers(msg)
		local_users.find_all { |u|
			u.mode.include? 'w' or u.mode.include? 'o'
		}.each { |u| u.send msg }
	end

	# send as notice to all opers/+g users, related to irc routing
	def send_gnotice(msg)
		send_servers ":#{name} GNOTICE :#{msg}"
		send_global_local(msg, 'Routing')
	end

	# send as notice to all opers/+g users
	def send_global(msg)
		send_servers ":#{name} GLOBOPS :#{msg}"
		send_global_local(msg)
	end

	def send_global_local(msg, qual='Global')
		local_users.find_all { |u|
			u.mode.include? 'g' or u.mode.include? 'o'
		}.each { |u| u.sv_send 'NOTICE', u.nick, ":*** #{qual} -- #{msg}" }
	end


	def main_loop
		loop { main_loop_iter }
	end

	def startup
		# close old ports no longer in conf (close first to allow reuse)
		@ports.dup.each { |port|
			next if @conf.plines.find { |pline| port.pline == pline }
			port.cleanup
		}

		# open new ports from conf
		@conf.plines.each { |pline|
			next if @ports.find { |port| port.pline == pline }
			fd = TCPServer.open(pline[:host], pline[:port])
			puts "#{Time.now} listening on #{pline[:host]}:#{pline[:port]}#{' (ssl)' if pline[:ssl]}"
			@ports << Port.new(self, fd, pline)
		}

		@conf.clines.each { |c|
			next if not c[:port]
			next if @servers.find { |s| s.cline == c }
			Server.sconnect(self, c)
		}
		# opers will squit servers no longer needed
	end

	def main_loop_iter
		check_timeouts
		wait_sockets
	rescue
		puts "#{Time.now} ircd.mainiter #{$!.class} #{$!.message}", $!.backtrace, ''
		$stdout.flush
		sleep 0.4
	end

	def check_timeouts
		tnow = Time.now.to_f
		@last_tnow ||= tnow
		return if @last_tnow > tnow - 0.4
		@last_tnow = tnow

		servers.dup.each { |s|
			if s.last_pong < tnow - (@conf.ping_timeout * 2 + 10)
				s.send 'ERROR', ":Closing Link: (Ping timeout)" rescue nil
				s.cleanup
				next
			end
			if s.last_ping < tnow - @conf.ping_timeout * 2
				s.send 'PING', ":#{name}"
				s.last_ping = tnow
			end
		}

		@clines_timeout.each { |ct|
			c = ct[:cline]
			next if not c[:port]
			next if @servers.find { |s| s.cline == c }
			next if ct[:last_try_sconnect] > tnow - c[:delay]
			ct[:last_try_sconnect] = tnow
			Server.sconnect(self, c)
		}

		local_users.dup.each { |u|
			if u.last_pong < tnow - @conf.ping_timeout
				u.send 'ERROR', ":Closing Link: #{u.hostname} (Ping timeout)"
				u.cleanup ":#{u.fqdn} QUIT :Ping timeout"
				next
			end
			if u.last_ping < tnow - @conf.ping_timeout / 2
				u.send 'PING', ":#{name}"
				u.last_ping = tnow + rand
			end
		}

		pending.dup.each { |pend|
			if pend.last_pong < tnow - @conf.ping_timeout / 2
				if pend.cline
					send_global "No response from #{pend.cline[:name]} (#{pend.cline[:host]}), closing link"
				end
				pend.send 'ERROR', ':Closing Link: 0.0.0.0 (Ping timeout)'
				pend.cleanup
				next
			end
		}
	end

	def wait_sockets
		rs = rd_socks
		rd = rs.find_all { |fd| fd.respond_to?(:pending) and fd.pending > 0 }
		rd, wr = IO.select(rs, nil, nil, 2) if rd.empty?
		rd.to_a.each { |fd|
			fd_to_recv(fd).can_read
		}
	end

	# list of sockets we should select(rd)
	def rd_socks
		ports.map { |port| port.fd } +
		servers.map { |s| s.fd } +
		local_users_canread.map { |u| u.fd } +
		pending.map { |pend| pend.fd }
	end

	# fd => Client/Server/Port
	def fd_to_recv(fd)
		(ports + servers + local_users + pending).find { |o| fd == o.fd or fd == o.fd.to_io }	# SSL => no to_io
	end

	# read a line byte by byte
	def fd_gets(fd, maxlen=512)
		@fd_lines ||= {}

		if @fd_lines.length > 10
			tnow = Time.now.to_i
			@fd_lines.delete_if { |f, (t, l)| t < tnow - 5 }
		end

		if c = @fd_lines.delete(fd)
			l = c[1]
		else
			l = ''
		end

		while (fd.respond_to?(:pending) and fd.pending > 0) or IO.select([fd], nil, nil, 0)
			return if l.length > maxlen*8
			return if not c = fd.read(1)
			if c == "\n"
				l = l[0, maxlen].chomp
				puts "> #{l}" if $DEBUG
				return l
			end
			l << c
		end
		@fd_lines[fd] = [(tnow || Time.now.to_i), l]
		''
	rescue
		r = fd_to_recv(fd)
		puts "#{Time.now} ircd.fd_gets #{r.respond_to?(:fqdn) ? r.fqdn : r}  #{$!.class}  #{$!.message}", $!.backtrace, ''
		$stdout.flush
		nil
	end

	# ":abc d e f :g h"  =>  [":abc", "d", "e", "f", "g h"]
	def split_line(l)
		l = l.chomp
		lsplit = l.split
		return [] if lsplit.empty?
		if last = lsplit[1..-1].find { |e| e[0] == ?: }
			lsplit = l.split(/\s+/, lsplit[1..-1].index(last)+2)
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

	def self.run(conffile='conf', logfile=nil)
		if logfile
			$stdout.reopen File.open(logfile, 'a')
			$stderr.reopen $stdout
		end
		puts "#{Time.now} run"
		ircd = new(conffile)
		ircd.startup
		trap('HUP') { ircd.rehash }
		ircd.conf.logfile = logfile
		ircd.main_loop
	end

	def self.run_bg(conffile='conf', logfile='log')
		log = File.open(logfile, 'a')
		ircd = new(conffile)	# abort now if there is an error in the conf
		ircd.startup
		if pid = Process.fork
			puts "Running in background, pid #{pid}"
			return
		end

		$stdout.reopen log
		$stderr.reopen $stdout
		puts "#{Time.now} run_bg"
		trap('HUP') { ircd.rehash }
		ircd.conf.logfile = logfile
		ircd.main_loop
		exit!
	end
end

# set of configuration parameters
class Conf
	# our server name
	attr_accessor :network_name, :name, :descr
	# list of { :host => '1.2.3.4', :port => 6667, :ssl => true }
	attr_accessor :plines
	# list of { :nick => 'lol' (OPER command param), :mask => '*!blabla@*', :pass => '123$1azde2', :mode => 'oOaARD' }
	attr_accessor :olines
	# list of { :name => 'bob.com', :host => '1.2.3.4', :port => 42, :pass => 'secret', :rc4 => true, :zip => true }
	attr_accessor :clines

	attr_accessor :ping_timeout
	attr_accessor :motd_path
	attr_accessor :ssl_key_path, :ssl_cert_path
	attr_accessor :user_chan_limit	# max chan per user
	attr_accessor :max_chan_mode_cmd	# max chan mode change per /mode command
	attr_accessor :max_nickname_len
	attr_accessor :max_channame_len
	attr_accessor :logfile
	attr_accessor :whowas
	attr_accessor :cloak_users
	attr_accessor :user_pass	# required client PASS
	attr_accessor :misc

	def initialize
		@plines = []
		@olines = []
		@clines = []
		@misc = {}

		# config elements that have no corresponding line in the conf
		# edit this file to change values
		# if you change a value in your startup script with ircd.conf.bla = 42, this will be forgotten when rehashing !
		@motd_path = 'motd'
		@ping_timeout = 180
		@ssl_key_path = 'ssl_key.pem'
		@ssl_cert_path = 'ssl_cert.pem'
		@user_chan_limit = 50
		@max_chan_mode_cmd = 6
		@max_nickname_len = 32
		@max_channame_len = 50
		@whowas = { :maxlen => 5000, :maxdup => 9, :maxage => 3600*24*32 }
		#@cloak_users = true
	end

	def load(filename)
		File.read(filename).each_line { |l|
			l = l.strip
			case l.split(':', 2)[0]
			when 'N'; n, @network_name = l.split(':', 2)
			when 'M'; n, @name, @descr = l.split(':', 3)
			when 'P'; parse_p_line(l)
			when 'C'; parse_c_line(l)
			when 'O'; parse_o_line(l)
			when 'PASS'; @user_pass = l.split(':', 2)[1]
			when 'MISC'; k, v = l.split(':', 3)[1, 2] ; @misc[k.downcase] = v.strip
			when /^#/
			when nil
			else raise "Unknown configuration line #{l.inspect}"
			end
		}

		# network_name default to name tld
		@network_name ||= @name[/[^.]*\.[^.]*$/] || @name
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
		pline = {}
		fu = split_ipv6(l)
		fu.shift	# 'P'
		pline[:host] = fu.shift
		pline[:port] = fu.shift.to_i
		raise "P:host:port:opts" if pline[:port] == 0
		while e = fu.shift
			case e
			when 'SSL'; pline[:ssl] = true
			when /^key=(.*)/; pline[:ssl_key] = $1; File.open($1){}
			when /^cert=(.*)/; pline[:ssl_cert] = $1; File.open($1){}
			when '', nil
			else raise "P:host:port:[SSL[:key=foo.pem:cert=bar.pem]]"
			end
		end
		@plines << pline
	end

	# C:bob.srv.com:127.0.0.1:7001:RC4:ZIP:240	# active connection from us, delay = 240s
	# C:danny.ircd:127.0.0.2::RC4		# passive cx (listen only)
	def parse_c_line(l)
		c = {}
		fu = split_ipv6(l)
		fu.shift	# 'C'
		c[:name] = fu.shift
		c[:host] = fu.shift
		c[:port] = fu.shift.to_i
		c[:pass] = fu.shift

		if c[:port] == 0
			c.delete :port
		else
			c[:delay] = 240
		end

		while e = fu.shift
			case e
			when 'RC4'; c[:rc4] = true
			#when 'ZIP'; c[:zip] = true	# XXX unsupported
			when 'SSL'; c[:ssl] = true	# only used for outgoing cx ; TODO cert checks
			when /^\d+$/; c[:delay] = e.to_i
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
