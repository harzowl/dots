#!/usr/bin/env python3
"""Seed qBittorrent's WebUI settings into its config file.

Two things need writing into `qBittorrent.conf` that the LinuxServer image
exposes no environment variable for:

* the WebUI password — the image only accepts `WebUI\\Password_PBKDF2`, stored
  the way qBittorrent itself stores it (PBKDF2-HMAC-SHA512, 100000 iterations,
  16-byte salt, 64-byte key, as `@ByteArray(<salt base64>:<key base64>)`);
* static preferences (e.g. the alternative-WebUI switch that activates the
  VueTorrent mod), passed as `--pref KEY=VALUE`.

The password is read from a dotenv file (the secretspec env), never from the
command line, so it cannot leak into a process list or the journal.

A value is only rewritten when it is actually out of date, so the unit is
idempotent and does not restart the container on every boot. Prints `changed`
when the config was rewritten, otherwise `unchanged`.
"""

import argparse
import base64
import binascii
import hashlib
import hmac
import os

ITERATIONS = 100_000
KEY_LENGTH = 64
SALT_LENGTH = 16
PASSWORD_KEY = "WebUI\\Password_PBKDF2"
USERNAME_KEY = "WebUI\\Username"
GROUP = "[Preferences]"


def read_dotenv(path: str, key: str) -> str:
    """Return the value of `key` in a dotenv file, unquoting it if needed."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return ""
    for line in lines:
        name, sep, value = line.partition("=")
        if sep and name.strip() == key:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return ""


def verifies(stored: str, password: str) -> bool:
    """Whether a stored `Password_PBKDF2` value already matches `password`."""
    stored = stored.strip()
    if len(stored) >= 2 and stored[0] == stored[-1] and stored[0] in "\"'":
        stored = stored[1:-1]
    if stored.startswith("@ByteArray(") and stored.endswith(")"):
        stored = stored[len("@ByteArray(") : -1]
    salt_b64, sep, key_b64 = stored.partition(":")
    if not sep:
        return False
    try:
        salt = base64.b64decode(salt_b64, validate=True)
        expected = base64.b64decode(key_b64, validate=True)
    except (binascii.Error, ValueError):
        return False
    derived = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, ITERATIONS, len(expected))
    return hmac.compare_digest(derived, expected)


def encode(password: str) -> str:
    """Encode `password` the way qBittorrent stores it."""
    salt = os.urandom(SALT_LENGTH)
    key = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, ITERATIONS, KEY_LENGTH)
    return "@ByteArray({}:{})".format(
        base64.b64encode(salt).decode(), base64.b64encode(key).decode()
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--conf", required=True, help="path to qBittorrent.conf")
    parser.add_argument("--env-file", help="dotenv file holding the WebUI password")
    parser.add_argument(
        "--env-key", default="QBITTORRENT_PASSWORD", help="key to read that password from"
    )
    parser.add_argument("--username", default="", help="WebUI username to seed")
    parser.add_argument(
        "--pref",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="a static preference to seed (repeatable)",
    )
    args = parser.parse_args()

    # `None` marks a value we still have to derive (the hashed password).
    wanted: dict[str, str | None] = {}
    if args.username:
        wanted[USERNAME_KEY] = args.username
    for pref in args.pref:
        key, sep, value = pref.partition("=")
        if not sep:
            parser.error("--pref needs KEY=VALUE, got {!r}".format(pref))
        wanted[key] = value

    password = read_dotenv(args.env_file, args.env_key) if args.env_file else ""
    if password:
        wanted[PASSWORD_KEY] = None

    def rendered(key: str) -> str:
        if wanted[key] is not None:
            return wanted[key]
        return '"{}"'.format(encode(password))

    try:
        with open(args.conf, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        lines = []

    out, changed, seen = [], False, set()
    for line in lines:
        key, sep, current = line.partition("=")
        if sep and key in wanted:
            seen.add(key)
            if key == PASSWORD_KEY and password and verifies(current, password):
                wanted[key] = current  # already correct: keep the stored hash
            elif key == PASSWORD_KEY and password:
                current, wanted[key], changed = rendered(key), "known", True
            elif current != wanted[key]:
                current, changed = wanted[key], True
            line = "{}={}".format(key, current)
        out.append(line)

    missing = [key for key in wanted if key not in seen]
    if missing:
        try:
            at = out.index(GROUP) + 1
        except ValueError:
            if out and out[-1] != "":
                out.append("")
            out += [GROUP]
            at = len(out)
        for offset, key in enumerate(missing):
            wanted[key] = rendered(key)
            out.insert(at + offset, "{}={}".format(key, wanted[key]))
        changed = True

    if changed:
        with open(args.conf, "w", encoding="utf-8") as handle:
            handle.write("\n".join(out) + "\n")

    print("changed" if changed else "unchanged")


if __name__ == "__main__":
    main()
