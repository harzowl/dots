#!/usr/bin/env python3
"""Import completed slskd albums into beets.

Each top-level directory under the complete tree is a Soulseek user. slskd
mirrors the peer's path below `<user>/directories`, and incomplete downloads
below the incomplete tree, where the `directories` segment is absent. The
importer walks the completed trees, finds the directories that hold an album,
and hands settled albums to `beet import`. Only an import that moved the audio
out of the download tree is followed by sidecar cleanup and directory pruning.
"""

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

AUDIO_SUFFIXES = {
    ".aac",
    ".aif",
    ".aiff",
    ".alac",
    ".ape",
    ".dff",
    ".dsf",
    ".flac",
    ".m4a",
    ".m4b",
    ".mp3",
    ".mpc",
    ".oga",
    ".ogg",
    ".opus",
    ".tta",
    ".wav",
    ".wma",
    ".wv",
}

SIDECAR_SUFFIXES = {
    ".accurip",
    ".cue",
    ".db",
    ".html",
    ".ini",
    ".jpeg",
    ".jpg",
    ".json",
    ".log",
    ".lrc",
    ".m3u",
    ".m3u8",
    ".nfo",
    ".png",
    ".sfv",
    ".txt",
}

DISC_DIR = re.compile(r"^(?:cd|disc|disk|dvd)[\s._-]*\d+$", re.IGNORECASE)


def is_audio(name):
    return Path(name).suffix.lower() in AUDIO_SUFFIXES


def entries(path):
    try:
        return list(os.scandir(path))
    except OSError as error:
        print(f"skip unreadable {path}: {error}", file=sys.stderr)
        return []


def has_audio_directly(path):
    return any(entry.is_file(follow_symlinks=False) and is_audio(entry.name) for entry in entries(path))


def has_audio(path):
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        dirnames[:] = [name for name in dirnames if not name.startswith(".")]
        if any(is_audio(name) for name in filenames):
            return True
    return False


def newest_mtime(path):
    newest = 0.0
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        dirnames[:] = [name for name in dirnames if not name.startswith(".")]
        for name in filenames:
            try:
                mtime = os.stat(os.path.join(dirpath, name), follow_symlinks=False).st_mtime
            except OSError:
                continue
            newest = max(newest, mtime)
    return newest


def is_disc_root(path):
    return bool(DISC_DIR.match(path.name))


def album_roots(path):
    """Return album directories below `path`, collapsing disc subdirectories."""
    children = [
        Path(entry.path)
        for entry in entries(path)
        if entry.is_dir(follow_symlinks=False) and not entry.name.startswith(".")
    ]

    if has_audio_directly(path):
        return [path]

    roots = []
    for child in children:
        roots.extend(album_roots(child))

    if roots and all(is_disc_root(root) for root in roots):
        return [path]
    return roots


def incomplete_copy(complete, album, incomplete):
    relative = album.relative_to(complete)
    candidates = [incomplete / relative]

    # Completed downloads mirror the peer's path below `<user>/directories`,
    # while incomplete ones stay directly below `<user>`.
    parts = relative.parts
    if len(parts) > 1 and parts[1] == "directories":
        candidates.append(incomplete.joinpath(parts[0], *parts[2:]))

    return any(candidate.exists() for candidate in candidates)


def remove_sidecars(album):
    for dirpath, dirnames, filenames in os.walk(album, followlinks=False):
        dirnames[:] = [name for name in dirnames if not name.startswith(".")]
        for name in filenames:
            path = Path(dirpath) / name
            if path.suffix.lower() not in SIDECAR_SUFFIXES:
                continue
            try:
                path.unlink()
            except OSError as error:
                print(f"could not remove {path}: {error}", file=sys.stderr)


def prune(album, complete):
    for dirpath, dirnames, filenames in os.walk(album, topdown=False, followlinks=False):
        try:
            os.rmdir(dirpath)
        except OSError:
            pass

    directory = album.parent
    while directory != complete and directory.is_relative_to(complete):
        try:
            os.rmdir(directory)
        except OSError:
            break
        directory = directory.parent


def import_album(album, beet, complete, settle):
    newest = newest_mtime(album)
    if newest and time.time() - newest < settle:
        return False

    print(f"importing {album}", flush=True)
    result = subprocess.run([beet, "import", "-m", "-q", str(album)])
    if result.returncode != 0:
        print(f"beet import failed with {result.returncode}: {album}", file=sys.stderr)
        return True

    if has_audio(album):
        print(f"beet import left audio in place: {album}", file=sys.stderr)
        return True

    remove_sidecars(album)
    prune(album, complete)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--complete", required=True, type=Path)
    parser.add_argument("--incomplete", required=True, type=Path)
    parser.add_argument("--beet", required=True)
    parser.add_argument("--settle", type=int, default=120)
    args = parser.parse_args()

    if not args.complete.is_dir():
        sys.exit(f"complete directory not found: {args.complete}")

    skip = {"incomplete", "downloads", args.incomplete.name}
    failed = False

    for entry in sorted(os.scandir(args.complete), key=lambda item: item.name):
        if entry.name.startswith(".") or entry.name in skip:
            continue
        if not entry.is_dir(follow_symlinks=False):
            continue

        top = Path(entry.path)
        if has_audio_directly(top):
            print(f"skip legacy {top}: audio directly under the user directory")
            continue

        directories = top / "directories"
        if not directories.is_dir():
            continue

        for album in sorted(album_roots(directories)):
            if incomplete_copy(args.complete, album, args.incomplete):
                print(f"skip incomplete {album}")
                continue
            failed = import_album(album, args.beet, args.complete, args.settle) or failed

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
