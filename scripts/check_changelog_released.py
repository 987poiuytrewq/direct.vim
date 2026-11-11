#!/usr/bin/env python3
"""Fail when a pull request edits an already-released changelog section."""

import subprocess
import sys


def released_section(contents):
    lines = contents.splitlines()
    for index, line in enumerate(lines):
        if line.startswith('## [') and line != '## [Unreleased]':
            return tuple(lines[index:])
    return ()


def released_sections_match(before, after):
    return released_section(before) == released_section(after)


def git_changelog(revision):
    result = subprocess.run(
        ['git', 'show', f'{revision}:CHANGELOG.md'],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def main(argv):
    if len(argv) != 3:
        print('usage: check_changelog_released.py BASE HEAD', file=sys.stderr)
        return 2

    base, head = argv[1:]
    try:
        before = git_changelog(base)
        after = git_changelog(head)
    except subprocess.CalledProcessError as error:
        print(f'cannot read CHANGELOG.md from {error.cmd[-1]}', file=sys.stderr)
        return 2

    if not released_sections_match(before, after):
        print(
            'CHANGELOG.md changes a released section. Put new entries under '
            '[Unreleased], or add the `release` label for a release PR.',
            file=sys.stderr,
        )
        return 1
    print('released changelog sections are unchanged')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
