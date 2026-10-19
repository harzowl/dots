#!/usr/bin/env python3
"""Write a beets config whose secrets come from the environment.

Usage: render-config.py SOURCE DEST PATH=ENV...

SOURCE is the secret-free config rendered into the Nix store; DEST is the
runtime copy. Each PATH is a dotted beets config key and ENV the variable that
holds its value. Every variable is checked before the file is touched, so a
missing key fails the unit instead of producing a partial config.
"""

import os
import sys
import tempfile

import yaml


def set_path(config, dotted, value):
    keys = dotted.split(".")
    node = config
    for key in keys[:-1]:
        child = node.get(key)
        if not isinstance(child, dict):
            child = {}
            node[key] = child
        node = child
    node[keys[-1]] = value


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: render-config.py SOURCE DEST PATH=ENV...")

    source, dest = sys.argv[1:3]

    mapping = {}
    for pair in sys.argv[3:]:
        path, sep, variable = pair.partition("=")
        if not sep or not path or not variable:
            sys.exit(f"invalid secret mapping: {pair!r}")

        value = os.environ.get(variable)
        if not value:
            sys.exit(f"missing environment variable: {variable}")
        mapping[path] = value

    with open(source) as handle:
        config = yaml.safe_load(handle) or {}

    for path, value in mapping.items():
        set_path(config, path, value)

    directory = os.path.dirname(dest) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".config-", suffix=".yaml")
    try:
        with os.fdopen(fd, "w") as handle:
            yaml.safe_dump(config, handle, sort_keys=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, dest)
    except BaseException:
        os.unlink(temporary)
        raise


if __name__ == "__main__":
    main()
