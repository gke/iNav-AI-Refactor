#!/usr/bin/env python3
# iNavgke rules-lint (report-only).  Scans C/H sources under a directory and
# reports provisional compliance tallies against AGENT.md rules 1-18 plus the
# fork deltas.  This is a heuristic grep/structural check -- AGENT.md's
# Verification section states the build is the arbiter, so this report is
# advisory: it finds WHERE to look, not an authoritative pass/fail.

import os
import re
import sys
from collections import OrderedDict, Counter

ROOT = os.path.dirname(os.path.abspath(__file__)) + "/../.."

RULES = [
    ("r01_goto",          "1.  No goto; one exit per function"),
    ("r02_division",      "2.  No / or % except inherent math"),
    ("r03_braces_single", "3.  No braces for single statements"),
    ("r04_switch_chain",  "4.  switch over deep if-else; cyclomatic < 10"),
    ("r05_assign_in_if",  "5.  No assignments inside if()"),
    ("r06_isr",           "6.  ISRs minimal (manual review)"),
    ("r07_malloc_cast",   "7.  No malloc/free; pointer casts only to/from void*"),
    ("r08_bounds",        "8.  Bounds-check array accesses"),
    ("r09_preserve",      "9.  Preserve ALL code (manual review)"),
    ("r10_func_size",     "10. Functions <= 100 lines"),
    ("r11_macro_case",    "11. Macros UPPER_CASE; no leading underscore"),
    ("r12_slash_comment", "12. // comments preferred; /* */ acceptable"),
    ("r13_no_typedef",    "13. No typedef for structs/unions/enums"),
    ("r14_no_magic",      "14. No magic numbers (0,1,NULL exempt)"),
    ("r15_line_len",      "15. Max line length 80"),
    ("r16_brace_style",   "16. No newline before { after control/function header"),
    ("r17_real32",        "17. real32 floats for physical quantities (no double)"),
    ("r18_misra",         "18. MISRA C:2012 (switch default, no recursion)"),
]

EXTENSIONS = (".c", ".h")


def strip_comments(text):
    """Remove /* */ and // comments but keep code.  A line-based approximation."""
    # Protect the licence header detection: keep track separately.
    out_lines = []
    in_block = False
    for line in text.splitlines():
        code = []
        i = 0
        n = len(line)
        while i < n:
            if not in_block and line[i:i + 2] == '/*':
                in_block = True
                i += 2
                continue
            if in_block and line[i:i + 2] == '*/':
                in_block = False
                i += 2
                continue
            if not in_block and line[i:i + 2] == '//':
                break
            if not in_block:
                code.append(line[i])
            i += 1
        out_lines.append(''.join(code))
    return out_lines


def iter_sources(root):
    for dirpath, dirnames, filenames in os.walk(root):
        # skip build dirs and generated files
        dirnames[:] = [d for d in dirnames if d not in ('build', '.git')]
        for fn in sorted(filenames):
            if fn.endswith(EXTENSIONS):
                yield os.path.join(dirpath, fn)


def score_file(path):
    rel = os.path.relpath(path, ROOT)
    s = {r[0]: [] for r in RULES}
    with open(path, 'rb') as f:
        raw = f.read()
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        text = raw.decode('latin-1')
    lines = text.splitlines()
    code = strip_comments(text)  # parallel to lines

    def add(rule, lineno, snippet):
        s[rule].append((lineno, snippet.strip()[:100]))

    for i, (raw, cd) in enumerate(zip(lines, code), start=1):
        # r01 goto
        if re.search(r'\bgoto\b', cd):
            add('r01_goto', i, raw)
        # r02 division operators outside comments
        if '/' in cd or '%' in cd:
            # keep only real division/mods, not comments, not preprocessor
            seg = re.sub(r'^#.*', '', cd)
            if '/' in seg or '%' in seg:
                add('r02_division', i, raw)
        # r03 braces for single statement: `){` on same line but a lone
        # statement body -- too ambiguous; tally `if(x) { y; }` one-liners
        # r05 assignment inside if(...)
        m = re.search(r'\bif\s*\(([^)]*)\)', cd)
        if m and re.search(r'(?<![=!<>])=(?!=)', m.group(1)):
            add('r05_assign_in_if', i, raw)
        # r07 malloc/free
        if re.search(r'\b(malloc|calloc|realloc|free)\s*\(', cd):
            add('r07_malloc_cast', i, raw)
        # r07 pointer casts to non-void types (best effort)
        if re.search(r'\(\s*\w[\w\s]*\s*\*\s*\)\s*(?!\s*$)', cd) and not re.match(r'^\s*(void|const\s+void)\s*$', cd):
            if re.search(r'\(\s*[A-Za-z_]\w*(?:\s*\*|\s+.*\*)\s*\)', cd):
                add('r07_malloc_cast', i, raw)
        # r11 macro naming
        m = re.match(r'#\s*define\s+([A-Za-z_]\w*)', cd)
        if m:
            name = m.group(1)
            if not name.isupper() or name.startswith('_'):
                bad = (not name.isupper()) or name.startswith('_')
                if bad:
                    add('r11_macro_case', i, raw)
        # r12 block comments in code (not file-header, not straddled)
        if '/*' in raw and i > 12 and not re.search(r'[^;\s]\s*/\*.*\*/', raw):
            add('r12_slash_comment', i, raw)
        # r13 typedef struct/union/enum (excluding function pointer/opaque)
        if re.search(r'typedef\s+(struct|union|enum)\b', cd):
            add('r13_no_typedef', i, raw)
        # r14 magic numbers: numeric literals other than 0,1
        for m in re.finditer(r'(?<![\w.])0x[0-9A-Fa-f]+|(?<![\w.])\.?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?[fFuUlL]*', cd):
            tok = m.group(0)
            base = tok.lower().rstrip('ful')
            if base in ('0', '0.0', '1', '1.0'):
                continue
            if re.match(r'^\d+$', base) and int(base) <= 1:
                continue
            # string contents already stripped; coordinates like 1000 etc flagged
            add('r14_no_magic', i, raw)
            break  # one line = one finding to keep report readable
        # r15 line length
        if len(raw) > 80:
            add('r15_line_len', i, raw)
        # r16 brace on next line for control statements
        m = re.search(r'\b(if|else|for|while|do|switch)\b[^{;]*\)$', cd)
        if m and i <= len(code) - 2:
            nxt = code[i].strip()
            if nxt == '{':
                add('r16_brace_style', i, raw)
        # r16 brace on next line for function headers
        m = re.match(r'\s*[\w\s\*]+\([^;{}]*\)\s*$', cd)
        if m and i <= len(code) - 2:
            nxt = code[i].strip()
            if nxt == '{':
                add('r16_brace_style', i, raw)
        # r17 double usage
        if re.search(r'\bdouble\b', cd):
            add('r17_real32', i, raw)
        # r18 switch without default (heuristic: find switch { ... } blocks)
        # handled per-file pass below

    # r18 switch-without-default via brace scanning on cleaned code
    whole = '\n'.join(code)
    for m in re.finditer(r'\bswitch\s*\([^)]*\)\s*\{', whole):
        ln = whole[:m.start()].count('\n') + 1
        # find matching closing brace (simple depth scan)
        start = m.end() - 1
        depth = 0
        for j in range(start, len(whole)):
            if whole[j] == '{':
                depth += 1
            elif whole[j] == '}':
                depth -= 1
                if depth == 0:
                    block = whole[start:j]
                    if 'default' not in block:
                        add('r18_misra', ln, 'switch without default')
                    break
    return s


def summarize(all_scores):
    totals = {r[0]: 0 for r in RULES}
    files_hit = Counter()
    ranked = OrderedDict((r[0], []) for r in RULES)
    for rel, s in all_scores.items():
        for r in RULES:
            if s[r[0]]:
                totals[r[0]] += len(s[r[0]])
                files_hit[r[0]] += 1
                ranked[r[0]].append((rel, len(s[r[0]])))
    return totals, files_hit, ranked


def main():
    root = os.path.normpath(ROOT + "/src/main")
    filter_file = None
    detail = False
    args = sys.argv[1:]
    if args and not args[0].startswith('-'):
        root = os.path.abspath(args[0])
        args = args[1:]
    if '--files' in args:
        i = args.index('--files')
        filter_file = os.path.abspath(args[i + 1])
    if '--detail' in args:
        detail = True
    changed = {}
    if '--changed-lines' in args:
        i = args.index('--changed-lines')
        clf = args[i + 1]
        with open(clf) as f:
            for l in f:
                p, _, rest = l.rstrip('\n').partition('\t')
                rp = os.path.normcase(os.path.relpath(os.path.normpath(p), ROOT))
                changed[rp] = set(int(x) for x in rest.split(',') if x)
    print(f"Scanning {root}")
    all_scores = {}
    nfiles = 0
    include = None
    if filter_file:
        with open(filter_file) as f:
            include = set()
            for l in f:
                p = l.strip()
                if p:
                    include.add(os.path.normcase(os.path.normpath(p)))
    for path in iter_sources(root):
        rp = os.path.relpath(path, ROOT)
        if include and os.path.normcase(rp) not in include:
            continue
        nfiles += 1
        s = score_file(path)
        if changed:
            cl = changed.get(os.path.normcase(rp), None)
            if cl is not None:
                s = {k: [(ln, sn) for (ln, sn) in v if ln in cl] for k, v in s.items()}
        all_scores[rp] = s
    totals, files_hit, ranked = summarize(all_scores)

    out = []
    out.append("iNavgke rules-lint report (provisional, heuristic) -- report only")
    out.append(f"Scanned: {root}")
    out.append(f"Files:   {nfiles}")
    out.append("")
    out.append(f"{'Rule':<18} {'Finds':>7} {'Files':>6}  Description")
    out.append("-" * 72)
    for r in RULES:
        out.append(f"{r[0]:<18} {totals[r[0]]:>7} {files_hit[r[0]]:>6}  {r[1]}")
    out.append("")
    out.append("Top files per rule (file, count):")
    for r in RULES:
        top = sorted(ranked[r[0]], key=lambda x: -x[1])[:8]
        if top:
            out.append(f"  {r[0]}: " + ", ".join(f"{f}({c})" for f, c in top))

    if detail:
        out.append("")
        out.append("Per-file detail (only files with findings):")
        for r in RULES:
            out.append(f"\n  == {r[1]} ==")
            for rel, lst in sorted(all_scores.items()):
                if lst[r[0]]:
                    out.append(f"  {rel}:")
                    for ln, snip in lst[r[0]][:12]:
                        out.append(f"    L{ln}: {snip}")
                        if len(lst[r[0]]) > 12:
                            out.append(f"    ... +{len(lst[r[0]]) - 12} more")

    report = ROOT + "/build/standalone/rules-lint.txt"
    os.makedirs(os.path.dirname(report), exist_ok=True)
    with open(report, 'w') as f:
        f.write("\n".join(out) + "\n")
    print("\n".join(out))
    print(f"\nWrote {report}")


if __name__ == "__main__":
    main()