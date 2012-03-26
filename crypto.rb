# pure ruby implementation of Diffie-Hellman and RC4

module Bignum_ops
	# b**e % m
	def mod_exp(b, e, m)
		raise if e < 0
		ret = 1
		while e > 0
			ret = (ret * b) % m if (e&1) == 1
			e >>= 1
			b = (b * b) % m
		end
		ret
	end

	SMALL_PRIMES = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31] unless defined? SMALL_PRIMES

	# miller rabin probabilistic primality test
	# t = 3 adequate for n > 1000, smaller are found in SMALL_PRIMES
	def miller_rabin(n, t=3)
		return false if n < 2
		return true if SMALL_PRIMES.include?(n)

		SMALL_PRIMES.each { |p|
			return false if n % p == 0
		}

		s = 0
		r = n-1
		while r & 1 == 0
			s += 1
			r >>= 1 
		end

		t.times { |i|
			# 1st round uses 2, subsequent use rand(2..n-2)
			a = (i == 0 ? 2 : crypt_rand(2, n-2))
			y = mod_exp(a, r, n)
			if y != 1 and y != n-1
				(s-1).times {
					break if y == n-1
					y = mod_exp(y, 2, n)
					return false if y == 1
				}
				return false if y != n-1
			end
		}

		return true
	end

	# create a random number min <= n <= max from /dev/urandom
	def crypt_rand(min, max)
		return min if max <= min
		nr = 0
		File.open('/dev/urandom', 'r') { |fd|
			while nr < max-min
				nr = (nr << 8) | fd.read(1).unpack('C')[0]
			end
		}
		min + (nr % (max-min+1))
	end
end

class DH
	include Bignum_ops

	attr_accessor :p, :g, :x, :e

	# p = prime, g = generator
	def initialize(p, g)
		@p = p
		@g = g
		generate
	end

	# create a random secret & public nr
	def generate
		@x = crypt_rand(1, @p-2)
		@e = mod_exp(@g, @x, @p)
	end

	# compute the shared secret given the public key
	def secret(f)
		mod_exp(f, @x, @p)
	end

	# check that p is a strong prime, and that g's order > 2
	def self.validate(p, g)
		raise 'DH: p not prime' if not miller_rabin(p)
		raise 'DH: p not strong prime' if not miller_rabin((p-1)/2)
		raise 'DH: g bad generator' if mod_exp(g, 2, p) == 1
	end

	def self.test
		DH.validate(107, 2)
		alice = DH.new(107, 2)
		bob   = DH.new(107, 2)
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

class NullCipher
	def encrypt(l)
		l
	end

	def decrypt(l)
		l
	end
end

class CryptoIo
	attr_accessor :rd, :wr, :fd
	# usage: cryptsocket = CryptoIo.new(socket, RC4.new("foobar"), RC4.new("foobar"))
	# can be chained, and passed to IO.select
	def initialize(fd, cryptrd, cryptwr)
		@fd = fd
		@rd = cryptrd || NullCipher.new
		@wr = cryptwr || NullCipher.new
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

require 'zlib'
class ZipIo
	attr_accessor :ziprd, :zipwr, :fd

	def initialize(fd, ziprd, zipwr)
		@fd = fd
		@ziprd = ziprd
		@zipwr = zipwr
		@r = Zlib::Inflate.new
		@w = Zlib::Deflate.new
		@bufrd = ''
	end

	def read(len)
		if @ziprd
			ret = ''
			if not @bufrd.empty?
				ret << @bufrd[0, len]
				@bufrd[0, len] = ''
				len -= ret.length
			end
			if len > 0
				# FAIL
				@bufrd += @r.inflate(@fd.read(len))
			end
		else
			@fd.read(len)
		end
	end
	def pending
		@bufrd.length
	end
	def write(str)
	end
	def to_io
		@fd.to_io
	end
end
