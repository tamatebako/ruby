#!/usr/bin/env python3
"""reseal.py — replace gcc-built members inside the tebako-arscope-staged
libtfs.a with clang-built ones, prefix-renamed exactly as arscope would
have emitted them, and rebuild the archive positionally (GNU ar 2.34
mangles this writer's archive on rewrite; llvm-ar rebuilds cleanly).

Rename rule (arscope's): every defined non-tebako_* symbol gets the
__tebako_internal_ prefix; undefined refs ride the prefix iff their name
is defined anywhere in the staged archive.

Usage: reseal.py <staged.a> <out.a> <fresh1.o> [<fresh2.o> ...]
"""

import os
import shutil
import subprocess
import sys
import tempfile

PREFIX = "__tebako_internal_"


def run(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check)


def parse_archive(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    members = []
    strtab = b""
    off = 8
    while off < len(data):
        raw_name = data[off:off + 16].decode("ascii", "replace")
        size = int(data[off + 48:off + 58].decode("ascii").strip())
        body = data[off + 60:off + 60 + size]
        off += 60 + size + (size & 1)
        field = raw_name.strip()
        if field == "/":
            continue
        if field == "//":
            strtab = body
            continue
        if field.startswith("#1/"):
            # BSD extended name: the first <len> bytes of the body are the
            # name (NUL-padded to alignment by this writer); the real
            # content follows.
            namelen = int(field[3:])
            name = body[:namelen].decode("ascii", "replace").rstrip("\x00")
            body = body[namelen:]
        elif field.startswith("/") and field[1:].isdigit():
            start = int(field[1:])
            name = strtab[start:strtab.index(b"\n", start)].decode("ascii", "replace").rstrip("/")
        else:
            name = field.rstrip("/").strip()
        members.append([name, body])
    return members


def nm_names(path, defined_only):
    args = ["nm", "--defined-only", path] if defined_only else ["nm", path]
    names = set()
    for line in run(*args).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            names.add(parts[-1])
    return names


def main():
    staged, out_path, fresh = sys.argv[1], sys.argv[2], sys.argv[3:]
    members = parse_archive(staged)
    defined = nm_names(staged, defined_only=True)
    originals = {n[len(PREFIX):] if n.startswith(PREFIX) else n for n in defined}

    tmp = tempfile.mkdtemp(prefix="reseal-")
    swapped = {}
    for member in fresh:
        defs, refs = set(), set()
        for line in run("nm", member).stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[-2] == "U":
                refs.add(parts[-1])
            elif len(parts) >= 3:
                defs.add(parts[-1])
        pairs = [(n, PREFIX + n) for n in (defs | refs)
                 if not n.startswith(("tebako_", PREFIX)) and (n in defs or n in originals)]
        map_path = os.path.join(tmp, "map")
        with open(map_path, "w") as f:
            f.writelines(f"{old} {new}\n" for old, new in pairs)
        base = os.path.basename(member)
        stem = base[:-2] if base.endswith(".o") else base
        hits = [i for i, (name, _) in enumerate(members)
                if name == base or (name.startswith(stem) and len(name) <= len(base))]
        if not hits:
            sys.exit(f"FAIL: no member matches {base}")
        renamed = os.path.join(tmp, f"renamed-{base}")
        run("objcopy", "--redefine-syms", map_path, member, renamed)
        with open(renamed, "rb") as f:
            body = f.read()
        for i in hits:
            members[i][1] = body
            swapped[members[i][0]] = len(pairs)

    files = []
    for i, (name, body) in enumerate(members):
        member_dir = os.path.join(tmp, f"{i:05d}")
        os.makedirs(member_dir)
        path = os.path.join(member_dir, name)
        with open(path, "wb") as f:
            f.write(body)
        files.append(path)

    if os.path.exists(out_path):
        os.remove(out_path)
    run("llvm-ar-18", "rcs", out_path, *files)
    print(f"members: {len(members)}; swapped: {swapped}")

    out_members = run("llvm-ar-18", "t", out_path).stdout.splitlines()
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
    print(f"out members: {len(out_members)}; GNU_UNIQUE defs left: {len(uniq)}; "
          f"unprefixed non-tebako global defs left: {len(bare)}")
    for n in (uniq + bare)[:10]:
        print(f"  LEFT {n}")
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
