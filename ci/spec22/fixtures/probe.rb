# frozen_string_literal: true

# probe.rb — spec 22 phase 1 acceptance probe (POSIX). Runs as the
# --tebako-entry script of a jailed tebako runtime with the probe payload
# mounted at "/". Asserts, with NO per-gem Ruby adapter present:
#
#   fiddle          — Fiddle.dlopen of a VFS-resident library materializes
#                     it (+ its dependency closure) and returns 42.
#   cext-self-dlopen — a C extension's OWN dlopen of a VFS-resident path
#                     (bypassing ruby's dln_load) is routed likewise.
#   named-error     — a failed materialization (dlopen of a VFS directory)
#                     raises carrying the tebako verdict line: the library,
#                     the mount, the verdict (spec 22 §5).
#   jail-deny       — the TEBAKO_JAIL policy is live: a host read outside
#                     the allowance is denied (interposition did not punch
#                     through the jail).
#
# Every check prints one `PROBE <name> <ok|fail> <detail>` line; the
# process exits 0 only when all checks are ok.

LIB = "/probe/lib/libvfsprobe.#{RUBY_PLATFORM.match?(/darwin/) ? "dylib" : "so"}"

$probe_results = []

def probe(name)
  value = yield
  $probe_results << [name, "ok", value.inspect]
rescue Exception => e # rubocop:disable Lint/RescueException -- the probe must see every failure mode
  $probe_results << [name, "fail", "#{e.class}: #{e.message}"]
end

require "fiddle"

probe("fiddle") do
  handle = Fiddle.dlopen(LIB)
  answer = Fiddle::Function.new(handle["probe_answer"], [], Fiddle::TYPE_INT).call
  raise "want 42, got #{answer}" unless answer == 42

  answer
end

probe("cext-self-dlopen") do
  require "/probe/lib/probe_ext"
  answer = ProbeExt.answer
  raise "want 42, got #{answer}" unless answer == 42

  answer
end

probe("named-error") do
  begin
    Fiddle.dlopen("/probe/lib") # a directory: materialization refuses (EISDIR)
    raise "no error raised"
  rescue Fiddle::DLError => e
    unless e.message.include?("cannot materialize VFS-resident library '/probe/lib'") &&
           e.message.include?("(mount '/'")
      raise "verdict line missing library/mount: #{e.message}"
    end

    e.message
  end
end

probe("jail-deny") do
  begin
    File.read("/etc/passwd")
    raise "jail not enforced"
  rescue Errno::EPERM, Errno::EACCES => e
    e.class
  end
end

$probe_results.each { |name, status, detail| puts "PROBE #{name} #{status} #{detail}" }
exit($probe_results.all? { |_, status, _| status == "ok" } ? 0 : 1)
