#!/bin/bash
# build-runtime.sh — the factory build of ruby 4.0.6 against the local
# mirror + the staged linux link unit + the adapter-less tebako-runtime gem
# (file:// gem repo via GEMRC). Mirrors the factory CI's container leg
# (build-linux-gnu -> _build-platform.yml): TEBAKO_RUST_LIBDIR set, --patchelf.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# env.sh's CFLAGS/CXXFLAGS=-pthread belong to the LINK-UNIT build (the
# rnp/vcpkg glibc-pthreads floor). Exported here they poison the ruby
# configure: ruby's configure only flows the command-line cflags= (the
# tebako include paths) into the Makefile when CFLAGS is NOT set in the
# environment (configure: `if test -z "${CFLAGS+set}"`), so an exported
# CFLAGS silently drops -I<factory>/build/include and main.c stops
# finding <tebako/tebako-main.h>. The CI container leg exports neither.
unset CFLAGS CXXFLAGS

VERSION=4.0.6
TFS_CLI="/cargo-target/$TARGET/release/tfs"
RUNTIME_PKG="$SCRATCH/runtime-packages/tebako-runtime-local-$VERSION-linux-amd64"

echo "== gem repo sanity (adapter-less tebako-runtime resolves from file://) =="
rm -rf /tmp/gemtest
GEMRC="$SCRATCH/gemrc" gem install tebako-runtime --no-document --install-dir /tmp/gemtest
gem contents --gem-install-dir /tmp/gemtest tebako-runtime 2>/dev/null | head -3 || \
  find /tmp/gemtest/gems -maxdepth 1 -name 'tebako-runtime-*'

echo "== factory ruby tooling =="
cd "$SCRATCH/factory"
# BUNDLED WITH 4.0.16 — the image's bundler is 2.4.19.
gem list -i bundler -v 4.0.16 >/dev/null 2>&1 || gem install bundler -v 4.0.16 --no-document
bundle install --quiet

echo "== build_runtime =="
[ -x "$TFS_CLI" ] || { echo "tfs CLI missing at $TFS_CLI"; exit 64; }
# fresh src tag per content change: the fetcher caches SHA256SUMS per tag
tag="local-spec22-$(sha256sum "$SCRATCH/mirror/tfs-ruby-$VERSION-src.tar.gz" | cut -c1-8)"
GEMRC="$SCRATCH/gemrc" \
TEBAKO_RUST_LIBDIR=$LINK_UNIT \
TEBAKO_TFS="$TFS_CLI" \
tools/build_runtime --ruby "$VERSION" \
  --src-mirror "file://$SCRATCH/mirror" --src-release "$tag" \
  --prefix "$SCRATCH/factory-prefix" \
  --output "$RUNTIME_PKG" \
  --patchelf

RUNTIME_EXE="$RUNTIME_PKG"
RUNTIME_IMAGE="$RUNTIME_PKG.tfs"
[ -x "$RUNTIME_EXE" ] || { echo "runtime exe missing at $RUNTIME_EXE"; exit 65; }
[ -f "$RUNTIME_IMAGE" ] || { echo "env image missing at $RUNTIME_IMAGE"; exit 65; }

echo "== CRITICAL GATE: the exe must dynamically export dlopen/dlerror =="
nm -D "$RUNTIME_EXE" | grep -E ' (dlopen|dlerror)$' || {
  echo "GATE-FAIL: $RUNTIME_EXE does not dynamically export dlopen/dlerror —"
  echo "the interposition cannot preempt libdl. Link line follows in the log."
  exit 66
}

echo "BUILD-RUNTIME-OK $RUNTIME_EXE"
