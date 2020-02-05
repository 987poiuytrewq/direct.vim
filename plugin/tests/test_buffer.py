import os
import vim
import pytest

from direct.buffer import Buffer
from .utils import sync


def test_list(directory):
    Buffer(directory).list()
    assert vim.current.buffer[:] == ["dir1/", "file1"]


@pytest.mark.parametrize(
    'lines', [
        ["dir1/", "file1", "file2"],
        ["dir1/", "dir2/", "file1"],
        ["dir1/"],
        ["file1"],
        ["dir1/", "file2"],
        ["dir2/", "file1"],
    ]
)
def test_sync(lines, directory):
    sync(directory, lines)
    assert vim.current.buffer[:] == lines
    assert set(os.listdir(directory)) == set(
        (line.replace('/', '') for line in lines)
    )


def test_current_entry_file(directory):
    vim.current.buffer.name = 'file1'
    buffer = Buffer(directory)
    assert buffer.current_entry == os.path.join(directory, 'file1')


def test_current_entry_directory(directory):
    vim.current.buffer.name = 'dir1/'
    buffer = Buffer(directory)
    assert buffer.current_entry == os.path.join(directory, 'dir1/')


def test_current_entry_none(directory):
    vim.current.buffer.name = 'foo'
    buffer = Buffer(directory)
    assert buffer.current_entry is None
