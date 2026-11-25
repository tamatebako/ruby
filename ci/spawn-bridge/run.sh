#!/bin/bash
# ci/spawn-bridge/run.sh — the injection-stripped spawn bridge acceptance
# gate (packed-metanorma#305, spec 22 §3.2; macOS only).
#
# The spawn patch's darwin bridge half: an array-form spawn whose
# materialized target is hardened-runtime signed WITHOUT
# com.apple.security.cs.allow-dyld-environment-variables drops
# DYLD_INSERT_LIBRARIES at exec (darwin 23) — the probe
# (tebako_fs_exec_dyld_insertion_honored, a weak extern) answers 0 and
# the hook bridges the embedded operand tokens to their host twins,
# scrubs the insertion pair, and names the scrub on the TEBAKO_DEBUG_TFS
# channel; an honored verdict — or a pre-probe link unit — keeps the
# injection path byte-identical.
#
# This harness proves the patch's behavior END-TO-END without a factory
# runtime: it configures the patched tree (the compile-smoke discipline),
# builds miniruby against a tfs link-unit TEST DOUBLE (fixtures/
# stub_c_api.c — a one-mount VFS plus the tebako#1127 ABI's minimal
# verdict double), and array-spawns codesign'd echo targets through it:
#
#   leg stripped+probe   — hardened, no entitlement, probe linked:
#                          scrub + bridge + named warning, shim absent
#   leg honoring+probe   — hardened WITH the entitlement, probe linked:
#                          the injection path byte-identical (unbridged
#                          operand, insertion var armed, shim loaded)
#   leg unsigned+probe   — adhoc-signed: honored, same as honoring
#   leg stripped+legacy  — hardened, no entitlement, NO probe symbol
#                          (the pre-probe link unit): the legacy behavior
#                          byte-identical — operand UNBRIDGED, no
#                          warning, the insertion armed and dyld-stripped
#                          (the silent shimlessness the bridge retires)
#
# The verdict double's answers are pinned against `codesign -d` ground
# truth for each fixture, and the host dyld's own strip/honor behavior
# is re-proven live before the legs run.
#
# Usage: ci/spawn-bridge/run.sh
#   RUBY_VERSION  — the series tip to prove (default 4.0.9)
#   SCRATCH       — default /tmp/spawn-bridge-scratch-<version>
#   TFS_CACHE_DIR — tarball cache (default the repo's .cache/tarballs)
#
# Verdict: `SPAWN-BRIDGE-ACCEPTANCE-OK <ruby> (<arch>)` on success; a
# named `FAIL spawn-bridge (…)` line otherwise. Everything transient
# lives under $SCRATCH; delete it to re-run from scratch (the tree build
# re-runs every invocation — the patch under test must never go stale).

set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "FAIL spawn-bridge (run.sh is macOS-only — the bridge is a darwin contract)" >&2; exit 64 ;;
esac
command -v codesign >/dev/null || { echo "FAIL spawn-bridge (codesign is required)" >&2; exit 64; }

RUBY_VERSION="${RUBY_VERSION:-4.0.9}"
SCRATCH="${SCRATCH:-/tmp/spawn-bridge-scratch-$RUBY_VERSION}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$REPO_ROOT/ci/spawn-bridge/fixtures"
STUB_INC="$REPO_ROOT/ci/include"
ARCH="$(uname -m)"
VFS="$SCRATCH/vfs"
CACHE_DIR="$SCRATCH/exec-cache"
SHIM_DIR="$SCRATCH/shim"
TREE="$SCRATCH/tree/tfs-ruby-$RUBY_VERSION-src"

step() { echo "== spawn-bridge step: $*"; }
die()  { echo "FAIL spawn-bridge ($*)" >&2; exit 1; }

mkdir -p "$SCRATCH" "$VFS" "$CACHE_DIR" "$SHIM_DIR"

# --- 1. fixtures: echo targets in the three signature shapes -----------
step "fixtures: compile + codesign the echo targets"
cc -O1 -o "$SCRATCH/t-unsigned" "$FIXTURES/echo-target.c" || die "cc echo-target"
cc -O1 -dynamiclib -o "$SHIM_DIR/libtfs_preload.dylib" "$FIXTURES/dummy-shim.c" || die "cc dummy-shim"
cp "$SCRATCH/t-unsigned" "$SCRATCH/t-stripped"
cp "$SCRATCH/t-unsigned" "$SCRATCH/t-entitled"
# The honoring fixture is the temurin shape: hardened runtime WITH
# allow-dyld-environment-variables AND disable-library-validation. The
# first grant is the probe's plane (the variable survives); the second
# lets the adhoc dummy shim past library validation — an
# allow-dyld-only fixture keeps the variable but dyld silently skips a
# team-less dylib, a validation-plane edge the probe deliberately does
# not model (spec 22 §3.2's probe answers the entitlement question
# only).
cat > "$SCRATCH/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-dyld-environment-variables</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
PLIST
codesign -s - --options runtime "$SCRATCH/t-stripped" 2>/dev/null || die "codesign t-stripped"
codesign -s - --options runtime --entitlements "$SCRATCH/entitlements.plist" \
  "$SCRATCH/t-entitled" 2>/dev/null || die "codesign t-entitled"
echo "snapshot stand-in (the sass-embedded operand shape)" > "$VFS/operand.txt"
cp "$SCRATCH/t-stripped" "$SCRATCH/t-entitled" "$SCRATCH/t-unsigned" "$VFS/"

# --- 2. ground truth: codesign surface vs the verdict double ----------
step "ground truth: codesign -d vs the verdict double"
cc -O1 -I"$STUB_INC" -DSPAWN_BRIDGE_PROBE -DSPAWN_BRIDGE_PROBE_MAIN \
  "$FIXTURES/stub_c_api.c" -o "$SCRATCH/probe-cli" || die "cc probe-cli"
probe_verdict() { "$SCRATCH/probe-cli" "$1"; }
expect_flags() {  # <binary> <want: runtime|nort> <want-entitlement: yes|no>
  local desc
  desc="$(codesign -dv "$1" 2>&1 || true)"
  case "$2" in
    runtime) echo "$desc" | grep -q "flags=0x[0-9a-f]*1[0-9a-f]*(" || true ;;
  esac
  echo "$desc" | sed -n 's/^.*CodeDirectory.*\(flags=0x[0-9a-f]*([a-z,]*)\).*/\1/p' | head -1
}
for t in t-unsigned t-stripped t-entitled; do
  flags="$(expect_flags "$SCRATCH/$t" x x)"
  ents="$(codesign -d --entitlements :- --xml "$SCRATCH/$t" 2>/dev/null | grep -c "allow-dyld-environment-variables" || true)"
  v="$(probe_verdict "$SCRATCH/$t")"
  echo "   $t: codesign $flags entitlements-key=$ents probe-double=$v"
done
[ "$(probe_verdict "$SCRATCH/t-stripped")" = "0" ] || die "verdict double: t-stripped must answer 0"
[ "$(probe_verdict "$SCRATCH/t-entitled")" = "1" ] || die "verdict double: t-entitled must answer 1"
[ "$(probe_verdict "$SCRATCH/t-unsigned")" = "1" ] || die "verdict double: t-unsigned must answer 1"

step "ground truth: the host dyld's own strip/honor behavior"
out="$(DYLD_INSERT_LIBRARIES="$SHIM_DIR/libtfs_preload.dylib" "$SCRATCH/t-stripped" 2>&1)"
echo "$out" | grep -q "SPAWN-BRIDGE-SHIM-LOADED" && die "host dyld honored the insertion into the stripped target (host is not darwin 23-shaped)"
echo "$out" | grep -q "DYLD_INSERT_LIBRARIES=<unset>" || die "stripped target did not see the variable stripped"
out="$(DYLD_INSERT_LIBRARIES="$SHIM_DIR/libtfs_preload.dylib" "$SCRATCH/t-entitled" 2>&1)"
echo "$out" | grep -q "SPAWN-BRIDGE-SHIM-LOADED" || die "host dyld stripped the insertion from the ENTITLED target (unexpected on this host)"

# --- 3. the patched tree: compile-smoke + miniruby against the double --
step "tree: compile-smoke gate for $RUBY_VERSION"
"$REPO_ROOT/tools/compile_smoke" "$RUBY_VERSION" "$SCRATCH/tree" 2>&1 | grep -v "^DEFER" | tail -1 \
  || die "compile-smoke failed for $RUBY_VERSION"
[ -d "$TREE" ] || die "no patched tree at $TREE"

step "tree: stub variants + miniruby link (probe / legacy)"
cc -O1 -I"$STUB_INC" -DSPAWN_BRIDGE_PROBE -c "$FIXTURES/stub_c_api.c" -o "$SCRATCH/stub-probe.o" || die "cc stub-probe"
cc -O1 -I"$STUB_INC" -c "$FIXTURES/stub_c_api.c" -o "$SCRATCH/stub-legacy.o" || die "cc stub-legacy"
JOBS="$(sysctl -n hw.ncpu)"
(cd "$TREE" && make -j"$JOBS" miniruby MAINLIBS="$SCRATCH/stub-probe.o" >/dev/null) || die "miniruby-probe build"
cp "$TREE/miniruby" "$SCRATCH/miniruby-probe"
rm -f "$TREE/miniruby"
# The legacy variant carries NO probe symbol: ld64 refuses an undefined
# weak extern in an executable link, so the pre-probe link unit is
# simulated with -U (dynamic lookup) — the weak reference then reads
# NULL at run time, exactly the pre-probe contract (and the reason the
# real chain gates on a tfs release carrying the probe).
(cd "$TREE" && make -j"$JOBS" miniruby \
  MAINLIBS="$SCRATCH/stub-legacy.o -Wl,-U,_tebako_fs_exec_dyld_insertion_honored" >/dev/null) \
  || die "miniruby-legacy build"
cp "$TREE/miniruby" "$SCRATCH/miniruby-legacy"

# --- 4. legs ------------------------------------------------------------
MINIRUBY_ENV=(
  "SPAWN_BRIDGE_VFS_ROOT=$VFS"
  "SPAWN_BRIDGE_EXEC_CACHE=$CACHE_DIR"
  "SPAWN_BRIDGE_SHIM=$SHIM_DIR/libtfs_preload.dylib"
  "DYLD_INSERT_LIBRARIES=$SHIM_DIR/libtfs_preload.dylib"
)

run_leg() {  # <miniruby> <target-name> <debug:0|1> <log>
  local mr="$1" tgt="$2" dbg="$3" log="$4"
  local env=("${MINIRUBY_ENV[@]}")
  [ "$dbg" = "1" ] && env+=("TEBAKO_DEBUG_TFS=1")
  env "${env[@]}" "$mr" "$FIXTURES/driver.rb" "/__tfs__/$tgt" "/__tfs__/operand.txt" \
    >"$log" 2>&1
}

child_shim_loaded() {  # <log> → 0 when a SHIM-LOADED pid matches the child's
  local tpid
  tpid="$(sed -n 's/^SPAWN-BRIDGE-TARGET pid=\([0-9][0-9]*\)$/\1/p' "$1" | head -1)"
  [ -n "$tpid" ] || return 1
  grep -q "^SPAWN-BRIDGE-SHIM-LOADED pid=$tpid\$" "$1"
}

expect() {  # <log> <pattern> <what>
  grep -qF "$2" "$1" || { cat "$1"; die "$3 — expected: $2"; }
}
reject() {  # <log> <pattern> <what>
  if grep -qF "$2" "$1"; then cat "$1"; die "$3 — rejected: $2"; fi
}
ok() { echo "PROBE spawn-bridge $1 ok"; }

step "leg stripped+probe: scrub + bridge + named warning"
run_leg "$SCRATCH/miniruby-probe" t-stripped 1 "$SCRATCH/leg-stripped.log" \
  || { cat "$SCRATCH/leg-stripped.log"; die "stripped+probe leg: spawn failed"; }
WARN="hardened runtime without allow-dyld-environment-variables drops DYLD_INSERT_LIBRARIES"
expect "$SCRATCH/leg-stripped.log" "[spawn] $CACHE_DIR/t-stripped: $WARN" "the named warning fires"
expect "$SCRATCH/leg-stripped.log" "SPAWN-BRIDGE-TARGET argv[0]=$CACHE_DIR/t-stripped" "argv[0] bridged to the twin"
expect "$SCRATCH/leg-stripped.log" "SPAWN-BRIDGE-TARGET argv[1]=$CACHE_DIR/operand.txt" "operand bridged to the twin"
expect "$SCRATCH/leg-stripped.log" "SPAWN-BRIDGE-TARGET argv[2]=plain tail" "host token untouched"
expect "$SCRATCH/leg-stripped.log" "SPAWN-BRIDGE-TARGET TEBAKO_TFS_MOUNTS=<unset>" "mounts var omitted"
expect "$SCRATCH/leg-stripped.log" "SPAWN-BRIDGE-TARGET DYLD_INSERT_LIBRARIES=<unset>" "insertion var absent in the child"
reject  "$SCRATCH/leg-stripped.log" "SPAWN-BRIDGE-TARGET argv[1]=/__tfs__/operand.txt" "no embedded spelling survives"
child_shim_loaded "$SCRATCH/leg-stripped.log" && die "the shim entered the stripped child"
ok stripped+probe

step "leg stripped+probe (no debug channel): warning gated, behavior identical"
run_leg "$SCRATCH/miniruby-probe" t-stripped 0 "$SCRATCH/leg-nodebug.log" \
  || { cat "$SCRATCH/leg-nodebug.log"; die "nodebug leg: spawn failed"; }
reject "$SCRATCH/leg-nodebug.log" "[spawn]" "the warning rides the debug channel only"
expect "$SCRATCH/leg-nodebug.log" "SPAWN-BRIDGE-TARGET argv[1]=$CACHE_DIR/operand.txt" "bridge fires without the debug channel"
ok stripped+probe-nodebug

step "leg honoring+probe: the injection path byte-identical"
run_leg "$SCRATCH/miniruby-probe" t-entitled 1 "$SCRATCH/leg-entitled.log" \
  || { cat "$SCRATCH/leg-entitled.log"; die "honoring+probe leg: spawn failed"; }
reject "$SCRATCH/leg-entitled.log" "[spawn]" "no warning for an honored target"
expect "$SCRATCH/leg-entitled.log" "SPAWN-BRIDGE-TARGET argv[1]=/__tfs__/operand.txt" "operand unbridged (injection path)"
expect "$SCRATCH/leg-entitled.log" "SPAWN-BRIDGE-TARGET DYLD_INSERT_LIBRARIES=$SHIM_DIR/libtfs_preload.dylib" "insertion armed"
expect "$SCRATCH/leg-entitled.log" "SPAWN-BRIDGE-TARGET TEBAKO_TFS_MOUNTS=/__tfs__:/__tfs__" "mounts armed"
child_shim_loaded "$SCRATCH/leg-entitled.log" || die "the shim did not enter the entitled child"
ok honoring+probe

step "leg unsigned+probe: honored"
run_leg "$SCRATCH/miniruby-probe" t-unsigned 1 "$SCRATCH/leg-unsigned.log" \
  || { cat "$SCRATCH/leg-unsigned.log"; die "unsigned+probe leg: spawn failed"; }
reject "$SCRATCH/leg-unsigned.log" "[spawn]" "no warning for an unsigned target"
expect "$SCRATCH/leg-unsigned.log" "SPAWN-BRIDGE-TARGET argv[1]=/__tfs__/operand.txt" "operand unbridged"
child_shim_loaded "$SCRATCH/leg-unsigned.log" || die "the shim did not enter the unsigned child"
ok unsigned+probe

step "leg stripped+legacy: the pre-probe link unit keeps the old behavior"
run_leg "$SCRATCH/miniruby-legacy" t-stripped 1 "$SCRATCH/leg-legacy.log" \
  || { cat "$SCRATCH/leg-legacy.log"; die "stripped+legacy leg: spawn failed"; }
reject "$SCRATCH/leg-legacy.log" "[spawn]" "no warning without the probe symbol"
expect "$SCRATCH/leg-legacy.log" "SPAWN-BRIDGE-TARGET argv[1]=/__tfs__/operand.txt" "operand unbridged (legacy)"
expect "$SCRATCH/leg-legacy.log" "SPAWN-BRIDGE-TARGET TEBAKO_TFS_MOUNTS=/__tfs__:/__tfs__" "mounts armed (legacy)"
expect "$SCRATCH/leg-legacy.log" "SPAWN-BRIDGE-TARGET DYLD_INSERT_LIBRARIES=<unset>" "dyld strips the armed var (the silent shimlessness)"
child_shim_loaded "$SCRATCH/leg-legacy.log" && die "the shim entered the legacy stripped child"
ok stripped+legacy

echo "SPAWN-BRIDGE-ACCEPTANCE-OK $RUBY_VERSION ($ARCH)"
