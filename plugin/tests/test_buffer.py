import shutil
import tempfile
import os

from contextlib import contextmanager

import vimmock
vimmock.patch_vim()
import vim  # noqa E402

from direct.buffer import DirectBuffer  # noqa E402


@contextmanager
def example_dir():
    root = tempfile.mkdtemp()
    os.mkdir(os.path.join(root, 'foo'))
    open(os.path.join(root, 'bar'), 'w').close()
    yield root
    shutil.rmtree(root)


def test_list():
    with example_dir() as root:
        DirectBuffer(root=root).list()
        assert vim.current.buffer[:] == ["foo/", "bar"]


def test_sync_add():
    with example_dir() as root:
        sync(root, ["foo/", "bar", "baz"])
        assert vim.current.buffer[:] == ["foo/", "bar", "baz"]
        assert set(os.listdir(root)) == set(["foo", "bar", "baz"])
        assert os.path.isfile(os.path.join(root, "baz"))


def test_sync_add_directory():
    with example_dir() as root:
        sync(root, ["foo/", "bar", "baz/"])
        assert vim.current.buffer[:] == ["baz/", "foo/", "bar"]
        assert set(os.listdir(root)) == set(["foo", "bar", "baz"])
        assert os.path.isdir(os.path.join(root, "baz"))


def test_sync_remove():
    with example_dir() as root:
        sync(root, ["foo/"])
        assert vim.current.buffer[:] == ["foo/"]
        assert set(os.listdir(root)) == set(["foo"])


# def test_sync_remove_directory():
#     with example_dir() as root:
#         sync(root, ["bar"])
#         assert vim.current.buffer[:] == ["bar"]
#         assert set(os.listdir(root)) == set(["bar"])


def test_sync_rename():
    with example_dir() as root:
        INODE = os.stat(os.path.join(root, "bar")).st_ino
        sync(root, ["foo/", "baz"])
        assert vim.current.buffer[:] == ["foo/", "baz"]
        assert set(os.listdir(root)) == set(["foo", "baz"])
        assert os.path.isfile(os.path.join(root, "baz"))
        assert os.stat(os.path.join(root, "baz")).st_ino == INODE


def test_sync_rename_directory():
    with example_dir() as root:
        INODE = os.stat(os.path.join(root, "foo")).st_ino
        sync(root, ["baz/", "bar"])
        assert vim.current.buffer[:] == ["baz/", "bar"]
        assert set(os.listdir(root)) == set(["baz", "bar"])
        assert os.path.isdir(os.path.join(root, "baz"))
        assert os.stat(os.path.join(root, "baz")).st_ino == INODE


def sync(root, lines):
    buffer = DirectBuffer(root=root)
    buffer.list()
    vim.setup_text('\n'.join(lines))
    buffer.sync()
    DirectBuffer(root=root).list()
