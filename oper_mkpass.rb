require 'digest/md5'

salt = Array.new(1030) { rand(255) }[1024, 6].pack('C*')
salt_a = [salt].pack('m*').chomp        # base64

puts "Type your password:"
system 'stty', '-echo' if $stdin.tty?
pass = $stdin.gets
system 'stty', 'echo' if $stdin.tty?

md5 = pass.chomp
(1<<14).times { md5 = Digest::MD5.digest(salt+md5) }
md5_a = [salt[0, 2] + md5].pack('m*').chomp

puts "#{salt_a}$#{md5_a}"
