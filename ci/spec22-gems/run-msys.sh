#!/bin/bash
# ci/spec22-gems/run-msys.sh — spec 22 gem-level acceptance, WINDOWS leg.
# The msys port of run.sh (spec 22 §8's last acceptance row: the v2
# dogfood suite green with the gem gone on EVERY published platform).
# Runs the same four jailed proof legs against the same fixtures and
# pins the same PROBE lines (README.md) — plus a fifth forensic leg
# (sassc-matrix: the incident-13 diag sheet on a pristine loader, never
# gates) — with the gem-loaded canary pinned `no`.
#
# Unlike run.sh this script BUILDS NOTHING: the runtime (exe + ruby DLL
# + env image) arrives as the factory's CI build-leg artifact and the
# press/extract tooling is the published windows tfs CLI. On msys the
# roll/link-unit/factory-build steps of run.sh would reproduce the
# factory's own CI on a slower footing — the factory chain already
# proves them (and the release gate wants the SHIPPED shape exercised,
# not a local rebuild).
#
# Consumed by the factory's windows dogfood job (tebako-runtime-ruby
# build-windows.yml), which fetches the artifacts and exports the inputs
# below; runnable by hand on any msys shell with the same inputs.
#
# Usage: ci/spec22-gems/run-msys.sh [ruby-version]   (default 4.0.6)
#
# Required env:
#   RUNTIME_PKG_DIR — the factory runtime-packages artifact extracted
#                     (holds tebako-runtime-*-windows-ucrt64[.exe],
#                     the uniquely-named .dll, the .tfs env image)
#   DEVKIT_DIR      — the factory devkit artifact extracted
#                     (include/ = the stash headers the env image omits,
#                     lib/libx64-ucrt-ruby<ABI>.dll.a = the import library
#                     an msys native extension links against)
#   TFS_CLI         — the published windows tfs.exe (press + extract)
# Overridable:
#   SCRATCH     (default: /tmp/spec22-gems-msys-scratch-<version>;
#               POSIX spelling — it rides the conv_envvars below)
#   UCRT64_BIN  (default: /d/a/_temp/msys64/ucrt64/bin — the
#               setup-msys2 location; the gem-install leg's PATH source
#               for gcc/make, exactly what the factory builds with;
#               POSIX spelling — it rides PATH, a conv_envvar)
#
# Path discipline: the runtime exe, tfs.exe, and cmd.exe are NATIVE
# windows binaries, and msys bash's AUTOMATIC argv conversion is the
# trap: it rewrites leading-slash arguments into install-rooted host
# paths (`/setup/gem.rb` → `D:/a/_temp/msys64/setup/gem.rb` — the first
# dogfood run's exit-1), which silently corrupts VFS paths and
# cmd-style flags. So this script disables it outright
# (MSYS2_ARG_CONV_EXCL='*'): NOTHING is auto-converted, and every
# argument to a native binary is spelled in final form BY HAND —
# host paths through cygpath -m (the w() helper), VFS paths
# (/--spellings inside images) raw, cmd flags raw (/c, /D).
# msys-to-msys spawns (find/cp/grep/…) are unaffected either way.
# SUBTLETY: the scrubbed legs run the exe through `env -i`, which strips
# the exported copy — the conversion decision belongs to the DIRECT
# spawner (env, not bash), so MSYS2_ARG_CONV_EXCL rides INSIDE every
# env -i list too (env sets it into its own environ before the exec).
#
# The ENVIRONMENT side has TWO msys conversion layers and they take
# OPPOSITE spellings from this harness (msys2-runtime environ.cc):
#  1. conv_envvars — PATH, HOME, LD_LIBRARY_PATH, ORIGINAL_PATH, SHELL,
#     TMPDIR, TMP, TEMP — are converted posix→win32 UNCONDITIONALLY
#     when an msys process spawns a native one (cygwin's invariant: a
#     process's own environ holds these in POSIX form, always). The
#     eleventh dogfood incident fed them cygpath-m windows values:
#     build_env split `D:/a/…;D:/a/…;C:/Windows/System32` on ':' as
#     bogus POSIX list separators and mapped each fragment
#     (`D` + `/a/…`→`A:\…`; `C` + `/Windows/…`→`<install-root>\Windows\…`),
#     so every PATH entry was nonexistent and mkmf's bare-name `make`
#     spawn went ENOENT with make installed. MSYS2_ENV_CONV_EXCL does
#     NOT reach this layer. So the five are spelled in POSIX form below
#     (no w(); SCRATCH/UCRT64_BIN are already posix) and the boundary
#     converts them — the runtime receives the same win32 values the
#     cygpath-m spelling intended.
#  2. The HEURISTIC layer rewrites the VALUES of every OTHER variable
#     that looks like a path list. MSYS2_ENV_CONV_EXCL='*' disables it
#     entirely; it rides inside every env -i list chiefly because
#     TEBAKO_JAIL's grammar is a colon-list (`deny;<win32>:/host-scratch:rw`)
#     the heuristic would mangle. All non-conv values (TEBAKO_*,
#     USERPROFILE, APPDATA, SystemRoot, COMSPEC, GEM_*) keep their
#     cygpath-m windows spellings and pass through verbatim.
#
# Env discipline: `env -i` proves the runtime needs nothing from the host
# ENVIRONMENT — but on windows there is a floor. A custom env block below
# the platform baseline breaks SYSTEM apis the runtime legitimately
# calls: with no SystemDrive/WINDIR/ProgramData in the block,
# SHGetSpecialFolderLocation(CSIDL_COMMON_APPDATA) fails (the
# registry-held shell-folder spellings are expanded against the process
# env — below the baseline there is nothing to expand with),
# Etc.sysconfdir returns
# nil, and rubygems' config_file.rb dies at CLASS-LOAD (`File.join nil` —
# the sixth dogfood run's exit-1). A real user's env always carries the
# baseline, so a runtime that works there but not under a bare env -i is
# not a hermeticity failure — the bare block is simply not a survivable
# windows process. Both env -i lists therefore pin the baseline:
# SystemDrive/WINDIR/ProgramData/ALLUSERSPROFILE as the stock C:\
# constants (inert STRINGS — the jail still decides file access) and
# USERPROFILE/APPDATA scoped into the scratch like HOME. Section 3.5's
# envprobe diagnostic documents the mechanism in every run's log.

set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
export MSYS2_ENV_CONV_EXCL='*'

VERSION="${1:-4.0.6}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

RUNTIME_PKG_DIR="${RUNTIME_PKG_DIR:?run-msys.sh: RUNTIME_PKG_DIR (the factory runtime-packages artifact dir) is required}"
DEVKIT_DIR="${DEVKIT_DIR:?run-msys.sh: DEVKIT_DIR (the factory devkit artifact dir) is required}"
TFS_CLI="${TFS_CLI:?run-msys.sh: TFS_CLI (the published windows tfs.exe) is required}"
SCRATCH="${SCRATCH:-/tmp/spec22-gems-msys-scratch-$VERSION}"
UCRT64_BIN="${UCRT64_BIN:-/d/a/_temp/msys64/ucrt64/bin}"

case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *) echo "FAIL run-msys.sh: this leg is msys-only (uname: $(uname -s)); use run.sh on POSIX" >&2; exit 64 ;;
esac

# The pins — same gems, same negative-oracle signature as run.sh.
SINATRA_VERSION="4.2.1"
SASSC_VERSION="2.4.0"
SASSC_PARTIAL_PIN='SassC::SyntaxError: Error: File to import not found or unreadable: partials/thing.'

step() { echo "== spec22-gems-msys step: $*"; }
die()  { echo "FAIL spec22-gems-msys ($*)" >&2; exit 1; }
# Native-windows (mixed) spelling for values that cross the env/argv
# boundary into the runtime exe or tfs.exe. ARGV and NON-conv env values
# only — PATH/HOME/TMPDIR/TMP/TEMP (msys's conv_envvars) must stay
# POSIX, see the header comment.
w()    { cygpath -m "$1"; }

[ -x "$TFS_CLI" ] || [ -f "$TFS_CLI" ] || die "tfs CLI not at $TFS_CLI (download the tebako release's windows tfs.exe)"

# x64-ucrt-ruby<ABI>.dll — ruby configure's RUBY_SO_NAME for
# x86_64-w64-mingw32; <ABI> = <MAJOR><MINOR>0 (factory RubyVersion#msys_dll_name
# is the name's owner; mirrored here because a bash harness cannot flow it).
ABI="$(echo "$VERSION" | awk -F. '{printf "%d%d0", $1, $2}')"
PE_DLL="x64-ucrt-ruby${ABI}.dll"

mkdir -p "$SCRATCH"/{tmp,home,tebako-home}
export TMPDIR="$SCRATCH/tmp"

# --- 1. stage the runtime dir (exe + PE-named DLL + env image) -----------
# The artifact carries the DLL under the unique package name; the exe's
# PE imports resolve it only as x64-ucrt-ruby<ABI>.dll next to the exe
# (the consumer materializes the copy — the factory boot smoke's
# materialize_ruby_dll is the mirrored rule).
RUNTIME_DIR="$SCRATCH/runtime"
if [ ! -f "$RUNTIME_DIR/.staged-$VERSION" ]; then
  step "stage runtime package from $RUNTIME_PKG_DIR"
  rm -rf "$RUNTIME_DIR"; mkdir -p "$RUNTIME_DIR"
  exe="$(find "$RUNTIME_PKG_DIR" -maxdepth 2 -name 'tebako-runtime-*-windows-*' ! -name '*.dll' ! -name '*.tfs' ! -name '*.json' | head -1)"
  [ -n "$exe" ] || die "no runtime exe under $RUNTIME_PKG_DIR"
  pkg="${exe%.exe}"
  [ -f "$pkg.dll" ] || die "no package DLL at $pkg.dll"
  [ -f "$pkg.tfs" ] || die "no env image at $pkg.tfs"
  cp "$exe" "$RUNTIME_DIR/tebako-runtime.exe"
  cp "$pkg.dll" "$RUNTIME_DIR/$PE_DLL"
  cp "$pkg.tfs" "$RUNTIME_DIR/tebako-runtime.tfs"
  touch "$RUNTIME_DIR/.staged-$VERSION"
fi
RUNTIME_EXE="$RUNTIME_DIR/tebako-runtime.exe"
RUNTIME_IMAGE="$RUNTIME_DIR/tebako-runtime.tfs"

# The gem-kill acceptance, windows row: the env image must carry NO
# tebako-runtime gemspec (post-M2 the factory installs none).
img_gems="$("$TFS_CLI" find "$(w "$RUNTIME_IMAGE")" 'tebako-runtime-*.gemspec' | grep '^/lib/ruby/gems/' | sort -u || true)"
[ -z "$img_gems" ] \
  || die "env image carries a tebako-runtime gemspec — the gem kill regressed: $(echo "$img_gems" | tr '\n' ' ')"

# --- 2. the mount-root bridge tree (setup leg only) -----------------------
# Same construct as run.sh's ENV_HOST: the gem-install leg's two native
# consumers (rubygems' OpenSSL add_file on the in-image certs; mkmf's
# host-gcc compiles) read raw HOST paths under the runtime root. POSIX
# solves this with TEBAKO_MOUNT_ROOT — the driver re-mounts the env image
# at a host-real tree whose layout grants mount_root_override. On msys
# that mechanism does not exist BY DESIGN: configure forces LOAD_RELATIVE
# (the ruby.c loadpath helper compiles out), so the tarball carries no
# override manifest and the image grant stays closed. The windows bridge
# needs no override at all:
#   * the era-2 msys rbconfig already spells prefix/exec-prefix as
#     ENV["TEBAKO_MOUNT_ROOT"] || 'A:/t' — with the env unset, every
#     rbconfig-derived path is A:/t/...;
#   * `subst A: <bridge-parent>` makes the baked root HOST-REAL — A:\t IS
#     the bridge — so raw C opens (OpenSSL's fopen, the spawned gcc's
#     -I/-L) read the bridge through the drive-letter alias;
#   * rubygems respawns RbConfig.ruby (= A:/t/bin/ruby.exe) per extconf:
#     the bridge's exe copy plain-boots (no --tebako-* flags) and
#     LOAD_RELATIVE self-roots its load paths at A:/t — the subst serves
#     those reads too. The bridge must therefore live at <parent>/t.
# The tree is RECONSTITUTED from the shipped artifacts (no factory
# checkout): `tfs extract` of the env image + the devkit's include/ + the
# import library where rbconfig's libdir expects it. bin/ruby.exe is a
# copy of the runtime exe plus the PE-named DLL its imports resolve.
ENV_HOST_PARENT="$SCRATCH/a-drive"
ENV_HOST="$ENV_HOST_PARENT/t"
if [ ! -f "$ENV_HOST/.bridge-$VERSION" ]; then
  step "reconstitute the mount-root bridge tree (tfs extract + devkit)"
  rm -rf "$ENV_HOST"
  mkdir -p "$ENV_HOST/bin" "$ENV_HOST/lib"
  "$TFS_CLI" extract -q -d "$(w "$ENV_HOST")" "$(w "$RUNTIME_IMAGE")"
  [ -d "$DEVKIT_DIR/include" ] || die "devkit include/ missing under $DEVKIT_DIR"
  imp="$(find "$DEVKIT_DIR/lib" -name 'libx64-ucrt-ruby*.dll.a' | head -1)"
  [ -n "$imp" ] || die "devkit import library missing under $DEVKIT_DIR/lib"
  cp -R "$DEVKIT_DIR/include" "$ENV_HOST/include"
  cp "$imp" "$ENV_HOST/lib/"
  cp "$RUNTIME_EXE" "$ENV_HOST/bin/ruby.exe"
  cp "$RUNTIME_DIR/$PE_DLL" "$ENV_HOST/bin/$PE_DLL"
  touch "$ENV_HOST/.bridge-$VERSION"
fi

# --- 3. the setup image (GemRunner shim) ----------------------------------
# Identical to run.sh: the env image ships rubygems but no gem binstub,
# so the stock bin/gem body rides a tiny setup image (un-jailed: press,
# not proof).
SETUP_IMG="$SCRATCH/setup.tfs"
if [ ! -f "$SETUP_IMG" ] || [ "$SELF_DIR/fixtures/gem.rb" -nt "$SETUP_IMG" ] \
   || [ "$SELF_DIR/fixtures/envprobe.rb" -nt "$SETUP_IMG" ] \
   || [ "$SELF_DIR/fixtures/pipeprobe.rb" -nt "$SETUP_IMG" ]; then
  step "press setup image (GemRunner shim)"
  rm -rf "$SCRATCH/setup-tree"
  mkdir -p "$SCRATCH/setup-tree/setup"
  cp "$SELF_DIR/fixtures/gem.rb" "$SCRATCH/setup-tree/setup/"
  cp "$SELF_DIR/fixtures/envprobe.rb" "$SCRATCH/setup-tree/setup/"
  cp "$SELF_DIR/fixtures/pipeprobe.rb" "$SCRATCH/setup-tree/setup/"
  "$TFS_CLI" mkimage --format dwarfs "$(w "$SCRATCH/setup-tree")" --output "$(w "$SETUP_IMG")" >/dev/null
fi

# --- 3.5 env diagnostic: Etc.sysconfdir under scrubbed envs -------------
# Pins the env-discipline mechanism (header comment) with evidence in
# every run's log. env_probe runs the staged exe exactly as the legs do
# (driver + TEBAKO_RUNTIME_IMAGE + setup image entry; VFS-only fixture,
# so no subst bridge) under three scrubs: BARE = the pre-fix shape (the
# regression record — expected etc-sysconfdir=nil), BASELINE = the fix
# (must be non-nil or the install leg below dies the same way — fail
# HERE with the evidence in the log), MINIMAL = baseline minus the
# profile vars (isolates the REG_EXPAND_SZ expansion candidates
# SystemDrive/WINDIR/ProgramData from USERPROFILE/APPDATA).
env_probe() {
  local name="$1"; shift
  set +e
  env -i \
    MSYS2_ARG_CONV_EXCL='*' \
    MSYS2_ENV_CONV_EXCL='*' \
    HOME="$SCRATCH/home" \
    TMPDIR="$SCRATCH/tmp" \
    TMP="$SCRATCH/tmp" \
    TEMP="$SCRATCH/tmp" \
    PATH='/c/Windows/System32' \
    SystemRoot='C:\Windows' \
    "$@" \
    TEBAKO_RUNTIME_IMAGE="$(w "$RUNTIME_IMAGE")" \
    "$RUNTIME_EXE" --tebako-image "$(w "$SETUP_IMG"):-:/" --tebako-entry /setup/envprobe.rb \
    > "$SCRATCH/envprobe-$name.log" 2>&1
  local st=$?
  set -e
  cat "$SCRATCH/envprobe-$name.log"
  return "$st"
}
step "env diagnostic: Etc.sysconfdir under bare / baseline / minimal scrubs"
env_probe bare || true
env_probe baseline \
  SystemDrive='C:' \
  WINDIR='C:\Windows' \
  ProgramData='C:\ProgramData' \
  ALLUSERSPROFILE='C:\ProgramData' \
  USERPROFILE="$(w "$SCRATCH/home")" \
  APPDATA="$(w "$SCRATCH/home")/AppData/Roaming" \
  || die "envprobe baseline leg itself failed (see envprobe-baseline.log above)"
env_probe minimal \
  SystemDrive='C:' \
  WINDIR='C:\Windows' \
  || true
grep -qE '^PROBE-ENV etc-sysconfdir="' "$SCRATCH/envprobe-baseline.log" \
  || die "Etc.sysconfdir is nil even WITH the windows baseline env — the env-baseline theory is falsified; see envprobe-baseline.log above"

# --- 4. probe gems installed by the runtime's OWN gem tooling -------------
# sassc's native extension is compiled by the runtime's own mkmf through
# the ucrt64 gcc (the toolchain the factory builds with), guaranteeing
# ABI match. PATH here carries the toolchain + the windows system surface
# (cmd.exe for mkmf's shell-outs; the loader's DLL root); the proof legs
# below run WITHOUT it — the payload needs no compiler at run time.
GEMHOME="$SCRATCH/gemhome"
INSTALL_STAMP="$GEMHOME/.spec22-gems-$SINATRA_VERSION-$SASSC_VERSION.installed"
if [ ! -f "$INSTALL_STAMP" ]; then
  step "gem install sinatra:$SINATRA_VERSION sassc:$SASSC_VERSION via the staged runtime"
  rm -rf "$GEMHOME" "$SCRATCH/gembin"
  mkdir -p "$SCRATCH/spec_cache"
  # The bridge goes host-real at the baked root for THIS leg only (the
  # section-2 comment): A:\t == the bridge. Scoped — created here,
  # deleted right after the run; the proof legs never see the alias.
  cmd /c subst A: "$(cygpath -w "$ENV_HOST_PARENT")" >/dev/null \
    || die "subst A: onto $ENV_HOST_PARENT failed — is A: already taken?"
  # Diagnostic: the extconf respawn's spawn mechanics, isolated with FULL
  # backtraces before the install attempt (the seventh dogfood incident:
  # rubygems' ext builder printed "extconf failedundefined method 'close'
  # for nil" — open3's popen2e ensure masks the original exception when a
  # pipe step raises, so the real error never reached the log). Runs the
  # SAME env -i list as the install leg with the bridge host-real; always
  # catted, never gates — the PROBE-PIPE lines plus the install transcript
  # pinpoint the failing primitive.
  set +e
  env -i \
    MSYS2_ARG_CONV_EXCL='*' \
    MSYS2_ENV_CONV_EXCL='*' \
    HOME="$SCRATCH/home" \
    TMPDIR="$SCRATCH/tmp" \
    TMP="$SCRATCH/tmp" \
    TEMP="$SCRATCH/tmp" \
    PATH="$UCRT64_BIN:/usr/bin:/c/Windows/System32" \
    SystemRoot='C:\Windows' \
    SystemDrive='C:' \
    WINDIR='C:\Windows' \
    ProgramData='C:\ProgramData' \
    ALLUSERSPROFILE='C:\ProgramData' \
    USERPROFILE="$(w "$SCRATCH/home")" \
    APPDATA="$(w "$SCRATCH/home")/AppData/Roaming" \
    COMSPEC='C:\Windows\System32\cmd.exe' \
    TEBAKO_HOME="$(w "$SCRATCH/tebako-home")" \
    TEBAKO_RUNTIME_IMAGE="$(w "$RUNTIME_IMAGE")" \
    "$RUNTIME_EXE" --tebako-image "$(w "$SETUP_IMG"):-:/" --tebako-entry /setup/pipeprobe.rb \
    > "$SCRATCH/pipeprobe.log" 2>&1
  probe_status=$?
  set -e
  cat "$SCRATCH/pipeprobe.log"
  [ "$probe_status" -eq 0 ] \
    || echo "== spec22-gems-msys note: pipeprobe exit $probe_status (diagnostic only)"
  set +e
  env -i \
    MSYS2_ARG_CONV_EXCL='*' \
    MSYS2_ENV_CONV_EXCL='*' \
    HOME="$SCRATCH/home" \
    TMPDIR="$SCRATCH/tmp" \
    TMP="$SCRATCH/tmp" \
    TEMP="$SCRATCH/tmp" \
    PATH="$UCRT64_BIN:/usr/bin:/c/Windows/System32" \
    SystemRoot='C:\Windows' \
    SystemDrive='C:' \
    WINDIR='C:\Windows' \
    ProgramData='C:\ProgramData' \
    ALLUSERSPROFILE='C:\ProgramData' \
    USERPROFILE="$(w "$SCRATCH/home")" \
    APPDATA="$(w "$SCRATCH/home")/AppData/Roaming" \
    COMSPEC='C:\Windows\System32\cmd.exe' \
    TEBAKO_HOME="$(w "$SCRATCH/tebako-home")" \
    TEBAKO_RUNTIME_IMAGE="$(w "$RUNTIME_IMAGE")" \
    GEM_SPEC_CACHE="$(w "$SCRATCH/spec_cache")" \
    "$RUNTIME_EXE" --tebako-image "$(w "$SETUP_IMG"):-:/" --tebako-entry /setup/gem.rb \
      install "sinatra:$SINATRA_VERSION" "sassc:$SASSC_VERSION" \
      --install-dir "$(w "$GEMHOME")" --bindir "$(w "$SCRATCH/gembin")" --no-document \
      > "$SCRATCH/install.log" 2>&1
  gem_status=$?
  set -e
  cmd /c subst A: /D >/dev/null 2>&1 || true
  cat "$SCRATCH/install.log"
  [ "$gem_status" -eq 0 ] || die "gem install leg (see $SCRATCH/install.log)"
  grep -q "Successfully installed sinatra-$SINATRA_VERSION" "$SCRATCH/install.log" \
    || die "sinatra $SINATRA_VERSION not in the install log"
  grep -q "Successfully installed sassc-$SASSC_VERSION" "$SCRATCH/install.log" \
    || die "sassc $SASSC_VERSION not in the install log"
  # Incident 13: sassc's ffi_lib spells libsass.so by FULL path and ffi
  # calls LoadLibraryExA on it raw — the dln-load IAT rebind (ruby's msys
  # dln patch) routes that through the Rule-L1 materialize-then-load path,
  # whose PE closure walk resolves an imported DLL ONLY in the IMPORTING
  # module's own directory (the locked importer-dir rule — never a
  # cross-mount search). libsass.so's ucrt import closure
  # (libstdc++-6.dll → libgcc_s_seh-1.dll / libwinpthread-1.dll) lives in
  # $UCRT64_BIN on the host, NOT in the gem tree, so the materialized
  # module's closure would miss and the load would 126. Vendor the
  # transitive closure next to each libsass.so copy BEFORE the press so
  # the payload image is self-contained — existence-tested per name (OS
  # DLLs the toolchain bin dir does not carry are skipped by rule), no
  # hardcoded DLL list.
  # objdump path discipline (incident 13 round 2): the ucrt64 objdump is
  # a NATIVE exe and MSYS2_ARG_CONV_EXCL='*' disables bash's automatic
  # argv conversion, so a POSIX spelling reaches it verbatim and it
  # answers "No such file". Use /usr/bin/objdump (msys-native, reads
  # POSIX paths itself) whenever present — `command -v` is unusable for
  # this (an UCRT64 MSYSTEM puts the native one first in PATH); the
  # native fallback gets cygpath-m'd paths.
  OBJDUMP_BIN=/usr/bin/objdump
  if [ -x "$OBJDUMP_BIN" ]; then
    vendor_path() { printf '%s' "$1"; }
  else
    OBJDUMP_BIN="$UCRT64_BIN/objdump"
    [ -x "$OBJDUMP_BIN" ] || die "objdump not found at /usr/bin or $UCRT64_BIN"
    vendor_path() { cygpath -m "$1"; }
  fi
  vendor_closure() {
    local so="$1" dir changed guard pe dll
    [ -f "$so" ] || return 0
    dir="$(dirname "$so")"
    changed=1; guard=0
    while [ "$changed" -eq 1 ]; do
      changed=0; guard=$((guard + 1))
      [ "$guard" -le 8 ] || die "DLL closure vendoring did not converge under $dir"
      for pe in "$so" "$dir"/*.dll; do
        [ -f "$pe" ] || continue
        for dll in $("$OBJDUMP_BIN" -p "$(vendor_path "$pe")" | awk '/DLL Name:/ {print $3}'); do
          if [ ! -f "$dir/$dll" ] && [ -f "$UCRT64_BIN/$dll" ]; then
            cp "$UCRT64_BIN/$dll" "$dir/"
            echo "== spec22-gems-msys vendored $dll -> $dir (import of $(basename "$pe"))"
            changed=1
          fi
        done
      done
    done
  }
  vendor_closure "$GEMHOME/gems/sassc-$SASSC_VERSION/ext/libsass.so"
  vendor_closure "$GEMHOME/gems/sassc-$SASSC_VERSION/lib/sassc/libsass.so"
  touch "$INSTALL_STAMP"
fi

# --- 5. probe payload images (the class-R pair) ----------------------------
# Byte-for-byte run.sh's press: ONE tree, TWO presses; the materialize:
# declaration is the ONLY difference; both manifests asserted after press
# (a tfs CLI that drops the unknown key on re-serialization fails loud).
PROBE_TREE="$SCRATCH/probe-tree"
PAYLOAD_IMG="$SCRATCH/probe-gems-$VERSION.tfs"
PAYLOAD_IMG_NOMAT="$SCRATCH/probe-gems-$VERSION-unmaterialized.tfs"
if [ ! -f "$PAYLOAD_IMG" ] || [ ! -f "$PAYLOAD_IMG_NOMAT" ] \
   || [ "$INSTALL_STAMP" -nt "$PAYLOAD_IMG" ] \
   || [ -n "$(find "$SELF_DIR/fixtures" -newer "$PAYLOAD_IMG" -print -quit 2>/dev/null)" ]; then
  step "assemble probe tree + press payload images (materialized + negative oracle)"
  rm -rf "$PROBE_TREE"
  mkdir -p "$PROBE_TREE/probe" "$PROBE_TREE/__tpkg__"
  cp -R "$SELF_DIR/fixtures/." "$PROBE_TREE/probe/"
  rm -rf "$PROBE_TREE/probe/gem.rb"
  rm -f "$PROBE_TREE/probe/envprobe.rb" \
        "$PROBE_TREE/probe/pipeprobe.rb"
  rm -f "$PROBE_TREE/probe/payload-manifest.yaml" \
        "$PROBE_TREE/probe/payload-manifest-unmaterialized.yaml"
  cp -R "$GEMHOME" "$PROBE_TREE/probe/gemhome"
  # Incident 13 round 8: declare the vendored closure as library_aliases
  # (spec 03 §2.5) so the driver boot-materializes the vendored DLLs and
  # PATH-leads their dirs — the spec 22 §2.1 raw-surface answer. ffi's
  # LoadLibraryExA on libsass.so's IN-IMAGE spelling keeps its own route;
  # the aliases carry the bare-name IMPORTS the PE closure lists (round 7
  # proved the bytes present and byte-identical, the siblings
  # solo-loadable, and the require-time 126 the loader's dep-search
  # answer). The set is DERIVED (the same *.dll enumeration the vendoring
  # above produced), never hardcoded; names dedupe within the image (a
  # duplicate alias name fails the manifest parse by design). Stamped on
  # BOTH manifests: the aliases are orthogonal to the materialize:
  # negative oracle (the sassc-unmaterialized leg still requires sassc —
  # only the partial read is the oracle).
  stamp_library_aliases() {
    local manifest="$1" dll name rel stamped=0
    local declared=" "
    local gem_dir="$PROBE_TREE/probe/gemhome/gems/sassc-$SASSC_VERSION"
    for dll in $(find "$gem_dir" -name '*.dll' | sort); do
      name="$(basename "$dll")"
      case "$declared" in *" $name "*) continue ;; esac
      declared="$declared$name "
      rel="${dll#"$PROBE_TREE"}"
      if [ "$stamped" -eq 0 ]; then printf 'library_aliases:\n' >> "$manifest"; stamped=1; fi
      printf '  - name: %s\n    path: %s\n' "$name" "$rel" >> "$manifest"
    done
  }
  cp "$SELF_DIR/fixtures/payload-manifest.yaml" "$PROBE_TREE/__tpkg__/manifest.yaml"
  stamp_library_aliases "$PROBE_TREE/__tpkg__/manifest.yaml"
  rm -f "$PAYLOAD_IMG"
  "$TFS_CLI" mkimage --format dwarfs "$(w "$PROBE_TREE")" --output "$(w "$PAYLOAD_IMG")" >/dev/null
  cp "$SELF_DIR/fixtures/payload-manifest-unmaterialized.yaml" "$PROBE_TREE/__tpkg__/manifest.yaml"
  stamp_library_aliases "$PROBE_TREE/__tpkg__/manifest.yaml"
  rm -f "$PAYLOAD_IMG_NOMAT"
  "$TFS_CLI" mkimage --format dwarfs "$(w "$PROBE_TREE")" --output "$(w "$PAYLOAD_IMG_NOMAT")" >/dev/null
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG")" /__tpkg__/manifest.yaml | grep -q "^materialize:" \
    || die "the pressed image lost the materialize: key (spec 22 §4)"
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG_NOMAT")" /__tpkg__/manifest.yaml | grep -q "^materialize:" \
    && die "the negative-oracle image carries materialize: — the oracle would prove nothing"
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG")" /__tpkg__/manifest.yaml | grep -q "^library_aliases:" \
    || die "the pressed image lost the library_aliases: key (spec 22 §2.1)"
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG_NOMAT")" /__tpkg__/manifest.yaml | grep -q "^library_aliases:" \
    || die "the negative-oracle image lost the library_aliases: key (spec 22 §2.1)"
  # The gemhome tree must survive the press verbatim — the proof legs
  # discover gems ONLY from the image (incident 12: distinguish a
  # press-side drop from a runtime discovery miss before the legs run).
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG")" "/probe/gemhome/specifications/sinatra-$SINATRA_VERSION.gemspec" >/dev/null \
    || die "the payload image lacks the sinatra $SINATRA_VERSION gemspec — the press dropped the gemhome tree"
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG")" "/probe/gemhome/specifications/sassc-$SASSC_VERSION.gemspec" >/dev/null \
    || die "the payload image lacks the sassc $SASSC_VERSION gemspec — the press dropped the gemhome tree"
  # Incident 13: every vendored closure DLL must survive the press too —
  # the ffi leg's 126 is otherwise ambiguous between a press-side drop
  # and a runtime walk-miss.
  for f in "$PROBE_TREE/probe/gemhome/gems/sassc-$SASSC_VERSION/lib/sassc/"*.dll; do
    [ -f "$f" ] || continue
    rel="/probe/gemhome/gems/sassc-$SASSC_VERSION/lib/sassc/$(basename "$f")"
    "$TFS_CLI" cat "$(w "$PAYLOAD_IMG")" "$rel" >/dev/null \
      || die "the payload image lacks $rel — the press dropped a vendored closure DLL"
  done
fi

# --- 6. the jailed proofs ---------------------------------------------------
# TEBAKO_JAIL on windows: the grammar right-splits host:mount:ro|rw, so
# the drive-colon host path survives (`C:/…:/host-scratch:rw` parses
# host=`C:/…`); the mount side must be /-absolute and is informational —
# enforcement matches HOST path prefixes (tfs policy). The scratch grant
# covers HOME/TMP/TEMP/TEBAKO_HOME and the driver's exec cache (class R's
# materialization landing — the driver's std::env::temp_dir() on windows
# is GetTempPath2W, which reads TMP/TEMP/USERPROFILE, NEVER TMPDIR: pin
# TMP+TEMP into the scratch or the cache lands in C:\Windows and the
# jail denies it); the platform floor (spec 08 §2.1: System32, SysWOW64,
# Fonts) is granted implicitly under deny.
run_probe() {
  local leg="$1" img="${2:-$PAYLOAD_IMG}"
  set +e
  # TEBAKO_DEBUG_TFS: the closure-walk traces (dlmap2file's answer, the
  # PE parse verdict, each dep's resolve/materialize verdict) ride
  # stderr into the per-leg proof log — incident 13's 126 was mute
  # without them. env -i strips the ambient copy, so it rides inside
  # the list; overridable for a quiet local run.
  # WARNING: a comment line INSIDE a backslash continuation terminates
  # the command at that point (the continuation splices the comment
  # line in, the comment ends at its own newline) — the trailing lines
  # then run as a SEPARATE command with the ambient environment. The
  # round-4 insert below did exactly that: env -i ran with no command
  # and the runtime booted without TEBAKO_RUNTIME_IMAGE (no env image
  # mounted, rubygems prelude failed, probe.rb:66 NoMethodError on all
  # four legs — run 32188296332). Comments stay OUTSIDE the list.
  env -i \
    MSYS2_ARG_CONV_EXCL='*' \
    MSYS2_ENV_CONV_EXCL='*' \
    HOME="$SCRATCH/home" \
    TMPDIR="$SCRATCH/tmp" \
    TMP="$SCRATCH/tmp" \
    TEMP="$SCRATCH/tmp" \
    PATH='/c/Windows/System32' \
    SystemRoot='C:\Windows' \
    SystemDrive='C:' \
    WINDIR='C:\Windows' \
    ProgramData='C:\ProgramData' \
    ALLUSERSPROFILE='C:\ProgramData' \
    USERPROFILE="$(w "$SCRATCH/home")" \
    APPDATA="$(w "$SCRATCH/home")/AppData/Roaming" \
    TEBAKO_HOME="$(w "$SCRATCH/tebako-home")" \
    TEBAKO_RUNTIME_IMAGE="$(w "$RUNTIME_IMAGE")" \
    TEBAKO_JAIL="deny;$(w "$SCRATCH"):/host-scratch:rw" \
    TEBAKO_DEBUG_TFS="${TEBAKO_DEBUG_TFS:-1}" \
    "$RUNTIME_EXE" --tebako-image "$(w "$img"):-:/" --tebako-entry /probe/probe.rb "$leg" \
    > "$SCRATCH/proof-$leg.log" 2>&1
  local st=$?
  set -e
  cat "$SCRATCH/proof-$leg.log"
  return "$st"
}

step "jailed probe runs (TEBAKO_JAIL=deny;<scratch>:/host-scratch:rw)"
st_fixed=0; st_unfixed=0; st_sassc=0; st_sassc_nomat=0; st_matrix=0
run_probe sinatra-fixed   || st_fixed=$?
run_probe sinatra-unfixed || st_unfixed=$?
run_probe sassc           || st_sassc=$?
run_probe sassc-unmaterialized "$PAYLOAD_IMG_NOMAT" || st_sassc_nomat=$?
# The incident-13 forensic sheet on a pristine loader (no require attempt
# first — the bisect legs run post-LoadError by construction). Its
# PROBE-DIAG lines carry the verdicts; the leg itself must only complete.
run_probe sassc-matrix    || st_matrix=$?

gem_loaded="$(grep -m1 -oE '^PROBE gem-loaded (yes|no)' "$SCRATCH/proof-sinatra-fixed.log" | awk '{print $3}')"
[ -n "$gem_loaded" ] || die "gem-loaded instrumentation line missing"
# the gem-kill canary: no tebako-runtime gem may load at boot — a `yes`
# means the gem crept back into the env image (or a boot-time require
# returned) — same pin as POSIX.
[ "$gem_loaded" = "no" ] || die "gem-loaded must be no post-M2, got $gem_loaded"
for leg in sinatra-unfixed sassc sassc-unmaterialized sassc-matrix; do
  other="$(grep -m1 -oE '^PROBE gem-loaded (yes|no)' "$SCRATCH/proof-$leg.log" | awk '{print $3}')"
  [ "$other" = "$gem_loaded" ] || die "gem-loaded disagree across legs ($gem_loaded vs $other in $leg)"
done

[ "$st_fixed" -eq 0 ] || die "sinatra-fixed leg exit $st_fixed"
grep -q "^PROBE sinatra-fixed ok status=200 " "$SCRATCH/proof-sinatra-fixed.log" || die "sinatra-fixed leg"
[ "$st_sassc" -eq 0 ] || die "sassc leg exit $st_sassc"
grep -q "^PROBE sassc-main ok " "$SCRATCH/proof-sassc.log" || die "sassc-main leg"
grep -q "^PROBE sassc-partial ok " "$SCRATCH/proof-sassc.log" \
  || die "sassc-partial leg (expected GREEN via the materialize: declaration, spec 22 §4)"
grep -q "^PROBE sinatra-unfixed ok status=200 " "$SCRATCH/proof-sinatra-unfixed.log" \
  || die "sinatra-unfixed leg (gemless image: expected GREEN, got a surprise)"
[ "$st_sassc_nomat" -eq 0 ] || die "sassc-unmaterialized leg exit $st_sassc_nomat"
grep -qF "PROBE sassc-partial-unmaterialized expected-fail $SASSC_PARTIAL_PIN" "$SCRATCH/proof-sassc-unmaterialized.log" \
  || die "sassc-partial-unmaterialized leg (expected the pinned class-R failure signature)"
[ "$st_matrix" -eq 0 ] || die "sassc-matrix leg exit $st_matrix"
grep -q "^PROBE sassc-matrix done" "$SCRATCH/proof-sassc-matrix.log" \
  || die "sassc-matrix leg (no done line — the sheet aborted)"

echo "SPEC22-GEMS-MSYS-ACCEPTANCE-OK $VERSION ($RUNTIME_EXE; sinatra $SINATRA_VERSION, sassc $SASSC_VERSION, no tebako-runtime gem)"
