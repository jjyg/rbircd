class User
	def handle_command(l)
		msg = "cmd_#{l[0].to_s.downcase}"
		if respond_to? msg
			@last_pong = Time.now.to_f
			__send__ msg, l
		else
			puts "unhandled user #{fqdn} #{l.inspect}"
   			sv_send 421, @nick, l[0], ':unknown command'
		end
	end

	# warn user & return true if there are less than nr params
	def chk_parm(l, nr)
		if not l[nr]
			sv_send 461, @nick, l[0], ':Not enough parameters'
			return true
		end
	end

	def cmd_(l)	# user sends "\n"
	end

	def cmd_ping(l)
		if not l[1]
			sv_send 409, @nick, ':No origin specified'
		else
			sv_send 'PONG', @ircd.name, ":#{l[1]}"
		end
	end

	def cmd_pong(l)
		if not l[1]
			sv_send 409, @nick, ':No origin specified'
		else
			# @last_pong already updated
		end
	end

	def cmd_quit(l)
		send "ERROR :Closing Link: #{@ircd.name} (Quit: )"
		cleanup ":#{fqdn} QUIT :Quit: #{l[1]}"
	end

	def cmd_privmsg(l, send_err=true)
		if not l[1]
			sv_send 411, @nick, ':No recipient given'
			return
		elsif not l[2]
			sv_send 412, @nick, ':No text to send'
			return
		end

		@last_active = Time.now.to_f

		if l[1].include? ','
			l[1].split(',').each { |cn| cmd_privmsg([l[0], cn, l[2]], send_err) }
			return
		end

		msg = ":#{fqdn} #{l[0]} #{l[1]} :#{l[2]}"

		if chan = @ircd.find_chan(l[1]) or (l[1][0] == ?@ and chan = @ircd.find_chan(l[1][1..-1]))
			# can send if: 
			# on chan or chan public, and
			if (chan.users.include?(self) or not chan.mode.include?('n')) and
			# chan not moderated & we're not banned (unless we're op/voice)
			   ((not chan.mode.include?('m') and not chan.banned?(self)) or
			    chan.op?(self) or chan.voice?(self))
				if chan.mode.include? 'c' and l[2].index(3.chr)
					sv_send 408, @nick, l[1], ":You cannot use colors on this channel. Not sent: #{l[2]}" if send_err
				elsif l[1][0] == ?@
					@ircd.send_chan_op_butone(chan, self, msg)
				else
					@ircd.send_chan_butone(chan, self, msg)
				end
			else
				sv_send 404, @nick, l[1], ':Cannot send to channel' if send_err
			end
		elsif usr = @ircd.find_user(l[1]) and usr.kind_of?(User)
			msg = ":#{@nick} #{l[0]} #{l[1]} :#{l[2]}" if not usr.local?
			usr.send msg
		else
			sv_send 401, @nick, l[1], ':No such nick/channel' if send_err
		end
	end

	def cmd_notice(l)
		cmd_privmsg(l, false)
	end

	def cmd_nick(l)
		return if chk_parm(l, 1)

		nick = l[1]
		if not @ircd.check_nickname(nick)
			sv_send 432, @nick, nick, ':Bad nickname'
		elsif nick == @nick
		elsif @ircd.find_user(nick)
			sv_send 433, @nick, nick, ':Nickname is already in use'
		elsif cn = chans.find { |c| (c.banned?(self) or c.mode.include?('m')) and not (c.op?(self) or c.voice?(self)) }
			sv_send 437, @nick, cn.name, ':Cannot change nickname while banned or moderated on channel'
		else
			@ts = Time.now.to_i
			@ircd.servers.each { |s| s.send_nick(self, nick) }
			@ircd.send_visible_local(self, ":#{fqdn} NICK :#{nick}")
			send ":#{fqdn} NICK :#{nick}"
			@ircd.del_user(self)
			@nick = nick
			@ircd.add_user(self)
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
		return if chk_parm(l, 1)

		if l[1] == '0'
			chans.each { |c| cmd_part ['PART', c.name] }
			return
		end

		if l[1].include? ','
			l[1].split(',').zip(l[2].to_s.split(',')).each { |cn, ck| cmd_join([l[0], cn, ck]) }
			return
		end

		channame = l[1]

		if not @ircd.check_channame(channame)
			sv_send 403, @nick, channame, ':No such channel'
		elsif chan = @ircd.find_chan(channame)
			return if chan.users.include? self
			inv = chan.invites.find { |i| i[:user] == self }
			if chans.length >= @ircd.conf.user_chan_limit
				sv_send 405, @nick, channame, ':You have joined too many channels'
			elsif not inv and chan.limit and chan.limit <= chan.users.length
				sv_send 471, @nick, channame, ':Cannot join chan (+l)'
			elsif not inv and chan.mode.include? 'i' and
					not chan.banexcept.find { |e| @ircd.match_mask(e[:mask], fqdn) }
				sv_send 473, @nick, channame, ':Cannot join chan (+i)'
			elsif not inv and chan.banned?(self)
				sv_send 474, @nick, channame, ':Cannot join chan (+b)'
			elsif not inv and chan.key and l[2] != chan.key
				sv_send 475, @nick, channame, ':Cannot join chan (+k)'
			else
				chan.invites.delete inv if inv
				# XXX chan.ts = Time.now.to_i
				chan.users << self
				@ircd.servers.each { |s| s.send_join(self, chan) } if channame[0] != ?&
				@ircd.send_chan_local(chan, ":#{fqdn} JOIN :#{channame}")
				cmd_topic ['TOPIC', channame] if chan.topic
				cmd_names ['NAMES', channame]
			end
		else
			if chans.length >= @ircd.conf.user_chan_limit
				sv_send 405, @nick, channame, ':You have joined too many channels'
			else
				chan = Channel.new(@ircd, channame)
				chan.ts = Time.now.to_i
				chan.users << self
				chan.ops << self
				@ircd.add_chan chan
				@ircd.servers.each { |s| s.send_join(self, chan) } if channame[0] != ?&
				@ircd.send_chan_local(chan, ":#{fqdn} JOIN :#{channame}")
				cmd_names ['NAMES', channame]
			end
		end
	end

	def cmd_part(l)
		return if chk_parm(l, 1)

		if l[1].include? ','
			l[1].split(',').each { |cn| cmd_part([l[0], cn, l[2]]) }
			return
		end

		channame = l[1]
		if not chan = @ircd.find_chan(channame)
			sv_send 403, @nick, channame, ':No such channel'
		elsif not chan.users.include? self
			sv_send 442, @nick, channame, ':You are not on than channel'
		else
			@ircd.send_chan(chan, ":#{fqdn} PART #{channame} :#{l[2]}")
			chan.ops.delete self
			chan.voices.delete self
			chan.users.delete self
			@ircd.del_chan chan if chan.users.empty?
		end
	end

	def cmd_topic(l)
		return if chk_parm(l, 1)

		channame = l[1]
		if not chan = @ircd.find_chan(channame)
			sv_send 403, @nick, channame, ':No such channel'
		elsif not chan.users.include? self
			sv_send 442, @nick, channame, ':You are not on than channel'
		elsif l[2]
			# set topic
			if chan.mode.include? 't' and not chan.op?(self)
				sv_send 482, @nick, channame, ':You are not channel operator'
			else
				if l[2].empty?
					chan.topic = nil
				else
					chan.topic = l[2]
					chan.topicwho = @nick
					chan.topicwhen = Time.now.to_i
				end

				@ircd.servers.each { |s| s.send_topic(chan, self) } if chan.name[0] != ?&
				@ircd.send_chan_local(chan, ":#{fqdn} TOPIC #{channame} :#{l[2]}")
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
		if l[1] and l[1].include? ','
			l[1].split(',').each { |cn| cmd_names [l[0], cn] }
			return
		end

		channame = l[1]
		if channame and chan = @ircd.find_chan(channame) and chan.users.include?(self)
			# XXX what is [=*@] before channame ?
			lst = []
			chan.users.each { |u|
				lst << ((chan.op?(u) ? '@' : chan.voice?(u) ? '+' : '') + u.nick)
				if lst.join.length > 200
					sv_send 353, @nick, '=', channame, ":#{lst.join(' ')}"
					lst = []
				end
			}
			sv_send 353, @nick, '=', channame, ":#{lst.join(' ')}" if not lst.empty?
		end
		sv_send 366, @nick, channame, ':End of /NAMES list'
	end

	def cmd_mode(l)
		return if chk_parm(l, 1)

		if chan = @ircd.find_chan(l[1])
			if l[2]
				if not chan.op? self
					do_cmd_mode_chan_nopriv(chan, l)
				else
					do_cmd_mode_chan(chan, l)
				end
			else
				do_cmd_mode_chan_dump(chan)
			end
		elsif user = @ircd.find_user(l[1])
			if user != self
				sv_send 502, @nick, ':Cannot change mode for other users'
			else
				if l[2]
					do_cmd_mode_user(l)
				else
					do_cmd_mode_user_dump
				end
			end
		else
			sv_send 403, @nick, l[1], ':No such channel'
		end
	end

	def do_cmd_mode_chan_nopriv(chan, l)
		# on any mode, send "reserved to ops", except list ban/excepts
		nopriv = false
		params = l[3..-1]
		minus = false
		l[2].split(//).each { |m|
			case m
			when '+', '-'; minus = (m == '-') ; next
			when 'b', 'e'	# bans/excepts
				if not parm = params.shift
					list = (m == 'b' ? chan.bans : chan.banexcept)
					list.each { |b| sv_send 367, @nick, chan.name, b[:mask], b[:who], b[:when] }
					sv_send 368, @nick, chan.name, ":End of channel #{m == 'b' ? 'ban' : 'except'} list"
					next
				end
			when 'k', 'o', 'v'; params.shift
			when 'l'; params.shift if not minus
			end
			nopriv = true
		}
		sv_send 482, @nick, l[1], ':You are not channel operator' if nopriv
	end

	def do_cmd_mode_chan(chan, l)
		params = l[3..-1]
		done = ''
		done_params = []
		done_sign = 'z'
		minus = false
		mode_count = 0

		l[2].split(//).each { |m|
			break if mode_count >= @ircd.conf.max_chan_mode_cmd
			parm = nil
			case m
			when '+'; minus = false; next
			when '-'; minus = true;  next
			when 'b', 'e'	# bans/excepts
				list = (m == 'b' ? chan.bans : chan.banexcept)
				if not parm = params.shift
					list.each { |b| sv_send 367, @nick, chan.name, b[:mask], b[:who], b[:when] }
					sv_send 368, @nick, chan.name, ":End of channel #{m == 'b' ? 'ban' : 'except'} list"
					next
				end
				parm = parm + '!*' if not parm.include?('!') and not parm.include?('@')
				parm = '*!*' + parm if parm[0] == ?@ and not parm[1..-1].include?('@')
				parm = '*!' + parm if not parm.include?('!')
				parm = parm + '@*' if not parm.include?('@')
				if minus
					list.delete_if { |b| @ircd.downcase(b[:mask]) == @ircd.downcase(parm) }
				elsif not list.find { |b| @ircd.downcase(b[:mask]) == @ircd.downcase(parm) }
					list << { :mask => parm, :who => fqdn, :when => Time.now.to_i }
				else next
				end
			when 'k'	# key
				next if not parm = params.shift
				if minus; chan.key = nil	# dont check parm
				else chan.key = parm
				end
			when 'l'	# limit
				if minus; chan.limit = nil
				elsif parm = params.shift
					parm = parm.to_i
					next if parm == 0
					chan.limit = parm
				else
					sv_send 461, @nick, 'MODE', '+l', ':Not enough parameters'
					next
				end
			when 'o', 'v'	# ops/voices
				list = (m == 'o' ? chan.ops : chan.voices)
				next if not parm = params.shift
				if not u = chan.users.find { |u| @ircd.downcase(u.nick) == @ircd.downcase(parm) }
					sv_send 401, @nick, parm, ':No such nick/channel' if not @ircd.find_user(parm)
					sv_send 441, @nick, parm, chan.name, ':They are not on that channel'
					next
				end
				if minus
					list.delete u
				elsif not list.include?(u)
					list << u
				end
			when 'c', 'i', 'm', 'n', 'p', 's', 't'
				if minus
					chan.mode.delete! m
				elsif not chan.mode.include?(m)
					chan.mode << m
				end
			else
				sv_send 472, @nick, m, ':Unknown MODE flag'
				next
			end

			mode_count += 1
			if minus
				done << '-' if done_sign != '-'
				done_sign = '-'
				done << m
				done_params << parm if parm
			else
				done << '+' if done_sign != '+'
				done_sign = '+'
				done << m
				done_params << parm if parm
			end
		}

		if not done.empty?
			donep = done_params.map { |p| ' ' + p }.join
			@ircd.servers.each { |s| s.send_chanmode(self, chan, "#{done}#{donep}") } if chan.name[0] != ?&
			@ircd.send_chan_local(chan, ":#{fqdn} MODE #{chan.name} :#{done}#{donep}")

			"#{chan.name} #{done}#{donep}"	# return value, used by samode
		end
	end

	def do_cmd_mode_chan_dump(chan)
		params = []
		modestr = '+' + chan.mode
		if chan.limit
			modestr << 'l'
			params << chan.limit
		end
		if chan.key
			modestr << 'k'
			params << chan.key
		end

		if chan.users.include? self
			sv_send 324, @nick, chan.name, modestr, params.join(' ')
		else
			sv_send 324, @nick, chan.name, modestr
		end
	end

	def do_cmd_mode_user(l)
		done = ''
		done_sign = 'z'
		minus = false
		did_warn_invalid = false
		l[2].split(//).each { |m|
			case m
			when '+'; minus = false; next
			when '-'; minus = true;  next
			when 'i', 'g', 'w'	# normal modes
				# i invisible - no effects
				# g global - receive global notices
				# w wallops - receive wallops notices
			when 'o', 'O'	# oper modes - can set only if oper
				# o globop - operator
				# O locop - same as o
				next if not minus and not @mode.include? 'o'
			when 'S'	# frozen modes
				# S connected through SSL
				next
			else
				sv_send 501, @nick, ':Unknown MODE flag' if not did_warn_invalid
				did_warn_invalid = true
				next
			end

			if minus and @mode.include? m
				@mode.delete! m
				done << '-' if done_sign != '-'
				done_sign = '-'
				done << m
			elsif not minus and not @mode.include?(m)
				@mode << m
				done << '+' if done_sign != '+'
				done_sign = '+'
				done << m
			end
		}

		if not done.empty?
			msg = ":#{@nick} MODE #@nick :#{done}"
			send msg
			@ircd.send_servers msg
		end
	end

	def do_cmd_mode_user_dump
		sv_send 221, @nick, "+#@mode"
	end

	def cmd_kick(l)
		return if chk_parm(l, 2)

		if l[1].include? ','
			l[1].split(',').each { |cn| cmd_kick([l[0], cn, l[2]]) }
			return
		end

		channame = l[1]
		if not chan = @ircd.find_chan(channame)
			sv_send 403, @nick, channame, ':No such channel'
		elsif not chan.op? self
			sv_send 482, @nick, l[1], ':You are not channel operator'
		else
			l[2].split(',').each { |nick|
				if not u = @ircd.find_user(nick)
					sv_send 401, @nick, nick, ':No such nick/channel'
				elsif not chan.users.include? u
					sv_send 441, @nick, nick, channame, ':They are not on that channel'
				else
					@ircd.send_chan(chan, ":#{fqdn} KICK #{channame} #{nick} :#{l[3] || @nick}")
					chan.ops.delete u
					chan.voices.delete u
					chan.users.delete u
					@ircd.del_chan chan if chan.users.empty?
				end
			}
		end
	end

	def cmd_list(l)
		sv_send 321, @nick, 'Channel', ':Users'
		(l[1] ? [@ircd.find_chan(l[1])].compact : @ircd.chans).each { |chan|
			if !(chan.mode.include?('p') or chan.mode.include?('s')) or chan.users.include?(self) or @mode.include?('o')
				sv_send 322, @nick, chan.name, chan.users.length, ":#{chan.topic}"
			end
		}
		sv_send 323, @nick, ':End of /LIST command'
	end

	def cmd_away(l)
		@ircd.send_servers ":#@nick AWAY :#{l[1]}"
		if l[1] and not l[1].empty?
			@away = l[1]
			sv_send 306, @nick, ':You have been marked as away'
		else
			@away = nil
			sv_send 305, @nick, ':You are no longer marked as being away'
		end
	end

	def cmd_whois(l)
		if not l[1]
			sv_send 431, @nick, ':No nickname given'
			return
		end

		if l[2]
			nicklist = l[2]
			srvname = l[1]
			if srvname == @ircd.name
			elsif srv = @ircd.servers.find { |s| s.name == srvname }
				srv.send ":#@nick", 'WHOIS', l[1], l[2]
				return
			elsif usr = @ircd.find_user(srvname)
				if not usr.local?
					srv = usr.from_server
					srv.send ":#@nick", 'WHOIS', l[1], l[2]
					return
				end
			else
				sv_send 402, @nick, srvname, ':No such server'
				return
			end
		else
			nicklist = l[1]
		end

		fn = nil
		nicklist.split(',').each { |nick|
			fn ||= nick
			if u = @ircd.find_user(nick)
				sv_send 311, @nick, u.nick, u.ident, u.hostname, '*', ":#{u.descr}"
				clist = u.chans.find_all { |c| !(c.mode.include?('p') or c.mode.include?('s')) or c.users.include?(self) or @mode.include?('o') }
				clist = clist.map { |c| (c.op?(u) ? '@' : c.voice?(u) ? '+' : '') + c.name }
				sv_send 319, @nick, u.nick, ":#{clist.join(' ')}" if not clist.empty?
				sv_send 312, @nick, u.nick, u.servername, ":#{u.local? ? @ircd.descr : u.from_server.descr}"
				sv_send 301, @nick, u.nick, ":#{u.away}" if u.away
				sv_send 307, @nick, u.nick, ':has identified for this nick' if false
				sv_send 313, @nick, u.nick, ':is an IRC Operator - Service Administrator' if u.mode.include?('o')
				sv_send 275, @nick, u.nick, ':is using a secure connection (SSL)' if u.mode.include?('S')
				sv_send 317, @nick, u.nick, (Time.now - u.last_active).to_i, u.connect_time.to_i, ':seconds idle, signon time' if u.local?
			else
				sv_send 401, @nick, nick, ':No such nick/channel'
			end
		}
		sv_send 318, @nick, fn, ':End of /WHOIS command'
	end

	def cmd_invite(l)
		return if chk_parm(l, 2)

		nick = l[1]
		channame = l[2]

		if not u = @ircd.find_user(nick)
			sv_send 401, @nick, nick, ':No such nick/channel'
			return
		end

		if not chan = @ircd.find_chan(channame)
		elsif not chan.users.include?(self)
			sv_send 442, @nick, channame, ':You are not on that channel'
		elsif not chan.op?(self)
			sv_send 482, @nick, channame, ':You are not channel operator'
		elsif chan.users.include?(u)
			sv_send 443, @nick, nick, channame, ':is already on channel'
		else
			chan.invites << { :user => u, :who => fqdn, :when => Time.now.to_i } if not chan.invites.find { |i| i[:user] == u }
			msg = "INVITE #{nick} :#{channame}"
			u.send ":#{fqdn} #{msg}" if u.local?
			@ircd.send_servers "#@nick #{msg}"
			cmd_notice ['NOTICE', "@#{channame}", "#{nick} invited #{u.nick} into channel #{channame}"]
		end
	end

	def cmd_who(l)
		return if chk_parm(l, 1)

		if l[2]
			conds = []
			parms = l[2..-1]
			minus = '+'
			l[1].split(//).each { |m|
				case m
				when '+'; minus='+'
				when '-'; minus='-'
				when 'a'; conds << [minus, m]
				when 'c', 'g', 'h', 'i', 'm', 'n', 's', 'u'
					if parms.empty? or (minus == '-' and m == 'c')
						sv_send 522, @nick, ':/WHO bad syntax'
						return
					end
					conds << [minus, m, parms.shift]
				else
					sv_send 522, @nick, ':/WHO bad syntax'
					return
				end
			}
		else
			conds = [['+', 'c', l[1]]]
		end

		if not channame = conds.map { |cd| cd[2] if cd[1] == 'c' }.compact.last
			sv_send 522, @nick, ':/WHO bad syntax'
			return
		end

		if not chan = @ircd.find_chan(channame)
			sv_send 403, @nick, l[1], ':No such channel'
			return
		end

		list = chan.users
		list = [] if (chan.mode.include?('p') or chan.mode.include?('s')) and not chan.users.include?(self) and not @mode.include?('o')

		conds.each { |cd|
			arg = cd[2]
			sublist = case cd[1]
			when 'c'; next
			when 'a'; list.find_all { |u| u.away }
			when 'g'; list.find_all { |u| @ircd.match_mask(arg, u.descr) }
			when 'h'; list.find_all { |u| @ircd.match_mask(arg, u.hostname) }
			when 'i'; list.find_all { |u| @ircd.match_mask(arg, u.hostname) }
			when 'm'
				list.find_all { |u|
					a = arg.split(//)
					a &= %w[o O a A S] if not @mode.include?('o')
					(a & u.modes.split(//)).sort == a.sort
				}
			when 'n'; list.find_all { |u| @ircd.match_mask(arg, u.nick) }
			when 's'
				list.find_all { |u|
					@incd.match_mask(arg, u.servername)
				}
			when 'u'; list.find_all { |u| @ircd.match_mask(arg, u.ident) }
			end

			if cd[0] == '+'
				list &= sublist
			else
				list -= sublist
			end
		}

		list.each { |u|
			flags = '' 
			flags << 'H'	# XXX ?
			flags << '+' if chan.voice?(u)
			flags << '@' if chan.op?(u)
			sv_send 352, @nick, channame, u.ident, u.hostname, u.servername, u.nick, flags, ":#{u.local? ? 0 : 1} #{u.descr}"
		}

		sv_send 315, @nick, l, ':End of /WHO command'
	end

	def cmd_links(l)
		# TODO further
		sv_send 364, @nick, @ircd.name, @ircd.name, ":0 #{@ircd.descr}"
		@ircd.servers.each { |s|
			sv_send 364, @nick, s.name, @ircd.name, ":1 #{s.descr}"
		}
		sv_send 356, @nick, '*', ':End of /LINKS command'
	end

	def cmd_wallops(l)
		return if not chk_parm(l, 1)

		@ircd.send_wallops(":#{fqdn} WALLOPS :#{l[1]}")
	end

	def cmd_oper(l)
		return if chk_parm(l, 2)

		id = l[1]
		pass = l[2]

		@ircd.conf.olines.each { |ol|
			next if ol[:nick] != id
			next if not @ircd.match_mask(ol[:mask], fqdn)
			next if not @ircd.check_oper_pass(pass, ol[:pass])

			@ircd.send_global "#{fqdn} is now operator (O)"
			newmodes = (ol[:mode].split(//) - @mode.split(//)).join
			if not newmodes.empty?
				@mode << newmodes
				msg = ":#{@nick} MODE #@nick :+#{newmodes}"
				send msg
				@ircd.send_servers msg
			end
			sv_send 381, @nick, ':You are now an IRC Operator'
			return
		}

		@ircd.send_global "Failed OPER attempt by #{fqdn}"
		sv_send 42, @nick, ':No O-lines for your host'
	end

	def chk_oper(l, mode='o')
		if not @mode.include? mode
			sv_send 481, @nick, ':Permission denied, you do not have correct operator privileges'
			return true
		end
	end

	def cmd_kill(l)
		return if chk_oper(l)

		if not u = @ircd.find_user(l[1])
			sv_send 401, @nick, l[1], ':No such nick/channel'
		else
			reason = l[2] || @nick
			@ircd.send_servers ":#@nick KILL #{l[1]} :irc!#{@ircd.name}!#{u.nick} (#{reason})"
			if u.local?
				u.send "ERROR :Closing Link: #{@ircd.name} #{l[1]} (KILL by #@nick (#{reason}))"
				u.cleanup ":#{fqdn} KILL #{l[1]} :irc!#{@ircd.name}!#{u.nick} (#{reason})"	# XXX path..
			end
			@ircd.send_global "#@nick used KILL #{u.nick} (#{reason})"
		end
	end

	def cmd_samode(l)
		return if chk_oper(l)
		return if not l[2] or not chan = @ircd.find_chan(l[1])
		if ans = do_cmd_mode_chan(chan, l)
			@ircd.send_global "#@nick used SAMODE #{ans}"
		end
	end

	def cmd_rehash(l)
		return if chk_oper(l)
		sv_send 382, @nick, @ircd.conffile, ':Rehashing'
		@ircd.send_global "#@nick is rehashing server config while whistling innocently"
		@ircd.rehash
	end

	def cmd_connect(l)
		return if chk_oper(l)
		return if chk_parm(l, 1)

		n = @ircd.downcase(l[1])
		cline = @ircd.clines.find { |c| [c[:name], c[:host], "#{c[:host]}:#{c[:port]}"].find { |ce| @ircd.downcase(ce) == n } }
		if not cline
			sv_send 'NOTICE', @nick, ":No C-line for #{l[1]}"
			return
		end

		if l[2]
			cline = cline.dup
			h, p = @icrd.conf.split_ipv6(l[2])
			cline[:host] = h
			cline[:port] = p if p
		end
		Server.sconnect(@ircd, cline)
	end

	def cmd_squit(l)
		return if chk_oper(l)
		return if chk_param(l, 1)

		# TODO remote squit
		serv = @ircd.servers.find { |s| @ircd.downcase(s.name) == @ircd.downcase(l[1]) }
		if not serv
			sv_send 'NOTICE', @nick, ":No such server #{l[1]}"
			return
		end

		@ircd.global "#@nick SQUIT #{l[1]}"
		serv.cleanup
	end
end

class Server
	def handle_command(l, from)
		msg = "cmd_#{l[0].to_s.downcase}"
		if respond_to? msg
			@last_pong = Time.now.to_f
			__send__ msg, l, from
		elsif l[0] =~ /^\d+$/ and l[1] and u = @ircd.find_user(l[1])
			# whois response etc
			if u.local?
				u.send unsplit(l, from, true)
			else
				u.from_server.send unsplit(l, from)
			end
		else
			puts "unhandled server #{l.inspect}"
		end
	end

	# nick, user, host = split_nih("nico!tesla@volt.ru")
	def split_nih(fqdn)
		fqdn.split(/[!@]/)
	end

	# retrieve the TS shifted to match the peer delta
	def cur_ts(time = Time.now.to_i)
		Time.now.to_i - @ts_delta
	end

	# send nick change notification to peer - u = old user, ts = time of nick change
	def send_nick(user, newnick)
		if @ts_delta
			send ":#{user.nick}", 'NICK', newnick, ":#{cur_ts(user.ts)}"
		else
			send ":#{user.nick}", 'NICK', newnick
		end
	end

	def send_chanmode(user, chan, model)
		send ":#{user.nick} MODE #{chan.name} #{0} #{model}"
	end

	# send a client join channel notification
	def send_join(user, chan)
		if @ts_delta
			# XXX which ts ?
			pfx = ''
			pfx << '@' if chan.op?(user)
			pfx << '+' if chan.voice?(user)
			if pfx.empty?
				send ":#{user.nick}", 'SJOIN', cur_ts(chan.ts), chan.name
			else
				sv_send 'SJOIN', cur_ts(chan.ts), chan.name, '+', ":#{pfx}#{user.nick}"
			end
		else
			send ":#{user.nick}", 'JOIN', chan.name
		end
	end

	def send_burst
		send 'BURST'
		@ircd.users.each { |u|
			send_nick_full(u)
		}
		@ircd.chan.each { |c|
			next if c.name[0] == ?&
			send_chan_full(c)
		}
		@ircd.chan.each { |c|
			c.bans.each { |b|
			}
		}
		send 'PING', ":#{@ircd.name}"
		send 'BURST', 0
	end

	def send_nick_full(u)
		flags = 0	# XXX
		sv_send "NICK #{u.nick} #{u.local? ? 1 : 2} #{cur_ts(u.ts)} +#{u.mode} #{u.ident} #{u.hostname} #{u.servername} 0 #{flags} :#{u.descr}"
	end

	def send_chan_full(c)
		m = '+' + chan.mode
		ma = []
		if c.limit
			m << 'l'
			ma << c.limit
		end
		if c.key
			m << 'k'
			ma << c.key
		end
		ulist = []
		c.users.each { |u|
			pfx = ''
			pfx << '@' if c.op?(u)
			pfx << '+' if c.voice?(u)
			ulist << "#{pfx}#{u.nick}"
			if ulist.join(' ').length > 200
				sv_send 'SJOIN', cur_ts(chan.ts), chan.name, "#{[m, ma].join(' ')}", ":#{pfx}#{user.nick}"
				m, ma, ulist = '+', [], []
			end
		}
		if not ulist.empty?
			sv_send 'SJOIN', cur_ts(chan.ts), chan.name, "#{[m, ma].join(' ')}", ":#{pfx}#{user.nick}"
		end
	end

	# send the chan topic/topicwho/topicwhen
	def send_topic(chan, who=nil)
		send ":#{who ? who.nick : @ircd.name}", 'TOPIC', split_nih(chan.topicwho)[0], chan.topicwhen, ":#{chan.topic}"
	end

	# retrieve a user, create it if it does not exist already
	def may_create_user(nick)
		if not u = @ircd.find_user(nick)
			u = User.new(@ircd, nick, nil, nil, self)
			@ircd.add_user u
		end
		u
	end

	# attempt to rebuild the original message from the parsed array
	def unsplit(l, from, sender_fqdn=false)
		from = from[1..-1]
		if sender_fqdn and u = @ircd.find_user(from)
			from = u.fqdn
		end
		":#{from} #{l[0...-1].join(' ')} :#{l[-1]}"
	end

	# forward the message to other servers
	def forward(l, from)
		@ircd.servers.each { |s|
			next if s == self
			s.send unsplit(l, from)
		}
	end

	def cmd_ping(l, from)
		sv_send 'PONG', @ircd.name, ":#{l[1]}"
	end

	def cmd_pong(l, from)
	end

	def cmd_burst(l, from)
		if l[0] == '0'
			# end of burst
		end
	end

	def cmd_privmsg(l, from)
		if c = @ircd.find_chan(l[1])
			forward(l, from)
			@ircd.send_chan_local(c, unsplit(l, from, true))
		elsif u = @ircd.find_user(l[1])
			if u.local?
				u.send unsplit(l, from, true)
			else
				u.from_server.send unsplit(l, from)
			end
		end
	end
	def cmd_notice(l, from)
		cmd_privmsg(l, from)
	end

	def cmd_nick(l, from)
		forward(l, from)	# XXX check conflict/kill first
		if l.length <= 3 # nick change
			# :old NICK new :ts
			nick = from[1..-1]
			if cf = @ircd.find_user(l[1]) and false
			elsif u = @ircd.find_user(nick, '')
				@ircd.del_user u
				u.nick = l[1]
				u.ts = l[2].to_i
				# TODO if u2 = @ircd.find_user(u.nick), kill some
				@ircd.add_user u
			else
				u = User.new(@ircd, l[1], nil, nil, self)
				u.ts = l[2].to_i
				@ircd.add_user u
			end
		else # new nick
			# NICK mynick 1 1291672480 +oiwh myident myhost mysrv 0 2130706433 :mydescr
			if u = @ircd.find_user(l[1])
				# TODO kill
			else
				u = User.new(@ircd, l[1], l[5], l[6], self)
				u.descr = l[10]
				u.ts = l[3].to_i
				u.mode = l[4][1..-1] if l[4][0] == ?+
				@ircd.add_user u
			end
		end
	end

	def cmd_sjoin(l, from)
		forward(l, from)
		# :test.com SJOIN 1291679507 #bite +m :@uu
		if not c = @ircd.find_chan(l[2])
			c = Channel.new(@ircd, l[2])
			c.ts = l[1].to_i
			@ircd.add_chan c
		# XXX else if c.ts conflict
		end

		if l.length > 3
			mode = l[3]
			modeargs = l[4...-1]
			if mode[0] == ?+
				mode[1..-1].split(//).each { |m|
					case m
					when 'l'; c.limit = modeargs.shift.to_i
					when 'k'; c.key = modeargs.shift
					end
					c.mode << m
				}
			end
		end

		ulist = l[-1]
		ulist.split.each { |nick|
			if nick[0] == ?@
				isop = true
				nick = nick[1..-1]
			end
			if nick[0] == ?+
				isvoice = true
				nick = nick[1..-1]
			end
			if nick[0] == ?@
				isop = true
				nick = nick[1..-1]
			end
			u = may_create_user(nick)
			c.users << u
			c.voices << u if isvoice
			c.ops << u if isop
		}
	end

	def cmd_mode(l, from)
		forward(l, from)
		if c = @ircd.find_chan(l[1])
			ml = l[2..-1]
			ts = ml.shift.to_i if @ts_delta
			@ircd.send_chan_local(c, unsplit(l[0, 2] + ml, from, true))
			do_mode_chan(c, ml, from, ts)
		elsif u = @ircd.find_user(l[1])
			minus = false
			l[2].split(//).each { |m|
				case m
				when '+'; minus = false; next
				when '-'; minus = true ; next
				end
				if minus
					u.mode.delete! m
				elsif not u.mode.include?(m)
					u.mode << m
				end
			}
		end
	end

	def do_mode_chan(c, margs, who, ts)
		mode = margs.shift
		minus = false
		mode.split(//).each { |m|
			case m
			when '+'; minus = false
			when '-'; minus = true
			when 'o', 'v'
				u = @ircd.find_user(margs.shift)
				next if not c.users.include?(u)
				list = (m == 'o' ? c.ops : c.voices)
				if minus
					list.delete u
				elsif not list.include?(u)
					list << u
				end
			when 'l'; c.limit = (minus ? nil : margs.shift.to_i) 
			when 'k'; k = margs.shift; c.key = (minus ? nil : k)
			when 'b', 'e'
				list = (m == 'b' ? c.bans : c.banexcept)
				mask = margs.shift
				if minus
					list.delete_if { |b| @ircd.downcase(b[:mask]) == @ircd.downcase(mask) }
				elsif not list.find { |b| @ircd.downcase(b[:mask]) == @ircd.downcase(mask) }
					if who[0] == ?:
						who = who[1..-1]
						who = @ircd.find_user(who).fqdn if @ircd.find_user(who)
					end
					list << { :mask => mask, :who => who, :when => ts }
				else next
				end
			else
				if minus
					c.mode.delete! m
				elsif not c.mode.include?(m)
					c.mode << m
				end
			end
		}
	end

	def cmd_part(l, from)
		forward(l, from)
		if c = @ircd.find_chan(l[1])
			l[2] ||= ''
			@ircd.send_chan_local(c, unsplit(l, from, true))
			if u = @ircd.find_user(split_nih(from[1..-1])[0])
				c.ops.delete u
				c.voices.delete u
				c.users.delete u
				@ircd.del_chan c if c.users.empty?
			end
		end
	end

	def cmd_kick(l, from)
		forward(l, from)
		if chan = @ircd.find_chan(l[1]) and u = @ircd.find_user(l[2])
			@ircd.send_chan_local(chan, unsplit(l, from, true))
			chan.ops.delete u
			chan.voices.delete u
			chan.users.delete u
			@ircd.del_chan chan if chan.users.empty?
		end
	end

	def cmd_away(l, from)
		forward(l, from)
		if u = @ircd.find_user(split_nih(from[1..-1])[0])
			if l[1] and not l[1].empty?
				u.away = l[1]
			else
				u.away = nil
			end
		end
	end

	def cmd_invite(l, from)
		forward(l, from)
		if u = @ircd.find_user(l[1]) and c = @ircd.find_chan(l[2])
			src = from[1..-1]
			src = @ircd.find_user(src).fqdn if @ircd.find_user(src)
			c.invites << { :user => u, :who => src, :when => Time.now.to_i } if not c.invites.find { |i| i[:user] == u }
			u.send ":#{src} INVITE #{l[1]} :#{l[2]}" if u.local?
		end
	end

	def cmd_topic(l, from)
		forward(l, from)
		if c = @ircd.find_chan(l[1])
			if u = @ircd.find_user(l[2])
				c.topicwho = u.fqdn
			else
				c.topicwho = l[2]
			end
			c.topicwhen = l[3].to_i
			if l[4].empty?
				c.topic = nil
			else
				c.topic = l[4]
			end
			@ircd.send_chan_local(c, ":#{c.topicwho} TOPIC #{c.name} :#{c.topic}")
		end
	end

	def cmd_whois(l, from)
		srvname = l[1]
		nick = l[2]
		if srvname == @ircd.name
		elsif srv = @ircd.servers.find { |s| s.name == srvname }
			srv.send unsplit(l, from)
			return
		elsif usr = @ircd.find_user(srvname)
			if not usr.local?
				usr.from_server.send unsplit(l, from)
				return
			end
		else
			forward(l, from)
			return
		end

		ask = split_nih(from[1..-1])[0]

		if u = @ircd.find_user(nick)
			sv_send 311, ask, u.nick, u.ident, u.hostname, '*', ":#{u.descr}"
			clist = u.chans.find_all { |c| !(c.mode.include?('p') or c.mode.include?('s')) or c.users.include?(self) or @mode.include?('o') }
			clist = clist.map { |c| (c.op?(u) ? '@' : c.voice?(u) ? '+' : '') + c.name }
			sv_send 319, ask, u.nick, ":#{clist.join(' ')}" if not clist.empty?
			sv_send 312, ask, u.nick, u.servername, ":#{u.local? ? usr.ircd.descr : u.from_server.descr}"
			sv_send 301, ask, u.nick, ":#{u.away}" if u.away
			sv_send 307, ask, u.nick, ':has identified for this nick' if false
			sv_send 313, ask, u.nick, ':is an IRC Operator - Service Administrator' if u.mode.include?('o')
			sv_send 275, ask, u.nick, ':is using a secure connection (SSL)' if u.mode.include?('S')
			sv_send 317, ask, u.nick, (Time.now - u.last_active).to_i, u.connect_time.to_i, ':seconds idle, signon time' if u.local?
		else
			sv_send 401, ask, nick, ':No such nick/channel'
		end
		sv_send 318, ask, nick, ':End of /WHOIS command'
	end

	def cmd_quit(l, from)
		forward(l, from)
		nick, user, host = split_nih(l[1])
		if u = @ircd.find_user(nick) and u.local?
			u.send "ERROR :Closing Link: #{@ircd.name} #{l[1]} (#{l[0]} by #{from[1..-1]} (#{l[2]}))"
			u.cleanup(unsplit(l, from, true), false)
		end
	end

	def cmd_kill(l, from)
		cmd_quit(l, from)
	end

	#cmd_squit

	def cmd_gnotice(l, from)
		forward(l, from)
		@ircd.send_global_local(l[1])
	end
	def cmd_globops(l, from)
		cmd_gnotice(l, from)
	end

	def setup_cx
		if @cline[:rc4] and @capab.to_a.include?('DKEY')
			send 'DKEY', 'START'
		elsif @cline[:zip] and @capab.to_a.include?('ZIP')
			send 'SVINFO', 'ZIP'
		else
			send_burst
		end
	end

	def cmd_svinfo(l, from)
		case l[1]
		when 'ZIP'
			send 'SVINFO', 'ZIP'
			if @cline[:zip] and @capab.to_a.include?('ZIP')
				# ruby-zlib is the sux !
				#p Zlib::Inflate.inflate(@fd.read(4096))
				# send_burst
			else cleanup
			end
		when /^\d+/
			@ts_delta = Time.now.to_i - l[-1].to_i
		end
	end

	def cmd_dkey(l, from)
		case l[1]
		when 'START'
			@dh_i = DH.new(dkey_param_prime, dkey_param_generator)
			send 'DKEY', 'PUB', 'I', @dh_i.e.to_s(16)
			@dh_o = DH.new(dkey_param_prime, dkey_param_generator)
			send 'DKEY', 'PUB', 'O', @dh_o.e.to_s(16)
			@dh_secret_o = @dh_secret_i = nil
		when 'PUB'
			num = l[3].to_i(16)
			case l[2]
			when 'I'; @dh_secret_o = @dh_o.secret(num)
			when 'O'; @dh_secret_i = @dh_i.secret(num)
			end
			if @dh_secret_o and @dh_secret_i
				puts "< DKEY EXIT" if $DEBUG
				@fd.write "DKEY DONE\n"		# send 'DKEY', 'DONE' uses \r\n, remote side decodes \n with rc4 => fail
				key_o = @dh_secret_o.to_s(16)
				key_o = '0' + key_o if key_o.length & 1 == 1
				key_o = [key_o].pack('H*')
				@fd = CryptoIo.new(@fd, nil, RC4.new(key_o))
			end
		when 'DONE'
			if not @dh_secret_o or not @dh_secret_i
				send 'ERROR', ':nope'
				cleanup
				return
			end
			key_i = @dh_secret_i.to_s(16)
			key_i = '0' + key_i if key_i.length & 1 == 1
			key_i = [key_i].pack('H*')
			@fd.rd = RC4.new(key_i)
			send 'DKEY', 'EXIT'
			@ircd.send_global "DH negociation successful with #{@cline[:name]}, connection encrypted"
		when 'EXIT'
			if @cline[:zip] and @capab.to_a.include?('ZIP')
				# send 'SVINFO', 'ZIP'
				# @fd = ZipIo.new(@fd, nil, true)
			else
				send_burst
			end
		end
	end
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
			sv_send 461, @nick, 'USER', ':Not enough parameters'
		else
			@user = l
			if @hostname == '0.0.0.0'
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
			sv_send 432, @nick, nick, ':bad nickname'
		elsif nick == @nick
		elsif @ircd.find_user(nick)
			sv_send 433, @nick || '*', nick, ':nickname is already in use'
		else
			@ircd.del_user(self) if @nick
			@nick = nick
			@ircd.add_user(self)
			check_conn
		end
	end

	def cmd_quit(l)
		send "ERROR :Closing Link: 0.0.0.0 (Quit: )"
		cleanup
	end

	def cmd_error(l)
		cleanup
	end
	
	def cmd_notice(l)
		# other server checking our ident
	end

	def cmd_capab(l)
		@capab = l
	end

	def cmd_server(l)
		retrieve_hostname(false)
		retrieve_ident(false)
		@server = l
		check_server_conn
	end
end
