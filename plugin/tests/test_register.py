import os
import pytest
import tempfile

from mock import patch, MagicMock
from os.path import join

from direct.register import Register
from direct.directories import digest


@pytest.fixture
def register_directory():
    with patch('direct.register.directories') as directories:
        register_directory = tempfile.mkdtemp()
        directories.register_directory = register_directory
        directories.digest = digest
        yield register_directory


@pytest.mark.parametrize('src', ('file1', 'dir1'))
def test_yank(src, register_directory, directory):
    register = Register()
    register.yank([join(directory, src)])
    register_dst = join(register_directory, digest(join(directory, src)))
    with open(join(register_directory, 'content')) as content:
        assert content.read() == register_dst
    assert os.listdir(register_dst) == [src]


@patch('direct.register.History')
@pytest.mark.parametrize('src', ('file1', 'dir1'))
def test_paste(History, src, register_directory, directory):
    register = Register()
    register.yank([join(directory, src)])
    dst = tempfile.mkdtemp()

    history = MagicMock()
    History.return_value = history
    register.paste(dst)
    assert os.listdir(dst) == [src]
    (args, kwargs) = history.log.call_args
    (action, ) = args
    assert action.dst == dst
