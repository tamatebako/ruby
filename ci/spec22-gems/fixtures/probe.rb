# frozen_string_literal: true

# probe.rb — spec 22 gem-level acceptance probe (POSIX + windows/msys).
# Runs as the --tebako-entry script of a jailed tebako runtime with the
# probe payload (fixtures + the scratch gem home) mounted at "/".
# Dispatches on ARGV[0]:
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
# `PROBE gem-loaded yes|no` first — whether a tebako-runtime gem got
# loaded at interpreter startup. Nothing may load it: spec 22 phase M2
# removed the gem from the env image and the gem_prelude require patch is
# retired, so the line is a pure canary (a `yes` fails the harness). Then
# one PROBE line per leg. The harness (run.sh) pins the exact expectations.
#
# PATH DISCIPLINE: every in-image reference is derived from __FILE__
# (self-locating), NEVER a bare "/probe/..." literal. On POSIX the
# payload mount answers bare absolute paths; on windows an absolute
# path needs a drive letter and the VFS is anchored at A:, so
# "/probe/gemhome" would resolve rooted-relative against the process's
# current drive and miss the VFS entirely (the twelfth dogfood
# incident: LoadError on sinatra/sassc in all four jailed legs with the
# gems present in the image). __FILE__ is the driver-resolved entry
# path — "/probe/probe.rb" on POSIX, "A:/probe/probe.rb" on windows —
# so dirname-derived spellings are byte-identical to the old literals
# on POSIX and correct on windows.

PROBE_DIR = File.dirname(__FILE__)
GEM_HOME_IN_IMAGE = File.join(PROBE_DIR, "gemhome")

gem_loaded = $LOADED_FEATURES.any? { |f| f.end_with?("/tebako-runtime.rb") }
puts "PROBE gem-loaded #{gem_loaded ? 'yes' : 'no'}"

# Boot-environment tripwire (every leg, never gates): the harness hands
# the runtime its whole contract through the env (TEBAKO_RUNTIME_IMAGE
# mounts the stdlib env image; TEBAKO_HOME/HOME scope the store and the
# user dirs). Incident 13 round 5: a comment line inside run_probe's
# env -i continuation silently split the command, the runtime booted
# with NONE of these, and the only symptom was the rubygems prelude
# warning + the line-66 NoMethodError below — a full CI cycle to
# diagnose. Report presence up front so a lost handoff names itself in
# the first three lines of the proof log.
puts "PROBE-DIAG env TEBAKO_RUNTIME_IMAGE=#{ENV['TEBAKO_RUNTIME_IMAGE'] ? 'set' : 'UNSET'} " \
     "TEBAKO_HOME=#{ENV['TEBAKO_HOME'] ? 'set' : 'UNSET'} HOME=#{ENV['HOME'] ? 'set' : 'UNSET'}"

# Redirect rubygems at the in-image probe gem home BEFORE requiring any
# probe gem.
ENV["GEM_HOME"] = GEM_HOME_IN_IMAGE
ENV["GEM_PATH"] = GEM_HOME_IN_IMAGE
Gem.clear_paths

# Discovery diagnostics (every leg, never gates): name the exact
# primitive that misses if gem activation fails — File.directory?,
# Dir.children, Dir.glob against the in-image gemhome, then what
# rubygems itself sees. Incident 12 round 2: the self-locating
# respell (#80) still LoadError'd on windows with the gems in-image,
# so the failing primitive is inside the discovery chain, not the
# spelling.
puts "PROBE-DIAG gemhome=#{GEM_HOME_IN_IMAGE}"
puts "PROBE-DIAG gemhome-directory=#{File.directory?(GEM_HOME_IN_IMAGE)}"
begin
  puts "PROBE-DIAG gemhome-children=#{Dir.children(GEM_HOME_IN_IMAGE).sort.join(',')}"
rescue Exception => e # rubocop:disable Lint/RescueException -- the diagnostic must see every failure mode
  puts "PROBE-DIAG gemhome-children-err #{e.class}: #{e.message.lines.first.to_s.strip}"
end
begin
  gemspecs = Dir.glob(File.join(GEM_HOME_IN_IMAGE, "specifications", "*.gemspec"))
  puts "PROBE-DIAG gemspecs=#{gemspecs.length} first=#{gemspecs.first}"
rescue Exception => e # rubocop:disable Lint/RescueException -- the diagnostic must see every failure mode
  puts "PROBE-DIAG gemspecs-err #{e.class}: #{e.message.lines.first.to_s.strip}"
end
puts "PROBE-DIAG spec-dirs=#{Gem::Specification.dirs.join('|')}"
puts "PROBE-DIAG specs-total=#{Gem::Specification.count} sinatra=#{Gem::Specification.find_all_by_name('sinatra').length} sassc=#{Gem::Specification.find_all_by_name('sassc').length}"

# FD round-trip probes (incident 12 round 3): the JAILED twin of the
# pipeprobe fd-roundtrip block. logger's log_device.rb:256 probe —
# File.new(f.fileno, autoclose: false, path: "") on a VFS-backed fd —
# died Errno::EBADF in these legs. Names whether the failing primitive
# is fstat-on-memfs-fd (io-stat) or something deeper in io_initialize
# (io-new), and whether jailing flips the answer vs pipeprobe's
# unjailed run. Never gates.
begin
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

# Incident 13 round 7 diagnostics. Round 6 (the first run carrying the
# ffi bisect) proved two things and broke one: the closure walk's answers
# match ground truth byte-for-byte (the pressed payload image, extracted
# on macOS: all 16 imports of libsass.so match llvm-objdump's read of the
# real import tables; every vendored sibling is a valid coff-x86-64 PE),
# and the ffi failure is the OS's own answer (the shim's covered route
# forwards LOAD_WITH_ALTERED_SEARCH_PATH — dln_c_dlmap_msys.patch forces
# 0x8 when the caller named no LOAD_LIBRARY_SEARCH_* order). What broke:
# FFI::DynamicLibrary.load_library went private in ffi 1.17, so the
# round-6 bisect died NoMethodError on its first leg and no dep-load
# verdict ever printed.
#
# What has never been measured ON THE RUNNER:
#  (a) the bytes the WINDOWS backend streams out — a windows-only backend
#      read bug is poison the macOS extraction cannot show, so sha256 each
#      vendored module through ruby's patched IO and compare against the
#      image-extracted constants (the vendored DLLs are copied binaries —
#      byte-stable across runs; libsass.so is compiled per run by gem
#      install, so its comparison is informational, never a verdict);
#  (b) each vendored sibling's OWN OS bind — the 126 names "a dep",
#      never which;
#  (c) the search-order semantics themselves: a fiddle-driven flag matrix
#      against the materialized HOST spelling. The host spelling is not a
#      covered path, so the shim passes it through byte-identical and
#      fiddle drives the RAW loader; the default-order leg is the negative
#      control (the standard order never searches the DLL's own dir, so
#      126 there is documented behavior — a SUCCESS there rewrites the
#      model).
# Never gates: the original LoadError re-raises after the verdicts, and
# no leg may kill the bisect (every leg rescues StandardError).

# sha256 + byte counts of the three vendored modules, extracted from the
# round-6 run's pressed payload image (probe-gems-4.0.6.tfs) on macOS via
# the dwarfs-t backend's POSIX read path.
SASSC_MODULE_WANTS = {
  "libwinpthread-1.dll" => ["0bf76de7b957fc1f87f8be9c8c46af4588db204b0600a3e7abe7243c790f8dfd", 63_135],
  "libgcc_s_seh-1.dll" => ["80940372431cc76224dfda06e2d33f01e49af3b4e7c499c535be856ebcadd273", 151_654],
  "libsass.so" => ["a32057aec31b03576a96d2dd14ace082ac28c6b57955648b052fd1d391dd2039", 7_528_855]
}.freeze

# The vendored modules' in-image paths, keyed by basename; empty when the
# sassc spec never activated (the require died before rubygems recorded it).
def sassc_module_paths
  spec = Gem.loaded_specs["sassc"]
  return {} if spec.nil?
  native_dir = File.join(spec.gem_dir, "lib", "sassc")
  SASSC_MODULE_WANTS.keys.to_h { |mod| [mod, File.join(native_dir, mod)] }
end

def sassc_sha256_legs
  require "digest"
  sassc_module_paths.each do |label, path|
    want_hex, want_bytes = SASSC_MODULE_WANTS[label]
    got_hex = Digest::SHA256.file(path).hexdigest
    got_bytes = File.size(path)
    verdict = got_hex == want_hex && got_bytes == want_bytes ? "match" : "differs-from-r6-image"
    puts "PROBE-DIAG sha256 #{label} #{verdict} hex=#{got_hex} bytes=#{got_bytes}"
  rescue StandardError => se
    puts "PROBE-DIAG sha256 #{label} error #{se.class}: #{se.message.lines.first.to_s.strip}"
  end
end

# Two host-surface controls by bare name (a stock OS module; an
# api-ms-win-crt contract), then each vendored sibling individually, then
# the top module — all through ffi's public DynamicLibrary.open, i.e. the
# same covered route the failing ffi_lib took. A success stays loaded and
# would poison later legs, so every success is freed at once.
def sassc_ffi_load_legs
  legs = { "ADVAPI32.dll" => "ADVAPI32.dll",
           "api-ms-win-crt-runtime-l1-1-0.dll" => "api-ms-win-crt-runtime-l1-1-0.dll" }
  sassc_module_paths.each { |label, path| legs[label] = path }
  legs.each do |label, spell|
    lib = FFI::DynamicLibrary.open(spell, FFI::DynamicLibrary::RTLD_LAZY)
    puts "PROBE-DIAG dep-load #{label} ok"
    lib.free
  rescue StandardError => le
    puts "PROBE-DIAG dep-load #{label} fail #{le.message.lines.first.to_s.strip}"
  end
end

# The raw-loader flag matrix against the materialized HOST spelling. The
# dlmap cache mirrors the memfs tree under TEBAKO_EXEC_CACHE/tebako-dl-*;
# the host spelling is not a covered path, so the shim passes it through
# byte-identical and these legs measure the OS loader alone.
def sassc_fiddle_matrix
  cache = ENV["TEBAKO_EXEC_CACHE"].to_s
  if cache.empty?
    puts "PROBE-DIAG fiddle skipped (TEBAKO_EXEC_CACHE unset)"
    return
  end
  require "fiddle"
  kernel32 = Fiddle.dlopen("kernel32")
  load_ex_a = Fiddle::Function.new(kernel32["LoadLibraryExA"],
                                   [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                                   Fiddle::TYPE_VOIDP)
  free_lib = Fiddle::Function.new(kernel32["FreeLibrary"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG)
  last_err = Fiddle::Function.new(kernel32["GetLastError"], [], Fiddle::TYPE_LONG)
  host_dir = Dir.glob(File.join(cache, "tebako-dl-*", "A_", "probe", "gemhome", "gems",
                                "sassc-2.4.0", "lib", "sassc")).first
  if host_dir.nil?
    puts "PROBE-DIAG fiddle skipped (no tebako-dl cache under #{cache})"
    return
  end
  # libsass's three flag legs first (the search-order question), then the
  # siblings' solo binds under the ffi-equivalent flag (the which-dep
  # question). A succeeded load is freed immediately so no leg poisons
  # the next via the loader's already-loaded table.
  matrix = [["libsass.so:default-order-NEGCTL", File.join(host_dir, "libsass.so"), 0x0],
            ["libsass.so:altered", File.join(host_dir, "libsass.so"), 0x8],
            ["libsass.so:search-default+dll-dir", File.join(host_dir, "libsass.so"), 0x1100]]
  SASSC_MODULE_WANTS.each_key { |mod| matrix << ["#{mod}:altered", File.join(host_dir, mod), 0x8] }
  matrix.each do |label, host_path, fl|
    unless File.exist?(host_path)
      puts "PROBE-DIAG fiddle-load #{label} missing-on-host #{host_path}"
      next
    end
    h = load_ex_a.call(Fiddle::Pointer[host_path], nil, fl)
    if h.nil? || h.zero?
      puts "PROBE-DIAG fiddle-load #{label} fail os-err=#{last_err.call}"
    else
      puts "PROBE-DIAG fiddle-load #{label} ok"
      free_lib.call(h)
    end
  rescue StandardError => fe
    puts "PROBE-DIAG fiddle-load #{label} error #{fe.class}: #{fe.message.lines.first.to_s.strip}"
  end
rescue StandardError => fe
  puts "PROBE-DIAG fiddle aborted #{fe.class}: #{fe.message.lines.first.to_s.strip}"
end

def require_sassc_with_bisect
  require "sassc"
rescue LoadError => e
  sassc_sha256_legs
  sassc_ffi_load_legs
  sassc_fiddle_matrix
  raise e
end

case ARGV[0]
when "sinatra-fixed", "sinatra-unfixed"
  fixed = ARGV[0] == "sinatra-fixed"
  require_relative(fixed ? "app" : "app_unfixed")
  app_file, root, status, body = static_fetch
  want = File.read(File.join(PROBE_DIR, "public/static.txt"))
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
  require_sassc_with_bisect
  puts "PROBE sassc-version #{SassC::VERSION}"
  css = SassC::Engine.new(File.read(File.join(PROBE_DIR, "styles/plain.scss"))).render
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
  require_sassc_with_bisect
  puts "PROBE sassc-version #{SassC::VERSION}"
  begin
    # The SAME import against the image pressed WITHOUT materialize: —
    # the negative oracle. The importer's fopen() of the VFS path is not
    # host-real, so the pinned class-R failure must reproduce verbatim.
    css = sassc_partial(File.join(PROBE_DIR, "styles"))
    puts "PROBE sassc-partial-unmaterialized unexpected-ok bytes=#{css.bytesize}"
    exit 1
  rescue Exception => e # rubocop:disable Lint/RescueException -- the probe must see every failure mode
    puts "PROBE sassc-partial-unmaterialized expected-fail #{e.class}: #{e.message.lines.first.to_s.strip}"
  end
else
  warn "probe.rb: unknown leg #{ARGV[0].inspect} (sinatra-fixed|sinatra-unfixed|sassc|sassc-unmaterialized)"
  exit 64
end
