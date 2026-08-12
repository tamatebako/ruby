#!/bin/bash
# env.sh — sourced by every container-side step of the spec22 ELF leg.
# Layout contract:
#   $SCRATCH    (bind mount, host-persistent): sources, mirror, gem repo,
#                               HOME caches, outputs. Default
#                               /tmp/spec22-linux-scratch (override in the
#                               env); populate per ci/spec22/elf/README.md.
#   $LINK_UNIT  (bind mount, host-persistent): the staged link unit.
#                               Default: /tmp/spec22-link-unit-linux.
#   /vcpkg /cargo-target /sqfs-installed (container fs): heavy build trees —
#                               the vcpkg ARCHIVES cache (~/.cache/vcpkg) and
#                               the cargo registry/git db (~/.cargo) persist
#                               via HOME on the bind mount, so a re-run
#                               restores instead of rebuilding.
SCRATCH="${SCRATCH:-/tmp/spec22-linux-scratch}"
export SCRATCH
export LINK_UNIT="${LINK_UNIT:-/tmp/spec22-link-unit-linux}"
export HOME="$SCRATCH/home"
export PATH="$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

export CARGO_TARGET_DIR=/cargo-target
export CARGO_NET_GIT_FETCH_WITH_CLI=true

export VCPKG_ROOT=/vcpkg
export DWARFS_RS_VCPKG_ROOT=/vcpkg
export SQFS_SYS_VCPKG_ROOT=/vcpkg
export DWARFS_RS_VCPKG_TRIPLET=x64-linux-static
export SQFS_SYS_VCPKG_TRIPLET=x64-linux-static
export SQFS_SYS_VCPKG_INSTALLED_DIR=/sqfs-installed/x64-linux-static

# bindgen (rnp-rs) dlopens libclang; focal's stock is too old — clang-19 from
# apt.llvm.org (the gnu-floor-build.sh recipe).
export LIBCLANG_PATH=/usr/lib/llvm-19/lib

# glibc 2.31 pthreads vs librnp examples (gnu-floor-build.sh): driver-flag
# -pthread covers dwarfs-t-sys and every rnp-src dep configure.
export CFLAGS=-pthread
export CXXFLAGS=-pthread

# Absorb libstdc++/libgcc_s statically into the produced binaries (the floor
# rule); the wrapper rewrites the -l tokens at the driver boundary.
export RUSTFLAGS="-C linker=$SCRATCH/ws/tebako-rs/ci/linux-link-wrap.sh"

export TARGET=x86_64-unknown-linux-gnu
export TRIPLET=x64-linux-static
export VCPKG_COMMIT=f14401ca0f2754347c3864da7488a9b955b4e47a
export RUST_VERSION=1.94.1
