import unittest
import dirvish.vim as sut


@unittest.skip("Don't forget to test!")
class Dirvish.VimTests(unittest.TestCase):

    def test_example_fail(self):
        result = sut.dirvish.vim_example()
        self.assertEqual("Happy Hacking", result)
