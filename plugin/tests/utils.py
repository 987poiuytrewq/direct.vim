import random
import string


def random_string():
    return ''.join(
        random.choice(string.ascii_letters)
        for _ in xrange(random.randint(5, 10))
    )
