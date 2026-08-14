# frozen_string_literal: true

# gem.rb — the stock bin/gem body as a tebako entry script. The env image
# ships rubygems (lib/ruby/<api>/rubygems/) but deliberately no gem
# binstub (/bin holds only the bundled-gem stubs), so this shim rides the
# setup image and receives the gem CLI args as its ARGV:
#
#   <runtime> --tebako-image <setup.tfs>:-:/ \
#     --tebako-entry /setup/gem.rb install <gem>:<ver> ... --install-dir ...
#
# Used ONLY by the un-jailed setup leg (press, not proof): the probe gems
# are installed by the built runtime's own rubygems/mkmf, guaranteeing the
# sassc native extension is compiled against the same ruby ABI.

require "rubygems/gem_runner"

Gem::GemRunner.new.run ARGV.clone
