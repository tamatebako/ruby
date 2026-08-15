# ci/spec22-gems — spec 22 gem-level acceptance harness (real gems, jailed)

This directory is the **local, reproducible** acceptance proof that real
gems run correctly inside a packaged tebako ruby runtime with the
**adapter-less** tebako-runtime gem (v0.9.0, empty require maps — the
tebako-runtime gem kill, draft PR tamatebako/tebako-runtime#29) loaded at
boot by the patched gem_prelude. No per-gem require adapters exist
anywhere in the chain. It closes the two dogfood-coverage gaps flagged by
the gem-kill audit: **sassc** (spec 22 class R trigger) and **sinatra**
(fits no class; payload-side contract) appear in no dogfood closure
(metanorma 1.16.9, fontist 3.0.10 verified).

It is deliberately **not** wired into CI, same as `ci/spec22` (whose
class-L harness it reuses as the build template): it needs the three
repos on one machine plus a compiled runtime. Run it by hand; it is
idempotent and fully deterministic from pinned inputs.

## The leg matrix (fixtures/probe.rb, jailed)

`TEBAKO_JAIL="deny;<scratch>:<scratch>:rw"`, `env -i`, payload mounted at
`/`; the probe redirects rubygems at the in-image gem home
(`/probe/gemhome`) before requiring anything.

| leg | expectation | what it proves |
|---|---|---|
| `gem-loaded` | instrumentation (`yes` today) | whether the patched gem_prelude required tebako-runtime at boot; branches the sinatra-unfixed expectation |
| `sinatra-fixed` | **GREEN** | classic-style sinatra with the documented payload-side contract `set :app_file, __FILE__`; `Rack::MockRequest` fetches `/static.txt` from the root-derived `public/` (rack's file serving rides ruby's patched IO, so the VFS path reads fine), 200 + byte-exact body, jailed |
| `sinatra-unfixed` | **expected RED** when gem-loaded `yes` | sinatra 4.x's load-time `caller_files` app_file detection takes the gem's `Kernel#require` hook frame (`CALLERS_TO_IGNORE` rejects rubygems/bundler/zeitwerk frames, not ours): `app_file` misdetects as `…/gems/tebako-runtime-0.9.0.1/lib/tebako-runtime.rb`, `root` derives under the gem's `lib/`, the static fetch 404s. The harness pins that exact signature. If the gem is absent (`gem-loaded no`) the pollution source is gone and the leg must be GREEN — a surprise either way fails the harness |
| `sassc-main` | **GREEN** | `SassC::Engine.new(File.read("/probe/styles/plain.scss"))` — no imports: ruby's patched IO reads the VFS file, libsass compiles the string; the CSS carries the rule. Nothing touches a host path |
| `sassc-partial` | **expected RED** today | `SassC::Engine.new(…, filename:, load_paths: ["/probe/styles"])` with `@import "partials/thing"`: libsass's OWN C++ importer `fopen()`s `/probe/styles/partials/_thing.scss` on the raw host path — VFS paths are not host-real — and the engine raises `SassC::SyntaxError: Error: File to import not found or unreadable: partials/thing.` (pinned). This is the **class-R oracle** |

### The class-R flip contract

`sassc-partial` is expected RED against the in-flight spec 22 class-R work
(product-repo `materialize:` manifest key + driver boot extraction; see
`docs/spec/22-runtime-native-interposition.md`). When class R lands, this
leg flips GREEN — update the pin **in that PR**, never silently. Until
then a GREEN leg here is a harness failure, exactly like a RED one with
the wrong signature.

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
   payload image with the release `tfs` CLI (`mkimage --format dwarfs`).

The two classic-style sinatra apps share `Sinatra::Application` state by
definition, so the harness runs **three** jailed invocations
(sinatra-fixed, sinatra-unfixed, sassc) instead of ci/spec22's one; the
jail and `env -i` shape are identical in each. The bridge
(`TEBAKO_MOUNT_ROOT` redirect) is used **only** by the un-jailed setup
leg — the proof legs boot the runtime stock.

## Inputs and pins

- **This repo** (any checkout of tamatebako/ruby with the patch stack
  wired into `patches/*/patch-*.yaml`) — supplies the patched source tree
  via `tools/apply` + a sha256-pinned mirror, never the release channel.
- **tamatebako/tebako** at a commit carrying `tebako_fs_mount_of`
  (`crates/tfs`), staged with `tools/stage_link_unit` (env per
  AGENTS.md §13: `DWARFS_RS_VCPKG_ROOT`/`VCPKG_ROOT`/`SQFS_SYS_VCPKG_ROOT`,
  `CARGO_NET_GIT_FETCH_WITH_CLI=true`). Default: `../../tebako-wt-spec22-mountof`
  (override `TEBAKO_REPO`).
- **tamatebako/tebako-runtime-ruby** (the runtime factory), run from a
  detached git worktree at `origin/main` — its checkout is never mutated
  and its source pin is never bumped: `tools/build_runtime
  --src-mirror file://… --src-release spec22-gems-local-…` consumes the
  local mirror.
- **The adapter-less tebako-runtime gem** in a local gem repo (default
  `/tmp/tebako-gem-repo`, override `GEM_REPO_DIR`). Build it from the
  gem-kill branch of tamatebako/tebako-runtime (`feat/empty-require-maps`
  — the v0.9.0 adapter-less tree; the require-hook mechanism stays, the
  maps ship empty per spec 22 §7):

  ```sh
  cd ../tebako-runtime-wt-kill-gem          # the feat/empty-require-maps worktree
  # temporarily: VERSION = "0.9.0.1" in lib/tebako-runtime/version.rb
  gem build tebako-runtime.gemspec          # then restore version.rb
  cp tebako-runtime-0.9.0.1.gem /tmp/tebako-gem-repo/gems/
  gem generate_index --directory /tmp/tebako-gem-repo
  ```

  **Why 0.9.0.1 and not a `.local` suffix:** rubygems treats any
  letter-bearing version suffix as a *prerelease*, and `gem install`
  never auto-selects a prerelease over a released version — with
  `0.9.0.local` in the repo, the factory silently installs the released
  0.8.2 (which still carries the sassc/sinatra adapters) and the
  acceptance would prove nothing. The numeric fourth segment sorts above
  both 0.8.2 and the eventual 0.9.0 release without being a prerelease.
  The harness additionally **asserts the env image carries exactly the
  pinned gem version** (`tfs find … tebako-runtime-*.gemspec`), so a
  silent resolution change fails loud instead of passing vacuously.

  The harness points the factory's `GEMRC` at that repo, so its
  `gem install tebako-runtime` resolves the adapter-less build — without
  publishing anything and without touching `~/.gemrc`. run.sh dies early
  if `gems/tebako-runtime-0.9.0.1.gem` is absent.
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
