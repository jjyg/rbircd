class User
	def handle_command(l)
		msg = "cmd_#{l[0].to_s.downcase}"
		if respond_to? msg
			__send__ msg, l
		else
			puts "unhandled user #{fqdn} #{l.inspect}"
   			sv_send 421, @nick, l[0], ':unknown command'
		end
	end

	def cmd_(l)
	end

	def cmd_ping(l)
		sv_send 'PONG', @ircd.name, ":#{l[1]}"
	end

	def cmd_pong(l)
		@last_pong = Time.now.to_f if l[1] == @ircd.name
	end

	def cmd_quit(l)
		send "ERROR :Closing Link: #{@ircd.name} (Quit: )"
		cleanup("Quit: #{l[1]}")
	end

	def cmd_privmsg(l)
		if not l[1]
			sv_send 411, @nick, ':No recipient given'
			return
		elsif not l[2]
			sv_send 412, @nick, ':No text to send'
			return
		end

		if l[1].include? ','
			l[1].split(',').each { |cn| cmd_privmsg([l[0], cn, l[2]]) }
			return
		end

		msg = ":#{fqdn} #{l[0]} #{l[1]} :#{l[2]}"

		if chan = @ircd.channel[l[1].downcase]
			# can send if: 
			# on chan or chan public, and
			if (chan.users.include?(self) or not chan.mode.include?('n')) and
			# chan not moderated & we're not banned (unless we're op/voice)
			   ((not chan.mode.include?('m') and
			     (not chan.bans.find { |b| @ircd.match_mask(b, fqdn) } or
			      chan.banexcept.find { |e| @ircd.match_mask(e, fqdn) })) or
			    (chan.ops+chan.voices).include?(self))
				@ircd.send_chan_butone(chan, self, msg)
			else
				sv_send 404, @nick, l[1], ':Cannot send to channel' if l[0].downcase != 'notice'
			end
		elsif usr = @ircd.user[l[1].downcase] and usr.kind_of?(User)
			usr.send msg
		else
			sv_send 401, @nick, l[1], ':No such nick/channel' if l[0].downcase != 'notice'
		end
	end

	def cmd_notice(l)
		cmd_privmsg(l)
	end

	def cmd_nick(l)
		if not l[1]
			sv_send 461, @nick, l[0], ':Not enough parameters'
			return
		end

		nick = l[1]
		# TODO mode #chan +m
		if not @ircd.check_nickname(nick)
			sv_send(432, @nick, nick, ':Bad nickname')
		elsif nick == @nick
		elsif @ircd.user[nick.downcase]
			sv_send(433, @nick, nick, ':Nickname is already in use')
		else
			@ircd.send_visible(self, ":#{fqdn} NICK :#{nick}")
			send ":#{fqdn} NICK :#{nick}"
			@ircd.user[nick.downcase] = @ircd.user.delete @nick.downcase
			@nick = nick
		end
	end

	def cmd_motd(l)
		sv_send 375, @nick, ":- #{@ircd.name} message of the day"
		sv_send 372, @nick, ":- #{Time.now.strftime('%d/%m/%Y %H:%M')}"
		File.read(@ircd.conf.motd_path).each_line { |l|
			sv_send 372, @nick, ":- #{l.chomp}"
		} rescue nil
		sv_send 376, @nick, ':End of /MOTD command'
	end

	def cmd_join(l)
		if not l[1]
			sv_send 461, @nick, l[0], ':Not enough parameters'
			return
		end

		if l[1] == '0'
			@ircd.channels.find_all { |c| c.users.include? self }.each { |c| cmd_part ['PART', c.name] }
			return
		end

		if l[1].include? ','
			l[1].split(',').zip(l[2].to_s.split(',')).each { |cn, ck| cmd_join([l[0], cn, ck]) }
			return
		end

		channame = l[1]

		if not @ircd.check_channame(channame)
			sv_send 403, @nick, channame, ':No such channel'
		elsif chan = @ircd.channel[channame.downcase]
			return if chan.users.include? self
			if chan.limit and chan.limit <= chan.users.length
				sv_send 471, @nick, channame, ':Cannot join chan (+l)'
			elsif chan.mode.include? 'i' and not chan.banexcept.find { |e| @ircd.match_mask(e, fqdn) } and not chan.invites.index(@nick)
				sv_send 473, @nick, channame, ':Cannot join chan (+i)'
			elsif chan.bans.find { |b| @ircd.match_mask(b, fqdn) } and not chan.banexcept.find { |e| @ircd.match_mask(e, fqdn) }
				sv_send 474, @nick, channame, ':Cannot join chan (+b)'
			elsif chan.key and l[2] != chan.key
				sv_send 475, @nick, channame, ':Cannot join chan (+k)'
			else
				chan.users << self
				@ircd.send_chan(chan, ":#{fqdn} JOIN :#{channame}")
				cmd_topic ['TOPIC', channame] if chan.topic
				cmd_names ['NAMES', channame]
			end
		else
			chan = Channel.new(channame)
			chan.users << self
			chan.ops << self
			@ircd.channel[channame.downcase] = chan
			@ircd.send_chan(chan, ":#{fqdn} JOIN :#{channame}")
			cmd_names ['NAMES', channame]
		end
	end

	def cmd_part(l)
		if not l[1]
			sv_send 461, @nick, l[0], ':Not enough parameters'
			return
		end

		if l[1].include? ','
			l[1].split(',').each { |cn| cmd_part([l[0], cn]) }
			return
		end

		channame = l[1]
		if not chan = @ircd.channel[channame.downcase]
			sv_send 403, @nick, channame, ':No such channel'
		elsif not chan.users.include? self
			sv_send 442, @nick, channame, ':You are not on than channel'
		else
			@ircd.send_chan(chan, ":#{fqdn} PART #{channame}")
			chan.ops.delete self
			chan.voices.delete self
			chan.users.delete self
			@ircd.channel.delete channame.downcase if chan.users.empty?
		end
	end

	def cmd_topic(l)
		if not l[1]
			sv_send 461, @nick, l[0], ':Not enough parameters'
			return
		end

		channame = l[1]
		if not chan = @ircd.channel[channame.downcase]
			sv_send 403, @nick, channame, ':No such channel'
		elsif not chan.users.include? self
			sv_send 442, @nick, channame, ':You are not on than channel'
		elsif l[2]
			# set topic
			if chan.mode.include? 't' and not chan.ops.include? self
				sv_send 482, @nick, channame, ':You are not channel operator'
			else
				if l[2].empty?
					chan.topic = nil
				else
					chan.topic = l[2]
					chan.topicwho = @nick
					chan.topicwhen = Time.now.to_i
				end

				@ircd.send_chan(chan, ":#{fqdn} TOPIC #{channame} :#{l[2]}")
			end
		else
			# get topic
			if not chan.topic
				sv_send 331, @nick, channame, ":No topic is set"
			else
				sv_send 332, @nick, channame, ":#{chan.topic}"
				sv_send 333, @nick, channame, chan.topicwho, chan.topicwhen
			end
		end
	end

	def cmd_names(l)
		if not l[1]
			sv_send 461, @nick, l[0], ':Not enough parameters'
			return
		end

		if l[1].include? ','
			l[1].split(',').each { |cn| cmd_names([l[0], cn]) }
			return
		end

		channame = l[1]
		if chan = @ircd.channel[channame.downcase] and chan.users.include?(self)
			# XXX what is [=*@] before channame ?
			lst = []
			chan.users.each { |u|
				lst << ((chan.ops.include?(u) ? '@' : chan.voices.include?(u) ? '+' : '') + u.nick)
				if lst.join.length > 200
					sv_send 353, @nick, '=', channame, ":#{lst.join(' ')}"
					lst = []
				end
			}
			sv_send 353, @nick, '=', channame, ":#{lst.join(' ')}" if not lst.empty?
		end
		sv_send 366, @nick, channame, ':End of /NAMES list'
	end

	#cmd_kick
	#cmd_mode
	#cmd_list
	#cmd_who
	#cmd_whois
	#cmd_invite
	#cmd_oper
	#cmd_kill
	#cmd_samode
	#cmd_squit

	def send_welcome
		sv_send '001', @nick, ":Welcome to the RB IRC Network #{fqdn}"
		cmd_motd([])
		send ":#{fqdn}", 'MODE', @nick, ':+i'
	end
end

class Server
	def handle_command(l, from)
		msg = "cmd_#{l[0].to_s.downcase}"
		if respond_to? msg
			__send__ msg, l
		else
			puts "unhandled server #{l.inspect}"
		end
	end

	#cmd_privmsg
	#cmd_notice
	#cmd_join
	#cmd_nick
	#cmd_ping
	#cmd_quit
	#cmd_part
	#cmd_kick
	#cmd_mode
	#cmd_oper
	#cmd_topic
end

class Pending
	def handle_command(l)
		msg = "cmd_#{l[0].to_s.downcase}"
		if respond_to? msg
			__send__ msg, l
		else
			puts "unhandled pending #{l.inspect}"
		end
	end

	def cmd_(l)
	end

	def cmd_user(l)
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
	end

	def cmd_pass(l)
	  	@pass = l[1]
	end

	def cmd_nick(l)
		nick = l[1]
		if not @ircd.check_nickname(nick)
			sv_send(432, @nick, nick, ':bad nickname')
		elsif nick == @nick
		elsif @ircd.user[nick.downcase]
			sv_send(433, @nick || '*', nick, ':nickname is already in use')
		else
			@ircd.user.delete @nick.downcase if @nick
			@nick = nick
			@ircd.user[@nick.downcase] = self
			check_conn
		end
	end

	def cmd_quit(l)
		send "ERROR :Closing Link: 0.0.0.0 (Quit: )"
		cleanup
	end

	#cmd_server

	def check_conn
		return if not @user or not @nick
		wait_hostname
		wait_ident
		clt = User.new(@ircd, @nick, @ident || "~#{@user[1]}", @hostname, @fd)
		clt.descr = @user[4]
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
