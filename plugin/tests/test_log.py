import os
import random
import tempfile

from direct.log import Log

from .utils import random_string


def test_log():
    lines = [random_string() for _ in xrange(random.randint(10, 20))]

    path = os.path.join(tempfile.mkdtemp(), random_string())
    action_log = Log(path)

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
