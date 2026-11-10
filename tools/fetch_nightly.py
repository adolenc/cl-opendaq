#!/usr/bin/env python3
"""
fetch_nightly.py - Download the pinned openDAQ bindings nightly.

The bindings are generated from, and run against, one release of the
opendaq-bindings-nightly repository: the API spec (opendaq.json) and the C
bindings libraries built from the same openDAQ commit.  Which release is
recorded in opendaq-nightly.lock; this script downloads it and verifies every
file against the checksums in the release's manifest.

Usage:
    python fetch_nightly.py                       # the spec only
    python fetch_nightly.py --natives linux-x64   # ... and the libraries for a platform
    python fetch_nightly.py --pin <tag>           # move the pin to another release first

Prints the path of the downloaded spec on stdout.  Files land in
<dest>/<tag>/ and are reused when their checksum still matches, so repeated
runs do not download anything.

Set OPENDAQ_NIGHTLY_BASE_URL (or pass --base-url) to fetch the release assets
from somewhere else, e.g. a file:// directory holding a locally built release.

Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / "opendaq-nightly.lock"
DEFAULT_DEST = ROOT / "tmp" / "nightly"
SUPPORTED_MANIFEST = "opendaq-bindings-nightly/1"
BASE_URL_ENV = "OPENDAQ_NIGHTLY_BASE_URL"


class FetchError(RuntimeError):
    pass


def read_lock(path: Path) -> dict:
    lock = json.loads(path.read_text(encoding="utf-8"))
    for key in ("repository", "tag"):
        if not lock.get(key):
            raise FetchError(f"{path}: missing '{key}'")
    return lock


def write_lock(path: Path, lock: dict) -> None:
    path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")


def release_url(lock: dict, base_url: str | None) -> str:
    url = base_url or os.environ.get(BASE_URL_ENV) or (
        f"https://github.com/{lock['repository']}/releases/download/{lock['tag']}/")
    return url if url.endswith("/") else url + "/"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "opendaq-bindings-fetch"})
    try:
        with urllib.request.urlopen(request) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
    except Exception as error:
        partial.unlink(missing_ok=True)
        raise FetchError(f"could not download {url}: {error}") from error
    partial.replace(target)


def fetch_asset(base: str, asset: dict, directory: Path) -> Path:
    """Download one manifest asset unless a copy with the right checksum is there."""
    target = directory / asset["file"]
    if target.exists() and sha256(target) == asset["sha256"]:
        return target
    download(base + asset["file"], target)
    actual = sha256(target)
    if actual != asset["sha256"]:
        target.unlink()
        raise FetchError(f"{asset['file']}: checksum {actual} does not match the manifest ({asset['sha256']})")
    return target


def fetch_manifest(lock: dict, base: str, directory: Path) -> dict:
    target = directory / "manifest.json"
    # The manifest is what the checksums come from, so it is always fetched anew.
    download(base + "manifest.json", target)
    manifest = json.loads(target.read_text(encoding="utf-8"))
    if manifest.get("schema") != SUPPORTED_MANIFEST:
        raise FetchError(f"manifest schema {manifest.get('schema')!r} is not supported (expected {SUPPORTED_MANIFEST!r})")
    if manifest.get("tag") != lock["tag"]:
        raise FetchError(f"manifest is for {manifest.get('tag')!r}, the lock pins {lock['tag']!r}")
    return manifest


def extract_natives(archive: Path, directory: Path) -> None:
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        tar.extractall(directory, filter="data")


def main() -> int:
    parser = argparse.ArgumentParser(description="Download the pinned openDAQ bindings nightly.")
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK, help="Lock file naming the release.")
    parser.add_argument("--dest", type=Path, default=DEFAULT_DEST, help="Directory to download into.")
    parser.add_argument("--natives", nargs="*", default=[], metavar="TRIPLE",
                        help="Also download and extract the native libraries for these platforms "
                             "(e.g. linux-x64); 'all' for every platform of the release.")
    parser.add_argument("--base-url", help=f"Fetch the assets from here instead of the GitHub release (also ${BASE_URL_ENV}).")
    parser.add_argument("--pin", metavar="TAG", help="Rewrite the lock to this release before fetching.")
    args = parser.parse_args()

    try:
        lock = read_lock(args.lock)
        if args.pin and args.pin != lock["tag"]:
            lock["tag"] = args.pin
        base = release_url(lock, args.base_url)
        directory = args.dest / lock["tag"]

        manifest = fetch_manifest(lock, base, directory)
        spec = fetch_asset(base, manifest["spec"], directory)

        triples = sorted(manifest["natives"]) if args.natives == ["all"] else args.natives
        for triple in triples:
            if triple not in manifest["natives"]:
                raise FetchError(f"release {lock['tag']} has no natives for {triple} "
                                 f"(available: {', '.join(sorted(manifest['natives']))})")
            archive = fetch_asset(base, manifest["natives"][triple], directory)
            extract_natives(archive, directory / "natives" / triple)

        # Only a release that could be fetched and verified gets pinned.
        if args.pin:
            write_lock(args.lock, lock)
    except FetchError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(spec)
    return 0


if __name__ == "__main__":
    sys.exit(main())
