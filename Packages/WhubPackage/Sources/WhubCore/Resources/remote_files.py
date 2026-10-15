"""Directory and text reads confined to a root, without following symlinks."""
from contextlib import contextmanager
import os
import re
import stat

MAX_TEXT_BYTES = 1024 * 1024


class FileError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


@contextmanager
def open_target(root, path, directory=False):
    if (not isinstance(root, str) or not root.startswith("/")
            or not isinstance(path, str) or path.startswith("/")
            or "\0" in root or "\0" in path
            or ".." in root.split("/") or ".." in path.split("/")):
        raise FileError(-32001, "閲覧ルートと相対パスが不正です。")
    parts = [part for part in (root + "/" + path).split("/") if part not in ("", ".")]
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(parts):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if directory or index < len(parts) - 1:
                flags |= os.O_DIRECTORY
            try:
                child = os.open(part, flags, dir_fd=fd)
            except OSError:
                # O_DIRECTORY can report ENOTDIR rather than ELOOP for a symlink.
                try:
                    is_link = stat.S_ISLNK(os.stat(part, dir_fd=fd, follow_symlinks=False).st_mode)
                except OSError:
                    is_link = False
                if is_link:
                    raise FileError(-32002, "シンボリックリンクは辿れません。") from None
                raise
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def list_directory(root, path=""):
    entries = []
    with open_target(root, path, directory=True) as fd, os.scandir(fd) as children:
        for child in children:
            if child.name in (".git", ".DS_Store"):
                continue
            try:
                mode = child.stat(follow_symlinks=False).st_mode
            except FileNotFoundError:
                continue  # A concurrent deletion is reflected on the next refresh.
            kind = ("symlink" if stat.S_ISLNK(mode) else
                    "directory" if stat.S_ISDIR(mode) else
                    "file" if stat.S_ISREG(mode) else "other")
            entries.append({"name": child.name, "kind": kind})
    return entries


def read_text(root, path):
    with open_target(root, path) as fd:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise FileError(-32003, "通常のファイルではありません。")
        if info.st_size > MAX_TEXT_BYTES:
            raise FileError(-32004, "本文が1 MiBの上限を超えています。")
        with os.fdopen(fd, "rb", closefd=False) as source:
            data = source.read(MAX_TEXT_BYTES + 1)
        if len(data) > MAX_TEXT_BYTES:
            raise FileError(-32004, "本文が1 MiBの上限を超えています。")
    # ponytail: control-byte heuristic; add format detection if printable binary formats matter.
    if re.search(rb"[\x00-\x08\x0b\x0e-\x1f\x7f]", data):
        raise FileError(-32006, "バイナリファイルは表示できません。")
    try:
        return {"text": data.decode("utf-8")}
    except UnicodeDecodeError:
        raise FileError(-32005, "UTF-8テキストとして読み込めません。") from None
