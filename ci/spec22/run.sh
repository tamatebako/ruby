#!/bin/bash
# ci/spec22/run.sh — spec 22 phase 1 (loader interposition, POSIX)
# acceptance harness. Builds, from pinned inputs only:
#
#   1. a patched ruby source tree (this repo's tools/apply) — incl. the
#      dln_c_loader_interpose patch,
#   2. a v2 link unit staged from a tamatebako/tebako checkout that
#      carries tebako_fs_mount_of,
#   3. a runtime (exe + env image) built by the runtime factory against
#      that LOCAL source mirror and link unit, with the adapter-less
#      tebako-runtime gem (ffi/fiddle adapters deleted) installed from a
#      local gem repo,
#   4. a probe payload image (fixtures/): a VFS-resident native library
#      with a dependency, a C extension that self-dlopens it, and an
#      entry probe asserting fiddle + self-dlopen + the named dlerror
#      verdict + the jail,
#   5. one jailed invocation of the runtime; grep-verdict on the PROBE
#      lines.
#
# Idempotent: existing artifacts under $SCRATCH are reused; delete the
# scratch dir (or the specific artifact) to force a rebuild. Everything
# transient lives under $SCRATCH; the repos are never mutated (the
# factory runs from its own git worktree).
#
# Usage: ci/spec22/run.sh [ruby-version]   (default 4.0.6)
#
# Required env (the local toolchain roots, see AGENTS.md §13):
#   DWARFS_RS_VCPKG_ROOT / VCPKG_ROOT / SQFS_SYS_VCPKG_ROOT — vcpkg root
#   CARGO_NET_GIT_FETCH_WITH_CLI=true
# Overridable:
#   TEBAKO_REPO    (default: <ecosystem>/tebako-wt-spec22-mountof —
#                   the checkout carrying tebako_fs_mount_of)
#   FACTORY_REPO   (default: <ecosystem>/tebako-runtime-ruby)
#   GEM_REPO_DIR   (default: /tmp/tebako-gem-repo — local gem repo with
#                   the adapter-less tebako-runtime gem; see README.md)
#   SCRATCH        (default: /tmp/spec22-scratch-<version>)
#   SRC_TAG        (default: spec22-local-<version>)

set -euo pipefail

VERSION="${1:-4.0.6}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RUBY_REPO="$(cd "$SELF_DIR/../.." && pwd)"
ECOSYSTEM="$(cd "$RUBY_REPO/.." && pwd)"

TEBAKO_REPO="${TEBAKO_REPO:-$ECOSYSTEM/tebako-wt-spec22-mountof}"
FACTORY_REPO="${FACTORY_REPO:-$ECOSYSTEM/tebako-runtime-ruby}"
GEM_REPO_DIR="${GEM_REPO_DIR:-/tmp/tebako-gem-repo}"
SCRATCH="${SCRATCH:-/tmp/spec22-scratch-$VERSION}"
SRC_TAG="${SRC_TAG:-spec22-local-$VERSION}"
TFS_CLI="${TFS_CLI:-$ECOSYSTEM/tebako/target/release/tfs}"

PLATFORM_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$PLATFORM_OS" in
  darwin) LIBEXT=dylib; EXTEXT=bundle; MKIMAGE_FORMAT=dwarfs ;;
  linux)  LIBEXT=so;    EXTEXT=so;    MKIMAGE_FORMAT=dwarfs ;;
  *) echo "FAIL run.sh: unsupported host $PLATFORM_OS (POSIX only)" >&2; exit 64 ;;
esac

step() { echo "== spec22 step: $*"; }
die()  { echo "FAIL spec22 ($*)" >&2; exit 1; }

[ -x "$TFS_CLI" ] || die "tfs CLI not at $TFS_CLI (build the tebako workspace release)"
[ -d "$GEM_REPO_DIR/gems" ] || die "adapter-less gem repo missing at $GEM_REPO_DIR (README.md §gem)"

mkdir -p "$SCRATCH"/{mirror,tmp,home,tebako-home}
export TMPDIR="$SCRATCH/tmp"

# --- 1. patched source tree + local mirror -------------------------------
if [ ! -f "$SCRATCH/mirror/tfs-ruby-$VERSION-src.tar.gz" ]; then
  step "apply $VERSION + roll local source mirror"
  rm -rf "$SCRATCH/roll"
  TFS_CACHE_DIR="${TFS_CACHE_DIR:-$RUBY_REPO/.cache/tarballs}" \
    "$RUBY_REPO/tools/apply" "$VERSION" "$SCRATCH/roll" --platform linux-gnu >/dev/null
  [ -f "$SCRATCH/roll/tfs-ruby-$VERSION-src/dln.c" ] || die "apply produced no tree"
  grep -q "tfs_dlopen_route" "$SCRATCH/roll/tfs-ruby-$VERSION-src/dln.c" \
    || die "rolled tree lacks the loader-interpose block (manifest not wired?)"
  ( cd "$SCRATCH/roll" && tar -czf "$SCRATCH/mirror/tfs-ruby-$VERSION-src.tar.gz" "tfs-ruby-$VERSION-src" )
  ( cd "$SCRATCH/mirror" && shasum -a 256 "tfs-ruby-$VERSION-src.tar.gz" > SHA256SUMS )
fi

# --- 2. v2 link unit (carries tebako_fs_mount_of) -------------------------
if [ ! -f "$SCRATCH/link-unit/libtfs.a" ]; then
  step "stage link unit from $TEBAKO_REPO"
  [ -d "$TEBAKO_REPO/crates/tfs" ] || die "TEBAKO_REPO $TEBAKO_REPO is not the product checkout"
  ( cd "$TEBAKO_REPO" && ruby tools/stage_link_unit "$SCRATCH/link-unit" )
fi

# --- 3. runtime build against the local mirror ----------------------------
RUNTIME_PKG="$SCRATCH/runtime-packages/tebako-runtime-local-$VERSION-macos-arm64"
[ "$PLATFORM_OS" = linux ] && RUNTIME_PKG="$SCRATCH/runtime-packages/tebako-runtime-local-$VERSION-linux-$(uname -m)"
FACTORY_WT="$SCRATCH/factory-worktree"
if [ ! -x "$RUNTIME_PKG" ] && [ ! -e "$RUNTIME_PKG/$(basename "$RUNTIME_PKG")" ]; then
  step "factory build $VERSION (local mirror, staged link unit, adapter-less gem)"
  if [ ! -d "$FACTORY_WT" ]; then
    GIT_EDITOR=true git -C "$FACTORY_REPO" worktree add "$FACTORY_WT" origin/main >/dev/null 2>&1 \
      || GIT_EDITOR=true git -C "$FACTORY_REPO" worktree add "$FACTORY_WT" --detach origin/main >/dev/null
    ( cd "$FACTORY_WT" && bundle install --quiet )
  fi
  cat > "$SCRATCH/gemrc" <<GEMRC
:sources:
  - file://$GEM_REPO_DIR
gem: --no-document
GEMRC
  # fresh src tag per content change: the fetcher caches SHA256SUMS per tag
  tag="$SRC_TAG-$(shasum -a 256 "$SCRATCH/mirror/tfs-ruby-$VERSION-src.tar.gz" | cut -c1-8)"
  ( cd "$FACTORY_WT" && \
    GEMRC="$SCRATCH/gemrc" \
    TEBAKO_RUST_LIBDIR="$SCRATCH/link-unit" \
    TEBAKO_TFS="$TFS_CLI" \
    tools/build_runtime --ruby "$VERSION" \
      --src-mirror "file://$SCRATCH/mirror" --src-release "$tag" \
      --prefix "$SCRATCH/factory" \
      --output "$RUNTIME_PKG" )
fi
RUNTIME_EXE="$RUNTIME_PKG/$(basename "$RUNTIME_PKG")"
[ -x "$RUNTIME_EXE" ] || die "runtime exe missing at $RUNTIME_EXE"
RUNTIME_IMAGE="$RUNTIME_PKG/$(basename "$RUNTIME_PKG").tfs"
[ -f "$RUNTIME_IMAGE" ] || die "env image missing at $RUNTIME_IMAGE"

# --- 4. probe payload image ------------------------------------------------
PROBE_TREE="$SCRATCH/probe-tree"
PAYLOAD_IMG="$SCRATCH/probe-$VERSION.tfs"
if [ ! -f "$PAYLOAD_IMG" ]; then
  step "build probe natives + payload image"
  RB_BUILD_DIR="$(dirname "$(find "$SCRATCH/factory" -name 'ruby.h' -path '*/include/*' 2>/dev/null | head -1)")/.."
  [ -f "$RB_BUILD_DIR/include/ruby.h" ] || die "ruby build headers not found under $SCRATCH/factory"
  mkdir -p "$PROBE_TREE/probe/lib"
  cp "$SELF_DIR/fixtures/probe.rb" "$PROBE_TREE/probe/"
  PROBE_LIB="/probe/lib/libvfsprobe.$LIBEXT"
  if [ "$PLATFORM_OS" = darwin ]; then
    clang -dynamiclib -O2 "$SELF_DIR/fixtures/vfsdep.c" \
      -install_name "@rpath/libvfsdep.$LIBEXT" -o "$PROBE_TREE/probe/lib/libvfsdep.$LIBEXT"
    clang -dynamiclib -O2 "$SELF_DIR/fixtures/vfsprobe.c" "$PROBE_TREE/probe/lib/libvfsdep.$LIBEXT" \
      -install_name "@rpath/libvfsprobe.$LIBEXT" -Wl,-rpath,"@loader_path" \
      -o "$PROBE_TREE/probe/lib/libvfsprobe.$LIBEXT"
    clang -bundle -O2 -undefined dynamic_lookup \
      -I"$RB_BUILD_DIR/include" -I"$RB_BUILD_DIR/.ext/include/arm64-darwin24" \
      -DPROBE_LIB_PATH="\"$PROBE_LIB\"" \
      "$SELF_DIR/fixtures/probe_ext.c" -o "$PROBE_TREE/probe/lib/probe_ext.$EXTEXT"
  else
    clang -shared -fPIC -O2 "$SELF_DIR/fixtures/vfsdep.c" \
      -Wl,-soname,"libvfsdep.$LIBEXT" -o "$PROBE_TREE/probe/lib/libvfsdep.$LIBEXT"
    clang -shared -fPIC -O2 "$SELF_DIR/fixtures/vfsprobe.c" \
      -L"$PROBE_TREE/probe/lib" -lvfsdep -Wl,-rpath,'$ORIGIN' \
      -o "$PROBE_TREE/probe/lib/libvfsprobe.$LIBEXT"
    ARCH_DIR="$(basename "$(find "$RB_BUILD_DIR/.ext/include" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)")"
    clang -shared -fPIC -O2 \
      -I"$RB_BUILD_DIR/include" -I"$RB_BUILD_DIR/.ext/include/$ARCH_DIR" \
      -DPROBE_LIB_PATH="\"$PROBE_LIB\"" \
      "$SELF_DIR/fixtures/probe_ext.c" -o "$PROBE_TREE/probe/lib/probe_ext.$EXTEXT"
  fi
  "$TFS_CLI" mkimage --format "$MKIMAGE_FORMAT" "$PROBE_TREE" --output "$PAYLOAD_IMG" >/dev/null
fi

# --- 5. the jailed proof -----------------------------------------------------
step "jailed probe run (TEBAKO_JAIL=deny;\$SCRATCH:\$SCRATCH:rw)"
set +e
out="$(env -i \
  HOME="$SCRATCH/home" \
  TMPDIR="$SCRATCH/tmp" \
  PATH="/usr/bin:/bin" \
  TEBAKO_HOME="$SCRATCH/tebako-home" \
  TEBAKO_RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  TEBAKO_JAIL="deny;$SCRATCH:$SCRATCH:rw" \
  "$RUNTIME_EXE" --tebako-image "$PAYLOAD_IMG:-:/" --tebako-entry /probe/probe.rb 2>&1)"
status=$?
set -e
echo "$out"
echo "$out" | grep -q "^PROBE fiddle ok 42"            || die "fiddle leg"
echo "$out" | grep -q "^PROBE cext-self-dlopen ok 42"  || die "cext self-dlopen leg"
echo "$out" | grep -q "^PROBE named-error ok "         || die "named-error leg"
echo "$out" | grep -q "^PROBE jail-deny ok "           || die "jail leg"
[ "$status" -eq 0 ] || die "probe exit $status"
echo "SPEC22-ACCEPTANCE-OK $VERSION ($RUNTIME_EXE)"
