#!/bin/bash
# setup-toolchain.sh — run ONCE inside the container (as root).
# Reproduces the tebako-rs gnu-floor toolchain (ci/gnu-floor-build.sh) on top
# of the factory's CI image ghcr.io/tamatebako/tebako-ubuntu-20.04:0.16.2-amd64
# (which already carries: gcc-9, ruby 3.2.6 + bundler, git, autoconf/automake/
# bison, curl/wget, pkg-config, ninja, zip/unzip, and the ruby build deps
# libssl/zlib1g/readline/libyaml/libffi -dev — but NOT a modern cmake: focal's
# stock is 3.16, below dwarfs-t's 3.28 floor, so 3.31.9 is installed below).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

echo "== apt: base + link-unit additions =="
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential ninja-build pkg-config \
  autoconf automake autoconf-archive libtool \
  curl zip unzip tar ca-certificates git gnupg lsb-release wget \
  libbz2-dev patchelf flex gawk

# cmake >= 3.28 (dwarfs-t's floor): the image carries only focal's stock
# 3.16, so the Kitware binary tarball goes to /usr/local (first on PATH).
echo "== cmake 3.31.9 (kitware binary; focal's apt cmake is 3.16) =="
curl -fsSL https://github.com/Kitware/CMake/releases/download/v3.31.9/cmake-3.31.9-linux-x86_64.tar.gz \
  | tar xz -C /usr/local --strip-components=1
cmake --version | head -1

# focal git 2.25 + mounted uid-mismatched repos: trust everything (the
# build trees under the bind mount are owned by the host uid).
git config --global --add safe.directory '*'

echo "== clang-19 (llvm.org focal) =="
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg
echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-19 main" \
  > /etc/apt/sources.list.d/llvm19.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends clang-19 libclang-19-dev
echo "/usr/lib/llvm-19/lib" > /etc/ld.so.conf.d/llvm19.conf
ldconfig

echo "== gcc-11 (ubuntu-toolchain-r ppa; Botan 3.12 hard-gates gcc >= 11) =="
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x1E9377A2BA9EF27F" \
  | gpg --dearmor -o /usr/share/keyrings/toolchainr.gpg
echo "deb [signed-by=/usr/share/keyrings/toolchainr.gpg] http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu focal main" \
  > /etc/apt/sources.list.d/toolchainr.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc-11 g++-11
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
  --slave /usr/bin/g++ g++ /usr/bin/g++-11
update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-11 110
update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-11 110
gcc --version | head -1

echo "== rustup ($RUST_VERSION) =="
curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "$RUST_VERSION" --target "$TARGET"
rustc --version

echo "== vcpkg ($VCPKG_COMMIT) =="
git clone --quiet https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
git -C "$VCPKG_ROOT" checkout --quiet "$VCPKG_COMMIT"
"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics

echo "== git metadata for the dwarfs-t copy (version.cmake) =="
# dwarfs-t's cmake/version.cmake dies without git metadata ("missing
# version files"); the scratch copy is a git-less rsync, so give it a
# one-commit repo (describe falls back to v0.0.0-dev-<rev>, which the
# version parser accepts). Scratch copy only — the checkout is untouched.
git -C "$SCRATCH/ws/dwarfs-rs/dwarfs-t" init -q
git -C "$SCRATCH/ws/dwarfs-rs/dwarfs-t" -c user.email=spec22@local -c user.name=spec22 \
  commit -q --allow-empty -m "spec22 scratch (git metadata for version.cmake)"

echo "== cargo target off the bind mount =="
mkdir -p /cargo-target /sqfs-installed
ln -sfn /cargo-target "$SCRATCH/ws/tebako-rs/target"

echo "== neuter the distro libjemalloc.a (qemu/user-mode emulation) =="
# The ruby build's -ljemalloc probe resolves the DISTRO static archive via
# the -l: fallback and links it into miniruby; under qemu-user (Rosetta)
# that combination hangs the build. The distro archive is irrelevant to
# the runtime (the link unit brings its own allocator story), so replace
# it with an empty archive (a .real backup rides alongside for forensics).
# Idempotent; a no-op on real hardware runs where the file was already
# moved. DO NOT do this on a host you care about — container fs only.
JEM=/lib/x86_64-linux-gnu/libjemalloc.a
if [ -f "$JEM" ] && [ ! -f "$JEM.real" ]; then
  mv "$JEM" "$JEM.real"
  ar rc "$JEM"   # empty archive
  ranlib "$JEM" 2>/dev/null || true
  echo "neutered $JEM (backup: $JEM.real)"
else
  echo "libjemalloc.a already neutered or absent"
fi

echo "SETUP-TOOLCHAIN-OK"
