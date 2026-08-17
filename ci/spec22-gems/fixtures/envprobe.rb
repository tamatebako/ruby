# frozen_string_literal: true

# envprobe.rb — windows env-baseline diagnostic. run-msys.sh's section
# 3.5 rides this under several scrubbed env shapes and always cats the
# output, so every dogfood log pins WHY the windows baseline vars ride
# the env -i lists (the sixth dogfood incident: Etc.sysconfdir went nil
# under the pre-fix scrub — SHGetSpecialFolderLocation fails below the
# windows process baseline — and rubygems' config_file.rb died at
# class-load on `File.join nil`). VFS-only reads (require + RbConfig):
# no host IO, so no subst bridge is needed.

require "rbconfig"

puts "PROBE-ENV platform=#{RUBY_PLATFORM}"
puts "PROBE-ENV keys=#{ENV.keys.sort.join(',')}"

begin
  require "etc"
  puts "PROBE-ENV etc-sysconfdir=#{Etc.sysconfdir.inspect}"
rescue LoadError, NoMethodError => e
  puts "PROBE-ENV etc-sysconfdir=#{e.class}"
end

puts "PROBE-ENV rbconfig-sysconfdir=#{RbConfig::CONFIG['sysconfdir'].inspect}"
