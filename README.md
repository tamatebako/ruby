# tamatebako/ruby — canonical tebako patches for upstream ruby

This repository carries the tebako gem's ruby build patches as canonical,
machine-verified unified-diff `.patch` files. They were generated
mechanically from the gem's string-substitution patch maps
(`lib/tebako/packager/*.rb`, tebako-chainwt @ main): each substitution was
applied with Ruby's `String#sub!` (literal, first occurrence) to the pristine
upstream file extracted from the official ruby tarballs (see
`versions.yml`), and the result was diffed with `git diff --no-index`. No
diff was hand-written.

## Layout

Per-line folders with YAML manifests:

- `patches/<major.minor>/` — one folder per supported ruby line
  (`3.1`, `3.2`, `3.3`, `3.4`, `4.0`). A line's folder holds **only** that
  line's own (diverged) patch files plus its manifest(s): the base
  `patch-<line>.yaml` and, where a feature applies to one exact patch
  release only, an overlay `patch-<line>.<patch>.yaml` (currently
  `patch-3.2.7.yaml` and `patch-3.3.7.yaml` for the `ruby3x7`-gated
  onigmo/winmain fixes).
- **Home-line rule:** a patch body shared by several lines lives once, in
  the oldest line it applies to (its *home line*); other lines' manifests
  reference it by relative path (`../<home-line>/<file>.patch`) — never
  duplicated. Looking at one line's folder you see only its own files and
  the manifest listing which older-line patches it pulls in (limited
  information exposure).
- `schema/` — JSON Schemas: `versions.schema.yml` for `versions.yml`,
  `patches.schema.yml` for every `patch-*.yaml` manifest. CI validates
  all manifests against them before use (`tools/validate_manifests`).
- `versions.yml` — every supported ruby version with its official tarball
  URL, sha256 (mirroring the gem's `RUBY_VERSIONS`), major.minor line, and
  the platform `scenarios` it ships src releases for (subset of
  `linux-gnu`/`linux-musl`/`msys`, absent means linux-gnu only; verified
  apply-clean per version).

Patches are grouped by feature family rather than by build phase; the
`# X-Redesign: modern-api` header note still marks the io-routing family
(memfs `tebako_*` shims, legacy API flagged for redesign): `main.c`,
`io.c`, `dir.c`, `file.c`, `util.c`, `dln.c`, `prism_compile.c`, `ruby.c`,
`win32/file.c`, `win32/win32.c` getcwd, `tool/mkconfig.rb`,
`gem_prelude.rb`. Everything else (link rules, toolchain compatibility,
rubygems) is build-config.

## Naming

Real patch files: `<feature>[_<patch_version>].patch` — snake_case
throughout (features and file names). The `_<patch_version>` suffix marks
content tied to specific patch version(s) of its home line (e.g.
`gnumakefile_in_pass1_msys_4.patch` covers 3.2.4-3.2.6,
`gnumakefile_in_pass1_msys_7.patch` covers 3.2.7); whole-line bodies carry
no suffix.

Feature suffixes encode the build scenario: terminal `_msys` / `_darwin` /
`_musl` platform markers, and `_pass1` / `_pass2` where
`cygwin/GNUmakefile.in` differs between the toolchain and the final build.
A feature without a platform marker is platform-independent, or — when it
shares its target file with a platform-marked feature — the complementary
variant for the other platforms (e.g. `dir_c_memfs` vs `dir_c_memfs_msys`).

## Manifests and resolution

Manifest schema (`schema/patches.schema.yml`): `version: "<line>"` plus a
`patches:` **array** of entries (ordered; entries apply in listed order).
Each entry: `feature: <snake_case>`, `file: <path>` (local or
`../<line>/...`), and optionally `version: "<patch>"`.

Resolution for ruby **X.Y.Z** (`Tfs::PatchSelection`):

1. Read `patches/X.Y/patch-X.Y.yaml`, then overlay
   `patches/X.Y/patch-X.Y.Z.yaml` if present — the overlay wins per
   feature (replaced features keep their base position; overlay-only
   features append).
2. Take whole-line entries plus entries with `version: "<Z>"`; a
   versioned entry supersedes its feature's whole-line entry for that Z
   only.
3. A feature whose entries are all versioned and do not cover Z is an
   explicit error (`SelectionError`), never silent. Exact-release-only
   features therefore live in overlays, not in the base manifest.

## Verification

Every patch passes `git apply --check` against the pristine extracted tree of
**every** tarball whose major.minor line its filename claims (617 patch×version
checks, including the config.status checks below; additionally, every patch's
applied result was verified byte-identical to the gem's own `String#sub!`
transformation). A patch that did not apply to a whole line was narrowed to
the exact `-<patchlevel>-` releases it applies to; a substitution whose
pattern is absent upstream produces no patch at all (see "Drops and no-ops").

Exception: `config.status` is a *generated* file and is not shipped in the
tarballs. The `config-status-mainlibs-darwin` patches were generated against
and verified with `git apply --check` on `config.status` files produced by a
default `./configure` of each claimed version on macOS (arm64). Context lines
may differ on hosts with different configure flags or platforms.

## Placeholders

The gem computes the tebako static library list (`MAINLIBS`) dynamically per
packaging host. Canonical patches carry the literal placeholder
`@TEBAKO_MLIBS@`, which the consumer substitutes at packaging time (gem:
`PatchLibraries.mlibs`).

## Drops and no-ops

- `tool/rbinstall.rb` (`next if files.empty?`): pattern absent in every
  supported version (the gem's own comment already suspected this) — no patch
  emitted.
- `config.status` MAINLIBS, linux and msys variants: not emitted — a real
  linux/msys `config.status` cannot be produced on the generation host, and
  hand-writing the diff is disallowed. Source literals:
  `patch_buildsystem.rb#get_config_status_patch`.
- `RubygemsUpdatePatch` (rubygems repatch after `gem update --system`):
  targets the *installed* rubygems tree (version depends on the update, not
  on the ruby tarball) — covered by the same substitutions as the pass1
  rubygems patches against the ruby source tree.
- Faithful partial no-ops kept as-is (the gem's `sub!` silently no-ops too;
  patches contain only the hunks that match): `DIR_C_BASE_PATCH`'s
  `plain = 1` substitution matches only ruby 3.1; the `win32/win32.c` tebako
  include anchor (`_MSC_VER <= 1200`) is gone in ruby 4.0;
  `ext/io/console/win32_vk.inc` was fixed upstream in ruby 3.4+.
- Dead gem code not converted: `FILE_C_MSYS_PATCH`, `LINUX_PATCHES`
  (`ext/extmk.rb`) — defined but never referenced.

## Tooling (`tools/`)

Thin executables over the model classes in `tools/lib/tfs/`
(`Tfs::Versions`, `Tfs::PatchManifest`, `Tfs::PatchSelection`,
`Tfs::SchemaLint`, `Tfs::SourcePrep`; namespace parent `tools/lib/tfs.rb`
wires children with `autoload`):

- `tools/versions [--scenarios]` — prints versions.yml as a GitHub Actions
  matrix document. Default: the version list (one CI lane per version).
  `--scenarios`: the flat (version × scenario build) release matrix — one
  row per coherent build (`linux-gnu` unsuffixed for back-compat, musl at
  pass 2 since only the msys GNUmakefile features are pass-sensitive, msys
  expanded to its pass1/pass2 pair).
- `tools/validate_manifests` — validates versions.yml and every
  `patch-*.yaml` against `schema/`; run in CI before the manifests are used.
- `tools/lint <version>` — fetches the official tarball (sha256-verified,
  cached in `.cache/tarballs`, override with `TFS_CACHE_DIR`), extracts it,
  and runs `git apply --check` for every patch resolved from the line's
  manifest set (each patch checked independently). Fails named:
  `FAIL <version> <patch>`.
- `tools/apply <version> [outdir] [--platform NAME] [--pass 1|2]` — emits
  `<outdir>/tfs-ruby-<version>-src`, the pristine tree with the version's
  patch set applied for **one coherent build scenario**. The full manifest
  set is not co-applicable to a single tree (platform-variant pairs such as
  `dir_c_memfs` / `dir_c_memfs_msys` target the same lines, and
  `cygwin/GNUmakefile.in` has alternative pass1/pass2 patches), so apply
  narrows the set: `--platform` (`linux-gnu`/`linux-musl`/`darwin`/`msys`,
  default: host) drops other platforms' patches and, on msys, the neutral
  variants of msys-patched files; `--pass` (default 2, final build) selects
  the GNUmakefile variant. A patch whose target is absent from the pristine
  tree (`config.status`, generated by ./configure) is deferred with a note;
  any other failure raises, naming version and patch.
- `tools/monitor --detect | --onboard <version>` — the release monitor.
  `Tfs::RubyReleases` parses the official ruby-lang.org releases table
  (version + official tarball URL per row) and diffs against versions.yml
  (newer patch releases of tracked lines; the latest release of an
  untracked line inside the support window; previews excluded).
  `Tfs::Onboarder` then onboards one release end-to-end: pins it into
  versions.yml (official URL + sha256 of the fetched tarball), seeds a
  manifest for a new line from the nearest existing line, extends
  complete-partition families to the new patch level, carries the line's
  overlay forward, and lints the whole set with `git apply --check`
  against the sha256-verified tarball. On any failure every touched file
  is restored — nothing is released silently.

CI: `.github/workflows/lint-patches.yml` lints every version on a matrix
generated from versions.yml; `.github/workflows/release-src.yml` (tags
`v*` + manual dispatch) builds the per-scenario
`tfs-ruby-<version>-src[-<scenario>].tar.gz` assets on the versions.yml
scenario matrix (`linux-gnu` stays the unsuffixed back-compat asset; msys
ships `-msys-pass1`/`-msys-pass2`), verifies each artifact against the
apply output, and publishes the tarballs plus a `SHA256SUMS` to the
release; `.github/workflows/release-monitor.yml`
(daily 06:17 UTC + manual dispatch) detects new official ruby releases and
onboards each on its own lane: a clean onboard opens an
"Onboard ruby X.Y.Z" pull request (peter-evans/create-pull-request), a
failing one files an issue naming the version and the failing patches.
Optionally (repo variable `RELEASE_MONITOR_DISPATCH=true` +
`TEBAKO_DISPATCH_TOKEN` secret) a clean onboard fires a
`repository_dispatch` (event `tebako release`) to
tamatebako/tebako-runtime-ruby.

Specs (`bundle exec rspec`): manifest parsing, selection/supersede/scenario
logic, and apply correctness against tiny local fixtures (no network).

## Regeneration


Patches were produced by a script that loads the real gem patch classes
(read-only), applies each map to the pristine files of every supported
version, groups versions by identical diff body, and emits line-wide or
per-release files accordingly. Each patch header cites the gem source
constant/method and restates the gem's rationale comment.
