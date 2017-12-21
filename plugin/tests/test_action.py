import os
import pytest
import tempfile

from mock import patch
from os.path import isdir, isfile, join

from direct.action import Move
from direct.action import Remove
from direct.action import RemoveDirectory
from direct.action import Restore
from direct.action import RestoreDirectory
from direct.action import Touch
from direct.action import MakeDirectory
from direct.action import reverse

from .utils import random_string


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


def test_remove(directory):
    inode = os.stat(join(directory, 'file1')).st_ino
    action = Remove(join(directory, 'file1'))
    action.do()
    assert set(os.listdir(directory)) == set(['dir1'])
    assert isfile(action.dst)
    assert os.stat(action.dst).st_ino == inode


def test_remove_directory(directory):
    inode = os.stat(join(directory, 'dir1')).st_ino
    action = RemoveDirectory(join(directory, 'dir1'))
    action.do()
    assert set(os.listdir(directory)) == set(['file1'])
    assert isdir(action.dst)
    assert os.stat(action.dst).st_ino == inode


def test_restore(directory):
    inode = os.stat(join(directory, 'file1')).st_ino
    action = Remove(join(directory, 'file1'))
    action.do()
    Restore(action.dst, action.src).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file1'])
    assert isfile(join(directory, 'file1'))
    assert os.stat(join(directory, 'file1')).st_ino == inode


def test_restore_directory(directory):
    inode = os.stat(join(directory, 'dir1')).st_ino
    action = RemoveDirectory(join(directory, 'dir1'))
    action.do()
    Restore(action.dst, action.src).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file1'])
    assert isdir(join(directory, 'dir1'))
    assert os.stat(join(directory, 'dir1')).st_ino == inode


def test_touch(directory):
    Touch(join(directory, 'file2')).do()
    assert set(os.listdir(directory)) == set(['dir1', 'file1', 'file2'])
    assert isfile(join(directory, 'file2'))


def test_make_directory(directory):
    MakeDirectory(join(directory, 'dir2')).do()
    assert set(os.listdir(directory)) == set(['dir1', 'dir2', 'file1'])
    assert isdir(join(directory, 'dir2'))


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
@patch('direct.action.directories')
def test_reverse_remove(directories, RemoveAction, RestoreAction):
    directories.trash_directory = tempfile.mkdtemp()
    action = RemoveAction(random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == RestoreAction
    assert reverse_action.src == action.dst
    assert reverse_action.dst == action.src


@pytest.mark.parametrize(('RestoreAction', 'RemoveAction'), (
    (Restore, Remove),
    (RestoreDirectory, RemoveDirectory),
))
@patch('direct.action.directories')
def test_reverse_restore(directories, RestoreAction, RemoveAction):
    directories.trash_directory = tempfile.mkdtemp()
    action = RestoreAction(random_string(), random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == RemoveAction
    assert reverse_action.src == action.dst


@pytest.mark.parametrize(('CreateAction', 'RemoveAction'), (
    (Touch, Remove),
    (MakeDirectory, RemoveDirectory),
))
@patch('direct.action.directories')
def test_reverse_create(directories, CreateAction, RemoveAction):
    directories.trash_directory = tempfile.mkdtemp()
    action = CreateAction(random_string())
    reverse_action = reverse(action.serialize().strip())
    assert reverse_action.__class__ == RemoveAction
    assert reverse_action.src == action.dst
