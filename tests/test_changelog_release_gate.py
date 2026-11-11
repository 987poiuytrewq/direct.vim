from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.check_changelog_released import released_section, released_sections_match


BASE = """# Changelog

## [Unreleased]

## [0.2.1] - 2026-11-11

### Fixed
- A released fix.

## [0.2.0] - 2026-11-10

- An older fix.
"""


class ChangelogReleaseGateTests(unittest.TestCase):
    def test_unreleased_changes_do_not_change_released_sections(self):
        updated = BASE.replace(
            '## [Unreleased]\n',
            '## [Unreleased]\n\n### Added\n- A new feature.\n',
            1,
        )
        self.assertTrue(released_sections_match(BASE, updated))

    def test_editing_a_released_section_is_detected(self):
        updated = BASE.replace('- A released fix.', '- A misleading new fix.')
        self.assertFalse(released_sections_match(BASE, updated))

    def test_adding_a_release_section_is_detected(self):
        updated = BASE.replace(
            '## [0.2.1] - 2026-11-11',
            '## [0.2.2] - 2026-11-12\n\n- New release.\n\n## [0.2.1] - 2026-11-11',
            1,
        )
        self.assertFalse(released_sections_match(BASE, updated))


if __name__ == '__main__':
    unittest.main()
