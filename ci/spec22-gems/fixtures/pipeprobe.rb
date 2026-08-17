# frozen_string_literal: true

# pipeprobe.rb — windows spawn-mechanics diagnostic. run-msys.sh section 4
# rides this through the SAME env -i list as the gem-install leg, with the
# subst bridge up, right before the install attempt (the seventh dogfood
# incident: rubygems' ext builder died with "extconf failedundefined
# method 'close' for nil" — open3's popen2e ensure masks the original
# exception when a pipe step raises, so the real error never reached the
# log). Each sub-step of the extconf respawn is exercised separately with
# the FULL backtrace printed, so the failing primitive names itself.
# The child ruby is RbConfig.ruby — A:/t/bin/ruby.exe through the bridge,
# exactly what rubygems respawns per extconf.

require "rbconfig"

def step(name)
  yield
  puts "PROBE-PIPE #{name} ok"
rescue Exception => e # rubocop:disable Lint/RescueException -- diagnostic: report EVERYTHING
  puts "PROBE-PIPE #{name} FAIL #{e.class}: #{e.message}"
  (e.backtrace || []).first(8).each { |f| puts "PROBE-PIPE   #{f}" }
end

step("pipe-close") { IO.pipe.each(&:close) }
step("pipe-sync") do
  r, w = IO.pipe
  w.sync = true
  r.close
  w.close
end

ruby = RbConfig.ruby
puts "PROBE-PIPE rbconfig-ruby=#{ruby}"

step("spawn-plain") do
  pid = spawn(ruby, "-e", "STDOUT.puts 42")
  Process.wait(pid)
  raise "child exit #{$?.exitstatus}" unless $?.success?
end

step("spawn-env-chdir-redirect") do
  r, w = IO.pipe
  pid = spawn({ "PIPEPROBE" => "1" }, ruby, "-e", "STDOUT.puts 42",
              [:out, :err] => w, chdir: Dir.pwd)
  w.close
  r.read
  Process.wait(pid)
  r.close
  raise "child exit #{$?.exitstatus}" unless $?.success?
end

require "open3"
step("popen2e") do
  Open3.popen2e({ "SOURCE_DATE_EPOCH" => "1" }, ruby, "-e", "STDOUT.puts 42",
                chdir: Dir.pwd) do |stdin, stdouterr, wt|
    stdin.close
    while stdouterr.gets; end
    wt.value
  end.tap { |(_out, st)| raise "child exit #{st.exitstatus}" unless st.success? }
end
