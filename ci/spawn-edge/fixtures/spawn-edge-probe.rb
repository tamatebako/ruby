# frozen_string_literal: true

# spawn-edge-probe.rb — the consumer payload's entry. Exercises the
# spec-32 spawn surface: this payload's manifest declares a
# `kind: executable` edge with `expose: [spawn-edge-echo]`, so a bare-name
# spawn of "spawn-edge-echo" is intercepted by the runtime's spawn hook
# and re-planned as the provider payload's own dispatch (the provider
# image co-mounted in the child, the exposed entrypoint run there). Two
# legs, both array-form (never a shell — a shell string is a different,
# unplanned surface):
#
#   system-array  — system("spawn-edge-echo", "alpha", "beta gamma",
#                   "--flag=x", out: <capture>), the metanorma/xml2rfc
#                   call shape (tebako#691);
#   popen-array   — IO.popen(["spawn-edge-echo", ...]) — the pipe form.
#
# Each leg asserts the child exited 0 and echoed the EXACT argv (the
# space-carrying token proves the argv vector survives un-re-split; the
# flag-shaped token proves no option re-parse). The regression this
# tripwire exists for (ruby#121: the plan's argv[0] dropped at apply, so
# the child's flag parse shifted and its mounts/entry fell out) fails
# both legs at once. A plan failure raises in the parent — the rescue
# names it instead of dying on an unhandled exception line.
#
# Prints one `PROBE spawn-edge <leg> ok|fail <detail>` line per leg plus
# a PROBE-DIAG line carrying the captured child output (the proof log is
# the only place the child's stdout lands for the redirect/pipe forms).
# Exits 1 on the first failed leg, 0 when both pass.

COMMAND = "spawn-edge-echo"
ARGS = ["alpha", "beta gamma", "--flag=x"].freeze
WANT = "SPAWN-EDGE-CHILD argv=#{ARGS.inspect}".freeze

def fail!(leg, detail)
  puts "PROBE spawn-edge #{leg} fail #{detail}"
  exit 1
end

def judge(leg, ok, out)
  # Raw lines, not inspect: the proof log is the only place the child's
  # stdout lands for the redirect/pipe forms, and the harness pins the
  # child's echo line verbatim.
  out.each_line { |line| puts "PROBE-DIAG #{leg} child: #{line}" }
  fail!(leg, "the child did not exit 0 — its stderr rides this log") unless ok
  unless out.lines.map(&:chomp).include?(WANT)
    fail!(leg, "child argv mismatch — want #{WANT.inspect}, got #{out.strip.inspect}")
  end
  puts "PROBE spawn-edge #{leg} ok"
end

# Leg 1: array-form system(), the child's stdout captured through a spawn
# redirect (cwd is the harness-owned run dir — no absolute path crosses
# the spawn boundary, so nothing rides the carried-mount rewrite).
begin
  capture = File.expand_path("spawn-edge-system.out", Dir.pwd)
  ok = system(COMMAND, *ARGS, out: capture)
  out = File.file?(capture) ? File.read(capture) : ""
rescue StandardError => e
  fail!("system-array", "the spawn raised #{e.class}: #{e.message.lines.first.to_s.strip}")
end
judge("system-array", ok == true, out)

# Leg 2: array-form IO.popen (the pipe twin).
begin
  out = IO.popen([COMMAND, *ARGS], &:read)
  status = $?
rescue StandardError => e
  fail!("popen-array", "the spawn raised #{e.class}: #{e.message.lines.first.to_s.strip}")
end
judge("popen-array", status&.success? == true, out)
