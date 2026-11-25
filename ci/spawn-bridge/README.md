# ci/spawn-bridge — the injection-stripped spawn bridge acceptance gate (macOS)

The behavioral proof for the spawn patch's **injection-stripped bridge**
(packed-metanorma#305, spec 22 §3.2; the bridge half of tebako#1127's
probe): a darwin array-form spawn whose materialized target is
hardened-runtime signed WITHOUT
`com.apple.security.cs.allow-dyld-environment-variables` drops
`DYLD_INSERT_LIBRARIES` at exec (darwin 23) — the preload shim never
enters the child and every in-image argv operand is dead in it
(`dartaotruntime`'s snapshot: "not an AOT snapshot" — the EOFError
chain). The patch probes the materialized target per spawn
(`tebako_fs_exec_dyld_insertion_honored`, a WEAK extern) and, for the
stripped shape, fires the windows argv bridge's own primitive (each
embedded operand rewritten to its materialized host twin), omits the
injection pair, and names the scrub on the `TEBAKO_DEBUG_TFS` channel —
the child runs as an unsigned pre-shim binary against bridged
arguments, never silently shimless.

It is deliberately **not** wired into CI: it needs macOS + codesign +
a from-scratch miniruby build, which the patch-level gates (lint,
compile-smoke) intentionally do not build. Run it by hand; it is
idempotent and deterministic from pinned inputs.

## Why not a factory-runtime harness

The runtime under test must carry the patch — a factory build is the
chain's own gate. What THIS harness proves is the patch's behavior
end-to-end at its own boundary: the patched `process.c` runs for real
(a configured tree + `make miniruby`, the compile-smoke discipline),
linked against a tfs link-unit **test double**
(`fixtures/stub_c_api.c`) — a one-mount VFS plus the tebako#1127
verdict ABI's minimal Mach-O double. The double's answers are pinned
against `codesign -d` ground truth in the run itself; the ABI's real
byte-parse is the tfs crate's unit-tested surface (tebako#1127), never
re-implemented here.

## What it proves (one PROBE line per leg)

| leg | fixture | link unit | assertion |
|---|---|---|---|
| `stripped+probe` | hardened, no entitlement | probe | the `[spawn] … drops DYLD_INSERT_LIBRARIES …` warning fires under `TEBAKO_DEBUG_TFS`; `argv[0]` and the embedded operand arrive as their materialized host twins; `DYLD_INSERT_LIBRARIES` and `TEBAKO_TFS_MOUNTS` absent in the child; the shim never enters (pid-paired against the target's own line) |
| `stripped+probe-nodebug` | same | probe | the warning rides the debug channel only; the bridge fires identically without it |
| `honoring+probe` | hardened **with** the entitlement | probe | byte-identical injection path: no warning, operand unbridged, insertion + mounts armed, the shim verifiably enters the child |
| `unsigned+probe` | adhoc | probe | honored, same surface |
| `stripped+legacy` | hardened, no entitlement | **no probe symbol** (the weak extern reads NULL) | the pre-probe behavior byte-identical: no warning, operand unbridged, mounts armed — and the host dyld strips the armed variable in the child (the silent shimlessness the bridge retires, pinned as legacy parity) |

The honoring fixture is the temurin shape: hardened WITH
`allow-dyld-environment-variables` AND `disable-library-validation`.
The first grant is the probe's plane (the variable survives); the
second lets the adhoc dummy shim past library validation — an
allow-dyld-only fixture keeps the variable but dyld silently skips a
team-less dylib (verified on this host), a validation-plane edge the
probe deliberately does not model.

Before the legs, the run re-proves the host's own ground truth: the
dyld strip for the hardened-unentitled fixture and the honor for the
entitled one, with `codesign -dv` flags printed beside the verdict
double's answer.

## Run

```sh
ci/spawn-bridge/run.sh            # RUBY_VERSION=4.0.9 by default
```

Overridable: `RUBY_VERSION` (any series tip), `SCRATCH` (default
`/tmp/spawn-bridge-scratch-<version>`), `TFS_CACHE_DIR`. Verdict:
`SPAWN-BRIDGE-ACCEPTANCE-OK <ruby> (<arch>)` on success; a named
`FAIL spawn-bridge (…)` line otherwise. Everything transient lives
under `$SCRATCH`; delete it to re-run from scratch (the tree build
re-runs every invocation by design — the patch under test must never
go stale).

Verified: macOS 14.1.1 (darwin 23) arm64, ruby 4.0.9 —
`SPAWN-BRIDGE-ACCEPTANCE-OK 4.0.9 (arm64)`.
