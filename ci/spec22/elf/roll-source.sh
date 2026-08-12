#!/bin/bash
# roll-source.sh — roll the patched source tarball(s) for the ELF leg from
# a checkout of THIS repo (tamatebako/ruby, the dln_c_loader_interpose
# branch) into $SCRATCH/mirror, laid out exactly as the release assets are
# (tarball + SHA256SUMS — the SourceFetcher contract). linux-gnu scenario,
# unsuffixed asset names. VERSIONS selects the version set (default: the
# phase-1 line tip).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

VERSIONS="${VERSIONS:-4.0.6}"
RUBY_SRC="${RUBY_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
[ -x "$RUBY_SRC/tools/apply" ] || { echo "tamatebako/ruby checkout missing at $RUBY_SRC (set RUBY_SRC)"; exit 64; }

MIRROR="$SCRATCH/mirror"
mkdir -p "$MIRROR" "$SCRATCH/pristine"
for v in $VERSIONS; do
  work="$SCRATCH/.roll-work/$v"
  rm -rf "$work"
  TFS_CACHE_DIR="$SCRATCH/pristine" "$RUBY_SRC/tools/apply" "$v" "$work" --platform linux-gnu
  # The chain gate's whole point: the interpose block MUST be in the roll.
  grep -q tfs_dlopen_route "$work/tfs-ruby-$v-src/dln.c" || {
    echo "$v: rolled WITHOUT the loader-interpose block"; exit 1; }
  tar -czf "$MIRROR/tfs-ruby-$v-src.tar.gz" -C "$work" "tfs-ruby-$v-src"
  rm -rf "$work"
  echo "rolled $v"
done
( cd "$MIRROR" && sha256sum tfs-ruby-*-src.tar.gz > SHA256SUMS )
echo "ROLL-SOURCE-OK $MIRROR"
