# ci/spawn-edge — the spawn-edge acceptance gate (spec-32 executable edge)

The **regression tripwire** for the driver spawn-plan bug class:
tamatebako/ruby#121 (`tfs_spawn_plan_apply` dropping the plan's argv[0],
so the child's flag parse shifted and its mounts fell out) and
tamatebako/tebako#691 (`system("xml2rfc", …)` from a dispatched payload
failing with "spawn plan failed without a message") both shipped green
through every lighter gate and surfaced **days later in a full metanorma
compile** — no factory gate exercised "a payload array-spawns a child
through a spec-32 `kind: executable` edge". This harness is that gate.
It is deliberately tiny: two fixture payloads, two spawn forms, seconds
per leg — not a suite.

## What it proves

The consumer payload's manifest declares

```yaml
requires:
  - kind: executable
    name: spawn-edge-echo
    payload: spawn-edge-provider
    constraint: ">= 1.0"
    expose: [spawn-edge-echo]
    critical: true
```

and its entry script (`fixtures/spawn-edge-probe.rb`) array-spawns the
exposed name twice — `system("spawn-edge-echo", "alpha", "beta gamma",
"--flag=x", out: …)` and the `IO.popen` pipe form. The runtime's spawn
hook plans the PROVIDER payload's own dispatch as the child (the provider
image mounted at `/` in the child, the exposed entrypoint run there, the
child's runtime resolved cache-only from the scratch store); the provider
command (`fixtures/spawn-edge-echo.rb`) echoes its argv, and the probe
asserts the child received the exact vector — the space-carrying token
proves no shell re-split, the flag-shaped token proves no option
re-parse, and a shifted/garbled plan (the argv[0] class) mismatches
loudly. A plan failure raises in the parent and is named in the PROBE
line, never an unhandled backtrace.

One `PROBE spawn-edge <leg> ok|fail <detail>` line per leg
(`system-array`, `popen-array`); the harness pins both plus the child's
echoed argv line. Verdict: `SPAWN-EDGE-ACCEPTANCE-OK <ruby> (<triplet>)`
(`SPAWN-EDGE-MSYS-ACCEPTANCE-OK` on windows); a named `FAIL spawn-edge
(…)` otherwise.

## Inputs

Both scripts **build nothing** — the runtime under test is the factory
build leg's own artifact set, the press/readback tool is the leg's
pin-verified tfs CLI:

| env | meaning |
|---|---|
| `RUNTIME_PKG_DIR` | the leg's runtime-packages dir (one `tebako-runtime-<tv>-<lv>-<triplet>[.exe]` + its `.tfs`; on windows also the package-named ruby `.dll`) |
| `RUBY_VERSION` | the leg's ruby version (e.g. `4.0.7`) |
| `TEBAKO_VERSION` | the leg's tebako version (e.g. `0.16.33`) |
| `TFS_CLI` | the leg's pin-verified tfs CLI |
| `SCRATCH` | optional; default `/tmp/spawn-edge[-msys]-scratch-<ruby>-<triplet>` |

The scripts stage a scratch tebako store (spec 05 §3's grammar): the
leg's runtime pair under `runtimes/ruby-<lv>-<tv>-<triplet>/` (on windows
renamed to the scan's synthesized `.exe` spelling, with the PE-named DLL
copy beside it) and the provider under `payloads/spawn-edge-provider/`,
its manifest mirror **copied from the pressed image** (`tfs cat` — the
store's embedded-wins rule, and the readback doubles as the press
assertion). The parent boot is a hand-rolled dispatch, so the spawn
resolves the spec 32 §5 **unlocked** edge cache-only — no
`TEBAKO_SPAWN_LOCK` is composed.

## Run

```sh
RUNTIME_PKG_DIR=/path/to/runtime-packages RUBY_VERSION=4.0.7 \
  TEBAKO_VERSION=0.16.33 TFS_CLI=/path/to/tfs \
  ci/spawn-edge/run.sh          # POSIX (linux-gnu, macos; musl inside alpine)

# windows (msys shell):
RUNTIME_PKG_DIR=… RUBY_VERSION=4.0.7 TEBAKO_VERSION=0.16.33 \
  TFS_CLI=/path/to/tfs.exe ci/spawn-edge/run-msys.sh
```

Consumed by the runtime factory's build legs
(tebako-runtime-ruby's `_build-platform.yml`), which run the gate per
ruby line × platform after the boot smoke and before the leg-complete
marker — a red gate ships nothing. Runnable by hand against any built or
published runtime package with the same inputs; delete the scratch dir to
re-run from scratch (every stage rebuilds on every run regardless — all
of it is sub-second).
