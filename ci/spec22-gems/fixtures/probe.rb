# frozen_string_literal: true

# probe.rb — spec 22 gem-level acceptance probe (POSIX). Runs as the
# --tebako-entry script of a jailed tebako runtime with the probe payload
# (fixtures + the scratch gem home) mounted at "/". Dispatches on ARGV[0]:
#
#   sinatra-fixed    — classic-style sinatra with the documented
#                      payload-side contract (`set :app_file, __FILE__`);
#                      static fetch must round-trip. Expected GREEN.
#   sinatra-unfixed  — the same app WITHOUT the fix. Expected RED when the
#                      tebako-runtime gem is loaded at boot: the gem's
#                      Kernel#require hook frame pollutes sinatra 4.x's
#                      load-time caller_files app_file detection
#                      (CALLERS_TO_IGNORE rejects rubygems/bundler/
#                      zeitwerk frames, not ours), so root is misderived
#                      and the static fetch 404s. Expected GREEN only when
#                      the gem is absent.
#   sassc            — sassc-main: a no-imports template read through
#                      ruby's patched IO and compiled by libsass from the
#                      string. Expected GREEN.
#                      sassc-partial: a template whose @import libsass's
#                      C++ importer fopen()s on a raw HOST path (spec 22
#                      class R trigger) — VFS paths are not host-real, so
#                      the import fails with a pinned named error.
#                      Expected RED today; flips GREEN in the class-R PR.
#
# Every invocation prints the instrumentation line
# `PROBE gem-loaded yes|no` first — whether the tebako-runtime gem was
# required at interpreter startup (the patched gem_prelude) — then one
# PROBE line per leg. The harness (run.sh) pins the exact expectations.

GEM_HOME_IN_IMAGE = "/probe/gemhome"

gem_loaded = $LOADED_FEATURES.any? { |f| f.end_with?("/tebako-runtime.rb") }
puts "PROBE gem-loaded #{gem_loaded ? 'yes' : 'no'}"

# Redirect rubygems at the in-image probe gem home BEFORE requiring any
# probe gem. The already-activated tebako-runtime spec (env image) is
# unaffected.
ENV["GEM_HOME"] = GEM_HOME_IN_IMAGE
ENV["GEM_PATH"] = GEM_HOME_IN_IMAGE
Gem.clear_paths

def static_fetch
  require "rack/mock"
  app = Sinatra::Application
  res = Rack::MockRequest.new(app).get("/static.txt")
  [app.app_file, app.root, res.status, res.body]
end

case ARGV[0]
when "sinatra-fixed", "sinatra-unfixed"
  fixed = ARGV[0] == "sinatra-fixed"
  require_relative(fixed ? "app" : "app_unfixed")
  app_file, root, status, body = static_fetch
  want = File.read("/probe/public/static.txt")
  if fixed
    if status == 200 && body == want
      puts "PROBE sinatra-fixed ok status=200 bytes=#{body.bytesize} app_file=#{app_file}"
    else
      puts "PROBE sinatra-fixed fail status=#{status} app_file=#{app_file} root=#{root}"
      exit 1
    end
  elsif app_file.end_with?("/lib/tebako-runtime.rb")
    # the require-hook frame won caller_files: root is misderived under
    # the gem's lib/, the static fetch cannot find public/static.txt.
    puts "PROBE sinatra-unfixed expected-fail app_file=#{app_file} root=#{root} status=#{status}"
  elsif status == 200 && body == want
    puts "PROBE sinatra-unfixed ok status=200 app_file=#{app_file}"
  else
    puts "PROBE sinatra-unfixed surprise status=#{status} app_file=#{app_file} root=#{root}"
    exit 1
  end
when "sassc"
  require "sassc"
  puts "PROBE sassc-version #{SassC::VERSION}"
  css = SassC::Engine.new(File.read("/probe/styles/plain.scss")).render
  if css.include?(".spec22-gems") && css.include?("color: #1d2d3c")
    puts "PROBE sassc-main ok rule=.spec22-gems bytes=#{css.bytesize}"
  else
    puts "PROBE sassc-main fail css=#{css.inspect}"
    exit 1
  end
  begin
    SassC::Engine.new(
      File.read("/probe/styles/main.scss"),
      filename: "/probe/styles/main.scss",
      load_paths: ["/probe/styles"]
    ).render
    # class R has landed — flip this leg's expectation IN THAT PR.
    puts "PROBE sassc-partial unexpected-ok"
    exit 1
  rescue Exception => e # rubocop:disable Lint/RescueException -- the probe must see every failure mode
    puts "PROBE sassc-partial expected-fail #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
else
  warn "probe.rb: unknown leg #{ARGV[0].inspect} (sinatra-fixed|sinatra-unfixed|sassc)"
  exit 64
end
