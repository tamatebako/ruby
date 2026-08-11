# ci/spec22 — spec 22 phase 1 acceptance harness (loader interposition, POSIX)

This directory is the **local, reproducible** acceptance proof for the
`dln_c_loader_interpose` patch family (`patches/*/dln_c_loader_interpose.patch`):
spec 22 class L — the process's `dlopen`/`dlerror` are interposed inside the
runtime binary, so any native-library load of a VFS-resident path is
materialized (with its dependency closure) to the exec cache and loaded for
real, from any caller in the process. No per-gem Ruby adapter is present in
the runtime under test.

It is deliberately **not** wired into CI: it needs the three repos on one
machine plus a compiled runtime, which the patch-level gates (lint,
compile-smoke) intentionally do not build. Run it by hand; it is idempotent
and fully deterministic from pinned inputs.

## What it proves (fixtures/probe.rb, jailed)

| check | assertion |
|---|---|
| `fiddle` | `Fiddle.dlopen("/probe/lib/libvfsprobe.<ext>")` — a VFS path — loads and its function returns 42 (dependency `libvfsdep` resolved through the closure walk) |
| `cext-self-dlopen` | a hand-rolled C extension calls its **own** `dlopen` on the VFS path from `Init` (bypassing `dln_load`) and returns 42 |
| `named-error` | `Fiddle.dlopen("/probe/lib")` (a directory) raises `Fiddle::DLError` whose message is the tebako verdict line: `cannot materialize VFS-resident library '/probe/lib' (mount '/'): …` |
| `jail-deny` | `File.read("/etc/passwd")` is denied under `TEBAKO_JAIL=deny;<scratch>:<scratch>:rw` — interposition did not punch through the jail |

The probe exits 0 only when all four print `ok`.

## Inputs and pins

- **This repo** (any checkout of tamatebako/ruby with the patch wired into
  `patches/*/patch-*.yaml`) — supplies the patched source tree via
  `tools/apply` + a sha256-pinned mirror, never the release channel.
- **tamatebako/tebako** at a commit carrying `tebako_fs_mount_of`
  (`crates/tfs`), staged with `tools/stage_link_unit` (env per
  AGENTS.md §13: `DWARFS_RS_VCPKG_ROOT`/`VCPKG_ROOT`/`SQFS_SYS_VCPKG_ROOT`,
  `CARGO_NET_GIT_FETCH_WITH_CLI=true`). Default: `../../tebako-wt-spec22-mountof`
  (override `TEBAKO_REPO`).
- **tamatebako/tebako-runtime-ruby** (the runtime factory), run from a
  detached git worktree at `origin/main` — its checkout is never mutated
  and its source pin is never bumped: `tools/build_runtime
  --src-mirror file://… --src-release spec22-local-…` consumes the local
  mirror.
- **The adapter-less tebako-runtime gem** in a local gem repo (default
  `/tmp/tebako-gem-repo`, override `GEM_REPO_DIR`). Build it from the
  spec-22 deletion branch of tamatebako/tebako-runtime:

  ```sh
  git worktree add ../tebako-runtime-wt-spec22-drop-ff -b feat/drop-class-l-adapters origin/main
  cd ../tebako-runtime-wt-spec22-drop-ff
  # ffi/fiddle entries removed from POST_REQUIRE_MAP + adapters deleted (the branch)
  gem build tebako-runtime.gemspec   # with VERSION temporarily "0.8.2.local"
  mkdir -p /tmp/tebako-gem-repo/gems && cp tebako-runtime-0.8.2.local.gem /tmp/tebako-gem-repo/gems/
  gem generate_index --directory /tmp/tebako-gem-repo
  ```

  The harness points `GEMRC` at that repo, so the factory's
  `gem install tebako-runtime` resolves the adapter-less build — without
  publishing anything and without touching `~/.gemrc`.

## Run

```sh
export DWARFS_RS_VCPKG_ROOT=/path/to/vcpkg VCPKG_ROOT=/path/to/vcpkg \
       SQFS_SYS_VCPKG_ROOT=/path/to/vcpkg CARGO_NET_GIT_FETCH_WITH_CLI=true
ci/spec22/run.sh 4.0.6        # any version in versions.yml
```

Verdict: `SPEC22-ACCEPTANCE-OK <version>` on success; a named `FAIL
spec22 (…)` line otherwise. Everything transient is under
`/tmp/spec22-scratch-<version>` (`SCRATCH` to override); delete it to
rebuild from scratch, or delete a single artifact to rebuild just that
stage (the link unit is reused across runs by design).

Platform notes: on macOS dyld honors `__DATA,__interpose` tuples only
from dylib images (never from the main executable — verified
empirically), so the macOS interposition is the DRIVER's self-insertion
at boot (crates/tebako-driver's embedded interpose dylib +
`DYLD_INSERT_LIBRARIES` + a once-only re-exec); ELF (linux-gnu/musl)
uses the main binary's own `dlopen`/`dlerror` definitions from this
patch, which preempt process-wide (verify on ELF with
`nm -D <runtime-exe> | grep ' T dlopen'`). The probe is POSIX-only;
windows is out of phase-1 scope.
