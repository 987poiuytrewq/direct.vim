# Spec: direct.vim remaining improvements

**Status:** APPROVED (reviewer verdict `pass`). This document is the approved implementation spec; no implementation has started. It replaces all prior drafts.

## 1. Status and current objective

- **Objective:** Deliver the remaining approved findings in direct-vim as separate, reviewable slices. Each slice gets its own branch and worktree.
- **Prerequisite F1:** A local commit exists, but it is not merged and lacks OAK state. No remaining slice starts until a fresh, OAK-looped F1 is merged by the user.
- **F3:** Documentation and current code are already fixed. It is a baseline only. Do not edit it.
- **Base:** Last verified `origin/master` is `b47a91d`. Recheck before each slice. Each slice branches from the then-current `origin/master` after the user's merge of the previous slice.
- **Baseline tests:** 203/203 via `nvim --headless -l tests/run.lua`.

## 2. Decisions and non-goals

**Binding decisions**
- Scope: F2, F4–F9, O1, O3, O4, Hist/no-clobber, and the approved Unpaste safeguard.
- History is JSONL only. No migration. Recognized legacy logs reset to a header-only JSONL file with a warning and no backup. Unknown/future/malformed/unreadable logs are preserved byte-identically and fail closed.
- Invalid UTF-8 is rejected before any side effect.
- Bounded hardening: no cap/retention, journal, reorder, or cross-operation atomicity claim. Crash windows are documented.
- Async O3 is including redo, no synchronous fallback.
- Keep the custom test harness. No CI/dependency/O2 changes.
- F8 snapshot covers only the documented `require('direct')` facade. Do not remove public exports.

**Non-goals**
- No new identity format and no trash redesign.
- No history cap, journal, or reorder of pop/execute/append.
- No claim of atomicity across multiple operations.
- No F1 or F3 changes.
- No CI, dependency, data-location, or test-harness changes.
- No push, merge, fetch, or agent integration work.

## 3. Slices, dependencies, and OAK lifecycle

| Slice | Content | Depends on | Scope estimate | Affected areas |
|---|---|---|---|---|
| S0 | F1 prerequisite (user-merged) | none | n/a | n/a |
| S1 | Hygiene: F5, F6, F7, F8, F9, O4 | S0 | medium | UI/keymap module, helper modules, export facade, netrw tests, syntax/link files |
| S2 | JSONL history format, Hist atomic rewrite, raw reader, legacy reset, preflight | S1 | large | history module, history tests, preflight hooks in action dispatch |
| S3 | No-clobber for all ops, F2 `wx` touch, `rename_noreplace`, EXDEV safe copy | S2 | large | fs primitives, stage_moves, copy/move/trash/restore/undo/redo paths |
| S4 | Unpaste content-proof safeguard | S3 | medium | action.lua Unpaste path, register comparison, Unpaste tests |
| S5 | O3 async clashing-name prompt | S2, S3 | medium | paste/undo/redo prompt flow, pending guard, prompt tests |

**Ordering:** S1 → S2 → S3 → S4. S5 may follow S2 and is sequenced after S4 unless the user decides otherwise. Each slice is one branch and worktree, from then-current `origin/master`, merged by the user before the next starts.

**OAK loop per slice**
1. Developer implements the slice with tests first (TDD).
2. Developer runs slice validation and runtime verification.
3. Reviewer runs adversarial review of the real diff.
4. Developer fixes issues and syncs state.
5. Stop after at most 3 iterations and report.
6. Delivery (`oak deliver`) only on explicit user request.

**No fabricated state.** OAK state is created and updated only by real OAK commands. Do not hand-write loop state or attestation.

## 4. Finding → slice → behavior → test map

| Finding | Slice | Behavior | Test |
|---|---|---|---|
| F2 touch exclusive create | S3 | `touch` uses `fs_open('wx')`, closes fd; EEXIST error. Existing file never truncated. | T-touch-exists, new file, EEXIST race. |
| F4 KINDS/self-description/execute | S1 | One KINDS table, self-describing fields, execute dispatch. Preserve eager trash, staging/current-entry. | Golden tests before and after refactor. |
| F5 undo_ftplugin | S1 | Remove only plugin maps; preserve same-lhs user map and prior hook. | Runtime same-lhs map and old-hook test. |
| F6 dead/duplicate helpers | S1 | Inventory then remove zero-caller wrappers; `register.yank`→`log.write(path,{dst})`. | Inventory + full suite. |
| F7 constants | S1 | Shared literals moved; no behavior change. | Full suite. |
| F8 facade | S1 | Export snapshot only for documented facade. | F8 snapshot. |
| F9 netrw | S1 | Simplify only if five tests and residual source limit preserved; else no-op. | Five existing tests plus late-source behavior. |
| O1 JSONL | S2 | JSONL, reset, preserve, strict preflight. | Section 5. |
| Hist | S2 | Atomic history rewrite and byte-preserving raw reader. | Section 7. |
| No-clobber + EXDEV | S3 | Every destination-placing op uses no-replace/exclusive create or fails closed. | Section 8. |
| Unpaste safeguard | S4 | Quarantine captured pasted entries; content-check before deleting. | U1–U9 in section 10. |
| O3 async prompt | S5 | Async `vim.ui.input`, cancel/partial/pending/redo rules. | Section 11. |
| O4 syntax | S1 | One-char/hidden group pattern and current_syntax. | Syntax test. |
| F3 | baseline | Already fixed. No code. | Existing entry regression. |

## 5. Exact JSONL schema (O1)

### 5.1 File layout and header
- One file per history stack. The file identifies its stack; no stack field.
- Header is exact bytes `{"format":"direct-history","version":1}` plus LF.
- Each following line is one record in source order and ends in LF.

### 5.2 Records

| Kind | Exact ordered keys and types |
|---|---|
| `mv` | `{"op":"mv","src":string,"dst":string}` |
| `rm`, `rmdir` | `{"op":"rm","src":string,"dst":string}` / `rmdir`; dst is required in new JSONL |
| `rs`, `rsdir` | `{"op":"rs","src":string,"dst":string}` / `rsdir` |
| `touch` | `{"op":"touch","dst":string}` |
| `mkdir` | `{"op":"mkdir","dst":string}` |
| `p`, `up` | `{"op":"p","src":string,"dst":string,"src_names":[string,...],"dst_names":[string,...]}`; `up` same fields |
| `g` | `{"op":"g","moves":[{"src":string,"dst":string}, ...]}` with at least two move pairs |

Names in p/up must be non-empty, arrays same length, each name is one basename component. Reject empty, `/`, `.`, `..`, tab/control, invalid UTF-8. Spaces are allowed. Group move endpoints must be valid and satisfy the current group invariants.

### 5.3 Canonical encoding and strict decoder
- Fixed key order as above; no whitespace. P0 tests exact escaping on Neovim 0.11 (quotes, backslash, slash, non-ASCII, control). Do not depend on Lua table key iteration order; encode with a fixed-field writer.
- Decoder rejects duplicate keys, unknown keys, missing keys, wrong types, unknown op, invalid UTF-8/control. Parse then re-encode canonically and compare bytes; add a key scanner if Neovim's decoder collapses duplicates.
- A final line without LF is malformed, including if its JSON parses. No tail drop.

### 5.4 Legacy history classification

**Principle.** Classification is a set of exact-byte predicates over the raw log file. It runs before any directory creation, register read, auto-yank, or filesystem mutation. Any predicate failure selects preserve unless the file is one of the explicit reset cases below. Preserve means: no append, no execution, no rewrite, bytes untouched, and the triggering operation is refused.

The classifier is stricter than the current parser. The parser validates only line 1 and tolerates extra or missing fields. The classifier does not rely on the parser.

| Verb | Arity | Fields | Legal in |
|---|---|---|---|
| `mv` | 3 | src dst | v2, v3 |
| `rm` | 3 | src trash | v2, v3 |
| `rmdir` | 3 | src trash | v2, v3 |
| `rs` | 3 | src dst | v2, v3 |
| `rsdir` | 3 | src dst | v2, v3 |
| `touch` | 2 | dst | v2, v3 |
| `mkdir` | 2 | dst | v2, v3 |
| `p` | 5 | src dst names dstnames | v2, v3 |
| `up` | 5 | src dst names dstnames | v2, v3 |
| `g` | count, then count move pairs (total 2 + 2*count fields) | count >= 2 | v3 only |

No format has an md5 digest line. md5 occurs only as a trash-slot or register-directory basename. No escaping exists, so a TAB or newline inside a path corrupts framing.

**P1 header.** Line 1 is exactly `#direct-history-v2` or `#direct-history-v3` followed by LF. The file may instead be absent, zero-byte, or marker-only.

**P2 byte hygiene.** Readable with no read error; valid UTF-8; no NUL byte; no CRLF; no UTF-8 BOM at offset 0; ends in LF (zero-byte exempt).

**P3 body lines.** Every line after line 1 is non-empty, LF-terminated, starts with a verb legal for that version (no `g` in v2), has exactly the arity above, has no empty mandatory field except the two `p`/`up` name fields (governed by P5), and has no TAB or control character inside a single-field path.

**P4 groups.** A `g` record in v3 has count >= 2, the number of member pairs equals count, and every member is a move pair.

**P5 name fields (Lua).** For Lua `p`/`up`, accept either both name fields empty, or both containing equal-length, non-empty, space-free name lists. Space is both the list separator and a legal name character, so any space makes the list ambiguous; such a record is not recognized and the whole file is preserved.

**Reset-eligible** (rewrite to header-only current-format JSONL, warn, no backup, no `.legacy` quarantine path created) only when the file is absent, zero-byte, or marker-only; or when P1 through P5 all hold for a v2 or v3 file; or when the file is a recognized markerless Python log as defined below.

A v2 file is reset, not executed and not migrated: reset means discard, and a v2 file is never parsed under v3 grouping rules. A v2 file containing `g` fails P3 and is preserved.

**Python policy.** A markerless file is recognized as a Python predecessor log and reset only when every LF-terminated record uses an allowed verb with exact arity (`mv`/`rm`/`rmdir`/`rs`/`rsdir` = 3, `touch`/`mkdir` = 2, `p`/`up` = 5). Its `p`/`up` name fields are never decoded, replayed, or migrated; recognition is framing-level only. Python has no `g`, so a markerless file containing `g` fails recognition and is preserved. Pre-2018-09-18 space-framed Python logs, and all other unrecognized or malformed files, are preserved.

**Preserve byte-identically and fail closed** for: any markerless file that is not a recognized Python log; any pre-2018-09-18 space-framed Python file; any v2 or v3 file failing P3 to P5 (known marker plus malformed body is preserved, never reset); any unknown or future marker; any file that is unreadable, not valid UTF-8, contains NUL, uses CRLF, has a BOM, or does not end in LF.

**Refusal.** When classification returns preserve, the triggering operation is refused and both the log bytes and the filesystem are left untouched. No directory is created and no register is read.

**Evidence index.** At `e5d73ef`, the marker `#direct-history-v3` is defined at `lua/direct/history.lua:66` (line 30 is only a comment mention). In `lua/direct/action.lua`, the `g` serializer is `serialize_group` at 795-810 (record words built at 800-809, dispatched from `M.serialize` at 828-829), and the `g` parse branch is 881-895 inside `M.deserialize` (855-898). At `f5800b2`, the marker `#direct-history-v2` is at `lua/direct/history.lua:46`, with `M.serialize` at `lua/direct/action.lua:521-544` and `M.deserialize` at 550-578, and no `g` support. At `0890317^`, `plugin/direct/action.py` has the base `Action` with `FIELD_SEPARATOR='\t'` and `serialize` at 11-21; per-verb classes at 54-127 (Move 54-70, Remove 72-85, RemoveDirectory/Restore/RestoreDirectory 87-100, Touch/MakeDirectory 102-127); `MultiAction` with `ENTRY_SEPARATOR=' '` and space-joined name lists at 130-144; Paste/Unpaste at 147-205; verb dispatch via `REVERSALS` at 208-227 and `reverse(line)` at 230-232. Tab framing was introduced at `5591451` in `plugin/direct/action.py:12`; the parent used `' '`. All citations were verified with `git show` against the stated commits, not the working tree; arity figures count the verb name as field 1.

### 5.5 Legacy acceptance tests (L-series)

A refused operation leaves log bytes and the filesystem untouched.

| ID | Input | Expected |
|---|---|---|
| L-01 | absent file | reset: create header-only file, warn, no backup |
| L-02 | zero-byte file | reset |
| L-03 | marker-only v2 or v3 | reset |
| L-04 | valid v2 with all legal verbs | reset, not executed, not migrated |
| L-05 | valid v3 containing `g` with matching count | reset |
| L-06 | v3 `g` whose count does not match member pairs | preserve |
| L-07 | v2 containing `g` | preserve |
| L-08 | record with empty mandatory field | preserve |
| L-09 | record with extra field | preserve |
| L-10 | record with missing field | preserve |
| L-11 | `p`/`up` whose name field contains a space | preserve |
| L-12 | v2/v3 `p`/`up` with both name fields empty | reset |
| L-13 | markerless TAB Python log, all verbs exact arity, no `p`/`up` | reset |
| L-14 | markerless TAB Python log containing valid-arity `p`/`up` | reset, names not decoded |
| L-15 | markerless file containing `g` or an unknown verb | preserve |
| L-16 | pre-2018 space-framed Python file | preserve |
| L-17 | CRLF file | preserve |
| L-18 | BOM file | preserve |
| L-19 | file containing NUL | preserve |
| L-20 | file with no final LF | preserve |
| L-21 | unknown or future marker | preserve |
| L-22 | unreadable existing file | preserve, operation refused |
| L-23 | known marker plus malformed body | preserve |

## 6. Preflight ordering and UTF-8 (O1/Hist)

Split `paths.data_dir()` into pure `data_dir_path()` and creating `ensure_data_dir()`.

For every operation touching history/register/files:
1. Validate all user path inputs: absolute/canonical, valid UTF-8, no NUL/control. Validate names as single components where needed.
2. Resolve history paths with pure resolver. Read/classify both stacks raw, without creating dirs.
3. Invalid/unknown/malformed/unreadable refuses before register, directory creation, auto-yank, or filesystem mutation. Recognized legacy reset is scheduled but happens atomically before operation mutation. If reset fails, abort before register/filesystem side effects.
4. After preflight: create data dir, register/auto-yank, filesystem operation, then history append.

Tests: invalid input and bad logs with absent data directory → directory absent, register/log/tree unchanged; valid operation creates dirs only after preflight.

## 7. Hist atomic write

- Write full new log to unique same-dir temp with exclusive create; write, fsync, close, rename over owned history file.
- On failure remove only temp created by this operation and leave original bytes unchanged.
- Fault inject temp collision, partial write, fsync, close, rename. No history cap. Keep pop→execute→append; document remaining crash window. No multi-operation atomicity or inter-process lock.

## 8. No-clobber and EXDEV (S3)

- `rename_noreplace`: Darwin `renamex_np(RENAME_EXCL)`, Linux `renameat2(RENAME_NOREPLACE)`. Verify Neovim 0.11 FFI path; fail closed on unsupported OS/filesystem. Plain `fs.rename` never places onto user target. No check-then-act safety claim.
- Ordinary moves/trash/restore/undo/redo/stage_moves use no-replace. Stage rollback never deletes staged user data; restore only with no-replace, otherwise report exact stranded path.
- Touch uses wx; mkdir EEXIST errors.
- EXDEV: files copy to exclusive temp in destination parent via fs_copyfile `{excl=true}`, then final no-replace, then remove source. Directories copy complete tree to exclusive private temp, then no-replace placement, then remove source. Refuse FIFO/socket/device before open. Symlinks are recreated, never followed; top-level symlinks refuse if exact safe behavior cannot be guaranteed. If source remove fails after commit, report both paths and record completed destination, documenting partial source/two copies. Unsupported primitive fails closed.
- Tests: occupied target for each operation, deterministic race between plan and syscall, EXDEV copy success, temp collision/failure, FIFO non-blocking refusal, symlink no-follow, source remove failure report, staging rollback never deletes foreign data.

## 9. Cross-device limitations

No guarantee on unsupported/network filesystems. Neovim 0.11 APIs and FFI symbols are P0 gates. No dependencies. Test real EXDEV only if a second filesystem is available; otherwise use deterministic filesystem seams and report the evidence type.

## 10. Unpaste content-proof safeguard (S4, user-approved)

### 10.1 Protocol
- Register copy is the content reference. No new identity format, no trash redesign.
- Phase A, no mutation: for every pasted target, lstat; verify type and content against the register copy. Files compare bytes. Directories compare exact child names recursively. Symlinks compare readlink targets and are never followed. Unsupported types/read errors/missing or re-yanked register/mismatch refuse the entire operation.
- Phase B capture: for each P (paste destination), atomically rename P→Q in the same directory with `rename_noreplace`; Q is unique `.direct-unpaste-<random>`. Verify Q again against register. If mismatch, restore Q→P with no-replace. If P reoccupied, leave Q, report path. If any item fails, restore all prior Qs; if restore fails, preserve/report those Q paths. No deletion until every item is captured and verified.
- Phase C delete: delete only captured Q objects. Never delete P by path. On phase-2 failure, preserve remaining Qs and notify paths. No false success. History source line is preserved on refusal; inverse is appended only on full success.
- Residuals: open file descriptors may modify after capture; identical-byte replacement is indistinguishable and may be deleted; crash/phase-2 failure may leave Q debris. No multi-operation atomicity.

### 10.2 Tests U1–U9
1. unchanged file and tree: delete Qs, log inverse, no Q remains;
2. edited file: refuse and preserve bytes;
3. added/deleted/changed child in directory: refuse entire set, no partial deletion;
4. same-name replacement: refused if content differs;
5. symlink replacement/outside target: never follow, preserve target;
6. unreadable subtree: refuse before deletion;
7. mixed multi-entry, one mismatch: no target deleted;
8. race: after P→Q, create a new object at P; new object remains untouched and only captured Q may be deleted;
9. restore blocked during mismatch: Q remains and is reported; phase-two injected failure reports every remaining Q. Add register missing/re-yanked case and identical-byte residual test.

## 11. O3 async prompts (S5)

- `vim.ui.input` callback runner, separate from factory. DirectPaste/DirectPasteAs and undo/redo p/up. Not BufWriteCmd. No synchronous fallback.
- Per item: cancel/empty/invalid skip; cap 10 for repeated clash; partial success retained. All skipped: no history and no success notice. Group remains staged synchronous moves.
- Pending guard blocks sync, paste, undo, redo while pending. History append/relist happen after completion callback. Error/cancel paths clear guard and preserve history as specified.
- Tests: callback sequence, cancellation, partial, cap, all-skipped, redo, group unchanged, pending guard, callback error.

## 12. F-items not otherwise covered

- F5: same-lhs runtime mapping test; preserve previous undo_ftplugin.
- F6: caller inventory before deleting helpers; register.yank wrapper signature migration; no public exports removed.
- F7: shared constants.
- F8: snapshot only documented facade exports; internal modules remain internal.
- F9: five netrw tests and residual late-source note unchanged, or documented no-op.
- O4: one-char and hidden syntax matches, links, `b:current_syntax`.

## 13. Documentation and validation

- Implementation docs update: recognized legacy reset/no backup; unknown/malformed preserve; UTF-8 preflight; crash windows; no-clobber platform limitations; Unpaste refusal/debris behavior.
- Test command `nvim --headless -l tests/run.lua` (baseline 203/203); full suite per slice.
- Runtime verification for F5, F9, O3, O4, S3 and S4. OAK runtime verification before final review.
- Each slice: real OAK loop, TDD, reviewer attestation. No hand-written OAK state.
- `oak deliver` only on explicit user request.

## 14. Phases and forecast

`estimated_scope: large` (over 400 lines overall). The user chose phase-by-phase delivery. Phase 1 is S1 hygiene. Phase 2 is S2 JSONL history. Phase 3 is S3 no-clobber and EXDEV. Phase 4 is S4 Unpaste, then S5 async prompts; S5 depends on S2 and S3 and is sequenced after S4 unless the user decides otherwise. Reforecast before each developer delegation. A fresh OAK-looped F1 that the user merges is a P0 prerequisite.

## 15. Result contract

- Status: approved and written. No implementation has started.
- Target: `docs/ai/specs/direct-vim-remaining-improvements.md`; this is the only file added, and no existing file was modified.
- Current checkout/user docs remain untouched.
- Next: a fresh, OAK-looped F1 is merged by the user; then slice S1 starts from the then-current `origin/master`.
