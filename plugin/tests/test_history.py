import os
import pytest

from mock import patch

from direct.action import Action
from direct.history import History
from direct.register import Register
from .utils import sync

INITIAL_CONTENT = ["dir1", "file1"]


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
def test_action_undo_redo(lines, directory, history_directory):
    sync(directory, lines)
    history = History()
    history.undo()
    assert set(os.listdir(directory)) == set(INITIAL_CONTENT)
    history.redo()
    assert set(os.listdir(directory)) == set(
        (line.replace('/', '') for line in lines)
    )


def test_paste_undo_redo(directory, register_directory, history_directory):
    register = Register()
    register.yank([os.path.join(directory, "dir1")])
    with patch.object(Action, '_get_input') as _get_input:
        _get_input.return_value = 'dir1-renamed'
        register.paste(directory)

    history = History()
    history.undo()
    assert set(os.listdir(directory)) == set(INITIAL_CONTENT)
    history.redo()
    assert set(os.listdir(directory)
               ) == set(INITIAL_CONTENT + ["dir1-renamed"])
