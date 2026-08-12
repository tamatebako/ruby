#!/bin/bash
# build-link-unit.sh — the linux-gnu v2 link unit + tfs CLI, inside the
# toolchain container. Mirrors ci/gnu-floor-build.sh's env and ordering:
# serialized sqfs pre-install first (sqfs-sys's build.rs would otherwise
# race dwarfs-t-sys's vcpkg run on the root lock), then the cargo build,
# then tools/stage_link_unit --skip-build into $LINK_UNIT.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
cd "$SCRATCH/ws/tebako-rs"

echo "== vcpkg pre-install squashfs-tools-ng ($TRIPLET) =="
if [ ! -f "$SQFS_SYS_VCPKG_INSTALLED_DIR/lib/libsquashfs.a" ]; then
  "$VCPKG_ROOT/vcpkg" install \
    --vcpkg-root "$VCPKG_ROOT" \
    --x-wait-for-lock \
    --x-manifest-root crates/sqfs-sys \
    --x-install-root /sqfs-installed \
    --triplet "$TRIPLET" \
    --overlay-triplets crates/sqfs-sys/vcpkg_triplets \
    --overlay-ports crates/sqfs-sys/vcpkg_ports
fi

echo "== cargo build --release ($TARGET): tfs, tebako-driver, libtfs-preload, tfs-cli =="
cargo build --release --target "$TARGET" -p tfs -p tebako-driver -p libtfs-preload -p tfs-cli

echo "== bridge the pre-installed sqfs tree into the sqfs-sys out dir =="
# (link-unit-stage.sh's bridge: the harvest globs <sqfs-out>/vcpkg_installed/
# <triplet>/lib/libsquashfs.a, which a pre-install leaves empty)
sqfs_out=$(ls -dt "/cargo-target/$TARGET/release/build"/sqfs-sys-*/out | head -1)
trip=$(basename "$SQFS_SYS_VCPKG_INSTALLED_DIR")
if [ ! -e "$sqfs_out/vcpkg_installed/$trip/lib" ]; then
  mkdir -p "$sqfs_out/vcpkg_installed"
  ln -sfn "$SQFS_SYS_VCPKG_INSTALLED_DIR" "$sqfs_out/vcpkg_installed/$trip"
  echo "bridged $SQFS_SYS_VCPKG_INSTALLED_DIR -> $sqfs_out/vcpkg_installed/$trip"
fi

echo "== stage the link unit =="
ruby tools/stage_link_unit $LINK_UNIT --target "$TARGET" --skip-build

echo "== nm evidence =="
for sym in tebako_fs_mount_of tebako_fs_dlmap2file tebako_path_is_embedded; do
  hit_tfs=$(nm $LINK_UNIT/libtfs.a 2>/dev/null | grep -c " T $sym\$" || true)
  hit_drv=$(nm $LINK_UNIT/libtebako_driver.a 2>/dev/null | grep -c " T $sym\$" || true)
  echo "  $sym: libtfs.a T-defs=$hit_tfs libtebako_driver.a T-defs=$hit_drv"
done
echo "== preload cdylib dynamic deps (must be glibc-only) =="
ls -la $LINK_UNIT/
NEEDED=$(readelf -d $LINK_UNIT/libtfs_preload.so | grep NEEDED || true)
echo "$NEEDED"
echo "$NEEDED" | grep -E 'libstdc\+\+|libgcc_s' && { echo "FAIL: preload NEEDs the C++ runtime chain"; exit 65; } || true

echo "== GNU_UNIQUE gate (libtfs.a must carry none) =="
# gcc's libstdc++ emits inline-template statics (std::__detail::__to_chars_
# _10_impl::__digits, _Sp_make_shared_tag::__tag) as STB_GNU_UNIQUE inside
# the vendored rnp closure — process-singleton semantics that break the
# static-archive model (and mis-link under qemu-user). tebako-arscope's
# prefixing does not rewrite them away (upstream fix owed); the acceptance
# gate is that the STAGED archive carries zero. clang-built members do not
# emit them, so the container-local remedy is to rebuild the flagged
# members with clang-19 and reseal (ci/spec22/elf/reseal.py — see the
# README's reseal section). Backup the pre-reseal archive first.
UNIQUE=$(nm $LINK_UNIT/libtfs.a 2>/dev/null | grep -cE ' u [a-zA-Z_]' || true)
echo "  GNU_UNIQUE defs in libtfs.a: $UNIQUE"
[ "$UNIQUE" -eq 0 ] || {
  echo "GATE-FAIL: libtfs.a carries $UNIQUE GNU_UNIQUE definition(s) —"
  echo "rebuild the flagged members with clang-19 and reseal per"
  echo "ci/spec22/elf/README.md (reseal section), then re-run."
  exit 65
}

echo "BUILD-LINK-UNIT-OK"
