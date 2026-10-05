#!/bin/bash
# ci/spawn-edge/run-msys.sh — the spawn-edge acceptance gate, WINDOWS leg.
# The msys twin of run.sh: same fixtures, same store staging, same pinned
# PROBE lines and verdict, against the factory leg's windows artifacts.
# See run.sh's header for the gate's contract; this header owns only the
# windows mechanics:
#
#   * The PE-named DLL. The package carries the ruby DLL under the unique
#     package name (<runtime>.dll); the staged store exe's PE imports
#     resolve it only as <cpu-tag>-ucrt-ruby<ABI>.dll next to the exe.
#     The store entry gets the copy (the factory boot smoke's
#     materialize_ruby_dll is the mirrored rule).
#   * The store exe name. The factory ships windows exes SUFFIX-LESS (the
#     release index's filename spelling), but the staged entry carries no
#     release index, so the store scan derives the synthesized name —
#     tebako-runtime-<tv>-<lv>-<triplet>.exe — and the copy is renamed to
#     it. The scan's platform grammar reads the triplet off the exe name,
#     so the store dir names the same triplet.
#   * Path discipline. The runtime exe and tfs.exe are NATIVE windows
#     binaries: MSYS2_ARG_CONV_EXCL='*' / MSYS2_ENV_CONV_EXCL='*' disable
#     the msys conversion layers outright, and every value crossing into
#     a native binary is spelled in final form BY HAND — host paths
#     through cygpath -m (the w() helper), VFS paths (/--spellings inside
#     images) raw. The jail grammar is colon-sensitive — nothing here
#     feeds a heuristic. TMP/TMPDIR/TEMP are conv_envvars and stay POSIX
#     (the boundary converts them; see ci/spec22-gems/run-msys.sh's
#     header for the two-layer mechanism).
#
# Usage: ci/spawn-edge/run-msys.sh
#
# Required env: as run.sh (RUNTIME_PKG_DIR, RUBY_VERSION, TEBAKO_VERSION,
# TFS_CLI — the published/leg-cached windows tfs.exe).
# Overridable: SCRATCH (default /tmp/spawn-edge-msys-scratch-<ruby>-<triplet>,
# POSIX spelling).

set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
export MSYS2_ENV_CONV_EXCL='*'

RUNTIME_PKG_DIR="${RUNTIME_PKG_DIR:?run-msys.sh: RUNTIME_PKG_DIR (the leg runtime-packages dir) is required}"
RUBY_VERSION="${RUBY_VERSION:?run-msys.sh: RUBY_VERSION (the leg ruby version) is required}"
TEBAKO_VERSION="${TEBAKO_VERSION:?run-msys.sh: TEBAKO_VERSION (the leg tebako version) is required}"
TFS_CLI="${TFS_CLI:?run-msys.sh: TFS_CLI (the windows tfs.exe) is required}"

case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *) echo "FAIL spawn-edge (run-msys.sh is msys-only; uname: $(uname -s)) — use run.sh on POSIX" >&2; exit 64 ;;
esac

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

step() { echo "== spawn-edge-msys step: $*"; }
die()  { echo "FAIL spawn-edge-msys ($*)" >&2; exit 1; }
# Native-windows (mixed) spelling for values that cross the env/argv
# boundary into the runtime exe or tfs.exe.
w()    { cygpath -m "$1"; }

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# --- 0. the leg's artifacts ---------------------------------------------------
# tebako#716 era law (see run.sh): resolve the new-era name (with the -ruby-
# language segment) first, then the legacy one — the same harness serves
# old-tag reruns and new-era publishes.
PKG_BASE=""
pkg=""
for base in "tebako-runtime-$TEBAKO_VERSION-ruby-$RUBY_VERSION" \
            "tebako-runtime-$TEBAKO_VERSION-$RUBY_VERSION"; do
  pkg="$(find "$RUNTIME_PKG_DIR" -maxdepth 1 \( -name "$base-windows-ucrt64" -o -name "$base-windows-ucrt64.exe" \
          -o -name "$base-windows-ucrt-arm64" -o -name "$base-windows-ucrt-arm64.exe" \) | head -1)"
  if [ -n "$pkg" ]; then PKG_BASE="$base"; break; fi
done
[ -n "$pkg" ] || die "no runtime exe tebako-runtime-$TEBAKO_VERSION-{ruby-,}$RUBY_VERSION-windows-ucrt64[.exe]|-ucrt-arm64[.exe] under $RUNTIME_PKG_DIR"
exe_stem="${pkg%.exe}"
triplet="${exe_stem##*"$PKG_BASE"-}"
[ -f "$exe_stem.tfs" ] || die "no env image at $exe_stem.tfs"
[ -f "$exe_stem.dll" ] || die "no package ruby DLL at $exe_stem.dll"
[ -x "$TFS_CLI" ] || [ -f "$TFS_CLI" ] || die "tfs CLI not at $TFS_CLI"
case "$triplet" in
  *-ucrt-arm64) CPU_TAG=aarch64 ;;
  *-ucrt64)     CPU_TAG=x64 ;;
  *)            die "no arch-readable triplet on $(basename "$pkg")" ;;
esac
# <cpu-tag>-ucrt-ruby<ABI>.dll — ruby configure's RUBY_SO_NAME for a mingw
# host; <ABI> = <MAJOR><MINOR>0 (factory RubyVersion#msys_dll_name owns
# the name; mirrored here — a bash harness cannot flow it, and a drift
# dies loudly at boot).
ABI="$(echo "$RUBY_VERSION" | awk -F. '{printf "%d%d0", $1, $2}')"
PE_DLL="${CPU_TAG}-ucrt-ruby${ABI}.dll"

SCRATCH="${SCRATCH:-/tmp/spawn-edge-msys-scratch-$RUBY_VERSION-$triplet}"
mkdir -p "$SCRATCH"/{tmp,run}
step "leg runtime: $(basename "$pkg") (triplet $triplet, PE DLL $PE_DLL); scratch $SCRATCH"

# --- 1. press the fixture payload images --------------------------------------
PROVIDER_IMG="$SCRATCH/spawn-edge-provider.tfs"
CONSUMER_IMG="$SCRATCH/spawn-edge-consumer.tfs"
for side in provider consumer; do
  tree="$SCRATCH/$side-tree"
  rm -rf "$tree"; mkdir -p "$tree/__tpkg__"
  case "$side" in
    provider) cp "$SELF_DIR/fixtures/spawn-edge-echo.rb" "$tree/" ;;
    consumer) cp "$SELF_DIR/fixtures/spawn-edge-probe.rb" "$tree/" ;;
  esac
  cp "$SELF_DIR/fixtures/$side-manifest.yaml" "$tree/__tpkg__/manifest.yaml"
done
step "press the fixture payload images (tfs mkimage, default format)"
"$TFS_CLI" mkimage "$(w "$SCRATCH/provider-tree")" --output "$(w "$PROVIDER_IMG")" >/dev/null
"$TFS_CLI" mkimage "$(w "$SCRATCH/consumer-tree")" --output "$(w "$CONSUMER_IMG")" >/dev/null

# --- 2. stage the scratch store -------------------------------------------------
HOME_DIR="$SCRATCH/tebako-home"
RT_DIR="$HOME_DIR/runtimes/ruby-$RUBY_VERSION-$TEBAKO_VERSION-$triplet"
PAYLOAD_DIR="$HOME_DIR/payloads/spawn-edge-provider"
STORE_EXE="$RT_DIR/$PKG_BASE-$triplet.exe"
STORE_IMG="$RT_DIR/$PKG_BASE-$triplet.tfs"
step "stage the scratch store (runtime pair + PE-named DLL + provider payload)"
rm -rf "$HOME_DIR"
mkdir -p "$RT_DIR" "$PAYLOAD_DIR"
cp "$pkg" "$STORE_EXE"
cp "$exe_stem.dll" "$RT_DIR/$PE_DLL"
cp "$exe_stem.tfs" "$STORE_IMG"
echo "$(sha256_file "$STORE_IMG")  $PKG_BASE-$triplet.tfs" > "$STORE_IMG.sha256"
echo "$(sha256_file "$STORE_EXE")  $PKG_BASE-$triplet.exe" > "$STORE_EXE.sha256"
# The cached release index (see run.sh — tebako-shim owns the shape):
# the scan flows the exe/image names off it verbatim, era-agnostic;
# index-less, the synthesized fallback is pre-tebako#716-shaped only.
printf '[{"tebako_version": "%s", "ruby_version": "%s", "platform": "%s", "filename": "%s", "image": {"filename": "%s"}}]\n' \
  "$TEBAKO_VERSION" "$RUBY_VERSION" "$triplet" "$PKG_BASE-$triplet.exe" "$PKG_BASE-$triplet.tfs" \
  > "$RT_DIR/manifest.json"
cp "$PROVIDER_IMG" "$PAYLOAD_DIR/1.0.0.tfs"
echo "$(sha256_file "$PAYLOAD_DIR/1.0.0.tfs")  1.0.0.tfs" > "$PAYLOAD_DIR/1.0.0.tfs.sha256"
"$TFS_CLI" cat "$(w "$PROVIDER_IMG")" /__tpkg__/manifest.yaml > "$PAYLOAD_DIR/1.0.0.manifest.yaml" \
  || die "the provider image carries no readable /__tpkg__/manifest.yaml — the press dropped it"
grep -q "name: spawn-edge-echo" "$PAYLOAD_DIR/1.0.0.manifest.yaml" \
  || die "the provider manifest mirror lost the exposed entrypoint"
grep -q "expose:" <("$TFS_CLI" cat "$(w "$CONSUMER_IMG")" /__tpkg__/manifest.yaml) \
  || die "the consumer image lost the expose: edge — the press would prove nothing"

# --- 3. the proof run -------------------------------------------------------------
# env -i is deliberately ABSENT here (unlike ci/spec22-gems): the gate's
# question is the spawn plan, not hermeticity, and the runner's inherited
# baseline is the survivable windows env floor. TMP/TEMP stay POSIX
# (conv_envvars — the boundary converts); the TEBAKO_* values are w()'d.
step "boot the consumer payload and spawn through the executable edge"
set +e
(
  cd "$SCRATCH/run"
  TMP="$SCRATCH/tmp" \
  TMPDIR="$SCRATCH/tmp" \
  TEMP="$SCRATCH/tmp" \
  TEBAKO_HOME="$(w "$HOME_DIR")" \
  TEBAKO_RUNTIME_IMAGE="$(w "$exe_stem.tfs")" \
  "$pkg" --tebako-image "$(w "$CONSUMER_IMG"):-:/" --tebako-entry /spawn-edge-probe.rb
) > "$SCRATCH/proof.log" 2>&1
st=$?
set -e
cat "$SCRATCH/proof.log"

# --- 4. the pinned verdicts ---------------------------------------------------------
[ "$st" -eq 0 ] || die "the probe exited $st (the proof log above names the leg)"
for leg in system-array popen-array; do
  grep -q "^PROBE spawn-edge $leg ok" "$SCRATCH/proof.log" \
    || die "the $leg leg did not report ok (the proof log above)"
done
grep -qF 'SPAWN-EDGE-CHILD argv=["alpha", "beta gamma", "--flag=x"]' "$SCRATCH/proof.log" \
  || die "the child's echoed argv never reached the log (the PROBE-DIAG lines above)"

echo "SPAWN-EDGE-MSYS-ACCEPTANCE-OK $RUBY_VERSION ($triplet)"
