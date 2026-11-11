# Ignore snapshot approach comparison

Date: 2026-11-11
Worktree: `perf/parallel-git-ignore-snapshot`
Base: `origin/master` at `4ff54ac`
Environment: macOS, Neovim 0.12.5, Apple Git 2.54.0, Python 3.9.6

## Method

`bench/ignore_snapshot_approaches.py` creates a temporary Git repository with
20,000 files, warms each path, and reports medians. The current Neovim snapshot
measurement calls `direct.git.ignore_snapshot()` seven times in one headless
Neovim process. The CLI measurements use five timed samples after one warm-up.
All fixture paths are removed after each run.

The serial and guarded-parallel variants collect the same tracked and ignored
`git ls-files` inventories. Both first run `rev-parse --show-toplevel` as the
repository guard. The parallel variant then runs `rev-parse --show-prefix` and
both inventory queries concurrently; nested-repository scanning follows. This
matches the updated production flow while preserving its no-repository guard.

The candidate-only prototype asks `git check-ignore` about the directory's
immediate entries. For directory candidates, it uses a targeted tracked-file
query to retain directories with tracked descendants. It does **not** build or
validate Direct's full sync-safety snapshot. Its hidden-entry set matched the
current inventory on both fixtures.

## Results

Warm medians, milliseconds. The first column is the original implementation
before parallelization; the second is the updated Neovim implementation.

| Fixture (20,000 files) | Neovim snapshot before → after | Full snapshot, serial CLI | Guarded parallel CLI | Candidate-only filter |
|---|---:|---:|---:|---:|
| 1,000 directories (1,000 direct candidates; 500 hidden) | 71.97 → 51.94 | 67.50 | 57.76 | 38.06 |
| Flat directory (20,000 direct file candidates; 10,000 hidden) | 54.47 → 39.39 | 43.19 | 32.52 | 1,429.91 |

In the 1,000-directory fixture, each directory had 20 files; half had ten
tracked files and ten ignored files, and half contained only ignored files. In
the flat fixture, half the files were tracked and half ignored.

End-to-end `Buffer:list()` medians in Neovim before and after parallelization,
with Git status, icons, and single-entry collapsing disabled:

| Fixture | `respect_gitignore=true`, before → after | `respect_gitignore=false`, before → after |
|---|---:|---:|
| Directory fixture | 87.24 → 73.66 ms (502 rows) | 17.15 → 16.82 ms (1,002 rows) |
| Flat fixture | 666.95 → 626.58 ms (10,002 rows) | 601.28 → 531.81 ms (20,002 rows) |

The row counts differ because disabling filtering shows ignored entries. The
directory case makes snapshot collection the dominant cost; in the flat case,
buffer row construction and rendering dominate both timings.

## Takeaways

- The updated Neovim snapshot was about **28% faster** in both fixtures. The
  guarded CLI prototype was **14% faster** for the directory fixture and **25%**
  faster for the flat fixture, with the same full inventories. Some wall-time
  variation remains between runs.
- Candidate-only filtering was faster than the parallel full snapshot
  for 1,000 directory rows, but was about **33× slower** for 20,000 flat file
  rows compared with the serial inventory query (about **44×** compared with the
  parallel query). `git check-ignore` per candidate does not scale uniformly.
- Candidate-only filtering does not preserve the current sync-time validation
  guarantee; its lower number is not a like-for-like replacement for the full
  snapshot.

These are warm-cache measurements on synthetic repositories, not a claim about
every real worktree. For actual listing latency, benchmark `Buffer:list()` as
well: filesystem stats, row construction, rendering, and Git status can add
costs outside `ignore_snapshot()`.
