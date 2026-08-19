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
#   sassc-matrix     — pure forensics, never gates: the incident-13 diag
#                      sheet (sha256 legs, ffi solo loads, the spelling ×
#                      flag raw-loader matrix) run WITHOUT the require
#                      attempt, so the loader starts pristine. windows
#                      only (POSIX prints a skip line). Expected GREEN.
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

# Incident 13 round 8 diagnostics. Round 7 answered the byte and bind
# questions: every vendored module's sha256 through ruby's patched IO
# matched the image-extracted constants (no windows backend read bug),
# the closure walk materialized the siblings co-dir, and each module —
# libsass.so included — SOLO-LOADS through ffi's DynamicLibrary.open once
# its siblings are resident in the process. Yet ffi_lib's load of the
# in-image libsass.so spelling still 126'd at require time, and the ext/
# fallback's error 5 is the jail's EACCES synthesis on a file the image
# never held (the mkmf stub is not installed there — red herring). So
# the failure lives in the DEPENDENCY search of ffi's raw LoadLibraryExA
# (LOAD_WITH_ALTERED_SEARCH_PATH on the non-relative spelling), not in
# the bytes and not in the main module's own open.
#
# Round 8's questions:
#  (a) the spelling × flag matrix (sassc_raw_matrix) — the A: legs name
#      the covered route's answer per flag; the host legs measure the
#      bare OS loader; the 0x0 leg is the default-order negative control;
#  (b) the already-loaded-table discriminator (sassc_ffi_load_legs runs
#      libsass.so before AND after its siblings);
#  (c) the DECLARED answer (the candidate fix): the payload manifests
#      stamp library_aliases: for the vendored closure at press time
#      (spec 03 §2.5), so the driver boot-materializes the siblings and
#      PATH-leads their dir — the spec 22 §2.1 raw-surface mechanism,
#      exercised end to end. ffi_lib's own A: spelling keeps its route;
#      the alias carries the bare-name IMPORTS the PE closure lists.
# Never gates: the original LoadError re-raises after the verdicts, and
# no leg may kill the sheet (every leg rescues LoadError/StandardError).

# sha256 + byte counts of the three vendored modules, extracted from the
# round-6 run's pressed payload image (probe-gems-4.0.6.tfs) on macOS via
# the dwarfs-t backend's POSIX read path.
SASSC_MODULE_WANTS = {
  "libwinpthread-1.dll" => ["0bf76de7b957fc1f87f8be9c8c46af4588db204b0600a3e7abe7243c790f8dfd", 63_135],
  "libgcc_s_seh-1.dll" => ["80940372431cc76224dfda06e2d33f01e49af3b4e7c499c535be856ebcadd273", 151_654],
  "libsass.so" => ["a32057aec31b03576a96d2dd14ace082ac28c6b57955648b052fd1d391dd2039", 7_528_855]
}.freeze

# The vendored modules' in-image paths, keyed by basename; empty when the
# sassc spec is not discoverable. find_by_name, never loaded_specs — the
# sassc-matrix leg runs this sheet WITHOUT a require attempt, so nothing
# has activated the spec; the bisect path (post-LoadError) finds the same
# record either way.
def sassc_module_paths
  spec = Gem::Specification.find_by_name("sassc")
  return {} if spec.nil?
  native_dir = File.join(spec.gem_dir, "lib", "sassc")
  SASSC_MODULE_WANTS.keys.to_h { |mod| [mod, File.join(native_dir, mod)] }
rescue LoadError, StandardError
  {} # a broken gemhome index must not take the sheet down with it
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
# api-ms-win-crt contract), then the vendored modules — all through
# ffi's public DynamicLibrary.open, i.e. the same covered route the
# failing ffi_lib took (ffi's win32 dl_open ignores the RTLD flags and
# binds LoadLibraryExA with LOAD_WITH_ALTERED_SEARCH_PATH for every
# non-relative spelling — DynamicLibrary.c). libsass.so runs FIRST
# (nothing vendored resident — the already-loaded-table discriminator),
# the siblings next, then libsass.so again: a first-fail/second-ok pair
# names the dep-search class, and a success stays loaded (ffi 1.17's
# DynamicLibrary has no public free — the round-7 `.free` legs were
# NoMethodError noise; the raw matrix below owns the freed-legs
# questions).
def sassc_ffi_load_legs
  legs = { "ADVAPI32.dll" => "ADVAPI32.dll",
           "api-ms-win-crt-runtime-l1-1-0.dll" => "api-ms-win-crt-runtime-l1-1-0.dll" }
  paths = sassc_module_paths
  legs["libsass.so"] = paths["libsass.so"] if paths["libsass.so"]
  %w[libwinpthread-1.dll libgcc_s_seh-1.dll].each { |mod| legs[mod] = paths[mod] if paths[mod] }
  legs["libsass.so:again"] = paths["libsass.so"] if paths["libsass.so"]
  legs.each do |label, spell|
    FFI::DynamicLibrary.open(spell, FFI::DynamicLibrary::RTLD_LAZY)
    puts "PROBE-DIAG dep-load #{label} ok"
  rescue LoadError, StandardError => le
    puts "PROBE-DIAG dep-load #{label} fail #{le.message.lines.first.to_s.strip}"
  end
end

# The raw-loader matrix — spelling × flags — driven through FFI-bound
# kernel32 calls. Round 7 drove this through fiddle; fiddle left the
# default-gem set in ruby 4.0 ("fiddle is not part of the default gems"
# — the round-7 sheet died on the require, a LoadError StandardError
# never rescues). ffi is already on the sheet path (sassc's native.rb
# requires it before the failing ffi_lib) and its DynamicLibrary is the
# very surface under test, so the matrix needs no new dependency.
#
# The A: (VFS) legs are the covered-route question — does the shim serve
# the loader for THIS spelling/flag pair; the host legs measure the bare
# OS loader (the shim passes the materialized spelling through
# byte-identical). 0x0 (default order) is the negative control: the
# standard order never searches the DLL's own dir, so a 126 there is
# documented behavior and a SUCCESS rewrites the model. 0x8 is ffi's own
# binding (DynamicLibrary.c: LoadLibraryExA with LOAD_WITH_ALTERED_
# SEARCH_PATH for non-relative names). Every success is FreeLibrary'd at
# once so no leg poisons the next through the already-loaded table.
def sassc_raw_matrix
  unless Gem.win_platform?
    puts "PROBE-DIAG raw-matrix skipped (posix)"
    return
  end
  k32 = Module.new do
    extend FFI::Library
    ffi_lib "kernel32"
    attach_function :load_ex, :LoadLibraryExA, %i[string pointer ulong], :pointer
    attach_function :free_lib, :FreeLibrary, [:pointer], :int
    attach_function :last_err, :GetLastError, [], :ulong
  end
  paths = sassc_module_paths
  cache = ENV["TEBAKO_EXEC_CACHE"].to_s
  host_dir = cache.empty? ? nil : Dir.glob(File.join(cache, "tebako-dl-*", "A_", "probe", "gemhome", "gems",
                                                     "sassc-*", "lib", "sassc")).first
  legs = []
  [["default-order-NEGCTL", 0x0], ["altered", 0x8], ["search-default+dll-dir", 0x1100]].each do |fname, fl|
    legs << ["libsass.so:vfs:#{fname}", paths["libsass.so"], fl]
    legs << ["libsass.so:host:#{fname}", host_dir && File.join(host_dir, "libsass.so"), fl]
  end
  %w[libwinpthread-1.dll libgcc_s_seh-1.dll].each do |mod|
    legs << ["#{mod}:vfs:altered", paths[mod], 0x8]
    legs << ["#{mod}:host:altered", host_dir && File.join(host_dir, mod), 0x8]
  end
  legs.each do |label, spell, fl|
    if spell.nil?
      puts "PROBE-DIAG raw-load #{label} skipped (no spelling)"
      next
    end
    h = k32.load_ex(spell, nil, fl)
    if h.nil? || h.null?
      puts "PROBE-DIAG raw-load #{label} fail os-err=#{k32.last_err}"
    else
      puts "PROBE-DIAG raw-load #{label} ok"
      k32.free_lib(h)
    end
  rescue LoadError, StandardError => fe
    puts "PROBE-DIAG raw-load #{label} error #{fe.class}: #{fe.message.lines.first.to_s.strip}"
  end
end

# The diag sheet, shared by the bisect rescue (post-LoadError state) and
# the sassc-matrix leg (pristine state). ffi must load for the sheet to
# exist at all — name it and bail when even that fails.
def run_sassc_sheet
  begin
    require "ffi"
  rescue LoadError => le
    puts "PROBE-DIAG sheet aborted: ffi itself does not load (#{le.message.lines.first.to_s.strip})"
    return
  end
  sassc_sha256_legs
  sassc_ffi_load_legs
  sassc_raw_matrix
end

def require_sassc_with_bisect
  require "sassc"
rescue LoadError => e
  run_sassc_sheet
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
when "sassc-matrix"
  # Forensics WITHOUT the require attempt (pristine loader state): the
  # full diag sheet, never gates. windows-only — the raw-loader matrix
  # measures the windows loader's own semantics; POSIX has no such
  # question (dlopen serves the covered route directly).
  if Gem.win_platform?
    run_sassc_sheet
    puts "PROBE sassc-matrix done"
  else
    puts "PROBE sassc-matrix skipped (posix)"
  end
else
  warn "probe.rb: unknown leg #{ARGV[0].inspect} (sinatra-fixed|sinatra-unfixed|sassc|sassc-unmaterialized|sassc-matrix)"
  exit 64
end
