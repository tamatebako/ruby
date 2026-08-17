#!/bin/bash
# ci/spec22-gems/run-msys.sh — spec 22 gem-level acceptance, WINDOWS leg.
# The msys port of run.sh (spec 22 §8's last acceptance row: the v2
# dogfood suite green with the gem gone on EVERY published platform).
# Runs the same four jailed proof legs against the same fixtures and
# pins the same PROBE lines (README.md), with the gem-loaded canary
# pinned `no`.
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
#   SCRATCH     (default: /tmp/spec22-gems-msys-scratch-<version>)
#   UCRT64_BIN  (default: /d/a/_temp/msys64/ucrt64/bin — the
#               setup-msys2 location; the gem-install leg's PATH source
#               for gcc/make, exactly what the factory builds with)
#
# Path discipline: the runtime exe, tfs.exe, and cmd.exe are NATIVE
# windows binaries, and msys bash's AUTOMATIC argv conversion is the
# trap: it rewrites leading-slash arguments into install-rooted host
# paths (`/setup/gem.rb` → `D:/a/_temp/msys64/setup/gem.rb` — the first
# dogfood run's exit-1), which silently corrupts VFS paths and
# cmd-style flags. So this script disables it outright
# (MSYS2_ARG_CONV_EXCL='*'): NOTHING is auto-converted, and every
# argument to a native binary is spelled in final form BY HAND —
# host paths through cygpath -m (the w() helper, same as every
# exported env value: TEBAKO_*, HOME, TMP*, GEM_*), VFS paths
# (/--spellings inside images) raw, cmd flags raw (/c, /D).
# msys-to-msys spawns (find/cp/grep/…) are unaffected either way.
# SUBTLETY: the scrubbed legs run the exe through `env -i`, which strips
# the exported copy — the conversion decision belongs to the DIRECT
# spawner (env, not bash), so MSYS2_ARG_CONV_EXCL rides INSIDE every
# env -i list too (env sets it into its own environ before the exec).

set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'

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
# boundary into the runtime exe or tfs.exe.
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
if [ ! -f "$SETUP_IMG" ] || [ "$SELF_DIR/fixtures/gem.rb" -nt "$SETUP_IMG" ]; then
  step "press setup image (GemRunner shim)"
  rm -rf "$SCRATCH/setup-tree"
  mkdir -p "$SCRATCH/setup-tree/setup"
  cp "$SELF_DIR/fixtures/gem.rb" "$SCRATCH/setup-tree/setup/"
  "$TFS_CLI" mkimage --format dwarfs "$(w "$SCRATCH/setup-tree")" --output "$(w "$SETUP_IMG")" >/dev/null
fi

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
  set +e
  env -i \
    MSYS2_ARG_CONV_EXCL='*' \
    HOME="$(w "$SCRATCH/home")" \
    TMPDIR="$(w "$SCRATCH/tmp")" \
    TMP="$(w "$SCRATCH/tmp")" \
    TEMP="$(w "$SCRATCH/tmp")" \
    PATH="$(w "$UCRT64_BIN");$(w /usr/bin);C:/Windows/System32" \
    SystemRoot='C:\Windows' \
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
  rm -f "$PROBE_TREE/probe/payload-manifest.yaml" \
        "$PROBE_TREE/probe/payload-manifest-unmaterialized.yaml"
  cp -R "$GEMHOME" "$PROBE_TREE/probe/gemhome"
  cp "$SELF_DIR/fixtures/payload-manifest.yaml" "$PROBE_TREE/__tpkg__/manifest.yaml"
  rm -f "$PAYLOAD_IMG"
  "$TFS_CLI" mkimage --format dwarfs "$(w "$PROBE_TREE")" --output "$(w "$PAYLOAD_IMG")" >/dev/null
  cp "$SELF_DIR/fixtures/payload-manifest-unmaterialized.yaml" "$PROBE_TREE/__tpkg__/manifest.yaml"
  rm -f "$PAYLOAD_IMG_NOMAT"
  "$TFS_CLI" mkimage --format dwarfs "$(w "$PROBE_TREE")" --output "$(w "$PAYLOAD_IMG_NOMAT")" >/dev/null
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG")" /__tpkg__/manifest.yaml | grep -q "^materialize:" \
    || die "the pressed image lost the materialize: key (spec 22 §4)"
  "$TFS_CLI" cat "$(w "$PAYLOAD_IMG_NOMAT")" /__tpkg__/manifest.yaml | grep -q "^materialize:" \
    && die "the negative-oracle image carries materialize: — the oracle would prove nothing"
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
  env -i \
    MSYS2_ARG_CONV_EXCL='*' \
    HOME="$(w "$SCRATCH/home")" \
    TMPDIR="$(w "$SCRATCH/tmp")" \
    TMP="$(w "$SCRATCH/tmp")" \
    TEMP="$(w "$SCRATCH/tmp")" \
    PATH='C:/Windows/System32' \
    SystemRoot='C:\Windows' \
    TEBAKO_HOME="$(w "$SCRATCH/tebako-home")" \
    TEBAKO_RUNTIME_IMAGE="$(w "$RUNTIME_IMAGE")" \
    TEBAKO_JAIL="deny;$(w "$SCRATCH"):/host-scratch:rw" \
    "$RUNTIME_EXE" --tebako-image "$(w "$img"):-:/" --tebako-entry /probe/probe.rb "$leg" \
    > "$SCRATCH/proof-$leg.log" 2>&1
  local st=$?
  set -e
  cat "$SCRATCH/proof-$leg.log"
  return "$st"
}

step "jailed probe runs (TEBAKO_JAIL=deny;<scratch>:/host-scratch:rw)"
st_fixed=0; st_unfixed=0; st_sassc=0; st_sassc_nomat=0
run_probe sinatra-fixed   || st_fixed=$?
run_probe sinatra-unfixed || st_unfixed=$?
run_probe sassc           || st_sassc=$?
run_probe sassc-unmaterialized "$PAYLOAD_IMG_NOMAT" || st_sassc_nomat=$?

gem_loaded="$(grep -m1 -oE '^PROBE gem-loaded (yes|no)' "$SCRATCH/proof-sinatra-fixed.log" | awk '{print $3}')"
[ -n "$gem_loaded" ] || die "gem-loaded instrumentation line missing"
# the gem-kill canary: no tebako-runtime gem may load at boot — a `yes`
# means the gem crept back into the env image (or a boot-time require
# returned) — same pin as POSIX.
[ "$gem_loaded" = "no" ] || die "gem-loaded must be no post-M2, got $gem_loaded"
for leg in sinatra-unfixed sassc sassc-unmaterialized; do
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

echo "SPEC22-GEMS-MSYS-ACCEPTANCE-OK $VERSION ($RUNTIME_EXE; sinatra $SINATRA_VERSION, sassc $SASSC_VERSION, no tebako-runtime gem)"
