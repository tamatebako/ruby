#!/bin/bash
# run-elf-leg.sh — one-shot reproducible ELF (linux/amd64) acceptance leg for
# tebako spec 22 phase 1 (loader interposition). HOST-side driver: macOS +
# Docker Desktop, the container runs linux/amd64 under Rosetta/qemu-user.
#
# What it proves (the same four assertions as the macOS leg, ci/spec22/run.sh):
#   PROBE fiddle ok 42 / cext-self-dlopen ok 42 / named-error ok / jail-deny ok
# plus two ELF-only gates: the staged libtfs.a carries zero GNU_UNIQUE defs,
# and the runtime exe dynamically exports dlopen/dlerror (nm -D), else
# interposition cannot preempt libdl.
#
# Layout (populate once per ci/spec22/elf/README.md; everything resumes, a
# re-run never rebuilds what is already staged):
#   $SCRATCH/                       bind mount, host-persistent
#     ruby/                         THIS repo checkout (the harness rides it)
#     factory/                      tamatebako/tebako-runtime-ruby checkout
#     ws/tebako-rs/                 tamatebako/tebako checkout (@feat/tfs-mount-of)
#     ws/dwarfs-rs/                 tamatebako/dwarfs-rs (+ dwarfs-t submodule)
#     ws/limnifs/limnifs/           limnifs/limnifs (contract-tests sibling
#                                   path dep — cargo metadata fails without it)
#   $LINK_UNIT/                     bind mount for the staged link unit
#
set -euo pipefail

SCRATCH="${SCRATCH:-/tmp/spec22-linux-scratch}"
LINK_UNIT="${LINK_UNIT:-/tmp/spec22-link-unit-linux}"
IMAGE="${IMAGE:-ghcr.io/tamatebako/tebako-ubuntu-20.04:0.16.2-amd64}"
NAME="${NAME:-spec22-elf-build}"
ELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # ci/spec22/elf, inside $SCRATCH/ruby

case "$ELF" in
  "$SCRATCH"/*) ;;
  *) { echo "this harness rides the ruby checkout at \$SCRATCH/ruby — $ELF is outside $SCRATCH"; exit 64; } ;;
esac

echo "== 0. docker daemon =="
if ! docker info >/dev/null 2>&1; then
  open -a Docker 2>/dev/null || true
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 5; done
  docker info >/dev/null 2>&1 || { echo "FAIL: docker daemon did not come up"; exit 64; }
fi

echo "== 1. container =="
if ! docker inspect "$NAME" >/dev/null 2>&1; then
  docker run -d --name "$NAME" --platform linux/amd64 \
    -v "$SCRATCH:$SCRATCH" -v "$LINK_UNIT:$LINK_UNIT" \
    "$IMAGE" sleep infinity >/dev/null
fi
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ] || docker start "$NAME" >/dev/null

echo "== 2. toolchain (skip if already provisioned) =="
if ! docker exec "$NAME" bash -c "command -v cmake >/dev/null && cmake --version | grep -q 3.31 && [ -x '$SCRATCH/home/.cargo/bin/cargo' ] && [ -d /vcpkg ]" 2>/dev/null; then
  docker exec "$NAME" bash "$ELF/setup-toolchain.sh"
else
  echo "   toolchain present — skipping"
fi

echo "== 3. roll the patched source (mirror) =="
docker exec "$NAME" bash "$ELF/roll-source.sh"

echo "== 4. link unit (tfs, tebako-driver, libtfs-preload, tfs-cli) + GNU_UNIQUE gate =="
docker exec "$NAME" bash "$ELF/build-link-unit.sh"

echo "== 5. factory runtime build + nm -D export gate =="
docker exec "$NAME" bash "$ELF/build-runtime.sh"

echo "== 6. jailed acceptance probe =="
docker exec "$NAME" bash "$ELF/probe.sh"

echo "RUN-ELF-LEG-OK"
