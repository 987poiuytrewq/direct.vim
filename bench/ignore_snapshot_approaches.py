#!/usr/bin/env python3
"""Compare Git-ignore snapshot and candidate-query costs on a synthetic repo.

The candidate query is a listing-only prototype: it asks Git about the direct
children and checks tracked descendants only for ignored directory candidates.
It deliberately does not model the full sync-validation snapshot.
"""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[1]
TMP = Path('/private/var/folders/vv/y9mthq6j7cd3b6yflk0js_q80000gn/T/opencode')
DIRECTORIES = int(os.environ.get('BENCH_DIRECTORIES', '1000'))
FILES_PER_KIND = int(os.environ.get('BENCH_FILES_PER_KIND', '10'))
SAMPLES = int(os.environ.get('BENCH_SAMPLES', '5'))
LAYOUT = os.environ.get('BENCH_LAYOUT', 'dirs')


def git(root, *args, input_bytes=None):
    return subprocess.run(
        ['git', '-C', str(root), *args],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout


def timed(fn, samples=SAMPLES):
    fn()  # warm-up
    results = []
    for _ in range(samples):
        start = time.perf_counter()
        fn()
        results.append((time.perf_counter() - start) * 1000)
    return statistics.median(results), results


def nested_repo_scan(root):
    pending = [root]
    while pending:
        directory = pending.pop()
        if directory != root and (directory / '.git').exists():
            continue
        with os.scandir(directory) as entries:
            for entry in entries:
                if entry.name != '.git' and entry.is_dir(follow_symlinks=False):
                    pending.append(Path(entry.path))


def full_snapshot_serial(root):
    git(root, 'rev-parse', '--show-toplevel')
    prefix = git(root, 'rev-parse', '--show-prefix').decode().strip()
    args = ['--full-name']
    if prefix:
        args += ['--', f':(literal){prefix.rstrip("/")}']
    git(root, 'ls-files', '--cached', '-z', *args)
    git(root, 'ls-files', '--others', '--ignored', '--exclude-standard',
        '--directory', '-z', *args)
    nested_repo_scan(root)


def full_snapshot_guarded_parallel(root):
    # Repository membership is deliberately checked before any other query.
    git(root, 'rev-parse', '--show-toplevel')
    with ThreadPoolExecutor(max_workers=3) as pool:
        prefix = pool.submit(git, root, 'rev-parse', '--show-prefix')
        tracked = pool.submit(git, root, 'ls-files', '--cached', '-z', '--full-name')
        ignored = pool.submit(git, root, 'ls-files', '--others', '--ignored',
                              '--exclude-standard', '--directory', '-z', '--full-name')
        prefix.result()
        tracked.result()
        ignored.result()
    nested_repo_scan(root)


def inventory_hidden(root):
    output = git(root, 'ls-files', '--others', '--ignored', '--exclude-standard',
                 '--directory', '-z', '--full-name')
    # For this fixture, only a direct-child directory entry denotes a hidden
    # root row. Nested ignored files in mixed tracked/ignored directories do not.
    return {item.rstrip('/') for item in output.decode().split('\0')
            if item and '/' not in item.rstrip('/')}


def candidate_hidden(root, candidates, directory_candidates=(), no_index=False):
    encoded = ''.join(name + '\0' for name in candidates).encode()
    check_ignore = ['git', '-C', str(root), 'check-ignore']
    if no_index:
        check_ignore.append('--no-index')
    check_ignore += ['-z', '--stdin']
    result = subprocess.run(
        check_ignore,
        input=encoded,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.decode())
    matched = {item for item in result.stdout.decode().split('\0') if item}
    if not matched:
        return set()

    # Git's default check-ignore behavior already excludes tracked files. For
    # directory candidates, --no-index avoids checking the whole index for each
    # directory; then query tracked descendants only beneath matched directories.
    matched_directories = sorted(matched.intersection(directory_candidates))
    if not matched_directories:
        return matched
    tracked_output = subprocess.run(
        ['git', '--literal-pathspecs', '-C', str(root), 'ls-files', '--cached',
         '-z', '--full-name', '--', *matched_directories],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    tracked = [item for item in tracked_output.decode().split('\0') if item]
    has_tracked_entry = {
        item.split('/', 1)[0] if '/' in item else item for item in tracked
    }
    return matched - has_tracked_entry


def nvim_snapshot_median(root):
    lua_root = str(root).replace('\\', '\\\\').replace("'", "\\'")
    command = (
        "lua local git=require('direct.git'); local root='" + lua_root + "'; "
        "local times={}; for i=1,7 do local start=vim.uv.hrtime(); "
        "local snapshot,err=git.ignore_snapshot(root); assert(snapshot,err); "
        "times[i]=(vim.uv.hrtime()-start)/1e6 end; table.sort(times); "
        "print(string.format('SNAPSHOT_MEDIAN_MS=%.3f',times[4]))"
    )
    completed = subprocess.run(
        ['nvim', '--headless', '-u', 'NONE', '--cmd', f'set rtp^={REPO}',
         '-c', command, '-c', 'qa'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    )
    for line in completed.stdout.splitlines():
        if line.startswith('SNAPSHOT_MEDIAN_MS='):
            return float(line.split('=', 1)[1])
    raise RuntimeError(completed.stdout)


def nvim_list_median(root, respect_gitignore):
    lua_root = str(root).replace('\\', '\\\\').replace("'", "\\'")
    setting = 'true' if respect_gitignore else 'false'
    command = (
        "lua local direct=require('direct'); direct.setup({ "
        "respect_gitignore=" + setting + ", collapse_single_entry_directories=false, "
        "show_folder_icons=false, show_file_icons=false, show_filetype_icons=false, "
        "git={enabled=false} }); local root='" + lua_root + "'; "
        "local times={}; local rows=0; for i=1,7 do local start=vim.uv.hrtime(); "
        "local buffer=direct.list(root); assert(buffer); rows=vim.api.nvim_buf_line_count(0); "
        "times[i]=(vim.uv.hrtime()-start)/1e6 end; table.sort(times); "
        "print(string.format('LIST_MEDIAN_MS=%.3f ROWS=%d',times[4],rows))"
    )
    completed = subprocess.run(
        ['nvim', '--headless', '-u', 'NONE', '-i', 'NONE',
         '--cmd', f'set rtp^={REPO}', '-c', command, '-c', 'qa'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    )
    for line in completed.stdout.splitlines():
        if line.startswith('LIST_MEDIAN_MS='):
            left, rows = line.split(' ROWS=', 1)
            return float(left.split('=', 1)[1]), int(rows)
    raise RuntimeError(completed.stdout)


def make_fixture(root):
    subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
    children = []
    tracked = []
    if LAYOUT == 'flat':
        for index in range(DIRECTORIES * FILES_PER_KIND):
            tracked_name = f'tracked-{index:06d}.txt'
            ignored_name = f'ignored-{index:06d}.tmp'
            (root / tracked_name).write_text('tracked\n')
            (root / ignored_name).write_text('ignored\n')
            children.extend((tracked_name, ignored_name))
            tracked.append(tracked_name)
        subprocess.run(['git', '-C', str(root), 'add', '-f', '--', *tracked],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        (root / '.gitignore').write_text('*.tmp\n')
        git(root, 'add', '.gitignore')
        return children, len(tracked)

    if LAYOUT != 'dirs':
        raise ValueError(f'unknown BENCH_LAYOUT: {LAYOUT}')
    for index in range(DIRECTORIES):
        name = f'dir-{index:05d}'
        directory = root / name
        directory.mkdir()
        children.append(name)
        for file_index in range(FILES_PER_KIND):
            tracked_file = directory / f'tracked-{file_index:02d}.txt'
            tracked_file.write_text('tracked\n')
            ignored_file = directory / f'ignored-{file_index:02d}.tmp'
            ignored_file.write_text('ignored\n')
            if index < DIRECTORIES // 2:
                tracked.append(str(tracked_file.relative_to(root)))
    # Index tracked files first. The subsequent ignore rules apply to all
    # directories, but must not remove already tracked files from the index.
    subprocess.run(['git', '-C', str(root), 'add', '-f', '--', *tracked],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    (root / '.gitignore').write_text('dir-*/\n*.tmp\n')
    git(root, 'add', '.gitignore')
    return children, len(tracked)


def main():
    TMP.mkdir(parents=True, exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix='direct-ignore-bench-', dir=TMP))
    try:
        candidates, tracked_count = make_fixture(fixture)
        directory_candidates = set(candidates) if LAYOUT == 'dirs' else set()
        expected = inventory_hidden(fixture)
        actual = candidate_hidden(fixture, candidates, directory_candidates,
                                  no_index=LAYOUT == 'dirs')
        if actual != expected:
            missing = sorted(expected - actual)[:5]
            extra = sorted(actual - expected)[:5]
            raise AssertionError(f'candidate filtering mismatch: missing={missing}, extra={extra}')

        serial, serial_samples = timed(lambda: full_snapshot_serial(fixture))
        parallel, parallel_samples = timed(
            lambda: full_snapshot_guarded_parallel(fixture))
        candidate, candidate_samples = timed(lambda: candidate_hidden(
            fixture, candidates, directory_candidates, no_index=LAYOUT == 'dirs'))
        nvim = nvim_snapshot_median(fixture)
        listed = nvim_list_median(fixture, respect_gitignore=True)
        unfiltered = nvim_list_median(fixture, respect_gitignore=False)

        print(f'fixture: layout={LAYOUT}, direct candidates={len(candidates)}, '
              f'{DIRECTORIES * FILES_PER_KIND * 2} files, '
              f'{tracked_count} tracked files, '
              f'{len(expected)} hidden direct entries')
        print(f'current Neovim ignore_snapshot median (7 calls): {nvim:.2f} ms')
        print(f'full Neovim Buffer:list median, Git status/icons disabled: '
              f'{listed[0]:.2f} ms ({listed[1]} rows, ignore on); '
              f'{unfiltered[0]:.2f} ms ({unfiltered[1]} rows, ignore off)')
        print(f'full snapshot serial CLI median: {serial:.2f} ms '
              f'samples={[round(x, 2) for x in serial_samples]}')
        print(f'guarded full snapshot, prefix and inventories parallel median: '
              f'{parallel:.2f} ms '
              f'samples={[round(x, 2) for x in parallel_samples]}')
        print(f'candidate-only check-ignore + tracked-descendant query median: '
              f'{candidate:.2f} ms samples={[round(x, 2) for x in candidate_samples]}')
        print('candidate result matches current direct-child hidden set: yes')
    finally:
        shutil.rmtree(fixture)


if __name__ == '__main__':
    main()
