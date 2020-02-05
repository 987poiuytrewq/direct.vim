import os
import hashlib


def digest(*paths):
    message = hashlib.md5()
    for path in paths:
        message.update(path)
    return message.hexdigest()


class Local(object):
    ROOT = None
    HISTORY = None
    TRASH = None
    REGISTER = None

    @classmethod
    def history(cls):
        if not cls.HISTORY:
            return cls.__make(cls.__root(), 'history')

    @classmethod
    def trash(cls):
        if not cls.TRASH:
            return cls.__make(cls.__root(), 'trash')

    @classmethod
    def register(cls):
        if not cls.REGISTER:
            return cls.__make(cls.__root(), 'register')

    @classmethod
    def __root(cls):
        if not cls.ROOT:
            data_home = os.getenv('XDG_DATA_HOME')
            if not data_home and os.getenv('HOME'):
                data_home = os.path.join(os.getenv('HOME'), '.local', 'share')
            cls.ROOT = cls.__make(data_home, 'direct')
        return cls.ROOT

    @classmethod
    def __make(cls, root, path):
        directory = os.path.join(root, path)
        if not os.path.exists(directory):
            os.makedirs(directory)
        return directory
