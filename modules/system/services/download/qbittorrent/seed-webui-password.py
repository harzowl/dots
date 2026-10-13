#!/usr/bin/env python3
"""Seed qBittorrent's WebUI credentials into its config file.

The LinuxServer image exposes no environment variable for the WebUI password, so
the only declarative way in is the config's `WebUI\\Password_PBKDF2` key. The
value written here is exactly what qBittorrent stores itself: PBKDF2-HMAC-SHA512,
100000 iterations, a 16-byte salt and a 64-byte key, held as
`@ByteArray(<salt base64>:<key base64>)`.

The password is read from a dotenv file (the secretspec env), never from the
command line, so it cannot leak into a process list or the journal.

A value is only rewritten when the stored hash does not already verify the
password, so the unit is idempotent. Prints `changed` when the config was
rewritten, otherwise `unchanged`.
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
    parser.add_argument("--env-file", required=True, help="dotenv file holding the password")
    parser.add_argument("--env-key", required=True, help="key to read from that file")
    parser.add_argument("--conf", required=True, help="path to qBittorrent.conf")
    parser.add_argument("--username", default="", help="optional WebUI username to seed")
    args = parser.parse_args()

    password = read_dotenv(args.env_file, args.env_key)
    if not password:
        print("unchanged")
        return

    try:
        with open(args.conf, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        lines = []

    # What we want present, keyed by config key. `None` marks a key we still owe.
    wanted = {PASSWORD_KEY: None}
    if args.username:
        wanted[USERNAME_KEY] = args.username

    out, changed = [], False
    for line in lines:
        key, sep, current = line.partition("=")
        if sep and key in wanted:
            if key == PASSWORD_KEY:
                if verifies(current, password):
                    wanted[key] = current
                else:
                    current, wanted[key], changed = '"{}"'.format(encode(password)), "known", True
            elif current != wanted[key]:
                current, changed = wanted[key], True
            line = "{}={}".format(key, current)
        out.append(line)

    missing = [key for key, value in wanted.items() if value is None]
    if missing:
        try:
            at = out.index(GROUP) + 1
        except ValueError:
            if out and out[-1] != "":
                out.append("")
            out += [GROUP]
            at = len(out)
        for offset, key in enumerate(missing):
            value = '"{}"'.format(encode(password)) if key == PASSWORD_KEY else wanted[key]
            out.insert(at + offset, "{}={}".format(key, value))
        changed = True

    if changed:
        with open(args.conf, "w", encoding="utf-8") as handle:
            handle.write("\n".join(out) + "\n")

    print("changed" if changed else "unchanged")


if __name__ == "__main__":
    main()
