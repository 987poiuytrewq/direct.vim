import tempfile
import shutil
import os
import pytest
import vimmock

from mock import patch

vimmock.patch_vim()
import vim  # noqa: E402

from direct.data import Local  # noqa: E402


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


@pytest.fixture
def trash_directory():
    with patch.object(Local, 'trash') as trash:
        tmpdir = tempfile.mkdtemp()
        trash.return_value = tmpdir
        yield tmpdir


@pytest.fixture
def register_directory():
    with patch.object(Local, 'register') as register:
        tmpdir = tempfile.mkdtemp()
        register.return_value = tmpdir
        yield tmpdir


@pytest.fixture
def history_directory():
    with patch.object(Local, 'history') as history:
        tmpdir = tempfile.mkdtemp()
        history.return_value = tmpdir
        yield tmpdir
