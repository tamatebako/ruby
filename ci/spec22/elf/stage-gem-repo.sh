#!/bin/bash
# stage-gem-repo.sh — build the adapter-less tebako-runtime gem from a
# checkout of tamatebako/tebako-runtime@feat/drop-class-l-adapters (GEM_SRC,
# default $SCRATCH/tebako-runtime) and stage it as a file:// gem repo at
# $SCRATCH/gem-repo (+ $SCRATCH/gemrc consumed by build-runtime.sh). The
# env image's deploy does an unpinned `gem install tebako-runtime` and
# rubygems.org still serves the adapter-ful 0.8.1 — GEMRC points the
# install here instead.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

GEM_SRC="${GEM_SRC:-$SCRATCH/tebako-runtime}"
[ -f "$GEM_SRC/tebako-runtime.gemspec" ] || {
  echo "gem checkout missing at $GEM_SRC —"
  echo "clone tamatebako/tebako-runtime@feat/drop-class-l-adapters there or set GEM_SRC"
  exit 64
}

repo="$SCRATCH/gem-repo"
rm -rf "$repo"
mkdir -p "$repo/gems"
( cd "$GEM_SRC" && gem build tebako-runtime.gemspec )
built=$(ls "$GEM_SRC"/tebako-runtime-*.gem | head -1)
case "$built" in
  *tebako-runtime-0.8.1.gem)
    echo "the chain gem must not carry the published 0.8.1 identity (adapter-ful); the adapter-less line is 0.8.2"
    exit 1 ;;
esac
cp "$built" "$repo/gems/"
gem generate_index --directory "$repo"
printf ':sources:\n- file://%s/gem-repo\ngem: --no-document\n' "$SCRATCH" > "$SCRATCH/gemrc"
echo "STAGE-GEM-REPO-OK $repo ($(basename "$built"))"
