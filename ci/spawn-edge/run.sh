#!/bin/bash
# ci/spawn-edge/run.sh — the spawn-edge acceptance gate, POSIX legs
# (linux-gnu, linux-musl inside its alpine container, macos).
#
# The tripwire for the driver spawn-plan bug class (ruby#121's argv[0]
# drop at plan apply; tebako#691's `system("xml2rfc", …)` from a
# dispatched payload): a CONSUMER payload whose manifest carries a spec-32
# `kind: executable` edge with `expose: [spawn-edge-echo]` array-spawns
# the exposed provider command, and the probe asserts the child received
# the exact argv. A full metanorma compile is days of signal latency; this
# gate runs in seconds, per ruby line, against the leg's fresh runtime,
# before anything publishes.
#
# The script BUILDS NOTHING (the run-msys.sh contract): the runtime under
# test arrives as the factory build leg's runtime-packages/ dir and the
# press/readback tooling is the leg's own pin-verified tfs CLI. It:
#
#   1. presses the two fixture payload images (provider + consumer) in
#      the CLI's default format (limnifs — never a --format pin);
#   2. stages a scratch tebako store (spec 05 §3): the leg's runtime pair
#      under runtimes/ruby-<lv>-<tv>-<triplet>/ and the provider under
#      payloads/spawn-edge-provider/, the manifest mirror COPIED from the
#      pressed image (the store's "embedded wins" rule — the mirror is
#      the embedded manifest, stamped digests included);
#   3. boots the leg's runtime with the consumer image mounted at "/" and
#      the probe as the entry, TEBAKO_HOME pointed at the scratch store —
#      a hand-rolled dispatch, so the spawn resolves cache-only through
#      the store (spec 32 §5's unlocked edge; no TEBAKO_SPAWN_LOCK);
#   4. pins the probe's PROBE lines and the child's echoed argv.
#
# Usage: ci/spawn-edge/run.sh
#
# Required env:
#   RUNTIME_PKG_DIR — the leg's runtime-packages dir (one
#                     tebako-runtime-<tv>-<lv>-<triplet>[.exe] + its .tfs)
#   RUBY_VERSION    — the leg's ruby version (e.g. 4.0.7)
#   TEBAKO_VERSION  — the leg's tebako version (e.g. 0.16.33)
#   TFS_CLI         — the leg's pin-verified tfs CLI (press + readback)
# Overridable:
#   SCRATCH (default: /tmp/spawn-edge-scratch-<ruby>-<triplet>)
#
# Verdict: `SPAWN-EDGE-ACCEPTANCE-OK <ruby> (<triplet>)` on success; a
# named `FAIL spawn-edge (…)` line otherwise. Everything transient lives
# under $SCRATCH; delete it to re-run from scratch (the script rebuilds
# every stage on every run — all of it is sub-second).

set -euo pipefail

RUNTIME_PKG_DIR="${RUNTIME_PKG_DIR:?run.sh: RUNTIME_PKG_DIR (the leg runtime-packages dir) is required}"
RUBY_VERSION="${RUBY_VERSION:?run.sh: RUBY_VERSION (the leg ruby version) is required}"
TEBAKO_VERSION="${TEBAKO_VERSION:?run.sh: TEBAKO_VERSION (the leg tebako version) is required}"
TFS_CLI="${TFS_CLI:?run.sh: TFS_CLI (the pin-verified tfs CLI) is required}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "FAIL spawn-edge (run.sh is POSIX-only; the windows leg is run-msys.sh)" >&2; exit 64 ;;
esac

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

step() { echo "== spawn-edge step: $*"; }
die()  { echo "FAIL spawn-edge ($*)" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- 0. the leg's artifacts -------------------------------------------------
PKG_BASE="tebako-runtime-$TEBAKO_VERSION-$RUBY_VERSION"
exe="$(find "$RUNTIME_PKG_DIR" -maxdepth 1 -name "$PKG_BASE-*" \
        ! -name "*.tfs" ! -name "*.sha256" ! -name "*.origin" ! -name "*.abi" \
        ! -name "*.dll" ! -name "*.yaml" ! -name "*.json" | head -1)"
[ -n "$exe" ] || die "no runtime exe $PKG_BASE-* under $RUNTIME_PKG_DIR"
[ -f "$exe.tfs" ] || die "no env image at $exe.tfs"
triplet="${exe##*"$PKG_BASE"-}"
case "$triplet" in
  ""|*/*) die "cannot read the triplet off $(basename "$exe")" ;;
esac
[ -x "$TFS_CLI" ] || [ -f "$TFS_CLI" ] || die "tfs CLI not at $TFS_CLI"

SCRATCH="${SCRATCH:-/tmp/spawn-edge-scratch-$RUBY_VERSION-$triplet}"
mkdir -p "$SCRATCH"/{tmp,run}
step "leg runtime: $(basename "$exe") (triplet $triplet); scratch $SCRATCH"

# --- 1. press the fixture payload images ------------------------------------
# Default format (limnifs) — the only first-class writer; never a
# --format pin. The manifest rides the tree at __tpkg__/manifest.yaml.
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
"$TFS_CLI" mkimage "$SCRATCH/provider-tree" --output "$PROVIDER_IMG" >/dev/null
"$TFS_CLI" mkimage "$SCRATCH/consumer-tree" --output "$CONSUMER_IMG" >/dev/null

# --- 2. stage the scratch store ---------------------------------------------
# spec 05 §3's grammar: runtimes/<engine>-<lv>-<tv>-<triplet>/ holding the
# exe + env image + the image's sha256 trust anchor (the scan requires
# exactly these), and payloads/<name>/<version>.tfs + .tfs.sha256 +
# .manifest.yaml. The mirror is the PRESSED manifest (tfs cat readback —
# embedded wins, and the readback doubles as the press assertion).
HOME_DIR="$SCRATCH/tebako-home"
RT_DIR="$HOME_DIR/runtimes/ruby-$RUBY_VERSION-$TEBAKO_VERSION-$triplet"
PAYLOAD_DIR="$HOME_DIR/payloads/spawn-edge-provider"
step "stage the scratch store (runtime pair + provider payload)"
rm -rf "$HOME_DIR"
mkdir -p "$RT_DIR" "$PAYLOAD_DIR"
cp "$exe" "$RT_DIR/$PKG_BASE-$triplet"
chmod 0755 "$RT_DIR/$PKG_BASE-$triplet"
cp "$exe.tfs" "$RT_DIR/$PKG_BASE-$triplet.tfs"
chmod 0444 "$RT_DIR/$PKG_BASE-$triplet.tfs"
echo "$(sha256_file "$RT_DIR/$PKG_BASE-$triplet.tfs")  $PKG_BASE-$triplet.tfs" > "$RT_DIR/$PKG_BASE-$triplet.tfs.sha256"
echo "$(sha256_file "$RT_DIR/$PKG_BASE-$triplet")  $PKG_BASE-$triplet" > "$RT_DIR/$PKG_BASE-$triplet.sha256"
cp "$PROVIDER_IMG" "$PAYLOAD_DIR/1.0.0.tfs"
chmod 0444 "$PAYLOAD_DIR/1.0.0.tfs"
echo "$(sha256_file "$PAYLOAD_DIR/1.0.0.tfs")  1.0.0.tfs" > "$PAYLOAD_DIR/1.0.0.tfs.sha256"
"$TFS_CLI" cat "$PROVIDER_IMG" /__tpkg__/manifest.yaml > "$PAYLOAD_DIR/1.0.0.manifest.yaml" \
  || die "the provider image carries no readable /__tpkg__/manifest.yaml — the press dropped it"
grep -q "name: spawn-edge-echo" "$PAYLOAD_DIR/1.0.0.manifest.yaml" \
  || die "the provider manifest mirror lost the exposed entrypoint"
grep -q "expose:" <("$TFS_CLI" cat "$CONSUMER_IMG" /__tpkg__/manifest.yaml) \
  || die "the consumer image lost the expose: edge — the press would prove nothing"

# --- 3. the proof run ---------------------------------------------------------
# The parent boots the LEG's package pair (the artifact under test), the
# consumer image at "/" (the first triple — the entry resolves against
# it), TEBAKO_HOME at the scratch store. The probe's spawn of
# spawn-edge-echo is planned against the store: the provider image mounts
# in the child at "/", the child's runtime is the SAME pair, resolved
# cache-only from runtimes/. TMPDIR scopes ruby's Dir.* tempfile surface
# into the scratch.
step "boot the consumer payload and spawn through the executable edge"
set +e
(
  cd "$SCRATCH/run"
  TEBAKO_HOME="$HOME_DIR" \
  TEBAKO_RUNTIME_IMAGE="$exe.tfs" \
  TMPDIR="$SCRATCH/tmp" \
  "$exe" --tebako-image "$CONSUMER_IMG:-:/" --tebako-entry /spawn-edge-probe.rb
) > "$SCRATCH/proof.log" 2>&1
st=$?
set -e
cat "$SCRATCH/proof.log"

# --- 4. the pinned verdicts ---------------------------------------------------
[ "$st" -eq 0 ] || die "the probe exited $st (the proof log above names the leg)"
for leg in system-array popen-array; do
  grep -q "^PROBE spawn-edge $leg ok" "$SCRATCH/proof.log" \
    || die "the $leg leg did not report ok (the proof log above)"
done
grep -qF 'SPAWN-EDGE-CHILD argv=["alpha", "beta gamma", "--flag=x"]' "$SCRATCH/proof.log" \
  || die "the child's echoed argv never reached the log (the PROBE-DIAG lines above)"

echo "SPAWN-EDGE-ACCEPTANCE-OK $RUBY_VERSION ($triplet)"
