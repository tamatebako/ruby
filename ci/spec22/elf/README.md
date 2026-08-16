# ci/spec22/elf — the ELF (linux/amd64) acceptance leg, containerized

The linux/amd64 twin of `../run.sh` (macOS): same four jailed assertions
(`fiddle`, `cext-self-dlopen`, `named-error`, `jail-deny`) plus two ELF-only
gates:

- **GNU_UNIQUE gate** — the staged `libtfs.a` carries zero `STB_GNU_UNIQUE`
  definitions (gcc's libstdc++ emits inline-template statics as GNU_UNIQUE
  inside the vendored rnp closure; they break the static-archive model and
  mis-link under qemu-user). See *Reseal* below when the gate fires.
- **nm -D export gate** — the runtime exe dynamically exports `dlopen` and
  `dlerror`. ruby compiles `dln.c` with `-fvisibility=hidden`; the patch's
  definitions carry `__attribute__((visibility("default")))` so they can
  preempt process-wide (`-Wl,-export-dynamic` cannot export a hidden
  symbol — the pre-fix builds failed here with exit 66).

Everything runs inside one container (`linux/amd64` under Rosetta/qemu-user
on Apple Silicon); the host only runs `run-elf-leg.sh`.

## Layout (populate once)

```
/tmp/spec22-linux-scratch/            # $SCRATCH, bind-mounted
  ruby/                               # THIS repo checkout — the harness rides it
  factory/                            # tamatebako/tebako-runtime-ruby
                                      #   @feat/boot-smoke-loader-interpose
  ws/tebako-rs/                       # tamatebako/tebako @feat/tfs-mount-of
  ws/dwarfs-rs/                       # tamatebako/dwarfs-rs (+ dwarfs-t submodule)
  ws/limnifs/limnifs/                 # limnifs/limnifs (tebako-rs contract-tests
                                      #   sibling path dep; cargo metadata fails
                                      #   without it)
/tmp/spec22-link-unit-linux/          # $LINK_UNIT, bind-mounted (empty dir)
```

Paths are overridable (`SCRATCH`, `LINK_UNIT`, `NAME`, `IMAGE` in the env);
the defaults match this document. The ruby checkout MUST live at
`$SCRATCH/ruby` — the driver refuses to run from anywhere else (the scripts
have to be visible inside the container through the bind mount).

## Run

```sh
ci/spec22/elf/run-elf-leg.sh
```

Steps: container up → `setup-toolchain.sh` (once; cmake 3.31, clang-19,
gcc-11, rustup, vcpkg, the libjemalloc neuter below) → `roll-source.sh`
(rolls `tfs-ruby-4.0.6-src.tar.gz` from this checkout into
`$SCRATCH/mirror`, guarding the interpose block landed) →
`build-link-unit.sh` (cargo + `tools/stage_link_unit`, nm
evidence, preload-deps gate, GNU_UNIQUE gate) → `build-runtime.sh`
(factory `tools/build_runtime` with `--src-mirror`, then the
nm -D export gate) → `probe.sh` (builds the probe natives from
`../fixtures/`, packs the payload with the staged `tfs` CLI, runs the exe
jailed: `TEBAKO_JAIL="deny;$SCRATCH:$SCRATCH:rw"`).

Success prints `SPEC22-ACCEPTANCE-OK 4.0.6` and `RUN-ELF-LEG-OK`.

## Container-local deviations (documented, not portable)

1. **libjemalloc neuter** (`setup-toolchain.sh`, idempotent): the ruby
   build's `-ljemalloc` probe resolves the distro's static
   `/lib/x86_64-linux-gnu/libjemalloc.a` via the `-l:` fallback and links
   it into miniruby — under qemu-user that combination hangs the build.
   The setup replaces the distro archive with an empty one
   (`libjemalloc.a.real` rides alongside as the backup). Container fs
   only; never run this on a host.

2. **Reseal** (manual, gated): when the GNU_UNIQUE gate fires, the flagged
   members (rnp/sexp objects carrying `std::__detail::__to_chars_10_impl::
   __digits` / `std::_Sp_make_shared_tag::_S_ti()::__tag` as `u` in `nm`)
   must be rebuilt with clang-19 (which emits them hidden, not GNU_UNIQUE)
   and resealed:

   ```sh
   # inside the container: rebuild the flagged TUs with clang-19, then
   nm /tmp/spec22-link-unit-linux/libtfs.a | grep -B1 ' u '   # the members
   cp /tmp/spec22-link-unit-linux/libtfs.a{,.pre-reseal-backup}
   python3 reseal.py /tmp/spec22-link-unit-linux/libtfs.a{,.resealed} <fresh .o ...>
   mv /tmp/spec22-link-unit-linux/libtfs.a{.resealed,}
   ```

   `reseal.py` = `swap-members.py` (prefix-rename exactly as tebako-arscope
   would emit) + `ar-rebuild.py` (positional extract/rebuild — GNU ar 2.34
   mangles this writer's archive on in-place rewrite; llvm-ar rebuilds
   cleanly). The durable fix is upstream (arscope must neutralize
   GNU_UNIQUE, or the rnp closure builds with clang); the gate keeps the
   manual step honest meanwhile.

3. **qemu-user clock**: the container's clock can lag the host by hours;
   artifact mtimes (cache keys, `make` decisions) follow the CONTAINER
   clock. Nothing in the harness compares mtimes across the boundary —
   keep it that way.
