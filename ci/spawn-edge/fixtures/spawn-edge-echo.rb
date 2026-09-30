# frozen_string_literal: true

# spawn-edge-echo.rb — the provider payload's exposed command, dispatched
# as a child process through the spec-32 kind: executable edge's spawn
# surface. Echoes its argv on one line; the verdict belongs to the
# consumer (spawn-edge-probe.rb), which compares byte-for-byte. The
# self-locating line proves the child booted with the provider image
# mounted ("/" on POSIX, "A:/" on msys) rather than anything host-side.
puts "SPAWN-EDGE-CHILD argv=#{ARGV.inspect}"
puts "SPAWN-EDGE-CHILD file=#{__FILE__}"
