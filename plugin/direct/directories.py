import os
import hashlib

data = os.getenv('XDG_DATA_HOME')
if not data and os.getenv('HOME'):
    data = os.path.join(os.getenv('HOME'), '.local', 'share')

direct = os.path.join(data, 'direct')

message = hashlib.md5()
message.update(os.getcwd())
curdir = os.path.join(direct, message.hexdigest())

history_directory = os.path.join(curdir, 'history')
trash_directory = os.path.join(curdir, 'trash')

for directory in (history_directory, trash_directory):
    if not os.path.exists(directory):
        os.makedirs(directory)
