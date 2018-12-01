import os
import vim

from direct.buffer import Buffer  # noqa E402


def test_list(directory):
    Buffer(directory).list()
    assert vim.current.buffer[:] == ["dir1/", "file1"]


def test_sync_add(directory):
    sync(directory, ["dir1/", "file1", "file2"])
    assert vim.current.buffer[:] == ["dir1/", "file1", "file2"]
    assert set(os.listdir(directory)) == set(["dir1", "file1", "file2"])


def test_sync_add_directory(directory):
    sync(directory, ["dir1/", "file1", "dir2/"])
    assert vim.current.buffer[:] == ["dir1/", "dir2/", "file1"]
    assert set(os.listdir(directory)) == set(["dir1", "dir2", "file1"])


def test_sync_remove(directory):
    sync(directory, ["dir1/"])
    assert vim.current.buffer[:] == ["dir1/"]
    assert set(os.listdir(directory)) == set(["dir1"])


def test_sync_remove_directory(directory):
    sync(directory, ["file1"])
    assert vim.current.buffer[:] == ["file1"]
    assert set(os.listdir(directory)) == set(["file1"])


def test_sync_rename(directory):
    sync(directory, ["dir1/", "file2"])
    assert vim.current.buffer[:] == ["dir1/", "file2"]
    assert set(os.listdir(directory)) == set(["dir1", "file2"])


def test_sync_rename_directory(directory):
    sync(directory, ["dir2/", "file1"])
    assert vim.current.buffer[:] == ["dir2/", "file1"]
    assert set(os.listdir(directory)) == set(["dir2", "file1"])


def sync(directory, lines):
    buffer = Buffer(directory)
    buffer.list()
    vim.setup_text('\n'.join(lines))
    buffer.sync()
    buffer.list()
