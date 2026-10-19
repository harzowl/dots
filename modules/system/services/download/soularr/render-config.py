#!/usr/bin/env python3
"""Write soularr's config.ini from the settings tree and runtime secrets.

Usage: render-config.py --settings JSON --output PATH SECTION.key=ENV...

The settings file is the secret-free JSON rendered into the Nix store. Secrets
are read from the environment (populated by the unit's EnvironmentFile) and are
never written anywhere except the generated INI. Every secret is checked before
the file is touched, so a missing value fails the unit instead of producing a
partial config.
"""

import argparse
import configparser
import json
import os
import sys
import tempfile


def render_value(value):
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, list):
        return ",".join(render_value(item) for item in value)
    return str(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("secret", nargs="*", help="SECTION.key=ENV")
    args = parser.parse_args()

    with open(args.settings, encoding="utf-8") as handle:
        settings = json.load(handle)

    config = configparser.RawConfigParser(interpolation=None)
    for section, values in settings.items():
        config.add_section(section)
        for key, value in values.items():
            config.set(section, key, render_value(value))

    for pair in args.secret:
        path, sep, variable = pair.partition("=")
        section, dot, key = path.rpartition(".")
        if not sep or not dot or not section or not key:
            sys.exit(f"invalid secret mapping: {pair!r}")

        value = os.environ.get(variable)
        if not value:
            sys.exit(f"missing environment variable: {variable}")

        if not config.has_section(section):
            config.add_section(section)
        config.set(section, key, value)

    directory = os.path.dirname(args.output) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".config-", suffix=".ini")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            config.write(handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, args.output)
    except BaseException:
        os.unlink(temporary)
        raise


if __name__ == "__main__":
    main()
