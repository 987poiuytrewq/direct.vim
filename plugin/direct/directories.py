import os
import hashlib


def digest(*paths):
    message = hashlib.md5()
    for path in paths:
        message.update(path)
    return message.hexdigest()


data = os.getenv('XDG_DATA_HOME')
if not data and os.getenv('HOME'):
    data = os.path.join(os.getenv('HOME'), '.local', 'share')

direct = os.path.join(data, 'direct')

curdir = os.path.join(direct, digest(os.getcwd()))

history_directory = os.path.join(curdir, 'history')
trash_directory = os.path.join(curdir, 'trash')
register_directory = os.path.join(curdir, 'register')

for directory in (history_directory, trash_directory):
    if not os.path.exists(directory):
        os.makedirs(directory)
