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
  the toolchain build vs the final build (`cygwin/GNUmakefile.in`). No suffix
  means the patch is platform-independent (or applies to all non-msys
  platforms, as stated in its header).

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

## Regeneration

Patches were produced by a script that loads the real gem patch classes
(read-only), applies each map to the pristine files of every supported
version, groups versions by identical diff body, and emits line-wide or
per-release files accordingly. Each patch header cites the gem source
constant/method and restates the gem's rationale comment.
