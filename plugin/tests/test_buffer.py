import pytest
import os
import vimmock

vimmock.patch_vim()
import vim  # noqa: E402


@pytest.fixture
def buffer(directory):
    vim.eval = lambda _: '0'
    vim.command = lambda _: None
    from direct.buffer import Buffer  # noqa E402
    return Buffer(path=directory)


def test_list(directory, buffer):
    buffer.list()
    assert vim.current.buffer[:] == ["dir1/", "file1"]


def test_sync_add(directory, buffer):
    sync(buffer, ["dir1/", "file1", "file2"])
    assert vim.current.buffer[:] == ["dir1/", "file1", "file2"]
    assert set(os.listdir(directory)) == set(["dir1", "file1", "file2"])


def test_sync_add_directory(directory, buffer):
    sync(buffer, ["dir1/", "file1", "dir2/"])
    assert vim.current.buffer[:] == ["dir1/", "dir2/", "file1"]
    assert set(os.listdir(directory)) == set(["dir1", "dir2", "file1"])


def test_sync_remove(directory, buffer):
    sync(buffer, ["dir1/"])
    assert vim.current.buffer[:] == ["dir1/"]
    assert set(os.listdir(directory)) == set(["dir1"])


def test_sync_remove_directory(directory, buffer):
    sync(buffer, ["file1"])
    assert vim.current.buffer[:] == ["file1"]
    assert set(os.listdir(directory)) == set(["file1"])


def test_sync_rename(directory, buffer):
    sync(buffer, ["dir1/", "file2"])
    assert vim.current.buffer[:] == ["dir1/", "file2"]
    assert set(os.listdir(directory)) == set(["dir1", "file2"])


def test_sync_rename_directory(directory, buffer):
    sync(buffer, ["dir2/", "file1"])
    assert vim.current.buffer[:] == ["dir2/", "file1"]
    assert set(os.listdir(directory)) == set(["dir2", "file1"])


def sync(buffer, lines):
    buffer.list()
    vim.setup_text('\n'.join(lines))
    buffer.sync()
    buffer.list()
