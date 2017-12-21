import os
import random
import tempfile

from mock import patch

from direct.history import ActionLog

from .utils import random_string


@patch('direct.history.directories')
def test_action_log(directories):
    directories.history_directory = tempfile.mkdtemp()
    lines = [random_string() for _ in xrange(random.randint(10, 20))]

    filename = random_string()
    path = os.path.join(directories.history_directory, filename)
    action_log = ActionLog(filename)

    # assert lines pushed correctly
    for index, line in enumerate(lines):
        action_log.push(line)
        assert_log_lines(path, lines[slice(0, index + 1)])

    # assert lines popped correctly
    for index, line in enumerate(reversed(lines)):
        popped_line = action_log.pop()
        assert popped_line.strip() == line
        end_slice = max(len(lines) - index - 1, 1)
        assert_log_lines(path, lines[slice(0, end_slice)])


def assert_log_lines(path, lines):
    with open(path, 'r') as log:
        assert [log_line.strip() for log_line in log.readlines()] == lines
