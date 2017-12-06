import shutil
import tempfile
import os

from contextlib import contextmanager

import vimmock
vimmock.patch_vim()
import vim  # noqa E402


@contextmanager
def example_dir():
    os.environ['XDG_DATA_HOME'] = tempfile.mkdtemp()
    path = tempfile.mkdtemp()
    os.mkdir(os.path.join(path, 'foo'))
    open(os.path.join(path, 'bar'), 'w').close()
    vim.eval = lambda _: '0'
    vim.command = lambda _: None
    from direct.buffer import Buffer  # noqa E402
    buffer = Buffer(path=path)
    yield buffer, path
    shutil.rmtree(path)


def test_list():
    with example_dir() as (buffer, path):
        buffer.list()
        assert vim.current.buffer[:] == ["foo/", "bar"]


def test_sync_add():
    with example_dir() as (buffer, path):
        sync(buffer, ["foo/", "bar", "baz"])
        assert vim.current.buffer[:] == ["foo/", "bar", "baz"]
        assert set(os.listdir(path)) == set(["foo", "bar", "baz"])
        assert os.path.isfile(os.path.join(path, "baz"))


def test_sync_add_directory():
    with example_dir() as (buffer, path):
        sync(buffer, ["foo/", "bar", "baz/"])
        assert vim.current.buffer[:] == ["baz/", "foo/", "bar"]
        assert set(os.listdir(path)) == set(["foo", "bar", "baz"])
        assert os.path.isdir(os.path.join(path, "baz"))


def test_sync_remove():
    with example_dir() as (buffer, path):
        sync(buffer, ["foo/"])
        assert vim.current.buffer[:] == ["foo/"]
        assert set(os.listdir(path)) == set(["foo"])


def test_sync_remove_directory():
    with example_dir() as (buffer, path):
        sync(buffer, ["bar"])
        assert vim.current.buffer[:] == ["bar"]
        assert set(os.listdir(path)) == set(["bar"])


def test_sync_rename():
    with example_dir() as (buffer, path):
        INODE = os.stat(os.path.join(path, "bar")).st_ino
        sync(buffer, ["foo/", "baz"])
        assert vim.current.buffer[:] == ["foo/", "baz"]
        assert set(os.listdir(path)) == set(["foo", "baz"])
        assert os.path.isfile(os.path.join(path, "baz"))
        assert os.stat(os.path.join(path, "baz")).st_ino == INODE


def test_sync_rename_directory():
    with example_dir() as (buffer, path):
        INODE = os.stat(os.path.join(path, "foo")).st_ino
        sync(buffer, ["baz/", "bar"])
        assert vim.current.buffer[:] == ["baz/", "bar"]
        assert set(os.listdir(path)) == set(["baz", "bar"])
        assert os.path.isdir(os.path.join(path, "baz"))
        assert os.stat(os.path.join(path, "baz")).st_ino == INODE


def sync(buffer, lines):
    buffer.list()
    vim.setup_text('\n'.join(lines))
    buffer.sync()
    buffer.list()
