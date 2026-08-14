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
#                      class R trigger). The payload image declares
#                      materialize: for the styles tree (spec 22 §4), so
#                      the driver extracts it to the host exec cache at
#                      boot and this leg consumes the materialized copies.
#                      Expected GREEN since class R landed.
#   sassc-unmaterialized — the SAME import run against the negative-oracle
#                      image (the same tree pressed WITHOUT the
#                      materialize: declaration): the importer's fopen()
#                      of the VFS path is not host-real and the leg fails
#                      with the pinned class-R signature. Expected RED —
#                      the mechanism oracle: a GREEN here means the flip
#                      came from somewhere other than materialize:.
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

# The spec 22 §6 consumption path for the materialized styles tree: a
# materialize: entry P lands at <TEBAKO_EXEC_CACHE>/resources/<image-key>/<P>.
# The exec cache root is the contractual surface (exported by the driver,
# read-only to payloads); the per-image key is an implementation detail.
# Exactly one payload image is mounted per invocation, so the single glob
# match IS this payload's extraction — anything else (no export, no match,
# several matches) is a loud probe failure, never a silent fallthrough.
def materialized_styles_dir
  cache = ENV["TEBAKO_EXEC_CACHE"].to_s
  if cache.empty?
    puts "PROBE sassc-partial fail TEBAKO_EXEC_CACHE is not exported (the driver predates class R?)"
    exit 1
  end
  hits = Dir.glob("#{cache}/resources/*/probe/styles")
  unless hits.length == 1
    puts "PROBE sassc-partial fail materialization-missing hits=#{hits.length} cache=#{cache}"
    exit 1
  end
  hits[0]
end

# The sassc-partial import, run against a styles dir: File.read rides
# ruby's patched IO either way, but the @import is resolved by libsass's
# OWN C++ importer, which fopen()s <styles>/partials/_thing.scss on the
# raw host filesystem. With the VFS path that fopen misses (the pinned
# class-R failure); with the materialized exec-cache copy it succeeds.
def sassc_partial(styles)
  SassC::Engine.new(
    File.read(File.join(styles, "main.scss")),
    filename: File.join(styles, "main.scss"),
    load_paths: [styles]
  ).render
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
    # GREEN since class R: the payload manifest's materialize: declaration
    # put the styles tree on the host at boot — the importer's raw fopen()
    # of the partial now succeeds, jail intact (the exec cache lives under
    # the harness scratch, which the jail grants rw).
    css = sassc_partial(materialized_styles_dir)
    if css.include?(".spec22-gems-thing") && css.include?("#c0392b")
      puts "PROBE sassc-partial ok rule=.spec22-gems-thing bytes=#{css.bytesize}"
    else
      puts "PROBE sassc-partial fail css=#{css.inspect}"
      exit 1
    end
  rescue Exception => e # rubocop:disable Lint/RescueException -- the probe must see every failure mode
    puts "PROBE sassc-partial fail #{e.class}: #{e.message.lines.first.to_s.strip}"
    exit 1
  end
when "sassc-unmaterialized"
  require "sassc"
  puts "PROBE sassc-version #{SassC::VERSION}"
  begin
    # The SAME import against the image pressed WITHOUT materialize: —
    # the negative oracle. The importer's fopen() of the VFS path is not
    # host-real, so the pinned class-R failure must reproduce verbatim.
    css = sassc_partial("/probe/styles")
    puts "PROBE sassc-partial-unmaterialized unexpected-ok bytes=#{css.bytesize}"
    exit 1
  rescue Exception => e # rubocop:disable Lint/RescueException -- the probe must see every failure mode
    puts "PROBE sassc-partial-unmaterialized expected-fail #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
else
  warn "probe.rb: unknown leg #{ARGV[0].inspect} (sinatra-fixed|sinatra-unfixed|sassc|sassc-unmaterialized)"
  exit 64
end
