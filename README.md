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

- `patches/build-config/` — build/link rules and toolchain compatibility:
  link rules (`template/Makefile.in`, `common.mk`, `cygwin/GNUmakefile.in`,
  darwin `configure`), `config.status` MAINLIBS injection, `win32/winmain.c`,
  `include/ruby/onigmo.h`, `ext/openssl/extconf.rb`,
  `ext/io/console/win32_vk.inc`, `tool/rbinstall.rb` (dropped, see below),
  `ext/Setup`, `ext/bigdecimal/bigdecimal.h`, `enc/jis/props.h`,
  `thread_pthread.c` (musl), rubygems (`path_support.rb`, `openssl.rb`),
  `win32/win32.c` clock renames.
- `patches/io-routing/` — memfs `tebako_*` io shims (legacy API, flagged for
  redesign): `main.c`, `io.c`, `dir.c`, `file.c`, `util.c`, `dln.c`,
  `prism_compile.c`, `ruby.c`, `win32/file.c`, `win32/win32.c` getcwd,
  `tool/mkconfig.rb` memfs prefix, `gem_prelude.rb` tebako-runtime loader.
  Every io-routing patch carries an `# X-Redesign: modern-api` header note.
- `versions.yml` — every supported ruby version with its official tarball
  URL, sha256 (mirroring the gem's `RUBY_VERSIONS`), and major.minor line.

## Naming

`tfs-ruby-<major>-<minor>-<seg>-<slug>.patch`

- `<seg> = x` — verified to apply to **every** supported release of the
  `<major>.<minor>` line listed in `versions.yml`.
- `<seg> = <patchlevel>` — the upstream text exists only at that exact patch
  release (e.g. `tfs-ruby-3-2-7-onigmo-h-onig-extern-msys.patch`: the gem
  gates `ONIG_EXTERN` to ruby 3.2.7 / 3.3.7 / 3.4+).
- Slug suffixes encode the scenario: `-msys`, `-darwin`, `-musl` platform
  variants; `-pass1` / `-pass2` where the same file is patched differently in
  the toolchain build vs the final build (`cygwin/GNUmakefile.in`). Platform
  markers are always the **terminal** slug element (e.g.
  `dln-c-dlmap-msys`). No platform suffix means the patch is
  platform-independent, or — when it shares its target file with a
  platform-suffixed patch — the complementary variant for the other
  platforms (e.g. `dir-c-memfs` vs `dir-c-memfs-msys`).

**Supersede rule:** a patchlevel-specific file
(`tfs-ruby-M-m-p-<slug>.patch`) supersedes the line-wide file
(`tfs-ruby-M-m-x-<slug>.patch`) for exactly that release. Consumers must
apply the most specific name matching the target version. Within a line, a
slug is emitted either line-wide or as per-release files — never both.

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
(`Tfs::Versions`, `Tfs::PatchSelection`, `Tfs::SourcePrep`; namespace parent
`tools/lib/tfs.rb` wires children with `autoload`):

- `tools/versions` — prints the versions.yml version list as a GitHub
  Actions matrix document (used to generate CI lanes from the manifest).
- `tools/lint <version>` — fetches the official tarball (sha256-verified,
  cached in `.cache/tarballs`, override with `TFS_CACHE_DIR`), extracts it,
  and runs `git apply --check` for every patch selected by the filename
  rule (the full union; each patch checked independently). Fails named:
  `FAIL <version> <patch>`.
- `tools/apply <version> [outdir] [--platform NAME] [--pass 1|2]` — emits
  `<outdir>/tfs-ruby-<version>-src`, the pristine tree with the version's
  patch set applied for **one coherent build scenario**. The union set is
  not co-applicable to a single tree (platform-variant pairs such as
  `dir-c-memfs` / `dir-c-memfs-msys` target the same lines, and
  `cygwin/GNUmakefile.in` has alternative pass1/pass2 patches), so apply
  narrows the set: `--platform` (`linux-gnu`/`linux-musl`/`darwin`/`msys`,
  default: host) drops other platforms' patches and, on msys, the neutral
  variants of msys-patched files; `--pass` (default 2, final build) selects
  the GNUmakefile variant. A patch whose target is absent from the pristine
  tree (`config.status`, generated by ./configure) is deferred with a note;
  any other failure raises, naming version and patch.

CI: `.github/workflows/lint-patches.yml` lints every version on a matrix
generated from versions.yml; `.github/workflows/release-src.yml` (tags
`v*` + manual dispatch) builds `tfs-ruby-<version>-src.tar.gz` per version,
verifies the artifact against the apply output, and publishes the tarballs
plus a `SHA256SUMS` to the release.

Specs (`bundle exec rspec`): manifest parsing, selection/supersede/scenario
logic, and apply correctness against tiny local fixtures (no network).

## Regeneration


Patches were produced by a script that loads the real gem patch classes
(read-only), applies each map to the pristine files of every supported
version, groups versions by identical diff body, and emits line-wide or
per-release files accordingly. Each patch header cites the gem source
constant/method and restates the gem's rationale comment.
