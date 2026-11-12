# Git-ignore performance benchmark

> Historical pre-implementation baseline. Measurements for the current
> implementation are in [Ignore snapshot approach comparison](ignore-snapshot-approaches.md).

Date: 2026-11-04
Worktree: `perf/performance` based on `origin/master` at `84d3261`
Environment: macOS, Neovim 0.12.5, Apple Git 2.54.0, libgit2 1.9.7

## Summary

These measurements are the pre-implementation baseline. For large candidate
sets, Git's ignored-path enumeration and libgit2's in-process ignore matcher
were substantially faster than sending every candidate to `git check-ignore`.
On a 20,000-file flat repository, the medians were:

| Operation | Median |
|---|---:|
| Current snapshot + batched `git check-ignore` | 913 ms |
| libgit2 ignore + index lookup, repository/index reused | 35 ms |
| libgit2 open + index load + ignore query | 38 ms |
| `git ls-files --others --ignored --exclude-standard --directory -z` | 18 ms |
| Direct `Buffer:list()` re-list with Git status/icons disabled | 1,272 ms first timed run; 1,310 ms repeat median |

The `ls-files` timing is just the Git command; it excludes parsing its output and
matching it against Direct's raw filesystem entries. The Direct listing timing
includes filesystem stats, row identity, and buffer rendering. The first timed
list was a re-list after an unmeasured initial attach; the repeat value is the
median of three re-lists. The benchmark therefore points to promising backends,
not a predicted end-to-end speedup.

The implementation now uses `git ls-files` as its sole ignore-enumeration
backend. It uses `--directory` and scopes queries with literal pathspecs where
the listed directory is below the repository root. `check-ignore` and libgit2
are not used; libgit2 was rejected to avoid a native dependency. The timing
table remains a baseline, not a measurement of the new implementation.

Ignore snapshots now capture Git's effective ignored/tracked path decisions
instead of hashing ignore files and Git configuration. Sync validates tracked
membership in the listed scope and ignore decisions for entries present at list
time, then re-queries the current ignored inventory when filtering current disk
entries and checking descendants. Thus newly appearing ignored entries are
excluded from delete sources without invalidating an otherwise unrelated sync.
Nested repositories are still captured and checked independently.

## Scaling comparison: CLI operations

Synthetic repositories had ten tracked `.txt` files and ten ignored `.tmp`
files per directory, a root `*.tmp` rule, and a nested `.gitignore` every 50
directories. Times are warm-cache medians:
five runs for `ignore_snapshot`, seven for other commands. `check-ignore all`
used the current Direct implementation, including its tracked-path prefilter.

| Directories | Candidate entries | Tracked | Ignored | `ignore_snapshot` | `ls-files` whole repo | `check-ignore` all candidates | `ls-files` one directory | `check-ignore` one directory |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 2,000 | 1,000 | 1,000 | 48.93 ms | 10.24 ms | 23.95 ms | 7.94 ms | 8.22 ms |
| 500 | 10,000 | 5,000 | 5,000 | 65.44 ms | 20.32 ms | 252.66 ms | 8.30 ms | 9.88 ms |
| 1,200 | 24,000 | 12,000 | 12,000 | 119.35 ms | 42.90 ms | 1,412.93 ms | 10.74 ms | 12.04 ms |

The one-directory scope had 20 entries. Its query time was dominated by Git
process startup, so `check-ignore` and `ls-files` were similar. At 24,000
candidates, `check-ignore` was much slower; its input contained 12,000
untracked paths after tracked paths were removed.

## Overlap with Git status

Direct already runs `git status --porcelain=v1 -z --untracked-files=all
--ignored=matching` in `git.read()` when Git status decorations are enabled.
That one query reports both tracked deletions and ignored untracked entries. On
the 20,000-file flat fixture:

| Operation | Median |
|---|---:|
| Raw `git status` query | 27.62 ms |
| Direct `git.read()` (repo discovery, status, and parsing) | 225.14 ms |
| `git ls-files` ignored inventory | 17.68 ms |

Status emitted 10,000 exact `!!` records, matching the 10,000 ignored paths
from `ls-files` in this fixture. Reusing the status output could avoid a second
ignore query when status is already enabled. Direct's current status map also
aggregates child statuses onto parent directories, so it cannot be used as the
filter set directly: a visible directory containing one ignored child may have
an aggregated ignored status. The parser would need to retain exact raw `!!`
paths separately. With `git.enabled = false`, a separate ignore query is still
needed. `git.read()` also has significant Lua parsing/aggregation cost in this
large fixture; reuse saves a Git query but not that parsing work.

## libgit2 comparison

The libgit2 path used `git_ignore_path_is_ignored()` through Neovim's LuaJIT FFI
and `git_index_get_bypath()` for tracked membership. The reused-handle case kept
one `git_repository` and index open across queries. The open/query case included
opening the repository and loading its index. The snapshot-plus-libgit2 case
still ran Direct's existing full `ignore_snapshot()` first, so it isolates the
matcher replacement without removing the snapshot cost.

| Operation | Median |
|---|---:|
| Existing full snapshot + CLI check-ignore | 912.81 ms |
| libgit2 matcher + index lookup, reused handles | 34.91 ms |
| libgit2 open + index load + matcher | 37.88 ms |
| Existing snapshot + libgit2 matcher | 113.48 ms |

The tested ignored-path sets matched exactly for this fixture. In the separate
semantic fixture, CLI and libgit2 also agreed (with tracked paths excluded from
the ignored set) for nested `.gitignore` rules, negation, spaces in names,
`.git/info/exclude`, a configured global excludes file, an empty ignored
directory, tracked-but-ignored files, and a nested repo queried using its own
repository handle. A long-lived libgit2 repository handle also reflected a test
edit to `.gitignore` immediately; index refresh on an already-loaded index was
not tested.

`git_ignore_path_is_ignored()` behaves like `git check-ignore --no-index`: it
answers from rules without considering index membership. Direct must therefore
consult the index separately. Nested repositories also need separate handles.
The semantic check was a focused fixture, not an exhaustive compatibility suite.

## Caveats and next measurements

- `git ls-files --others --ignored --exclude-standard` does not descend into
  nested repositories as their own repositories. They require separate queries.
- Add `--directory` when empty or wholly ignored directories must appear in the
  inventory; without it, the empty ignored directory was absent in the fixture.
- A whole-repository `ls-files` query can still inspect the whole worktree. The
  expected advantage is Git's native implementation and the ability to scope it
  with pathspecs, not a guaranteed O(1) operation.
- libgit2 was tested through a local macOS installation. Shipping it would add a
  native dependency and requires broader tests for worktrees, nested repos,
  global/config changes, index refreshes, symlinks, and Git-version parity.
- The updated end-to-end implementation has not yet been benchmarked against
  these baseline timings. Measure full list/expand/sync flows, including scoped
  pathspecs and nested repositories, before claiming a speedup.
- Destructive actions still inspect current descendants and refuse when they
  contain filtered entries; nested repositories are validated independently.

The original benchmark numbers above are unchanged; implementation and semantic
tests were added afterward.
