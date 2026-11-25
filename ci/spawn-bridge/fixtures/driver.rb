# ci/spawn-bridge driver: array-spawns the (embedded) target with one
# embedded operand and one host token. The patch's spawn hook does the
# materialize/probe/bridge/scrub parent-side; the echo target's own
# prints are the assertion surface.
#
#   miniruby driver.rb <target> <operand>
#
# The exit status is the spawn's: a child that never execs fails here
# (honest, named), never a silent pass.
target, operand = ARGV
abort "usage: driver.rb <target> <operand>" if target.nil? || operand.nil?
ok = system(target, operand, "plain tail")
exit(ok ? 0 : 1)
