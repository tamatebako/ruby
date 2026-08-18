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
    # The block's value IS the Process::Status popen2e hands back — tap
    # takes it whole (destructuring a Status yields nil for st, which is
    # how the tenth dogfood incident printed a NoMethodError here instead
    # of the child's verdict).
  end.tap { |st| raise "child exit #{st.exitstatus}" unless st.success? }
end

# The eleventh dogfood incident: the install leg's rubygems respawn of
# `make` died "No such file or directory - make" with the msys make
# package INSTALLED on the job and its /usr/bin on the env -i PATH.
# Absolute VFS paths spawn fine (rbconfig-ruby above); the bare-name
# PATH search through the VFS is the suspect. This step names the
# failing primitive per tool: can the VFS stat the exe at each PATH
# entry (visibility), and does bare-name spawn work (lookup+exec)?
# Round one printed NONE+ENOENT for ALL FOUR tools — so first dump the
# PATH the runtime actually sees, plus two controls: the VFS mount path
# itself (must be true) and the PATH's third entry's known host file
# (C:/Windows/System32/cmd.exe). vfs true + cmd false => the VFS serves
# NO host path; vfs true + cmd true + tools NONE => the msys64 dirs
# specifically are invisible (path-form, not policy).
step("host-tools") do
  paths = ENV.fetch("PATH").split(File::PATH_SEPARATOR)
  puts "PROBE-PIPE path=#{ENV.fetch("PATH")}"
  puts "PROBE-PIPE control vfs-ruby=#{File.file?("A:/t/bin/ruby.exe")} " \
       "host-cmd=#{File.file?("C:/Windows/System32/cmd.exe")}"
  %w[make gcc g++ sh].each do |tool|
    hits = paths.map { |d| File.join(d, "#{tool}.exe") }
    found = hits.find { |p| File.file?(p) }
    puts "PROBE-PIPE host-tool #{tool} resolved=#{found || "NONE"}"
    begin
      pid = spawn(tool, "--version", [:out, :err] => File::NULL)
      Process.wait(pid)
      puts "PROBE-PIPE host-tool #{tool} spawn exit=#{$?.exitstatus}"
    rescue SystemCallError => e
      puts "PROBE-PIPE host-tool #{tool} spawn FAIL #{e.class}: #{e.message}"
    end
  end
end

# FD round-trip probes (incident 12 round 3): logger's log_device.rb:256
# probe — File.new(f.fileno, autoclose: false, path: "") on a VFS-backed
# fd — died Errno::EBADF in the jailed proof legs. Name the exact failing
# primitive, UNJAILED here (the probe.rb twin answers jailed): IO#stat is
# the pure fstat-shim test; IO.new(fd) walks io_initialize (fstat +
# rb_update_max_fd + isatty); file-new-path is logger's exact line. The
# embedded bit mirrors the c_api TEBAKO_FD_FLAG (0x40000000).
step("fd-roundtrip") do
  fd_file = File.open(__FILE__)
  fd_num = fd_file.fileno
  puts "PROBE-FD fd=#{fd_num} embedded-bit=#{fd_num & 0x4000_0000 != 0}"
  begin
    puts "PROBE-FD io-stat size=#{fd_file.stat.size}"
  rescue Exception => e # rubocop:disable Lint/RescueException -- the diagnostic must see every failure mode
    puts "PROBE-FD io-stat #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
  begin
    IO.new(fd_num, autoclose: false)
    puts "PROBE-FD io-new ok"
  rescue Exception => e # rubocop:disable Lint/RescueException -- the diagnostic must see every failure mode
    puts "PROBE-FD io-new #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
  begin
    File.new(fd_num, autoclose: false, path: "").path
    puts "PROBE-FD file-new-path ok"
  rescue Exception => e # rubocop:disable Lint/RescueException -- the diagnostic must see every failure mode
    puts "PROBE-FD file-new-path #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
  begin
    puts "PROBE-FD path-size=#{File.size(__FILE__)}"
  rescue Exception => e # rubocop:disable Lint/RescueException -- the diagnostic must see every failure mode
    puts "PROBE-FD path-size #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
end
