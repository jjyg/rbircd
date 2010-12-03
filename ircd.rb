# IRC server
# (c) Yoann Guillot 2010
# Distributes under the terms of the WtfPLv2

# a client connection
class User
	# file descriptor
	attr_accessor :fd
	attr_accessor :nick, :ident, :hostname
	attr_accessor :mode
	# list of Channel
	attr_accessor :channels
	# Time.to_i of the last message sent from the user (except PINGs)
	attr_accessor :last_active

	def initialize(fd, nick, ident, hostname)
		@fd = fd
		@nick = nick
		@ident = ident
		@hostname = hostname
		@mode = ''
		@channels = []
		@last_active = 0
	end

	def fqdn
		"#@nick!#@ident@#@host"
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

	def initialize(fd)
		@fd = fd
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

	attr_accessor :conf

	def initialize(conffile=nil)
		@user = {}
		@channel = {}
		@servers = []
		@conf = Conf.new
		@conf.load(conffile) if conffile
	end

	def users
		@user.values
	end

	def opers
		users.find_all { |u| u.mode.include? 'o' }
	end

	def channels
		@channel.values
	end

	def main_loop
		loop { main_loop_iter }
	end

	def main_loop_iter
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
end

# set of configuration parameters
class Conf
	# list of { :mask => '*!blabla', :pass => '1ade2c39af8a83', :mode => 'oOaARD' }
	attr_accessor :olines
	# list of { :mask => '1.2.3.*', :pass => 'secret' }
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
			when ?P
			when ?C
			when ?O
			when ?#
			when nil
			else
				puts "Unknown configuration line #{l.inspect}"
			end
		}
	end
end
