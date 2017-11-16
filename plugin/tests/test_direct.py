import shutil
import tempfile
import os

from contextlib import contextmanager

import vimmock
vimmock.patch_vim()
import vim  # noqa E402

from direct.buffer import DirectBuffer  # noqa E402


@contextmanager
def test_dir():
    root = tempfile.mkdtemp()
    for filename in ('foo', 'bar'):
        open(os.path.join(root, filename), 'w').close()
    for dirname in ('baz', 'qux'):
        os.mkdir(os.path.join(root, dirname))
    yield root
    shutil.rmtree(root)


def test_list():
    with test_dir() as root:
        DirectBuffer(root=root).list()
        assert vim.current.buffer[:] == ["bar/", "foo/", "baz", "qux"]


def test_sync_add():
    with test_dir() as root:
        sync(root, ["bar/", "foo/", "baz", "qux", "quux"])
        assert vim.current.buffer[:] == ["bar/", "foo/", "baz", "qux", "quux"]
        assert set(os.listdir(root)) == set([
            "bar", "foo", "baz", "qux", "quux"
        ])
        assert os.path.isfile(os.path.join(root, "quux"))


def test_sync_add_directory():
    with test_dir() as root:
        sync(root, ["bar/", "foo/", "quux/", "baz", "qux"])
        assert vim.current.buffer[:] == ["bar/", "foo/", "quux/", "baz", "qux"]
        assert set(os.listdir(root)) == set([
            "bar", "foo", "baz", "qux", "quux"
        ])
        assert os.path.isdir(os.path.join(root, "quux"))


def test_sync_remove():
    with test_dir() as root:
        sync(root, ["bar/", "foo/", "baz"])
        assert vim.current.buffer[:] == ["bar/", "foo/", "baz"]
        assert set(os.listdir(root)) == set(["bar", "foo", "baz"])


def test_sync_remove_directory():
    with test_dir() as root:
        sync(root, ["foo/", "baz", "qux"])
        assert vim.current.buffer[:] == ["bar/", "baz", "qux"]
        assert set(os.listdir(root)) == set(["bar", "baz", "qux"])


def test_sync_rename():
    with test_dir() as root:
        sync(root, ["bar/", "foo/", "baz", "quux"])
        assert vim.current.buffer[:] == ["bar/", "foo/", "baz", "quux"]
        assert set(os.listdir(root)) == set(["bar", "foo", "baz", "quux"])
        assert os.path.isfile(os.path.join(root, "quux"))


def test_sync_rename_directory():
    with test_dir() as root:
        sync(root, ["bar/", "quux/", "baz", "qux"])
        assert vim.current.buffer[:] == ["bar/", "quux/", "baz", "qux"]
        assert set(os.listdir(root)) == set(["bar", "foo", "baz", "quux"])
        assert os.path.isdir(os.path.join(root, "quux"))


def sync(root, lines):
    buffer = DirectBuffer(root=root)
    buffer.list()
    vim.setup_text('\n'.join(lines))
    buffer.sync()
