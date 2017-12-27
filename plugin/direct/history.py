import os

from direct import directories
from direct.action import print_actions
from direct.action import reverse
from direct.log import Log


class History(object):
    def __init__(self):
        self.undo_log, self.redo_log = (
            Log(os.path.join(directories.history_directory, filename))
            for filename in ('undo.log', 'redo.log')
        )

    def log(self, action):
        self.undo_log.push(action.serialize())
        self.redo_log.clear()

    def undo(self):
        self.__reverse(self.undo_log, self.redo_log)

    def redo(self):
        self.__reverse(self.redo_log, self.undo_log)

    def __reverse(self, src_log, dst_log):
        reverse_action = reverse(src_log.pop())
        reverse_action.do()
        print_actions(reverse_action)
        dst_log.push(reverse_action.serialize())
