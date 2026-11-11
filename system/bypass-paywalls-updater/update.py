#!/usr/bin/python3
"""Update an unpacked Bypass Paywalls Clean folder on macOS or Windows."""

import argparse
import base64
import contextlib
import datetime
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

WINDOWS = sys.platform == "win32"
if WINDOWS:
    import msvcrt
else:
    import fcntl


SOURCE = (
    "https://gitflic.ru/project/magnolia1234/bpc_uploads/blob/raw"
    "?file=bypass-paywalls-chrome-clean-master.zip"
)
ROOT = "bypass-paywalls-chrome-clean-master"
KEY_SHA256 = "ba1412962ce186f45505ae3ed2755e2b60ee781a639c7f1c2281467d09ab48ed"
DEFAULT_STATE = (
    Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "Bypass Paywalls Updater"
    if WINDOWS else
    Path.home() / "Library/Application Support/Bypass Paywalls Updater"
)
DEFAULT_TARGET = DEFAULT_STATE / "extension"
MAX_DOWNLOAD = 16 * 1024 * 1024
MAX_EXTRACTED = 32 * 1024 * 1024


def log(message):
    print(f"{datetime.datetime.now().astimezone().isoformat(timespec='seconds')} {message}",
          flush=True)


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", value):
        raise ValueError(f"Invalid extension version: {value!r}")
    parts = tuple(map(int, value.split(".")))
    if any(n > 65535 for n in parts) or not any(parts):
        raise ValueError(f"Invalid extension version: {value!r}")
    return parts + (0,) * (4 - len(parts))


def read_manifest(folder):
    data = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    if data.get("name") != "Bypass Paywalls Clean" or data.get("manifest_version") != 3:
        raise ValueError("Package is not Bypass Paywalls Clean Manifest V3")
    key = base64.b64decode(data.get("key", ""), validate=True)
    if hashlib.sha256(key).hexdigest() != KEY_SHA256:
        raise ValueError("Extension public key differs from the original installation")
    version(data.get("version"))
    return data


def unpack(archive, destination):
    """Reject unsafe ZIP paths, special files, duplicates and oversized packages."""
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if len(entries) > 2000 or sum(e.file_size for e in entries) > MAX_EXTRACTED:
            raise ValueError("Extension ZIP exceeds extraction limits")
        seen = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if (path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                    or any(unsafe_component(part) for part in path.parts)
                    or not path.parts or path.parts[0] != ROOT):
                raise ValueError(f"Unsafe ZIP path: {entry.filename!r}")
            normalized = str(path).casefold()
            if normalized in seen:
                raise ValueError(f"Duplicate ZIP path: {entry.filename!r}")
            seen.add(normalized)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"Special file in ZIP: {entry.filename!r}")
            target = destination.joinpath(*path.parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.open(entry) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o644)
    folder = destination / ROOT
    manifest = read_manifest(folder)
    required = [manifest.get("background", {}).get("service_worker"), "sites.js"]
    required.extend(manifest.get("icons", {}).values())
    required.append(manifest.get("options_ui", {}).get("page"))
    for content in manifest.get("content_scripts", []):
        required.extend(content.get("js", []) + content.get("css", []))
    for filename in required:
        if (not filename or PurePosixPath(filename).is_absolute()
                or "\\" in filename
                or ".." in PurePosixPath(filename).parts
                or any(unsafe_component(part) for part in PurePosixPath(filename).parts)
                or not (folder / filename).is_file()):
            raise ValueError(f"Missing or invalid extension resource: {filename!r}")
    return folder, manifest


def unsafe_component(part):
    # Apply Windows rules on both platforms, including alternate data streams
    # and device names. The same upstream archive must be safe on either OS.
    return (bool(re.search(r'[\x00-\x1f<>:"|?*]', part)) or part.endswith((".", " "))
            or bool(re.fullmatch(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?",
                                 part, re.IGNORECASE)))


def download(destination):
    curl = (str(Path(os.environ["SystemRoot"]) / "System32/curl.exe")
            if WINDOWS else "/usr/bin/curl")
    result = subprocess.run([
        curl, "--fail", "--location", "--silent", "--show-error",
        "--proto", "=https", "--proto-redir", "=https",
        "--connect-timeout", "15", "--max-time", "60",
        "--retry", "2", "--retry-max-time", "120",
        "--max-filesize", str(MAX_DOWNLOAD), "--output", str(destination), SOURCE,
    ], capture_output=True, text=True,
        creationflags=subprocess.CREATE_NO_WINDOW if WINDOWS else 0)
    if result.returncode:
        if result.stderr:
            log(result.stderr.strip())
        result.check_returncode()
    if destination.stat().st_size > MAX_DOWNLOAD:
        raise ValueError("Extension ZIP exceeds download limit")


def install(staged, target, state, current_version):
    """Back up first; restore the original folder if replacement fails."""
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = state / "backups" / f"{current_version}-{stamp}"
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(target, backup, symlinks=True)
    previous = staged.parent / "previous"
    target.rename(previous)
    try:
        staged.rename(target)
    except BaseException:
        previous.rename(target)
        raise
    log(f"Backup: {backup}")
    return backup


@contextlib.contextmanager
def locked(state):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / "update.lock").open("a+b") as lock:
        if WINDOWS:
            if lock.seek(0, os.SEEK_END) == 0:
                lock.write(b"\0")
                lock.flush()
            lock.seek(0)
        try:
            if WINDOWS:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                raise
            log("Another updater is running; skipped")
            yield False
            return
        try:
            yield True
        finally:
            if WINDOWS:
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)


def run(target, state, check=False, initialize=False):
    if target.is_symlink() or (not target.is_dir() and not (initialize and not target.exists())):
        raise ValueError(f"Extension directory is missing or is a symlink: {target}")
    target = target.resolve()
    with locked(state) as acquired:
        if not acquired:
            return
        current = read_manifest(target) if target.exists() else None
        if initialize:
            target.parent.mkdir(parents=True, exist_ok=True)
        # Staging beside the target keeps the final renames on one filesystem.
        with tempfile.TemporaryDirectory(prefix=".bpc-update-", dir=target.parent) as temp:
            workspace = Path(temp)
            archive = workspace / "extension.zip"
            download(archive)
            staged, latest = unpack(archive, workspace / "unpacked")
            old, new = current["version"] if current else None, latest["version"]
            if old and version(new) < version(old):
                raise ValueError(f"Refusing upstream downgrade: {old} -> {new}")
            if old and version(new) == version(old):
                log(f"Already current: {old}")
                return
            if check:
                log(f"Update available: {old} -> {new}; extension folder unchanged")
                return
            # Also catches a concurrent manual replacement while downloading.
            if (read_manifest(target) if target.exists() else None) != current:
                raise ValueError("Installed manifest changed during download; retry later")
            if current:
                backup = install(staged, target, state, old)
            else:
                staged.rename(target)
                backup = None
            record = state / "last-update.json"
            pending = record.with_suffix(".tmp")
            pending.write_text(json.dumps({
                "updated_at": datetime.datetime.now().astimezone().isoformat(),
                "previous_version": old, "version": new, "target": str(target),
                "backup": str(backup) if backup else None, "source": SOURCE,
                "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            }, indent=2) + "\n", encoding="utf-8")
            pending.replace(record)
            action = f"Updated {old} -> {new}" if old else f"Installed {new}"
            log(f"{action}. Reload the extension or restart Chrome to activate.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension-dir", type=Path, default=DEFAULT_TARGET)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--check", action="store_true", help="Validate the download without installing")
    parser.add_argument("--initialize", action="store_true", help="Allow a fresh installation from upstream")
    parser.add_argument("--log-file", type=Path, help="Append output to this local log file")
    args = parser.parse_args()
    with contextlib.ExitStack() as stack:
        if args.log_file:
            args.log_file.parent.mkdir(parents=True, exist_ok=True)
            output = stack.enter_context(args.log_file.open("a", encoding="utf-8", buffering=1))
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(contextlib.redirect_stderr(output))
        try:
            run(args.extension_dir.expanduser(), args.state_dir.expanduser().resolve(),
                args.check, args.initialize)
        except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
            log(f"ERROR: {error}")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
