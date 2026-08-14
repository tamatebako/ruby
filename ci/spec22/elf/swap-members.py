#!/usr/bin/env python3
"""swap-members.py — replace gcc-built members inside the staged libtfs.a
with clang-built ones, prefix-renamed exactly as tebako-arscope would have
emitted them (every defined non-tebako_* symbol gets the __tebako_internal_
prefix; undefined refs ride the prefix iff their name is defined anywhere
in the staged archive).

Usage: swap-members.py <staged.a> <fresh-member.o> [<fresh-member.o> ...]
Writes <staged.a>.swapped and verifies: no unprefixed non-tebako global
definitions and no GNU_UNIQUE definitions remain."""

import os
import subprocess
import sys
import tempfile

PREFIX = "__tebako_internal_"


def run(*args):
    return subprocess.run(args, capture_output=True, text=True)


def archive_defined(archive):
    names = set()
    for line in run("nm", "--defined-only", archive).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            names.add(parts[-1])
    return names


def member_syms(obj):
    defs, refs = set(), set()
    for line in run("nm", obj).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-2] in ("U",):
            refs.add(parts[-1])
        elif len(parts) >= 3:
            defs.add(parts[-1])
    return defs, refs


def main():
    archive, fresh = sys.argv[1], sys.argv[2:]
    originals = set()
    for name in archive_defined(archive):
        originals.add(name[len(PREFIX):] if name.startswith(PREFIX) else name)

    out_path = archive + ".swapped"
    run("cp", archive, out_path)
    before = run("ar", "t", out_path).stdout.splitlines()

    with tempfile.TemporaryDirectory() as tmp:
        for member in fresh:
            defs, refs = member_syms(member)
            pairs = []
            for name in defs | refs:
                if name.startswith(("tebako_", PREFIX)):
                    continue
                if name in defs or name in originals:
                    pairs.append((name, PREFIX + name))
            map_path = os.path.join(tmp, "map")
            with open(map_path, "w") as f:
                f.writelines(f"{old} {new}\n" for old, new in pairs)

            base = os.path.basename(member)
            stem = base[:-2] if base.endswith(".o") else base
            hits = [m for m in before if m == base or (m.startswith(stem) and len(m) <= len(base))]
            if not hits:
                sys.exit(f"FAIL: no archive member matches {base}")
            target = hits[0]
            staged_member = os.path.join(tmp, target)
            run("objcopy", "--redefine-syms", map_path, member, staged_member)
            rc = run("ar", "r", out_path, staged_member)
            if rc.returncode != 0:
                sys.exit(f"FAIL: ar r {target}: {rc.stderr}")
            after = run("ar", "t", out_path).stdout.splitlines()
            if len(after) != len(before):
                sys.exit(f"FAIL: ar appended {target} (member-name mismatch)")
            print(f"swapped {target} ({len(pairs)} symbols renamed)")

    run("ranlib", out_path)
    uniq, bare = [], []
    for line in run("nm", "--defined-only", out_path).stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        binding, name = parts[-2], parts[-1]
        if binding == "u":
            uniq.append(name)
        if binding in "TWDGB" and not name.startswith(("tebako_", PREFIX)):
            bare.append(name)
    print(f"verify: GNU_UNIQUE defs left: {len(uniq)}; unprefixed non-tebako global defs left: {len(bare)}")
    for n in (uniq + bare)[:10]:
        print(f"  LEFT {n}")


if __name__ == "__main__":
    main()
