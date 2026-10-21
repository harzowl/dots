#!/usr/bin/env python3
"""Import completed downloads into beets.

Each `--complete`/`--incomplete` pair names one download source. slskd mirrors
each peer's path below `<user>/directories`, and incomplete downloads below the
incomplete tree, where the `directories` segment is absent. The importer walks
every completed tree, finds the directories that hold an album, and hands
settled albums to `beet import`. With `--top-level-albums`, a top-level
directory without that segment is an album root too: an album staged there by
another tool, a legacy flat download, or a torrent client's completed album.

An album is attempted at most once: every outcome (imported, duplicate/skip or
error) is recorded in a `.slskd-imported` marker inside the album directory, and
a marked album is never handed to beets again. A successful import removes the
sidecars and prunes the emptied directories; a duplicate or failed import is
left in place. Audio is never deleted. Only an unusable complete root or a
missing `beet` makes the run fail; per-album problems are logged and skipped.

With `--stale-after`, an incomplete tree whose newest file is older than the
given age is removed, as is a completed album already marked duplicate or
error. An album still waiting to be imported is never removed.

With `--qbt-url`, an album that reached the library also removes the matching
torrent from qBittorrent. The torrent's files are never deleted.
"""

import argparse
import http.cookiejar
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

MARKER_NAME = ".slskd-imported"

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
    return list(os.scandir(path))


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


def marker_outcome(album):
    try:
        record = json.loads((album / MARKER_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "handled"
    return record.get("outcome", "handled")


def write_marker(album, outcome, detail=None):
    marker = album / MARKER_NAME
    record = {
        "outcome": outcome,
        "time": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }
    if detail:
        record["detail"] = detail

    temporary = marker.with_name(f"{MARKER_NAME}.tmp")
    try:
        temporary.write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, marker)
    except OSError as error:
        print(f"could not write {marker}: {error}", file=sys.stderr)
        try:
            temporary.unlink()
        except OSError:
            pass


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


def remove_tree(path):
    try:
        shutil.rmtree(path)
        print(f"removed stale {path}")
    except OSError as error:
        print(f"could not remove stale {path}: {error}", file=sys.stderr)


def prune_empty(root):
    for dirpath, dirnames, filenames in os.walk(root, topdown=False, followlinks=False):
        path = Path(dirpath)
        if path == root or filenames:
            continue
        try:
            path.rmdir()
        except OSError:
            pass


def clean_stale(complete, incomplete, max_age):
    if max_age <= 0:
        return

    now = time.time()
    for root, marked_only in ((incomplete, False), (complete, True)):
        for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
            path = Path(dirpath)
            if path == root:
                continue
            if marked_only and not (path / MARKER_NAME).exists():
                continue
            newest = newest_mtime(path)
            if newest and now - newest > max_age:
                remove_tree(path)
                dirnames[:] = []


def map_remote_path(path, mappings):
    text = str(path)
    best = None
    for remote, local in mappings:
        prefix = remote.rstrip("/")
        if text == prefix or text.startswith(prefix + "/"):
            if best is None or len(prefix) > len(best[0]):
                best = (prefix, local.rstrip("/"))
    if best is None:
        return Path(text)
    prefix, local = best
    return Path(local + text[len(prefix):])


def is_under(path, root):
    return path == root or path.is_relative_to(root)


def torrent_matches(album, content_path, mappings):
    if not content_path:
        return False
    content = Path(content_path)
    mapped = map_remote_path(content, mappings)
    return mapped == album or mapped.parent == album or content.name == album.name


def remove_torrents(albums, url, username, password, mappings):
    if not albums:
        return

    base = url.rstrip("/")
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    login = urllib.parse.urlencode({"username": username, "password": password}).encode()
    request = urllib.request.Request(f"{base}/api/v2/auth/login", data=login)
    try:
        with opener.open(request, timeout=15) as response:
            if response.read().decode().strip() != "Ok.":
                print("qBittorrent login failed", file=sys.stderr)
                return
        with opener.open(f"{base}/api/v2/torrents/info", timeout=15) as response:
            torrents = json.load(response)
    except (OSError, ValueError) as error:
        print(f"qBittorrent request failed: {error}", file=sys.stderr)
        return

    roots = [Path(local) for _, local in mappings]
    hashes = []
    for album in albums:
        if roots and not any(is_under(album, root) for root in roots):
            continue
        matches = [
            torrent
            for torrent in torrents
            if torrent_matches(album, torrent.get("content_path"), mappings)
        ]
        if not matches:
            print(f"no torrent matched {album}")
            continue
        for torrent in matches:
            hashes.append(torrent["hash"])
            print(f"remove torrent {torrent['name']!r} for {album}")

    unique = list(dict.fromkeys(hashes))
    if not unique:
        return

    body = urllib.parse.urlencode({"hashes": "|".join(unique), "deleteFiles": "false"}).encode()
    request = urllib.request.Request(f"{base}/api/v2/torrents/delete", data=body)
    try:
        with opener.open(request, timeout=15) as response:
            response.read()
    except OSError as error:
        print(f"could not remove qBittorrent torrents: {error}", file=sys.stderr)


def import_album(album, beet, complete, settle):
    if (album / MARKER_NAME).exists():
        print(f"skip {album}: already handled ({marker_outcome(album)})")
        return False

    newest = newest_mtime(album)
    if newest and time.time() - newest < settle:
        return False

    print(f"importing {album}", flush=True)
    result = subprocess.run([beet, "import", "-m", "-q", str(album)])
    if result.returncode != 0:
        print(f"beet import failed with {result.returncode}: {album}", file=sys.stderr)
        write_marker(album, "error", f"beet exit {result.returncode}")
        return False

    if has_audio(album):
        print(
            f"beet import left audio in place (duplicate or skipped): {album}",
            file=sys.stderr,
        )
        write_marker(album, "duplicate", "audio left in place")
        return True

    write_marker(album, "imported")
    remove_sidecars(album)
    try:
        (album / MARKER_NAME).unlink()
    except OSError as error:
        print(f"could not remove {album / MARKER_NAME}: {error}", file=sys.stderr)
    prune(album, complete)
    return True


def scan_source(complete, incomplete, beet, settle, top_level_albums, skip):
    handled = []
    try:
        top_entries = sorted(os.scandir(complete), key=lambda item: item.name)
    except OSError as error:
        sys.exit(f"complete directory is unreadable: {complete}: {error}")

    for entry in top_entries:
        if entry.name.startswith(".") or entry.name in skip:
            continue
        if not entry.is_dir(follow_symlinks=False):
            continue

        top = Path(entry.path)
        try:
            directories = top / "directories"
            if directories.is_dir():
                roots = sorted(album_roots(directories))
            elif top_level_albums:
                roots = sorted(album_roots(top))
            elif has_audio_directly(top):
                print(f"skip legacy {top}: audio directly under the user directory")
                continue
            else:
                continue
        except OSError as error:
            print(f"skip unreadable {top}: {error}", file=sys.stderr)
            continue

        for album in roots:
            try:
                if incomplete_copy(complete, album, incomplete):
                    print(f"skip incomplete {album}")
                    continue
                if import_album(album, beet, complete, settle):
                    handled.append(album)
            except OSError as error:
                print(f"skip {album}: {error}", file=sys.stderr)
                write_marker(album, "error", str(error))

    return handled


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--complete",
        required=True,
        action="append",
        type=Path,
        help="completed-download root; repeat with --incomplete for each source",
    )
    parser.add_argument(
        "--incomplete",
        required=True,
        action="append",
        type=Path,
        help="incomplete-download root matching the preceding --complete",
    )
    parser.add_argument("--beet", required=True)
    parser.add_argument("--settle", type=int, default=120)
    parser.add_argument("--top-level-albums", action="store_true")
    parser.add_argument("--stale-after", type=int, default=0)
    parser.add_argument("--qbt-url")
    parser.add_argument("--qbt-username", default="admin")
    parser.add_argument("--qbt-password-file")
    parser.add_argument("--qbt-path-remote", action="append", default=[])
    parser.add_argument("--qbt-path-local", action="append", default=[])
    args = parser.parse_args()

    if len(args.complete) != len(args.incomplete):
        sys.exit("--complete and --incomplete must be supplied in pairs")
    if len(args.qbt_path_remote) != len(args.qbt_path_local):
        sys.exit("--qbt-path-remote and --qbt-path-local must be supplied in pairs")
    if bool(args.qbt_url) != bool(args.qbt_password_file):
        sys.exit("--qbt-url and --qbt-password-file must be supplied together")

    sources = list(zip(args.complete, args.incomplete))
    for complete, _ in sources:
        if not complete.is_dir():
            sys.exit(f"complete directory not found: {complete}")
    if not os.path.isfile(args.beet) or not os.access(args.beet, os.X_OK):
        sys.exit(f"beet is not executable: {args.beet}")

    skip = {"incomplete", "downloads"} | {incomplete.name for _, incomplete in sources}

    handled = []
    for complete, incomplete in sources:
        clean_stale(complete, incomplete, args.stale_after)
        handled.extend(
            scan_source(complete, incomplete, args.beet, args.settle, args.top_level_albums, skip)
        )
        prune_empty(complete)
        prune_empty(incomplete)

    if args.qbt_url:
        try:
            password = Path(args.qbt_password_file).read_text(encoding="utf-8").strip()
        except OSError as error:
            print(f"could not read qBittorrent password: {error}", file=sys.stderr)
        else:
            remove_torrents(
                handled,
                args.qbt_url,
                args.qbt_username,
                password,
                list(zip(args.qbt_path_remote, args.qbt_path_local)),
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
