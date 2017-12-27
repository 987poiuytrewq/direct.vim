import tempfile
import shutil
import os
import pytest


@pytest.fixture
def directory():
    os.environ['XDG_DATA_HOME'] = tempfile.mkdtemp()
    path = tempfile.mkdtemp()
    dir_path =os.path.join(path, 'dir1') 
    os.mkdir(dir_path)
    open(os.path.join(path, 'file1'), 'w').close()
    open(os.path.join(dir_path, 'subfile1'), 'w').close()
    yield path
    shutil.rmtree(path)
