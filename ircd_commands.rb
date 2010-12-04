class User
	def handle_command(ircd, l)
		case l[0].to_s.downcase
		when ''
		when 'nick'
		when 'join'
		when 'part'
		when 'kick'
		when 'mode'
		when 'quit'
		when 'ping'
		end
	end
end

class Server
	def handle_command(ircd, l)
		case l[0].to_s.downcase
		when ''
		when 'nick'
		when 'join'
		when 'part'
		when 'kick'
		when 'mode'
		when 'quit'
		when 'ping'
		end
	end
end
