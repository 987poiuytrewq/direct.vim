import random
import string
import vim

from direct.buffer import Buffer


def random_string():
    return ''.join(
        random.choice(string.ascii_letters)
        for _ in xrange(random.randint(5, 10))
    )


def sync(directory, lines):
    buffer = Buffer(directory)
    buffer.list()
    vim.setup_text('\n'.join(lines))
    buffer.sync()
    buffer.list()
