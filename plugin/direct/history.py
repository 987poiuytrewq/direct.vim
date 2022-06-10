import os

from direct.data import Local
from direct.action import print_actions
from direct.action import reverse
from direct.log import Log


class History(object):
    def __init__(self):
        self.undo_log, self.redo_log = (
            Log(os.path.join(Local.history(), filename))
            for filename in ('undo.log', 'redo.log')
        )

    def log(self, action):
        self.undo_log.push(action.serialize())
        self.redo_log.clear()

    def undo(self):
        self.__reverse('undo', self.undo_log, self.redo_log)

    def redo(self):
        self.__reverse('redo', self.redo_log, self.undo_log)

    def __reverse(self, action_name, src_log, dst_log):
        reverse_action = reverse(src_log.pop())
        try:
            reverse_action.do()
        except (IOError, OSError):
            print('Failed to {} action - {}'.format(
                action_name, print_actions(reverse_action)
            ))
        else:
            print_actions(reverse_action)
            dst_log.push(reverse_action.serialize())
