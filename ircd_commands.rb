class User
	def handle_command(l)
		p l
		case l[0].to_s.downcase
		#when 'privmsg'
		#when 'join'
		when 'nick'
			nick = l[1]
			if not @ircd.check_nickname(nick)
				sv_send(432, @nick, nick, ':bad nickname')
			elsif nick == @nick
			elsif @ircd.user[nick]
				sv_send(433, @nick, nick, ':nickname is already in use')
			else
				@ircd.send_visible(self, ":#{fqdn} NICK :#{nick}")
				send ":#{fqdn} NICK :#{nick}"
				@ircd.user[nick] = @ircd.user.delete @nick
				@nick = nick
			end
		when 'ping'
			sv_send 'PONG', @ircd.name, ":#{l[1]}"
		when 'pong'
			@last_pong = Time.now.to_f if l[1] == @ircd.name
		when 'quit'
			send "ERROR :Closing Link: 0.0.0.0 (Quit: )"
			cleanup(l[1])
		#when 'part'
		#when 'kick'
		#when 'mode'
		#when 'oper'
		#when 'topic'
		#when 'kill'
		#when 'list'
		#when 'who'
		#when 'whois'
		#when 'names'
		#when 'samode'
		when 'motd'
			send_motd
		when ''
		else puts "unhandled user command #{l.inspect}"
		     sv_send 'WTF', @nick, ':lolz', l.inspect
		end
	end

	def send_welcome
		sv_send '001', @nick, ":Welcome to the RB IRC Network #{fqdn}"
		send_motd
	end

	def send_motd
		sv_send 375, @nick, ":- #{@ircd.name} message of the day"
		sv_send 372, @nick, ":- #{Time.now.strftime('%d/%m/%Y %H:%M')}"
		File.read(@ircd.conf.motd_path).each_line { |l|
			sv_send 372, @nick, ":- #{l.chomp}"
		} rescue nil
		sv_send 376, @nick, ':End of /MOTD command'
	end
end

class Server
	def handle_command(l, from)
		case l[0].to_s.downcase
		when 'privmsg'
		when 'join'
		when 'nick'
		when 'ping'
		when 'quit'
		when 'part'
		when 'kick'
		when 'mode'
		when 'oper'
		when 'topic'
		else puts "unhandled server command #{l.inspect}"
		end
	end
end

class Pending
	# TODO async dns/ident
	def handle_command(l)
		case l[0].to_s.downcase
		when 'user'
			if l.length < 5
				sv_send(461, @nick, 'USER', ':Not enough parameters')
			else
				@user = l
				if not @hostname
					retrieve_hostname
					retrieve_ident
				end
				check_conn
			end
		when 'pass'
	  		@pass = l[1]
		when 'nick'
			nick = l[1]
			if not @ircd.check_nickname(nick)
				sv_send(432, @nick, nick, ':bad nickname')
			elsif nick == @nick
			elsif @ircd.user[nick]
				sv_send(433, @nick || '*', nick, ':nickname is already in use')
			else
				@ircd.user.delete @nick
				@nick = nick
				@ircd.user[@nick] = self
				check_conn
			end
		when 'quit'
			send "ERROR :Closing Link: 0.0.0.0 (Quit: )"
			cleanup
		#when 'server'
		when ''
		else puts "unhandled pending command #{l.inspect}"
		end
	end

	def check_conn
		return if not @user or not @nick
		wait_hostname
		wait_ident
		clt = User.new(@ircd, @nick, @ident || "~#{@user[1]}", @hostname, @fd)
		clt.descr = @user[4]
		@ircd.pending.delete self
		@ircd.user[@nick] = clt
		clt.send_welcome
	end

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
