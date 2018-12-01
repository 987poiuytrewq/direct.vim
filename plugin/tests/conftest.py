import tempfile
import shutil
import os
import pytest
import vimmock

vimmock.patch_vim()
import vim  # noqa: E402


@pytest.fixture(autouse=True)
def patch_vim():
    vim.buffers = []
    vim.current.buffer.name = ''
    vim.eval = lambda _: '0'
    vim.command = lambda _: None


@pytest.fixture
def directory():
    data = tempfile.mkdtemp()
    os.environ['XDG_DATA_HOME'] = data
    path = tempfile.mkdtemp()
    dir_path = os.path.join(path, 'dir1')
    os.mkdir(dir_path)
    open(os.path.join(path, 'file1'), 'w').close()
    open(os.path.join(dir_path, 'subfile1'), 'w').close()
    yield path
    shutil.rmtree(path)
    shutil.rmtree(data)
