#!/bin/bash
# probe.sh — the jailed acceptance run (linux adaptation of ci/spec22/run.sh
# steps 4-5): build the probe natives against the factory build tree's ruby
# headers, pack the payload image with the tfs CLI, run the runtime exe
# jailed, assert the four PROBE lines + exit 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

VERSION=4.0.6
TFS_CLI="/cargo-target/$TARGET/release/tfs"
RUNTIME_PKG="$SCRATCH/runtime-packages/tebako-runtime-local-$VERSION-linux-amd64"
RUNTIME_EXE="$RUNTIME_PKG"
RUNTIME_IMAGE="$RUNTIME_PKG.tfs"
FIXTURES="${FIXTURES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)}"
PROBE_TREE="$SCRATCH/probe-tree"
PAYLOAD_IMG="$SCRATCH/probe-$VERSION.tfs"
PROBE_LIB="/probe/lib/libvfsprobe.so"

echo "== build probe natives (gcc, ELF) =="
# The build tree is deps/src/_ruby_$VERSION (headers at include/ruby.h);
# a blanket find can land on the deps/stash_* installed-headers copy
# (include/ruby-X/ruby.h — one level deeper), which breaks the dirname
# math (same trap ci/spec22/run.sh documents for macOS).
RB_BUILD_DIR="$SCRATCH/factory-prefix/deps/src/_ruby_$VERSION"
if [ ! -f "$RB_BUILD_DIR/include/ruby.h" ]; then
  RB_BUILD_DIR="$(dirname "$(find "$SCRATCH/factory-prefix/deps/src" -mindepth 3 -maxdepth 3 -path '*/include/ruby.h' 2>/dev/null | head -1)")/.."
fi
[ -f "$RB_BUILD_DIR/include/ruby.h" ] || { echo "ruby build headers not found under $SCRATCH/factory-prefix/deps/src"; exit 64; }
rm -rf "$PROBE_TREE"
mkdir -p "$PROBE_TREE/probe/lib"
cp "$FIXTURES/probe.rb" "$PROBE_TREE/probe/"

# libvfsdep: the leaf the closure walk must extract next to libvfsprobe
gcc -shared -fPIC -O2 "$FIXTURES/vfsdep.c" \
  -Wl,-soname,"libvfsdep.so" -o "$PROBE_TREE/probe/lib/libvfsdep.so"
# libvfsprobe: DT_NEEDED libvfsdep.so + $ORIGIN runpath (the ELF twin of
# the macOS @rpath/@loader_path pair)
gcc -shared -fPIC -O2 "$FIXTURES/vfsprobe.c" \
  -L"$PROBE_TREE/probe/lib" -lvfsdep -Wl,-rpath,'$ORIGIN' \
  -o "$PROBE_TREE/probe/lib/libvfsprobe.so"
# probe_ext: a ruby C extension that self-dlopens the VFS path from Init.
# Undefined rb_* symbols resolve from the exe at load (linux C-extension
# convention; no -lruby).
# .ext/include holds BOTH the arch dir (x86_64-linux/ruby/config.h) and a
# plain ruby/ entry on linux — pick the one carrying ruby/config.h, never
# a positional first-dir (order is unspecified).
ARCH_DIR="$(basename "$(find "$RB_BUILD_DIR/.ext/include" -mindepth 3 -maxdepth 3 -path '*/ruby/config.h' 2>/dev/null | head -1 | xargs -r dirname | xargs -r dirname)")"
[ -f "$RB_BUILD_DIR/.ext/include/$ARCH_DIR/ruby/config.h" ] || { echo "arch config.h not found under $RB_BUILD_DIR/.ext/include"; exit 64; }
gcc -shared -fPIC -O2 \
  -I"$RB_BUILD_DIR/include" -I"$RB_BUILD_DIR/.ext/include/$ARCH_DIR" \
  -DPROBE_LIB_PATH="\"$PROBE_LIB\"" \
  "$FIXTURES/probe_ext.c" -o "$PROBE_TREE/probe/lib/probe_ext.so"

echo "== pack the payload image =="
rm -f "$PAYLOAD_IMG"
"$TFS_CLI" mkimage --format dwarfs "$PROBE_TREE" --output "$PAYLOAD_IMG"

echo "== the jailed proof (TEBAKO_JAIL=deny;\$SCRATCH:\$SCRATCH:rw) =="
mkdir -p "$SCRATCH"/{probe-home,probe-tmp,tebako-home}
# §3.6's transition gate: the exe-shape leg asserts only on a runtime
# that LINKS the family — the driver arms it through
# tebako_preload_init, which a family-carrying exe exports in its
# dynamic symbol table (the factory's --export-dynamic). A pre-family
# pin skips the leg loudly rather than failing the harness mid-roll.
exe_shape_probe=0
if nm -D "$RUNTIME_EXE" 2>/dev/null | grep -q tebako_preload_init; then
  exe_shape_probe=1
  echo "the runtime exports tebako_preload_init — the §3.6 leg asserts"
else
  echo "NOTE: this runtime carries no exe-shape family — the §3.6 leg skips (pre-#953 link unit)"
fi
set +e
out="$(env -i \
  HOME="$SCRATCH/probe-home" \
  TMPDIR="$SCRATCH/probe-tmp" \
  PATH="/usr/bin:/bin" \
  TEBAKO_HOME="$SCRATCH/tebako-home" \
  TEBAKO_RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  EXE_SHAPE_PROBE="$exe_shape_probe" \
  TEBAKO_JAIL="deny;$SCRATCH:$SCRATCH:rw" \
  "$RUNTIME_EXE" --tebako-image "$PAYLOAD_IMG:-:/" --tebako-entry /probe/probe.rb 2>&1)"
status=$?
set -e
echo "$out"
echo "$out" | grep -q "^PROBE fiddle ok 42"            || { echo "FAIL spec22 (fiddle leg)"; exit 1; }
echo "$out" | grep -q "^PROBE cext-self-dlopen ok 42"  || { echo "FAIL spec22 (cext self-dlopen leg)"; exit 1; }
echo "$out" | grep -q "^PROBE named-error ok "         || { echo "FAIL spec22 (named-error leg)"; exit 1; }
echo "$out" | grep -q "^PROBE jail-deny ok "           || { echo "FAIL spec22 (jail leg)"; exit 1; }
if [ "$exe_shape_probe" = "1" ]; then
  echo "$out" | grep -q "^PROBE exe-shape-jail ok "    || { echo "FAIL spec22 (exe-shape jail leg: the in-exe libcrypto read a host cert under TEBAKO_JAIL=deny — the runtime exports tebako_preload_init but the read still reached the host)"; exit 1; }
  # §3.6's second half: the denial is journaled, not just raised. The
  # jail-deny leg's /etc/passwd read is the same proof one level down
  # (the interposed File.read), so the journal naming /etc/ssl names
  # the exe shape's own denial specifically.
  grep -q "/etc/ssl" "$SCRATCH/tebako-home/journal.log" || { echo "FAIL spec22 (the cert-read denial is not in the audit journal)"; exit 1; }
fi
[ "$status" -eq 0 ] || { echo "FAIL spec22 (probe exit $status)"; exit 1; }
echo "SPEC22-ACCEPTANCE-OK $VERSION ($RUNTIME_EXE)"
