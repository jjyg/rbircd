# pure ruby implementation of Diffie-Hellman and RC4

# from http://labs.mudynamics.com/2007/05/09/diffie-hellman-in-ruby/
class DH
	# b**e % m
	def mod_exp(b, e, m)
		raise if e < 0
		ret = 1
		while e > 0
			ret = (ret * b) % m if e[0] == 1
			e >>= 1
			b = (b * b) % m
		end
		ret
	end

	# hamming weight
	def bit_count(b)
		raise if b < 0
		ret = 0
		while b > 0
			ret += b[0]
			b >>= 1
		end
		ret
	end

	attr_accessor :p, :g, :q, :x, :e

	# p = prime, g = generator, q = subgroup order
	def initialize(p, g, q)
		@p = p
		@g = g
		@q = q
		generate
	end

	# create a random secret & public nr
	def generate
		until valid?
			@x = rand(@q)
			@e = mod_exp(@g, @x, @p)
		end
	end

	def valid?
		e and @e >= 2 and @e <= @p-2 and bit_count(@e) > 1
	end

	# compute the shared secret given the public key
	def secret(f)
		mod_exp(f, @x, @p)
	end

	def self.test
		alice = DH.new(53, 5, 23)
		bob   = DH.new(53, 5, 15)
		raise if alice.secret(bob.e) != bob.secret(alice.e)
	end
end

# from https://github.com/juggler/ruby-rc4/blob/master/lib/rc4.rb
class RC4
	def initialize(key)
		@q1, @q2 = 0, 0

		@key = key.unpack('C*')
		@key += @key while @key.length < 256
		@key = @key[0, 256]

		@s = (0..255).to_a

		j = 0
		256.times { |i|
			j = (j + @s[i] + @key[i]) & 0xff
			@s[i], @s[j] = @s[j], @s[i]
		}
	end

	def encrypt(text)
		return nil if not text
		text.unpack('C*').map { |c| c ^ round }.pack('C*')
	end
	alias decrypt encrypt

	def round
		@q1 = (@q1 + 1) & 0xff
		@q2 = (@q2 + @s[@q1]) & 0xff
		@s[@q1], @s[@q2] = @s[@q2], @s[@q1]
		@s[(@s[@q1] + @s[@q2]) & 0xff]
	end
end

class CryptoIo
	attr_accessor :rd, :wr, :fd
	# usage: cryptsocket = CryptoIo.new(socket, RC4.new("foobar"), RC4.new("foobar"))
	# can be chained, and passed to IO.select
	def initialize(fd, cryptrd, cryptwr)
		@fd = fd
		@rd = cryptrd
		@wr = cryptwr
	end

	def read(len)
		@rd.decrypt(@fd.read(len))
	end
	def write(str)
		@fd.write(@wr.encrypt(str))
	end
	def to_io
		@fd.to_io
	end
end
