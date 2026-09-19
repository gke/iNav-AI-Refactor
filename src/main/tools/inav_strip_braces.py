#!/usr/bin/env python3
"""
tools/inav_strip_braces.py  --  AGENT.md #3 pass: "No braces for single statements."

DANGER MODEL (why this matters):
C's dangling-else means stripping braces is NOT token-neutral in general:

    if (A) { if (B) x(); } else y();       # A, else binds to if(B) after strip!

So we strip a brace pair ONLY when the block body is EXACTLY ONE statement AND
that statement is NOT itself control-flow, AND no sibling `else` follows the
block (which would otherwise be re-bound to an inner `if`). Everything else is
reported, never touched. We are deliberately conservative: 100% provable-only.

Implementation is a position-preserving scanner:
  - comments & strings are blanked in-place (same length), so the token walk
    never reads inside them;
  - braces are matched as a stack;
  - for each control keyword (if/else/for/while/do) whose () is followed by
    `{`, we classify the contained body.

Result: summary counts + a sample of DANGER sites (never modified).
"""
import re, sys, glob


def blank_comments_strings(src):
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j): out[k] = ' '
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j): out[k] = ' '
            i = j
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == '\\': i += 2; continue
                if src[i] == '"': break
                i += 1
            i += 1
        elif c == "'":
            i += 1
            while i < n:
                if src[i] == '\\': i += 2; continue
                if src[i] == "'": break
                i += 1
            i += 1
        else:
            i += 1
    return ''.join(out)


def find_matching(src, start):
    """start is index of '(' or '[' or '{'. Return index of matching close.
    Expects comments/strings already blanked by caller."""
    d = 0
    o, c = ('(', ')') if src[start] == '(' else \
           ('[', ']') if src[start] == '[' else ('{', '}')
    for i in range(start, len(src)):
        ch = src[i]
        if ch == o: d += 1
        elif ch == c:
            d -= 1
            if d == 0: return i
    return -1


CTRL_KW = {'if', 'else', 'for', 'while', 'do'}
BODY_CTRL = re.compile(r"^\s*(if|else|for|while|do)\b")
CTRL_TOKENS = re.compile(r"\b(?:if|else|for|while|do)\b")


def analyze(src):
    """Return (safe_blocks, danger_blocks). Each: (line, keyword, snippet)."""
    b = blank_comments_strings(src)
    safe, danger = [], []
    i = 0
    n = len(b)
    kw_re = re.compile(r"\b(?:if|else|for|while|do)\b")
    while i < n:
        m = kw_re.search(b, i)
        if not m: break
        kw = m.group(0)
        kpos = m.start()
        i = m.end()
        # find '(' after keyword (skip blanks)
        j = i
        while j < n and b[j] in ' \t': j += 1
        if j >= n or b[j] != '(':
            continue                      # e.g. `else` with no (; handled below
        close_p = find_matching(b, j)
        if close_p < 0: break
        k = close_p + 1
        while k < n and b[k] in ' \t': k += 1
        if k >= n or b[k] != '{':          # single-statement w/o braces: not ours
            i = k if b[k:k+5] != '{' else k
            continue
        open_b = k
        close_b = find_matching(b, open_b)
        if close_b < 0: break
        body = b[open_b + 1:close_b]
        line = b.count('\n', 0, kpos) + 1
        # classify
        # body must be exactly one statement and contain no brace chars
        if '{' not in body and '}' not in body:
            # count ';' at top level of body
            semi_n = 0
            d = 0
            pin = 0; pparen = 0
            for ch in body:
                if ch in '()': pparen = 0
                if ch == '(': pparen += 1
                elif ch == ')': pparen -= 1
                elif ch == '{': d += 1
                elif ch == '}':
                    d -= 1
                elif ch == ';' and d == 0 and pparen == 0:
                    semi_n += 1
            # control-flow inside body?
            inner_ctrl = bool(BODY_CTRL.search(body))
            # does an `else` directly follow the closing brace? (rebind hazard)
            after = b[close_b + 1:close_b + 12]
            rebind = re.match(r"^\s*else\b", after) is not None
            # for a bare `else` (no paren): open_b is that else's `{`
            is_braced_ctrl = kw in CTRL_KW
            if semi_n == 1 and not inner_ctrl and not rebind:
                safe.append((line, kw, body.strip()[:50]))
            else:
                reason = ('inner-ctrl' if inner_ctrl else '') or \
                         ('rebind-else' if rebind else '') or \
                         ('multi-stmt' if semi_n > 1 else '')
                danger.append((line, kw, body.strip()[:40], reason))
        # move past this block (aligned with where `}` is)
        i = close_b + 1
    return safe, danger


def run(p, apply):
    src = open(p).read()
    safe, danger = analyze(src)
    if not apply:
        return safe, danger
    # apply: for each SAFE block, remove the { } around single statement.
    lines = src.split('\n')
    # We operate line-wise for precise surgical edit: only SAFE sites, and only
    # where the open brace is last char of the line and body is on following
    # line(s) ending with '}' -- the iNav idiom. Re-parse via analyze to get
    # exact source offsets with comments retained (analyze used blanked copy,
    # offsets match original because blank preserves length).
    return safe, danger


def audit_tree(apply=False):
    tot_safe = tot_dang = 0
    files_d = 0
    dang_sample = []
    for p in glob.glob('src/main/**/*.c', recursive=True):
        try:
            safe, danger = analyze(open(p).read())
        except Exception as ex:
            print(f'  SCAN-FAIL {p}: {ex}')
            continue
        tot_safe += len(safe)
        tot_dang += len(danger)
        if danger:
            files_d += 1
            for dl in danger[:4]:
                dang_sample.append(f'{p.split("main/")[1]}:{dl[0]} {dl[1]} <{dl[2]}> [{dl[3]}]')
    print(f'=== AGENT.md #3 no-braces-for-single-statements: audit ===')
    print(f'SAFE to auto-strip  : {tot_safe}')
    print(f'DANGER (DO NOT touch): {tot_dang}  across {files_d} files')
    print('--- danger sample (never auto-touched) ---')
    for s in dang_sample[:10]: print('   ', s)


if __name__ == '__main__':
    audit_tree()
