# ci/spec22-gems — spec 22 gem-level acceptance harness (real gems, jailed)

This directory is the **local, reproducible** acceptance proof that real
gems run correctly inside a packaged tebako ruby runtime with **no
tebako-runtime gem anywhere** (the gem kill, spec 22 phase M2, factory
PR #103): no require hook at boot, no per-gem require adapters in any
layer. It closes the two dogfood-coverage gaps flagged by
the gem-kill audit: **sassc** (spec 22 class R trigger) and **sinatra**
(fits no class; payload-side contract) appear in no dogfood closure
(metanorma 1.16.9, fontist 3.0.10 verified).

The POSIX harness (`run.sh`) is deliberately **not** wired into CI, same
as `ci/spec22` (whose class-L harness it reuses as the build template):
it needs the three repos on one machine plus a compiled runtime. Run it
by hand; it is idempotent and fully deterministic from pinned inputs.
(The windows leg, `run-msys.sh`, IS CI-consumed — the factory's windows
dogfood job runs it against CI-built artifacts; see the last section.)

## The leg matrix (fixtures/probe.rb, jailed)

`TEBAKO_JAIL="deny;<scratch>:<scratch>:rw"`, `env -i`, payload mounted at
`/`; the probe redirects rubygems at the in-image gem home
(`/probe/gemhome`) before requiring anything.

| leg | expectation | what it proves |
|---|---|---|
| `gem-loaded` | instrumentation (must be `no`) | no tebako-runtime gem may load at boot (spec 22 phase M2); a `yes` means a gem crept back into the env image and fails the harness loud |
| `sinatra-fixed` | **GREEN** | classic-style sinatra with the documented payload-side contract `set :app_file, __FILE__`; `Rack::MockRequest` fetches `/static.txt` from the root-derived `public/` (rack's file serving rides ruby's patched IO, so the VFS path reads fine), 200 + byte-exact body, jailed |
| `sinatra-unfixed` | **GREEN** | the same app WITHOUT the fix. Pre-M2 this leg was the pinned RED oracle: with the gem loaded, its `Kernel#require` hook frame polluted sinatra 4.x's load-time `caller_files` app_file detection, `root` derived under the gem's `lib/`, and the static fetch 404d. Post-M2 no such frame exists and the leg must be GREEN — if a gem ever returns, the probe still reports the pollution signature and the harness fails it loud (this row is the sentinel) |
| `sassc-main` | **GREEN** | `SassC::Engine.new(File.read("/probe/styles/plain.scss"))` — no imports: ruby's patched IO reads the VFS file, libsass compiles the string; the CSS carries the rule. Nothing touches a host path |
| `sassc-partial` | **GREEN** (since class R landed) | `SassC::Engine.new(…, filename:, load_paths:)` with `@import "partials/thing"` run against the **materialized** styles tree: the payload manifest declares `materialize:` for `main.scss` + `partials/_thing.scss` (spec 22 §4), the driver extracts them to `<TEBAKO_EXEC_CACHE>/resources/<image-key>/…` at boot, and libsass's C++ importer `fopen()`s REAL host paths (the exec cache lives under the harness scratch, which the jail grants rw). The probe asserts the partial's own rule (`.spec22-gems-thing`, `#c0392b`) is in the CSS |
| `sassc-partial-unmaterialized` | **expected RED** | the SAME import run against the **negative-oracle image** — the same probe tree pressed with a manifest identical except for the absent `materialize:` key. The importer's `fopen()` of `/probe/styles/partials/_thing.scss` is not host-real and the engine raises `SassC::SyntaxError: Error: File to import not found or unreadable: partials/thing.` (pinned). This is the **class-R mechanism oracle** |

### The class-R flip contract

Class R landed in tamatebako/tebako PR #403 (spec 22 §4: the additive
`materialize:` payload-manifest key + driver boot-time extraction to the
host exec cache). `sassc-partial` flipped from the pinned RED oracle to
GREEN **in this change**, by declaring the styles tree in the probe
payload's manifest — nothing else moved: the jail spec is byte-identical,
the import statement is byte-identical, only the consumption paths point
at the documented `<TEBAKO_EXEC_CACHE>/resources/<image-key>/<P>` landing
zone (spec 22 §6).

The mechanism is kept honest by `sassc-partial-unmaterialized`: the same
tree pressed **without** the declaration (the two manifests differ ONLY
in the `materialize:` block; the payload content hashes identically — the
mkimage `tree_hash` stamp excludes `/__tpkg__/`). That leg must stay RED
with the exact pinned signature. So:

- a RED `sassc-partial` → the materialization chain broke (driver,
  manifest parse, exec-cache extraction) — harness failure;
- a GREEN `sassc-partial-unmaterialized` → the failure mode vanished
  WITHOUT the declaration, i.e. the flip came from a silent jail
  relaxation or transparent host fallback, not from `materialize:` —
  harness failure;
- a RED `sassc-partial-unmaterialized` with a DIFFERENT error → the
  failure surface drifted — harness failure (re-pin deliberately, never
  silently).

Both verdicts ride on a runtime exe whose driver carries class R: run.sh
dies early unless `$TEBAKO_REPO/crates/tebako-driver/src/materialize.rs`
exists, restages the link unit AND the runtime when `TEBAKO_REPO`'s HEAD
moves, and asserts after the press that the materialized image really
carries the `materialize:` key (a pre-class-R `tfs` CLI tolerates the
unknown key at parse but drops it on the `tree_hash` re-serialization)
and that the oracle image really lacks it.

## How the probe gems get in (setup legs — press, not proof)

The env image ships rubygems (mkmf included) but deliberately **no gem
binstub** (`/bin` in the image holds only the bundled-gem stubs; the v2
interpreter exe lives outside the image). The harness therefore:

1. presses a tiny **setup image** carrying `fixtures/gem.rb` — the stock
   `bin/gem` body (`Gem::GemRunner.new.run ARGV.clone`) as a tebako entry
   script;
2. stages a **mount-root bridge** tree: the era-2 rbconfig emits
   `ENV["TEBAKO_MOUNT_ROOT"] || <baked>`, and the env image's layout
   grants `mount_root_override`, so the setup invocation redirects the
   mount root to a host-real copy of the pressed layout tree **plus** the
   stash `include/` headers and a `bin/ruby` hardlink to the runtime exe.
   Two build-time consumers need this — both are spec 22 class R shaped
   (native code reading raw host paths): rubygems' HTTPS fetcher
   (`OpenSSL::X509::Store#add_file` on the in-image `ssl_certs/*.pem`)
   and mkmf's spawned clang (the image ships no `include/`, and VFS paths
   are not host-real). The `bin/ruby` hardlink exists because rubygems
   respawns `RbConfig.ruby` (`<prefix>/bin/ruby`) for every extconf; with
   no `--tebako-*` flags the driver falls through to a plain interpreter
   boot and ruby's patched IO opens the host-side extconf via host
   fallback. No host ruby is involved anywhere — every ruby that runs is
   the built runtime itself;
3. runs the **built runtime's own** gem tooling, un-jailed:
   `<runtime> --tebako-image <setup.tfs>:-:/ --tebako-entry /setup/gem.rb
   install sinatra:4.2.1 sassc:2.4.0 --install-dir <scratch>/gemhome …`.
   sassc's extconf compiles libsass through the runtime's own mkmf with
   host clang — ABI match is guaranteed by construction, and a working
   install is itself evidence the packaged rubygems/mkmf stack is whole;
4. copies the scratch gem home into the probe tree and presses the probe
   payload images with the release `tfs` CLI (`mkimage --format dwarfs`)
   — the materialized image and the negative-oracle image, same tree.

The two classic-style sinatra apps share `Sinatra::Application` state by
definition, so the harness runs **four** jailed invocations
(sinatra-fixed, sinatra-unfixed, sassc, sassc-unmaterialized) instead of
ci/spec22's one; the jail and `env -i` shape are identical in each. The
bridge (`TEBAKO_MOUNT_ROOT` redirect) is used **only** by the un-jailed
setup leg — the proof legs boot the runtime stock.

## Inputs and pins

- **This repo** (any checkout of tamatebako/ruby with the patch stack
  wired into `patches/*/patch-*.yaml`) — supplies the patched source tree
  via `tools/apply` + a sha256-pinned mirror, never the release channel.
- **tamatebako/tebako** at a commit carrying `tebako_fs_mount_of`
  (`crates/tfs`) AND the class-R boot materialization
  (`crates/tebako-driver/src/materialize.rs` — spec 22 §4, PR #403;
  tebako main carries both), staged with `tools/stage_link_unit` (env per
  AGENTS.md §13: `DWARFS_RS_VCPKG_ROOT`/`VCPKG_ROOT`/`SQFS_SYS_VCPKG_ROOT`,
  `CARGO_NET_GIT_FETCH_WITH_CLI=true`). Default: `../../tebako-wt-spec22-mountof`
  (override `TEBAKO_REPO`). The release `tfs` CLI that presses the probe
  images (`TFS_CLI`) must come from a class-R checkout too — see the flip
  contract above.
- **tamatebako/tebako-runtime-ruby** (the runtime factory), run from a
  detached git worktree at `origin/main` — its checkout is never mutated
  and its source pin is never bumped: `tools/build_runtime
  --src-mirror file://… --src-release spec22-gems-local-…` consumes the
  local mirror.
- **Probe gems**: `sinatra 4.2.1`, `sassc 2.4.0` (pinned in run.sh;
  resolved from rubygems.org at setup time; sassc has no precompiled
  darwin gem, so its libsass/native extension always compiles locally;
  its `ffi` dependency may resolve to a precompiled arm64-darwin gem —
  the install log under the scratch dir records what was picked).

## Run

```sh
export DWARFS_RS_VCPKG_ROOT=/path/to/vcpkg VCPKG_ROOT=/path/to/vcpkg \
       SQFS_SYS_VCPKG_ROOT=/path/to/vcpkg CARGO_NET_GIT_FETCH_WITH_CLI=true
ci/spec22-gems/run.sh 4.0.6        # any version in versions.yml
```

Verdict: `SPEC22-GEMS-ACCEPTANCE-OK <version>` on success; a named
`FAIL spec22-gems (…)` line otherwise. Everything transient is under
`/tmp/spec22-gems-scratch-<version>` (`SCRATCH` to override); delete it
to rebuild from scratch, or delete a single artifact to rebuild just that
stage (the mirror, the link unit, the runtime, the gem home, and the
payload image are gated independently; the runtime and link unit are
reused across runs by design). Per-leg proof output lands in
`<scratch>/proof-<leg>.log`; the gem install transcript in
`<scratch>/install.log`.

`ci/spec22` (the phase-1 class-L harness) is untouched by this addition;
the two harnesses share the input pins and the scratch layout conventions
but no state.

## The windows leg (`run-msys.sh`, msys only)

`run-msys.sh` is the same acceptance on windows (spec 22 §8's last row:
the suite green with the gem gone on **every** published platform). Same
fixtures, same four jailed legs, same pinned PROBE lines — but it builds
nothing: the runtime arrives as the factory's CI artifacts and the
press/extract tooling is the published windows `tfs` CLI. On msys the
POSIX harness's roll → link-unit → factory-build chain would re-run the
factory's own CI on a slower footing; the release gate wants the SHIPPED
shape exercised.

Inputs (env): `RUNTIME_PKG_DIR` (the factory `runtime-packages-windows-*`
artifact extracted), `DEVKIT_DIR` (the factory `devkit-windows-*`
artifact — the stash `include/` the env image omits plus
`lib/libx64-ucrt-ruby<ABI>.dll.a`, the import library an msys native
extension links), `TFS_CLI` (the published `tfs-…-windows-ucrt64.exe`).
Overridable: `SCRATCH`, `UCRT64_BIN` (the gem-install leg's gcc/make
source — default the setup-msys2 location).

The windows-specific mechanics the leg owns:

- **The PE-named DLL.** The artifact carries the ruby DLL under the
  unique package name; the exe's imports resolve only
  `x64-ucrt-ruby<ABI>.dll` next to the exe. The leg materializes the copy
  (the same rule the factory's boot smoke runs).
- **Path discipline.** The runtime exe and `tfs.exe` are native windows
  binaries: env values crossing into them are `cygpath -m`'d (msys bash
  converts argv, never env); VFS paths are never converted.
  `--tebako-image C:/…/x.tfs:-:/` parses because the driver splits the
  triple on the LAST two colons.
- **The bridge tree is reconstituted, and host-real via `subst` — no
  mount-root override.** run.sh's setup leg redirects the mount root with
  `TEBAKO_MOUNT_ROOT` (the POSIX images grant `mount_root_override`). On
  msys that mechanism is absent BY DESIGN: configure forces LOAD_RELATIVE
  (the ruby.c loadpath helper compiles out), so the tarball carries no
  override manifest and the driver refuses `TEBAKO_MOUNT_ROOT` on msys
  images (fail-closed). The windows bridge instead relies on two shipped
  behaviors: the era-2 msys rbconfig already spells
  `ENV["TEBAKO_MOUNT_ROOT"] || 'A:/t'` (unset → the baked root), and
  `subst A: <bridge-parent>` makes `A:\t` host-real for the leg's
  duration — raw C opens (OpenSSL's cert `fopen`, the spawned gcc's
  `-I`/`-L`) read the bridge through the alias, and rubygems' per-extconf
  respawn of `A:/t/bin/ruby.exe` plain-boots the bridge's exe copy, whose
  LOAD_RELATIVE load paths self-root at `A:/t`. The bridge tree itself is
  `tfs extract` of the env image + the devkit's `include/` + the import
  lib under `lib/`, plus `bin/ruby.exe` and the PE-named DLL beside it;
  it lives at `<scratch>/a-drive/t` so the drive letter maps its parent.
- **The ucrt import-closure vendoring (incident 13).** sassc's
  `ffi_lib` spells `libsass.so` by FULL path and ffi calls
  `LoadLibraryExA` on it raw; ruby's msys dln patch rebinds every loaded
  module's kernel loader imports onto the Rule-L1 materialize-then-load
  route, whose PE closure walk resolves an imported DLL ONLY in the
  importing module's own directory (the locked importer-dir rule — never
  a cross-mount search). `libsass.so`'s ucrt closure
  (`libstdc++-6.dll` → `libgcc_s_seh-1.dll` / `libwinpthread-1.dll`)
  lives in `UCRT64_BIN`, not in the gem tree, so the materialized module
  would 126. After a successful install the leg vendors the transitive
  closure (`objdump -p`, fixed-point, existence-tested per name — OS DLLs
  are skipped by rule, no hardcoded list) next to each `libsass.so` copy,
  so the pressed payload image is self-contained. The walk prefers the
  msys-native `objdump` (`MSYS2_ARG_CONV_EXCL='*'` keeps POSIX paths from
  reaching the native ucrt64 one — the first run's silent no-op).
- **The jail spelling.** `TEBAKO_JAIL="deny;<C:/…/scratch>:/host-scratch:rw"`:
  the grammar right-splits, so the drive-colon host path survives; the
  mount side must be `/`-absolute and is informational (enforcement
  matches host prefixes). The platform floor (spec 08 §2.1: System32,
  SysWOW64, Fonts) is implicit under `deny`. The proof legs run WITHOUT
  the toolchain on PATH — a payload needs no compiler at run time.
- **The windows env baseline.** `env -i` proves the runtime needs nothing
  from the host environment, but on windows a custom env block below the
  platform baseline breaks system apis the runtime legitimately calls:
  with no SystemDrive/WINDIR/ProgramData in the block,
  `SHGetSpecialFolderLocation` fails (the registry-held shell-folder
  spellings expand against the process env), so `Etc.sysconfdir` returns
  nil and rubygems' `config_file.rb` dies at class-load — a real user's
  env always carries the baseline, so this is not a hermeticity failure.
  Every `env -i` list pins the baseline: SystemDrive/WINDIR/ProgramData/
  ALLUSERSPROFILE as the stock `C:\` constants (inert strings — the jail
  still decides file access), USERPROFILE/APPDATA scoped into the scratch
  like HOME. A diagnostic leg (`fixtures/envprobe.rb`, always catted)
  prints `Etc.sysconfdir` under the bare / baseline / minimal scrubs on
  every run — the bare probe is the regression record; per-shape logs in
  `<scratch>/envprobe-<shape>.log`. A second diagnostic
  (`fixtures/pipeprobe.rb`, section 4, always catted, never gating)
  exercises the extconf respawn's spawn mechanics step-by-step with full
  backtraces — IO.pipe, spawn with env/chdir/redirects, Open3.popen2e —
  because rubygems' ext builder compresses a respawn failure to
  `extconf failed` + open3's ensure-masked `nil.close`; the PROBE-PIPE
  lines name the failing primitive (`<scratch>/pipeprobe.log`).

Verdict: `SPEC22-GEMS-MSYS-ACCEPTANCE-OK <version>`; per-leg proof output
in `<scratch>/proof-<leg>.log`, the install transcript in
`<scratch>/install.log`. Consumed by the factory's windows dogfood job
(tebako-runtime-ruby), which fetches the artifacts and exports the
inputs; runnable by hand on any msys shell with the same inputs.
