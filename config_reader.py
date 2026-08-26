#!/usr/bin/env python3

import json
import os
import stat
import sys


class UnsafeInput(Exception):
    pass


OPEN_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
OVERRIDE_LIMIT = 16 * 1024
CONFIG_LIMIT = 8 * 1024 * 1024
MAX_CONFIG_FILES = 256
MAX_DIRECTORY_ENTRIES = 1024


def open_path(path, *, dir_fd=None):
    try:
        return os.open(path, OPEN_FLAGS, dir_fd=dir_fd)
    except (OSError, TypeError, ValueError) as error:
        raise UnsafeInput from error


def read_regular(path, limit, *, dir_fd=None):
    fd = open_path(path, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise UnsafeInput

        chunks = []
        remaining = limit + 1
        while remaining > 0:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > limit:
            raise UnsafeInput
        return data, info
    except OSError as error:
        raise UnsafeInput from error
    finally:
        os.close(fd)


def directory_names(path, max_files):
    fd = open_path(path)
    try:
        if not stat.S_ISDIR(os.fstat(fd).st_mode):
            raise UnsafeInput

        names = []
        scanned = 0
        with os.scandir(fd) as entries:
            for entry in entries:
                scanned += 1
                if scanned > MAX_DIRECTORY_ENTRIES:
                    raise UnsafeInput
                if entry.name.endswith(".json"):
                    names.append(entry.name)
                    if len(names) > max_files:
                        raise UnsafeInput
        return fd, sorted(names)
    except (OSError, TypeError, ValueError) as error:
        os.close(fd)
        raise UnsafeInput from error
    except Exception:
        os.close(fd)
        raise


def merged_clash_api(specs, total_limit, max_files):
    experimental = None
    seen_experimental = False
    total = 0
    count = 0

    def consume(path, dir_fd=None):
        nonlocal experimental, seen_experimental, total, count
        count += 1
        if count > max_files:
            raise UnsafeInput
        data, _ = read_regular(path, total_limit - total, dir_fd=dir_fd)
        total += len(data)
        try:
            payload = json.loads(data.decode("utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise UnsafeInput from error
        if not isinstance(payload, dict):
            raise UnsafeInput
        if "experimental" in payload:
            experimental = deep_merge(experimental, payload["experimental"]) \
                if seen_experimental else payload["experimental"]
            seen_experimental = True

    for spec in specs:
        kind, separator, path = spec.partition(":")
        if not separator or kind not in ("file", "dir") or not path:
            raise UnsafeInput
        if kind == "file":
            consume(path)
            continue

        dir_fd, names = directory_names(path, max_files - count)
        try:
            for name in names:
                consume(name, dir_fd=dir_fd)
        finally:
            os.close(dir_fd)

    api = experimental.get("clash_api") \
        if isinstance(experimental, dict) else None
    return {"experimental": {"clash_api": api}}


def deep_merge(left, right):
    if not isinstance(left, dict) or not isinstance(right, dict):
        return right
    merged = dict(left)
    for key, value in right.items():
        merged[key] = deep_merge(merged[key], value) if key in merged else value
    return merged


def print_stat(path):
    fd = open_path(path)
    try:
        info = os.fstat(fd)
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise UnsafeInput
        print(f"size={info.st_size}")
        print(f"mtime={int(info.st_mtime)}")
        print("readable=1")
    finally:
        os.close(fd)


def main(argv):
    try:
        mode = argv[1]
        if mode == "read" and len(argv) == 3:
            data, _ = read_regular(argv[2], OVERRIDE_LIMIT)
            sys.stdout.buffer.write(data)
        elif mode == "config" and len(argv) >= 2:
            result = merged_clash_api(argv[2:], CONFIG_LIMIT, MAX_CONFIG_FILES)
            sys.stdout.write(json.dumps(result, separators=(",", ":")))
        elif mode == "stat" and len(argv) == 3:
            print_stat(argv[2])
        else:
            raise UnsafeInput
    except (IndexError, MemoryError, OSError, RecursionError, UnsafeInput):
        if len(argv) > 1 and argv[1] == "config":
            sys.stdout.write("{}")


if __name__ == "__main__":
    main(sys.argv)
