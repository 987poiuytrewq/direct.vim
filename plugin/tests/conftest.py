import tempfile
import shutil
import os
import pytest


@pytest.fixture
def directory():
    os.environ['XDG_DATA_HOME'] = tempfile.mkdtemp()
    path = tempfile.mkdtemp()
    os.mkdir(os.path.join(path, 'dir1'))
    open(os.path.join(path, 'file1'), 'w').close()
    yield path
    shutil.rmtree(path)
