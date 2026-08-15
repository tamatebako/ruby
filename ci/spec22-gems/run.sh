#!/bin/bash
# ci/spec22-gems/run.sh — spec 22 gem-level acceptance harness (POSIX).
# Proves that real gems — sinatra and sassc — behave correctly inside a
# packaged tebako ruby runtime, JAILED, with the adapter-less
# tebako-runtime gem (v0.9.0, empty require maps) loaded at boot: no
# per-gem require adapters anywhere in the chain.
#
# Builds, from pinned inputs only (same shape as ci/spec22/run.sh):
#
#   1. a patched ruby source tree (this repo's tools/apply),
#   2. a v2 link unit staged from a tamatebako/tebako checkout that
#      carries tebako_fs_mount_of,
#   3. a runtime (exe + env image) built by the runtime factory against
#      that LOCAL source mirror and link unit, with the adapter-less
#      tebako-runtime gem installed from a local gem repo,
#   4. the probe gems INSTALLED BY THE BUILT RUNTIME'S OWN gem tooling
#      (the env image ships rubygems but no gem binstub, so a GemRunner
#      shim rides a tiny setup image) into a scratch gem home — sassc's
#      native extension is compiled by the runtime's own mkmf through
#      host clang, guaranteeing ABI match,
#   5. a probe payload image (fixtures/ + the scratch gem home) pressed
#      with the release tfs CLI,
#   6. three jailed invocations of the runtime (one per proof leg group);
#      grep-verdict on the PROBE lines, branching on the gem-loaded
#      instrumentation leg.
#
# The leg matrix and the pinned expected-fail signatures are documented
# in README.md. The sassc-partial leg is the class-R oracle: it is
# expected RED today and flips GREEN only in the PR that lands the
# in-flight class-R work (docs/spec/22 `materialize:` + driver boot
# extraction) — update the pin there, never silently.
#
# Idempotent: existing artifacts under $SCRATCH are reused; delete the
# scratch dir (or the specific artifact) to force a rebuild. Everything
# transient lives under $SCRATCH; the repos are never mutated (the
# factory runs from its own git worktree).
#
# Usage: ci/spec22-gems/run.sh [ruby-version]   (default 4.0.6)
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
#   SCRATCH        (default: /tmp/spec22-gems-scratch-<version>)
#   SRC_TAG        (default: spec22-gems-local-<version>)

set -euo pipefail

VERSION="${1:-4.0.6}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RUBY_REPO="$(cd "$SELF_DIR/../.." && pwd)"
ECOSYSTEM="$(cd "$RUBY_REPO/.." && pwd)"

TEBAKO_REPO="${TEBAKO_REPO:-$ECOSYSTEM/tebako-wt-spec22-mountof}"
FACTORY_REPO="${FACTORY_REPO:-$ECOSYSTEM/tebako-runtime-ruby}"
GEM_REPO_DIR="${GEM_REPO_DIR:-/tmp/tebako-gem-repo}"
SCRATCH="${SCRATCH:-/tmp/spec22-gems-scratch-$VERSION}"
SRC_TAG="${SRC_TAG:-spec22-gems-local-$VERSION}"
TFS_CLI="${TFS_CLI:-$ECOSYSTEM/tebako/target/release/tfs}"

# --- the pins --------------------------------------------------------------
# Exact gem versions under test (recorded in README.md).
SINATRA_VERSION="4.2.1"
SASSC_VERSION="2.4.0"
# The adapter-less gem that MUST be the one installed into the env image.
# Version note: rubygems treats any letter-bearing suffix (".local") as a
# prerelease, and `gem install` never auto-selects a prerelease over the
# released 0.8.2 — the numeric 0.9.0.1 sorts above both (README.md §gem).
TEBAKO_RUNTIME_GEM="tebako-runtime-0.9.0.1"
# Pinned failure oracles (spec 14: captured from real runs, then pinned;
# the class-R PR flips sassc-partial and re-pins HERE, in that PR).
#   sinatra-unfixed (gem-loaded yes): sinatra 4.x's load-time
#   caller_files picks the tebako-runtime require-hook frame as app_file,
#   deriving a wrong root, so the static fetch misses.
UNFIXED_APP_FILE_RE='/gems/tebako-runtime-0\.9\.0\.1/lib/tebako-runtime\.rb'
#   sassc-partial: libsass's C++ importer fopen()s the partial on a raw
#   host path (class R trigger); the VFS path is not host-real.
SASSC_PARTIAL_PIN='SassC::SyntaxError: Error: File to import not found or unreadable: partials/thing.'

PLATFORM_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$PLATFORM_OS" in
  darwin) MKIMAGE_FORMAT=dwarfs ;;
  linux)  MKIMAGE_FORMAT=dwarfs ;;
  *) echo "FAIL run.sh: unsupported host $PLATFORM_OS (POSIX only)" >&2; exit 64 ;;
esac

step() { echo "== spec22-gems step: $*"; }
die()  { echo "FAIL spec22-gems ($*)" >&2; exit 1; }

[ -x "$TFS_CLI" ] || die "tfs CLI not at $TFS_CLI (build the tebako workspace release)"
[ -f "$GEM_REPO_DIR/gems/$TEBAKO_RUNTIME_GEM.gem" ] \
  || die "adapter-less gem $TEBAKO_RUNTIME_GEM missing from $GEM_REPO_DIR (README.md §gem)"

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
RUNTIME_EXE="$RUNTIME_PKG"
RUNTIME_IMAGE="$RUNTIME_PKG.tfs"
FACTORY_WT="$SCRATCH/factory-worktree"
if [ ! -x "$RUNTIME_EXE" ]; then
  step "factory build $VERSION (local mirror, staged link unit, adapter-less gem)"
  if [ ! -d "$FACTORY_WT" ]; then
    # the scratch dir may have been deleted out from under a registered
    # worktree — prune stale registrations first
    git -C "$FACTORY_REPO" worktree prune
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
[ -x "$RUNTIME_EXE" ] || die "runtime exe missing at $RUNTIME_EXE"
[ -f "$RUNTIME_IMAGE" ] || die "env image missing at $RUNTIME_IMAGE"
# The acceptance is meaningless if a silent version resolution installed a
# gem WITH adapters: assert the env image carries the pinned adapter-less
# gem (and no other tebako-runtime version). /spec_cache holds quick-specs
# for every version in the repo index — only …/gems/<api>/specifications/
# is the installed truth.
img_gems="$("$TFS_CLI" find "$RUNTIME_IMAGE" 'tebako-runtime-*.gemspec' | grep '^/lib/ruby/gems/' | sort -u)"
echo "$img_gems" | grep -q "/$TEBAKO_RUNTIME_GEM.gemspec\$" \
  || die "env image lacks the pinned adapter-less gem $TEBAKO_RUNTIME_GEM (got: $(echo "$img_gems" | tr '\n' ' '))"
[ "$(echo "$img_gems" | grep -c gemspec)" -eq 1 ] \
  || die "env image carries more than one tebako-runtime version: $(echo "$img_gems" | tr '\n' ' ')"

# --- 4. probe gems installed by the runtime's OWN gem tooling -------------
# The env image ships rubygems (mkmf included) but deliberately no bin/
# binstubs, so a GemRunner shim (fixtures/gem.rb, the stock bin/gem body)
# rides a tiny setup image and receives the gem CLI args as its ARGV.
# Un-jailed on purpose: this is press, not proof.
SETUP_IMG="$SCRATCH/setup.tfs"
if [ ! -f "$SETUP_IMG" ] || [ "$SELF_DIR/fixtures/gem.rb" -nt "$SETUP_IMG" ]; then
  step "press setup image (GemRunner shim)"
  rm -rf "$SCRATCH/setup-tree"
  mkdir -p "$SCRATCH/setup-tree/setup"
  cp "$SELF_DIR/fixtures/gem.rb" "$SCRATCH/setup-tree/setup/"
  "$TFS_CLI" mkimage --format "$MKIMAGE_FORMAT" "$SCRATCH/setup-tree" --output "$SETUP_IMG" >/dev/null
fi

# The mount-root bridge (setup leg only). Two build-time consumers reach
# for raw HOST paths under the runtime root, exactly like spec 22 class R:
#   - rubygems' HTTPS fetcher: OpenSSL::X509::Store#add_file on the
#     in-image ssl_certs/*.pem (ruby's File.exist? sees the VFS file, the
#     C-level fopen does not),
#   - mkmf: the era-2 rbconfig derives rubyhdrdir from the prefix; the
#     image ships no include/, and host clang cannot read VFS paths.
# The env image's layout.yaml grants mount_root_override, so the setup leg
# runs with TEBAKO_MOUNT_ROOT pointed at a host-real tree carrying the
# byte-same content (the factory's pressed layout tree) PLUS the stash
# headers. Ruby resolves the VFS at the redirected root; native code and
# spawned build tools read the host tree. The proof legs never do this.
#
# The bridge also carries bin/ruby as a hardlink to the runtime exe: the
# v2 image ships no ruby binstub, but rubygems respawns RbConfig.ruby
# (<prefix>/bin/ruby) for every extconf. With no --tebako-* flags in that
# invocation the driver falls through to a plain interpreter boot, and
# ruby's patched IO opens the host-side extconf.rb via host fallback.
ENV_HOST="$SCRATCH/env-host"
if [ ! -f "$ENV_HOST/.bridge-$VERSION" ] || [ ! -e "$ENV_HOST/bin/ruby" ] \
   || [ "$RUNTIME_EXE" -nt "$ENV_HOST/.bridge-$VERSION" ]; then
  step "stage mount-root bridge tree for the setup leg"
  rm -rf "$ENV_HOST"
  mkdir -p "$ENV_HOST/bin"
  cp -R "$SCRATCH/factory/o/s/." "$ENV_HOST/"
  stash="$(find "$SCRATCH/factory/deps" -maxdepth 1 -type d -name 'stash_*' | head -1)"
  [ -d "$stash/include" ] || die "stash headers not found under $SCRATCH/factory/deps"
  cp -R "$stash/include" "$ENV_HOST/include"
  ln -f "$RUNTIME_EXE" "$ENV_HOST/bin/ruby"
  touch "$ENV_HOST/.bridge-$VERSION"
fi

GEMHOME="$SCRATCH/gemhome"
INSTALL_STAMP="$GEMHOME/.spec22-gems-$SINATRA_VERSION-$SASSC_VERSION.installed"
if [ ! -f "$INSTALL_STAMP" ]; then
  step "gem install sinatra:$SINATRA_VERSION sassc:$SASSC_VERSION via the built runtime"
  rm -rf "$GEMHOME" "$SCRATCH/gembin"
  mkdir -p "$SCRATCH/spec_cache"
  set +e
  env -i \
    HOME="$SCRATCH/home" \
    TMPDIR="$SCRATCH/tmp" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TEBAKO_HOME="$SCRATCH/tebako-home" \
    TEBAKO_RUNTIME_IMAGE="$RUNTIME_IMAGE" \
    TEBAKO_MOUNT_ROOT="$ENV_HOST" \
    GEM_SPEC_CACHE="$SCRATCH/spec_cache" \
    "$RUNTIME_EXE" --tebako-image "$SETUP_IMG:-:/" --tebako-entry /setup/gem.rb \
      install "sinatra:$SINATRA_VERSION" "sassc:$SASSC_VERSION" \
      --install-dir "$GEMHOME" --bindir "$SCRATCH/gembin" --no-document \
      > "$SCRATCH/install.log" 2>&1
  gem_status=$?
  set -e
  cat "$SCRATCH/install.log"
  [ "$gem_status" -eq 0 ] || die "gem install leg (see $SCRATCH/install.log)"
  grep -q "Successfully installed sinatra-$SINATRA_VERSION" "$SCRATCH/install.log" \
    || die "sinatra $SINATRA_VERSION not in the install log"
  grep -q "Successfully installed sassc-$SASSC_VERSION" "$SCRATCH/install.log" \
    || die "sassc $SASSC_VERSION not in the install log"
  touch "$INSTALL_STAMP"
fi

# --- 5. probe payload image ------------------------------------------------
PROBE_TREE="$SCRATCH/probe-tree"
PAYLOAD_IMG="$SCRATCH/probe-gems-$VERSION.tfs"
if [ ! -f "$PAYLOAD_IMG" ] || [ "$INSTALL_STAMP" -nt "$PAYLOAD_IMG" ] \
   || [ -n "$(find "$SELF_DIR/fixtures" -newer "$PAYLOAD_IMG" -print -quit 2>/dev/null)" ]; then
  step "assemble probe tree + press payload image"
  rm -rf "$PROBE_TREE"
  mkdir -p "$PROBE_TREE/probe"
  cp -R "$SELF_DIR/fixtures/." "$PROBE_TREE/probe/"
  rm -rf "$PROBE_TREE/probe/gem.rb"  # the setup shim is not a probe fixture
  cp -R "$GEMHOME" "$PROBE_TREE/probe/gemhome"
  rm -f "$PAYLOAD_IMG"
  "$TFS_CLI" mkimage --format "$MKIMAGE_FORMAT" "$PROBE_TREE" --output "$PAYLOAD_IMG" >/dev/null
fi

# --- 6. the jailed proofs ----------------------------------------------------
# One process per leg group: the two classic-style sinatra apps share
# Sinatra::Application state by definition, so they run in separate
# invocations; the two sassc legs share one.
run_probe() {
  local leg="$1"
  set +e
  env -i \
    HOME="$SCRATCH/home" \
    TMPDIR="$SCRATCH/tmp" \
    PATH="/usr/bin:/bin" \
    TEBAKO_HOME="$SCRATCH/tebako-home" \
    TEBAKO_RUNTIME_IMAGE="$RUNTIME_IMAGE" \
    TEBAKO_JAIL="deny;$SCRATCH:$SCRATCH:rw" \
    "$RUNTIME_EXE" --tebako-image "$PAYLOAD_IMG:-:/" --tebako-entry /probe/probe.rb "$leg" \
    > "$SCRATCH/proof-$leg.log" 2>&1
  local st=$?
  set -e
  cat "$SCRATCH/proof-$leg.log"
  return "$st"
}

step "jailed probe runs (TEBAKO_JAIL=deny;\$SCRATCH:\$SCRATCH:rw)"
st_fixed=0; st_unfixed=0; st_sassc=0
run_probe sinatra-fixed   || st_fixed=$?
run_probe sinatra-unfixed || st_unfixed=$?
run_probe sassc           || st_sassc=$?

gem_loaded="$(grep -m1 -oE '^PROBE gem-loaded (yes|no)' "$SCRATCH/proof-sinatra-fixed.log" | awk '{print $3}')"
[ -n "$gem_loaded" ] || die "gem-loaded instrumentation line missing"
# every invocation must report the same boot state
for leg in sinatra-unfixed sassc; do
  other="$(grep -m1 -oE '^PROBE gem-loaded (yes|no)' "$SCRATCH/proof-$leg.log" | awk '{print $3}')"
  [ "$other" = "$gem_loaded" ] || die "gem-loaded disagree across legs ($gem_loaded vs $other in $leg)"
done

# green legs
[ "$st_fixed" -eq 0 ] || die "sinatra-fixed leg exit $st_fixed"
grep -q "^PROBE sinatra-fixed ok status=200 " "$SCRATCH/proof-sinatra-fixed.log" || die "sinatra-fixed leg"
[ "$st_sassc" -eq 0 ] || die "sassc leg exit $st_sassc"
grep -q "^PROBE sassc-main ok " "$SCRATCH/proof-sassc.log" || die "sassc-main leg"

# red legs — pinned signatures, branched on the instrumentation verdict
if [ "$gem_loaded" = "yes" ]; then
  grep -E "^PROBE sinatra-unfixed expected-fail app_file=\S*$UNFIXED_APP_FILE_RE root=\S* status=404" \
    "$SCRATCH/proof-sinatra-unfixed.log" >/dev/null \
    || die "sinatra-unfixed leg (expected the pinned caller_files pollution signature)"
else
  # no tebako-runtime frame on the stack: nothing pollutes caller_files
  grep -q "^PROBE sinatra-unfixed ok status=200 " "$SCRATCH/proof-sinatra-unfixed.log" \
    || die "sinatra-unfixed leg (gem absent: expected GREEN, got a surprise)"
fi
grep -qF "PROBE sassc-partial expected-fail $SASSC_PARTIAL_PIN" "$SCRATCH/proof-sassc.log" \
  || die "sassc-partial leg (expected the pinned class-R failure signature)"

echo "SPEC22-GEMS-ACCEPTANCE-OK $VERSION ($RUNTIME_EXE; sinatra $SINATRA_VERSION, sassc $SASSC_VERSION, $TEBAKO_RUNTIME_GEM)"
