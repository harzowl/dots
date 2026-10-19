#!/usr/bin/env bash
# Flag two kinds of unnecessary nesting:
#
# 1. Assignments whose dotted LHS paths share a prefix inside the same attrset
#    literal (or the same `let` binding scope) — the prefix should be nested
#    once.
# 2. Assignments whose entire value is an attrset literal with exactly one plain
#    `key = value;` binding — that binding should be flattened into the LHS.
#
# Rule 1 compares two assignments only when they are direct children of the same
# scope: a `{ ... }` literal, or the bindings of the same `let`. A `let` opens
# a scope frame that its matching `in` closes, so an inline `let ... in` used as
# a value (e.g. `x = let y = 1; in y;`) opens and closes inside that value and
# does not split its siblings, while a `let x = ...; in <body>` still separates
# its bindings from the body. That keeps a repeat split across separate
# `lib.mkIf`/`lib.mkMerge`/`lib.optionalAttrs`/`let` scopes — where nesting
# would change semantics — unflagged. Strings and comments are blanked first, so
# example paths in prose are ignored.
#
# Usage: check-nest.sh FILE...
# Exit status: 0 clean, 1 findings, 2 usage/awk error.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: check-nest.sh FILE..." >&2
  exit 2
fi

if ! command -v awk >/dev/null 2>&1; then
  echo "check-nest: awk not found" >&2
  exit 2
fi

program=$(cat <<'AWK'
function reset_file() {
  ctx_top = 1; ctype[1] = "code"; cbrace[1] = 0
  st_mode = "code"
  frame_top = 0; frame_counter = 0
  n_assigns = 0
  delete apath; delete aline; delete akey
  cand_active = 0; cand_depth = 0
  cand_text = ""; cand_lhs = ""; cand_line = 0
  pending_start = 0; pending_lhs = ""; pending_line = 0
  r2_n = 0
  delete r2_line; delete r2_msg
}

function fkey(   k, s) {
  s = ""
  for (k = 1; k <= frame_top; k++) s = s (k > 1 ? "." : "") frame_stack[k]
  return s
}

# Blank a line's strings and comments. Braces stay in the line, so the anchored
# LHS match cannot fire for a path that shares a line with an opening brace.
function scan(line,   i, len, ch, two, three, cur, prev, nxt, blank) {
  i = 1
  len = length(line)
  blank = ""
  while (i <= len) {
    ch = substr(line, i, 1)
    two = substr(line, i, 2)
    three = substr(line, i, 3)
    if (st_mode == "bcomment") {
      if (two == "*/") { blank = blank "  "; i += 2; st_mode = "code"; continue }
      blank = blank " "; i++; continue
    }
    cur = ctype[ctx_top]
    if (cur == "code") {
      if (ch == "#") break
      if (ch == "l" && three == "let") {
        prev = (i == 1) ? "" : substr(line, i - 1, 1)
        nxt = substr(line, i + 3, 1)
        if (prev !~ /[A-Za-z0-9_'.-]/ && nxt !~ /[A-Za-z0-9_'-]/) {
          blank = blank "let"; i += 3
          frame_kind[++frame_top] = "l"
          frame_stack[frame_top] = ++frame_counter
          continue
        }
      }
      if (ch == "i" && two == "in") {
        prev = (i == 1) ? "" : substr(line, i - 1, 1)
        nxt = substr(line, i + 2, 1)
        if (prev !~ /[A-Za-z0-9_'.-]/ && nxt !~ /[A-Za-z0-9_'-]/) {
          blank = blank "in"; i += 2
          if (frame_top > 0 && frame_kind[frame_top] == "l") frame_top--
          continue
        }
      }
      if (two == "/*") { blank = blank "  "; i += 2; st_mode = "bcomment"; continue }
      if (ch == "\"") { blank = blank " "; i++; ctype[++ctx_top] = "str"; continue }
      if (two == "''") { blank = blank "  "; i += 2; ctype[++ctx_top] = "istr"; continue }
      if (ch == "{") {
        blank = blank ch; i++
        cbrace[ctx_top]++
        frame_kind[++frame_top] = "b"
        frame_stack[frame_top] = ++frame_counter
        continue
      }
      if (ch == "}") {
        blank = blank ch; i++
        if (cbrace[ctx_top] > 0) { cbrace[ctx_top]--; frame_top-- }
        else if (ctx_top > 1) { ctx_top-- }
        continue
      }
      blank = blank ch; i++; continue
    }
    if (cur == "xcode") {
      if (ch == "#") break
      if (two == "/*") { blank = blank "  "; i += 2; st_mode = "bcomment"; continue }
      if (ch == "\"") { blank = blank " "; i++; ctype[++ctx_top] = "str"; continue }
      if (two == "''") { blank = blank "  "; i += 2; ctype[++ctx_top] = "istr"; continue }
      if (ch == "{") { blank = blank " "; i++; cbrace[ctx_top]++; continue }
      if (ch == "}") {
        blank = blank " "; i++
        if (cbrace[ctx_top] > 0) cbrace[ctx_top]--
        else ctx_top--
        continue
      }
      blank = blank " "; i++; continue
    }
    if (cur == "str") {
      if (ch == "\\") { blank = blank "  "; i += 2; continue }
      if (two == "${") { blank = blank "  "; i += 2; ctype[++ctx_top] = "xcode"; cbrace[ctx_top] = 0; continue }
      if (ch == "\"") { blank = blank " "; i++; ctx_top--; continue }
      blank = blank " "; i++; continue
    }
    if (cur == "istr") {
      if (three == "''$" || three == "'''" || three == "''\\") { blank = blank "   "; i += 3; continue }
      if (two == "${") { blank = blank "  "; i += 2; ctype[++ctx_top] = "xcode"; cbrace[ctx_top] = 0; continue }
      if (two == "''") { blank = blank "  "; i += 2; ctx_top--; continue }
      blank = blank " "; i++; continue
    }
  }
  return blank
}

# The value of an assignment, once strings and comments are blanked, is scanned
# here: characters directly inside the outermost `{` are collected, characters
# inside nested braces are ignored. That leaves only the top-level bindings, so
# exactly one `;` means exactly one binding.
function cand_finish(   t, tmp, nsemi) {
  t = cand_text
  gsub(/^[ \t]+|[ \t]+$/, "", t)
  tmp = t
  gsub(/[^;]/, "", tmp)
  nsemi = length(tmp)
  if (nsemi == 1 && t ~ /^[A-Za-z_][A-Za-z0-9_'-]*[ \t]*=/) {
    r2_n++
    r2_line[r2_n] = cand_line
    r2_msg[r2_n] = sprintf("unnecessary single-binding attrset '%s'; flatten it", cand_lhs)
  }
  cand_active = 0; cand_depth = 0; cand_text = ""
}

function cand_feed(s,   i, n, ch) {
  i = 1
  n = length(s)
  while (i <= n && cand_active) {
    ch = substr(s, i, 1)
    if (cand_depth == 0) {
      if (ch == " " || ch == "\t") { i++; continue }
      if (ch == ";") { cand_finish(); return }
      cand_active = 0; return
    }
    if (ch == "{") { cand_depth++; i++; continue }
    if (ch == "}") { cand_depth--; i++; continue }
    if (cand_depth == 1) cand_text = cand_text ch
    i++
  }
}

function rhs_check(s,   m, rest) {
  if (cand_active) { cand_feed(s); return }
  if (pending_start) {
    if (s ~ /^[ \t]*$/) return
    if (match(s, /^[ \t]*\{/)) {
      pending_start = 0
      cand_active = 1; cand_depth = 1; cand_text = ""
      cand_lhs = pending_lhs; cand_line = pending_line
      cand_feed(substr(s, RSTART + RLENGTH))
      return
    }
    pending_start = 0
  }
  if (match(s, RHS_OPEN, m)) {
    cand_active = 1; cand_depth = 1; cand_text = ""
    cand_lhs = m[1]; cand_line = FNR
    cand_feed(substr(s, RSTART + RLENGTH))
    return
  }
  if (match(s, RHS_PENDING, m)) {
    pending_start = 1; pending_lhs = m[1]; pending_line = FNR
  }
}

function lcp(a, b,   na, nb, sa, sb, i, out) {
  na = split(a, sa, "[.]")
  nb = split(b, sb, "[.]")
  out = ""
  for (i = 1; i <= na && i <= nb; i++) {
    if (sa[i] != sb[i]) break
    out = (i == 1) ? sa[i] : out "." sa[i]
  }
  return out
}

function flush(   i, j, p, nf, a, b, kl, kp) {
  delete seen
  nf = 0
  for (i = 1; i <= n_assigns; i++) {
    for (j = i + 1; j <= n_assigns; j++) {
      if (akey[i] != akey[j]) continue
      p = lcp(apath[i], apath[j])
      if (p == "" || (p in seen)) continue
      seen[p] = 1
      nf++
      fL[nf] = (aline[i] > aline[j]) ? aline[i] : aline[j]
      fM[nf] = sprintf("repeated attribute path '%s'; nest it once", p)
    }
  }
  for (i = 1; i <= r2_n; i++) {
    nf++
    fL[nf] = r2_line[i]
    fM[nf] = r2_msg[i]
  }
  for (a = 2; a <= nf; a++) {
    kl = fL[a]; kp = fM[a]; b = a - 1
    while (b >= 1 && (fL[b] > kl || (fL[b] == kl && fM[b] > kp))) {
      fL[b + 1] = fL[b]; fM[b + 1] = fM[b]; b--
    }
    fL[b + 1] = kl; fM[b + 1] = kp
  }
  for (a = 1; a <= nf; a++) {
    printf "%s:%d: %s\n", curfile, fL[a], fM[a]
  }
  found += nf
  delete fL; delete fM
  delete r2_line; delete r2_msg
  r2_n = 0
}

BEGIN {
  ASSIGN = "^[ \t]*([A-Za-z_][A-Za-z0-9_'-]*(\\.[A-Za-z_][A-Za-z0-9_'-]*)+)[ \t]*="
  RHS_OPEN = "^[ \t]*([A-Za-z_][A-Za-z0-9_'-]*(\\.[A-Za-z_][A-Za-z0-9_'-]*)*)[ \t]*=[ \t]*\\{"
  RHS_PENDING = "^[ \t]*([A-Za-z_][A-Za-z0-9_'-]*(\\.[A-Za-z_][A-Za-z0-9_'-]*)*)[ \t]*=[ \t]*$"
  have_file = 0
  found = 0
}

{
  if (FNR == 1) {
    if (have_file) flush()
    reset_file()
    curfile = FILENAME
    have_file = 1
  }
  key = fkey()
  blank = scan($0)
  if (match(blank, ASSIGN, m)) {
    after = substr(blank, RSTART + RLENGTH, 1)
    if (after != "=" && after != ">") {
      n_assigns++
      apath[n_assigns] = m[1]
      aline[n_assigns] = FNR
      akey[n_assigns] = key
    }
  }
  rhs_check(blank)
}

END {
  if (have_file) flush()
  exit (found > 0) ? 1 : 0
}
AWK
)

exec awk "$program" "$@"
