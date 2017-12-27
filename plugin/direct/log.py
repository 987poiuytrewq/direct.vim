import os


class Log(object):
    def __init__(self, path):
        self.path = path

    def push(self, line):
        with open(self.path, 'a') as file:
            file.write(line + '\n')

    def pop(self):
        characters = []
        with open(self.path, 'r+') as file:
            file.seek(0, os.SEEK_END)
            cursor = file.tell() - 1

            while cursor > 0:
                cursor -= 1
                file.seek(cursor, os.SEEK_SET)
                character = file.read(1)
                if character == '\n':
                    break
                characters.append(character)

            if cursor > 0:
                file.truncate()

        return ''.join(reversed(characters))

    def clear(self):
        open(self.path, 'w').close()
