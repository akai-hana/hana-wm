#!/usr/bin/env python3
# Dead-code scanner: reports file-scope declarations nothing in the tree references.
# Usage: dev/scripts/dead-code.py
# Checks unused @import bindings, unused functions, and unused file-scope consts
# across src/ + build.zig. A name counts as used when it appears outside its
# declaration in its own file, or as a qualified `x.NAME` anywhere else (bare
# tokens in other files are those files' own same-named decls, not references).
# Exits 1 when findings exist, 0 when clean.

import re
import sys
from bisect import bisect_right
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SKIP_DIRS = {".git", ".zig-cache", "zig-out", "contrib", "dev", "library", "config"}
ENTRY_FNS = {"main", "build"}

FN_RE = re.compile(
    r"^(?P<lead>[ \t]*)(?:pub\s+|export\s+|inline\s+|extern\s+|naked\s+|addrspace\([^)]*\)\s+)*"
    r"fn\s+(?P<name>[A-Za-z_]\w*)"
)
CONST_RE = re.compile(r"^(?P<lead>[ \t]*)(?:pub\s+)?const\s+(?P<name>[A-Za-z_]\w*)\s*=")
TOKEN_RE = re.compile(r"[A-Za-z_]\w*")
FIELD_STR_RE = re.compile(r'@field\(\s*[^,()]+,\s*"([A-Za-z_]\w*)"')
STRUCTWORD_RE = re.compile(r"(?:struct|union|enum|opaque|packed)\s*$")


def process(src):
    """Blank comments+strings (code) and comments only (keep), newlines intact."""
    code = list(src)
    keep = list(src)
    i, n = 0, len(src)

    def blank(dst, a, b):
        for k in range(a, b):
            if dst[k] != "\n":
                dst[k] = " "

    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            if j == -1:
                j = n
            blank(code, i, j)
            blank(keep, i, j)
            i = j
        elif c == "\\" and i + 1 < n and src[i + 1] == "\\":
            j = src.find("\n", i)
            if j == -1:
                j = n
            blank(code, i, j)
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            blank(code, i, j)
            i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "'":
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            blank(code, i, j)
            i = j
        else:
            i += 1
    return "".join(code), "".join(keep)


def scan_decls(code, rel):
    """File-scope consts (depth==0) and fn decls (any depth, `fn` keyword)."""
    decls = []
    depth = 0
    off = 0
    lines = code.splitlines(keepends=True)
    for ln, line in enumerate(lines, 1):
        if depth == 0:
            m = CONST_RE.match(line)
            if m and not FN_RE.match(line):
                kind = "import" if "@import(" in line else "const"
                if kind == "const" and line.rstrip().endswith("="):
                    kind = "?"  # resolved by lookahead below
                decls.append((m.group("name"), off + m.start("name"), kind, ln, line))
        m = FN_RE.match(line)
        if m:
            decls.append((m.group("name"), off + m.start("name"), "fn", ln, line))
        for ch in line:
            if ch in "{([":
                depth += 1
            elif ch in "})]":
                depth -= 1
        off += len(line)
    # resolve multi-line `const x =` initializers (import if @import follows)
    for idx, d in enumerate(decls):
        if d[2] != "?":
            continue
        joined = "".join(lines[d[3] - 1 : d[3] + 4])
        first = re.search(r"@import\(|;|\{|=", joined[joined.find("=") + 1 :])
        kind = "const"
        if first and first.group(0) == "@import(":
            kind = "import"
        decls[idx] = (d[0], d[1], kind, d[3], d[4])
    return decls


def body_span(code, name_off):
    """Span [start, end) of a fn body; empty when the fn has no body (extern)."""
    n = len(code)
    i = name_off
    paren = 0
    seen_paren = False
    while i < n:
        c = code[i]
        if c == "(":
            paren += 1
            seen_paren = True
        elif c == ")":
            paren -= 1
        elif c == ";" and paren == 0 and seen_paren:
            return (0, 0)
        elif c == "{" and paren == 0:
            j = i - 1
            while j >= 0 and code[j] in " \t\n":
                j -= 1
            k = j
            while k >= 0 and (code[k].isalnum() or code[k] == "_"):
                k -= 1
            word = code[k + 1 : j + 1]
            if STRUCTWORD_RE.search(word + " " ) or STRUCTWORD_RE.search(word):
                # return-type struct literal: skip its balanced block, keep looking
                d, m = 1, i + 1
                while m < n and d:
                    if code[m] == "{":
                        d += 1
                    elif code[m] == "}":
                        d -= 1
                    m += 1
                i = m
                continue
            d, m = 1, i + 1
            while m < n and d:
                if code[m] == "{":
                    d += 1
                elif code[m] == "}":
                    d -= 1
                m += 1
            return (i, m)
        i += 1
    return (0, 0)


def main():
    files = []
    for p in sorted(ROOT.rglob("*.zig")):
        rel = p.relative_to(ROOT)
        if rel.parts[0] in SKIP_DIRS:
            continue
        files.append(p)
    if (ROOT / "build.zig").exists() and ROOT / "build.zig" not in files:
        files.append(ROOT / "build.zig")

    texts, codes, keeps, rels = [], [], [], []
    for p in files:
        src = p.read_text(encoding="utf-8", errors="replace")
        code, keep = process(src)
        texts.append(src)
        codes.append(code)
        keeps.append(keep)
        rels.append(str(p.relative_to(ROOT)))

    # line text for reporting comes from the original source, not the blanked copy
    orig_lines = [t.splitlines(keepends=True) for t in texts]

    # collect declarations
    all_decls = []  # (name, file_idx, name_off, kind, line_no, line_text)
    for fi, code in enumerate(codes):
        for name, off, kind, ln, _ in scan_decls(code, rels[fi]):
            if kind == "fn" and name in ENTRY_FNS:
                continue
            line = orig_lines[fi][ln - 1].strip() if ln <= len(orig_lines[fi]) else ""
            all_decls.append((name, fi, off, kind, ln, line))
    if not all_decls:
        print("dead-code: no declarations found")
        return 0

    # candidate names -> token occurrences (file_idx, offset, prev_char)
    cand = {d[0] for d in all_decls}
    occ = {name: [] for name in cand}
    for fi, code in enumerate(codes):
        for m in TOKEN_RE.finditer(code):
            w = m.group(0)
            if w in occ:
                prev = code[m.start() - 1] if m.start() > 0 else ""
                occ[w].append((fi, m.start(), prev))

    # names reachable via @field(x, "name")
    field_names = set()
    for keep in keeps:
        field_names.update(FIELD_STR_RE.findall(keep))

    findings = []
    for name, fi, off, kind, ln, text in all_decls:
        if kind == "fn":
            bs, be = body_span(codes[fi], off)
        else:
            bs = be = 0
        used = False
        for ofi, ooff, prev in occ[name]:
            if ofi == fi:
                if ooff == off:
                    continue
                if bs and bs <= ooff < be:
                    continue  # inside its own body: self-reference only
                used = True
                break
            if prev == ".":
                used = True
                break
        if not used and name in field_names:
            used = True
        if not used:
            findings.append((kind, rels[fi], ln, text, name))

    order = {"import": 0, "fn": 1, "const": 2, "?": 3}
    findings.sort(key=lambda f: (order.get(f[0], 9), f[1], f[2]))
    counts = {"import": 0, "fn": 0, "const": 0}
    for kind, rel, ln, text, _ in findings:
        counts[kind] = counts.get(kind, 0) + 1
        label = {"import": "UNUSED-IMPORT", "fn": "UNUSED-FN", "const": "UNUSED-CONST"}[kind]
        print(f"dead-code: {label}  {rel}:{ln}: {text}")
    print(
        f"dead-code: summary: {counts['import']} unused imports, "
        f"{counts['fn']} unused functions, {counts['const']} unused consts "
        f"({len(all_decls)} declarations in {len(files)} files)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
