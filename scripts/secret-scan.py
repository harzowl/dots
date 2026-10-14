#!/usr/bin/env python3
"""Fail when a source tree looks like it carries a real credential.

This is the companion to gitleaks' format rules. gitleaks catches the
well-known credential *formats* (cloud keys, provider tokens, private keys);
this catches the *shape* those rules miss — a long, high-entropy token such as
a Keycloak personal access token or an HMAC signing key pasted into a fixture
with no `key`/`secret`/`token` keyword nearby to trip them, which is exactly
how a real credential once landed in a test file here.

A match is a finding only when it is long (>= 40 chars), high-entropy
(>= 3.5 bits/char) **and** mixes upper case, lower case and digits, so
ordinary long identifiers (CamelCase, no digits), Store/nar hashes and the
`dummy-DO-NOT-USE-...` placeholder convention do not trip it. It also flags a
few literal credential prefixes outright, and any email address that is not on
a reserved example domain (or a GitHub noreply host) — a real personal address
is a leak even when it carries no credential shape.

Usage: secret-scan.py [PATH ...]   (defaults to the current directory)
Exit status: 0 clean, 1 findings, 2 usage error.
"""

from __future__ import annotations

import math
import os
import re
import sys
from collections import Counter

# Directories that never hold our own source/fixtures.
SKIP_DIRS = {
    ".git",
    ".direnv",
    ".venv",
    "node_modules",
    "vendor",
    "result",
    "__pycache__",
}

# Only files where a credential-shaped literal is meaningful here; other kinds
# are still covered by gitleaks' format rules.
SCAN_SUFFIXES = (
    ".go",
    ".nix",
    ".toml",
    ".yaml",
    ".yml",
    ".json",
    ".sh",
    ".bash",
    ".env",
    ".md",
    ".js",
    ".ts",
    ".svelte",
)

MAX_FILE_BYTES = 2 * 1024 * 1024

# Whole-line allowlists: public material, Store hashes, and the placeholder
# convention every committed fixture must use.
ALLOW_LINE = re.compile(
    r"DO-NOT-USE|dummy|placeholder|REDACTED|RESERVED|"
    r"sha256-|sha512-|sha1-|age1[0-9a-z]{20,}|example",
    re.IGNORECASE,
)

# Paths that are public by construction (public keys, encrypted blobs, locks).
ALLOW_PATH = re.compile(
    r"(\.pub$|\.patch$|flake\.lock$|go\.sum$|"
    r"secrets\.enc\.yaml$|\.sops\.yaml$|package-lock\.json$)"
)

# Every address must live on a reserved example domain (RFC 2606/6761) or a
# privacy-preserving noreply host. A real personal address is a leak, so this
# runs before the line allowlist — a stray `example` on the same line must not
# shield a real address. The percent-encoded form (`%40`) hides the same leak
# inside a URL query string.
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
EMAIL_ENCODED = re.compile(r"[A-Za-z0-9._%+-]+%40([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
RESERVED_DOMAIN = re.compile(
    r"(?:^|\.)(?:example\.(?:com|net|org|edu)|invalid|test|localhost|example)$",
    re.IGNORECASE,
)
NOREPLY_DOMAIN = re.compile(r"\.noreply\.github\.com$", re.IGNORECASE)


def is_reserved_email(domain: str) -> bool:
    return bool(RESERVED_DOMAIN.search(domain) or NOREPLY_DOMAIN.search(domain))


def non_example_email(line: str) -> str | None:
    """The finding label for the first non-reserved address on the line, if any."""
    for pattern, label in (
        (EMAIL, "non-example email address"),
        (EMAIL_ENCODED, "non-example email address (percent-encoded)"),
    ):
        for match in pattern.finditer(line):
            if not is_reserved_email(match.group(1)):
                return label
    return None

# A long run of base64/base64url characters (padding allowed).
TOKEN = re.compile(r"[A-Za-z0-9_+/=-]{40,}")

# Literal credential formats that are unambiguous regardless of entropy.
PREFIXES = re.compile(
    r"AGE-SECRET-KEY-1[0-9A-Z]{20,}|"
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"ghp_[A-Za-z0-9]{36}|"
    r"github_pat_[A-Za-z0-9_]{20,}|"
    r"glpat-[A-Za-z0-9_-]{20}|"
    r"xox[baprs]-[A-Za-z0-9-]{10,}|"
    r"AKIA[0-9A-Z]{16}|"
    r"AIza[0-9A-Za-z_-]{35}"
)


def shannon(text: str) -> float:
    """Shannon entropy in bits per character."""
    if not text:
        return 0.0
    counts = Counter(text)
    length = len(text)
    return -sum((n / length) * math.log2(n / length) for n in counts.values())


def looks_like_credential(token: str) -> bool:
    token = token.strip("=")
    if len(token) < 40:
        return False
    if not any(c.isdigit() for c in token):
        return False
    if not any(c.isupper() for c in token):
        return False
    if not any(c.islower() for c in token):
        return False
    return shannon(token) >= 3.5


def iter_files(roots: list[str]):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                path = os.path.join(dirpath, name)
                if name.endswith(".env") or path.endswith(SCAN_SUFFIXES):
                    yield path


def scan_file(path: str) -> list[tuple[int, str]]:
    if ALLOW_PATH.search(path):
        return []
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return []
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return []
    findings: list[tuple[int, str]] = []
    for number, line in enumerate(lines, start=1):
        label = non_example_email(line)
        if label is not None:
            findings.append((number, label))
            continue
        if ALLOW_LINE.search(line):
            continue
        if PREFIXES.search(line):
            findings.append((number, "literal credential prefix"))
            continue
        for match in TOKEN.finditer(line):
            if looks_like_credential(match.group(0)):
                findings.append((number, "high-entropy token"))
                break
    return findings


def main(argv: list[str]) -> int:
    roots = argv[1:] or ["."]
    findings = 0
    for path in iter_files(roots):
        for number, reason in scan_file(path):
            print(f"{path}:{number}: {reason}", file=sys.stderr)
            findings += 1
    if findings:
        print(
            f"secret-scan: {findings} finding(s); use an obvious dummy "
            "(dummy-DO-NOT-USE-...) or a reserved example address",
            file=sys.stderr,
        )
        return 1
    print("secret-scan: clean", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
