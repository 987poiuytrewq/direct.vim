import os
import pytest
import tempfile
import shutil

from mock import patch
from os.path import isdir, isfile, join
from contextlib import contextmanager

from direct.action import Move
from direct.action import Remove
from direct.action import RemoveDirectory
from direct.action import Restore
from direct.action import RestoreDirectory
from direct.action import Touch
from direct.action import MakeDirectory
from direct.action import Paste
from direct.action import Unpaste
from direct.action import reverse
from direct.directories import digest

from .utils import random_string


@pytest.fixture
def trash_directory():
    with patch('direct.action.directories') as directories:
        trash_directory = tempfile.mkdtemp()
        directories.trash_directory = trash_directory
        directories.digest = digest
        yield trash_directory


def test_move_file(directory):
    inode = os.stat(join(directory, 'file1')).st_ino
    Move(join(directory, 'file1'), join(directory, 'file2')).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file2'])
    assert isfile(join(directory, 'file2'))
    assert os.stat(join(directory, 'file2')).st_ino == inode


def test_move_directory(directory):
    inode = os.stat(join(directory, 'dir1')).st_ino
    Move(join(directory, 'dir1'), join(directory, 'dir2')).do()
    assert set(os.listdir(directory)) == set(['dir2', 'file1'])
    assert isdir(join(directory, 'dir2'))
    assert os.stat(join(directory, 'dir2')).st_ino == inode


def test_remove(trash_directory, directory):
    inode = os.stat(join(directory, 'file1')).st_ino
    action = Remove(join(directory, 'file1'))
    action.do()
    assert set(os.listdir(directory)) == set(['dir1'])
    assert isfile(action.dst)
    assert os.stat(action.dst).st_ino == inode


def test_remove_directory(trash_directory, directory):
    dir_path = join(directory, 'dir1')
    inode = os.stat(join(dir_path, 'subfile1')).st_ino
    action = RemoveDirectory(join(directory, 'dir1'))
    action.do()
    assert set(os.listdir(directory)) == set(['file1'])
    assert isdir(action.dst)
    assert os.stat(join(action.dst, 'subfile1')).st_ino == inode


def test_restore(trash_directory, directory):
    inode = os.stat(join(directory, 'file1')).st_ino
    action = Remove(join(directory, 'file1'))
    action.do()
    Restore(action.dst, action.src).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file1'])
    assert isfile(join(directory, 'file1'))
    assert os.stat(join(directory, 'file1')).st_ino == inode


def test_restore_directory(trash_directory, directory):
    dir_path = join(directory, 'dir1')
    inode = os.stat(join(dir_path, 'subfile1')).st_ino
    action = RemoveDirectory(join(directory, 'dir1'))
    action.do()
    Restore(action.dst, action.src).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file1'])
    assert isdir(join(directory, 'dir1'))
    assert os.stat(join(dir_path, 'subfile1')).st_ino == inode


def test_touch(directory):
    Touch(join(directory, 'file2')).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file1', 'file2'])
    assert isfile(join(directory, 'file2'))


def test_make_directory(directory):
    MakeDirectory(join(directory, 'dir2')).do()
    assert set(os.listdir(directory)) == set(['dir1', 'dir2', 'file1'])
    assert isdir(join(directory, 'dir2'))


@contextmanager
def register():
    path = tempfile.mkdtemp()
    yield path
    shutil.rmtree(path)


def test_paste_file(directory):
    with register() as register_path:
        open(join(register_path, 'file2'), 'w').close()
        Paste(register_path, directory, ['file2'], ['file2']).do()
        assert set(os.listdir(directory)) == set(['dir1', 'file1', 'file2'])
        assert isfile(join(directory, 'file2'))


def test_paste_directory(directory):
    with register() as register_path:
        os.mkdir(join(register_path, 'dir2'))
        Paste(register_path, directory, ['dir2'], ['dir2']).do()
        assert set(os.listdir(directory)) == set(['dir1', 'dir2', 'file1'])
        assert isdir(join(directory, 'dir2'))


def test_unpaste_file(directory):
    with register() as register_path:
        open(join(register_path, 'file1'), 'w').close()
        Unpaste(directory, register_path, ['file1'], ['file1']).do()
        assert set(os.listdir(directory)) == set(['dir1'])


def test_unpaste_directory(directory):
    with register() as register_path:
        os.mkdir(join(register_path, 'dir1'))
        Unpaste(directory, register_path, ['dir1'], ['dir1']).do()
        assert set(os.listdir(directory)) == set(['file1'])


def test_paste_file_rename(directory):
    with register() as register_path:
        open(join(register_path, 'file1'), 'w').close()
        action = Paste(register_path, directory, ['file1'], ['file1'])
        with patch.object(action, '_get_input') as _get_input:
            _get_input.return_value = 'file1-renamed'
            action.do()
        assert set(os.listdir(directory)) == set([
            'dir1', 'file1', 'file1-renamed'
        ])
        assert isfile(join(directory, 'file1-renamed'))
        assert action.serialize(
        ) == '{name}{FS}{src}{FS}{dst}{FS}file1{FS}file1-renamed'.format(
            name=action.NAME,
            src=register_path,
            dst=directory,
            FS=action.FIELD_SEPARATOR
        )


def test_unpaste_file_rename(directory):
    with register() as register_path:
        open(join(register_path, 'file1'), 'w').close()
        open(join(directory, 'file1-renamed'), 'w').close()
        action = Unpaste(register_path, directory, ['file1-renamed'], ['file1'])
        assert isfile(join(directory, 'file1-renamed'))
        assert action.serialize(
        ) == '{name}{FS}{src}{FS}{dst}{FS}file1-renamed{FS}file1'.format(
            name=action.NAME,
            src=register_path,
            dst=directory,
            FS=action.FIELD_SEPARATOR
        )


def test_reverse_move():
    action = Move(random_string(), random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == Move
    assert reverse_action.src == action.dst
    assert reverse_action.dst == action.src


@pytest.mark.parametrize(('RemoveAction', 'RestoreAction'), (
    (Remove, Restore),
    (RemoveDirectory, RestoreDirectory),
))
def test_reverse_remove(trash_directory, RemoveAction, RestoreAction):
    action = RemoveAction(random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == RestoreAction
    assert reverse_action.src == action.dst
    assert reverse_action.dst == action.src


@pytest.mark.parametrize(('RestoreAction', 'RemoveAction'), (
    (Restore, Remove),
    (RestoreDirectory, RemoveDirectory),
))
def test_reverse_restore(trash_directory, RestoreAction, RemoveAction):
    action = RestoreAction(random_string(), random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == RemoveAction
    assert reverse_action.src == action.dst


@pytest.mark.parametrize(('CreateAction', 'RemoveAction'), (
    (Touch, Remove),
    (MakeDirectory, RemoveDirectory),
))
def test_reverse_create(trash_directory, CreateAction, RemoveAction):
    action = CreateAction(random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == RemoveAction
    assert reverse_action.src == action.dst


@pytest.mark.parametrize(('Action', 'ReverseAction'), (
    (Paste, Unpaste),
    (Unpaste, Paste),
))
def test_reverse_paste(Action, ReverseAction):
    src_name = random_string()
    dst_name = random_string()
    action = Action(random_string(), random_string(), [src_name], [dst_name])
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == ReverseAction
    assert reverse_action.src == action.dst
    assert reverse_action.dst == action.src
    assert action.renames == {src_name: dst_name}
    assert reverse_action.renames == {dst_name: src_name}
