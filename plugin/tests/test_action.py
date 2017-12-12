import pytest
import tempfile

from mock import patch

from direct.action import Move
from direct.action import Remove
from direct.action import RemoveDirectory
from direct.action import Restore
from direct.action import RestoreDirectory
from direct.action import Touch
from direct.action import MakeDirectory
from direct.action import reverse

from .utils import random_string


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
