-- Dot-hidden visibility, Git ignore filtering, and safe view toggles.
local H = require('tests.support.harness')

local function git(root, ...)
  local args = { 'git', '-C', root }
  for _, arg in ipairs({ ... }) do args[#args + 1] = arg end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then error(result.stderr or 'git failed') end
  return (result.stdout or ''):gsub('[\r\n]+$', '')
end

local function init_repo(root)
  git(root, 'init', '-q')
  git(root, 'config', 'user.name', 'Direct Test')
  git(root, 'config', 'user.email', 'direct-test@example.invalid')
end

local function contains(lines, value)
  return vim.tbl_contains(lines, value)
end

local function row_of(lines, value)
  for row, line in ipairs(lines) do
    if line == value then return row end
  end
end

H.describe('hidden and Git-ignore filtering', function()
  H.it('defaults dot-hidden entries visible and accepts validated filter options', function()
    local config = require('direct.config')
    H.assert_true(config.defaults.show_hidden, 'hidden entries show by default')
    H.assert_false(config.defaults.respect_gitignore, 'Git ignore is opt-in')
    H.capture_messages()
    local options = config.setup({ show_hidden = false, respect_gitignore = true })
    H.assert_false(options.show_hidden, 'boolean dotfile option is accepted')
    H.assert_true(options.respect_gitignore, 'boolean Git ignore option is accepted')
    options = config.setup({ show_hidden = 'no', respect_gitignore = 1 })
    H.assert_true(options.show_hidden, 'invalid show_hidden keeps its default')
    H.assert_false(options.respect_gitignore, 'invalid respect_gitignore keeps its default')
    H.assert_notified('show_hidden', vim.log.levels.ERROR)
    H.assert_notified('respect_gitignore', vim.log.levels.ERROR)
  end)

  H.it('toggles hidden entries with the command and owned gh mapping', function()
    local config = require('direct.config')
    config.setup({ map_default_keys = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'ws')
    H.mkfile(root, '.hidden', 'dot')
    H.mkfile(root, 'visible', 'visible')
    local listing = require('direct').list(root)
    H.assert_true(contains(H.buf_lines(), '.hidden'), 'dotfile visible initially')
    H.assert_eq(vim.fn.maparg('gh', 'n', false, true).rhs,
      '<Cmd>DirectToggleHidden<CR>', 'gh is the plugin-owned toggle mapping')

    pcall(vim.cmd, 'DirectToggleHidden')
    H.assert_buf_eq({ 'visible' }, 0, 'toggle hides dotfiles')
    pcall(vim.cmd, 'DirectToggleHidden')
    H.assert_buf_eq({ '.hidden', 'visible' }, 0, 'second toggle restores dotfiles')
    H.assert_true(listing ~= nil, 'listing remains attached')

    local child = H.mkdir(root, 'dir')
    H.mkfile(child, '.child-hidden', '')
    H.mkfile(child, 'child-visible', '')
    listing:list()
    listing:expand(row_of(H.buf_lines(), 'dir/'))
    H.assert_true(contains(H.buf_lines(), '  .child-hidden'),
      'expanded children share the view filter')
    pcall(vim.cmd, 'DirectToggleHidden')
    H.assert_buf_eq({ 'dir/', 'visible' }, 0,
      'toggle refreshes the root and collapses stale expanded children')

    config.setup({ map_default_keys = false })
    H.assert_eq(vim.fn.maparg('gh', 'n'), '', 'opt-out clears gh')
    H.assert_eq(vim.fn.maparg('gs', 'n'), '', 'opt-out clears gs')
  end)

  H.it('toggles a Git-status-only view with gs at roots and expanded directories', function()
    local config = require('direct.config')
    config.setup({ map_default_keys = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local changed_dir = H.mkdir(root, 'changed-dir')
    init_repo(root)
    H.mkfile(root, 'changed.txt', 'before')
    H.mkfile(root, 'clean.txt', 'clean')
    H.mkfile(changed_dir, 'changed-child.txt', 'before')
    H.mkfile(changed_dir, 'clean-child.txt', 'clean')
    git(root, 'add', '.')
    git(root, 'commit', '-qm', 'baseline')
    H.mkfile(root, 'changed.txt', 'after')
    H.mkfile(changed_dir, 'changed-child.txt', 'after')
    H.mkfile(root, 'untracked.txt', 'new')

    local listing = require('direct').list(root)
    H.assert_true(contains(H.buf_lines(), 'clean.txt'), 'clean entries show normally')
    H.assert_eq(vim.fn.maparg('gs', 'n', false, true).rhs,
      '<Cmd>DirectToggleGitStatus<CR>', 'gs is the plugin-owned status-filter mapping')

    pcall(vim.cmd, 'DirectToggleGitStatus')
    local filtered = H.buf_lines()
    H.assert_true(contains(filtered, 'changed-dir/'), 'changed descendant keeps its directory visible')
    H.assert_true(contains(filtered, 'changed.txt'), 'modified files are included')
    H.assert_true(contains(filtered, 'untracked.txt'), 'untracked files are included')
    H.assert_false(contains(filtered, 'clean.txt'), 'clean files are hidden')

    listing:expand(row_of(filtered, 'changed-dir/'))
    local expanded = H.buf_lines()
    H.assert_true(contains(expanded, '  changed-child.txt'), 'changed children are included')
    H.assert_false(contains(expanded, '  clean-child.txt'), 'clean children are hidden')

    pcall(vim.cmd, 'DirectToggleGitStatus')
    local restored = H.buf_lines()
    H.assert_true(contains(restored, 'clean.txt'), 'second toggle restores clean entries')
    H.assert_false(contains(restored, '  changed-child.txt'),
      'toggling rebuilds the root and collapses old expansions')
  end)

  H.it('does not treat status-filtered entries as deletions during sync', function()
    require('direct.config').setup({ map_default_keys = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    init_repo(root)
    H.mkfile(root, 'changed.txt', 'before')
    H.mkfile(root, 'clean.txt', 'clean')
    git(root, 'add', '.')
    git(root, 'commit', '-qm', 'baseline')
    H.mkfile(root, 'changed.txt', 'after')

    local listing = require('direct').list(root)
    pcall(vim.cmd, 'DirectToggleGitStatus')
    H.assert_buf_eq({ 'changed.txt' }, 0, 'only the modified entry is shown')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(listing:sync(), 'deleting the visible changed entry syncs')
    H.assert_false(H.exists(root, 'changed.txt'), 'visible deletion is applied')
    H.assert_true(H.exists(root, 'clean.txt'), 'filtered clean entry is left untouched')
  end)

  H.it('shows no rows outside a repository and refuses the toggle with unsaved edits', function()
    require('direct.config').setup({ map_default_keys = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'plain')
    H.mkfile(root, 'ordinary.txt', 'content')
    require('direct').list(root)

    pcall(vim.cmd, 'DirectToggleGitStatus')
    H.assert_false(contains(H.buf_lines(), 'ordinary.txt'),
      'entries without a Git status are hidden')
    pcall(vim.cmd, 'DirectToggleGitStatus')
    H.assert_true(contains(H.buf_lines(), 'ordinary.txt'), 'second toggle restores the listing')

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited.txt' })
    vim.bo.modified = true
    H.capture_messages()
    pcall(vim.cmd, 'DirectToggleGitStatus')
    H.assert_buf_eq({ 'edited.txt' }, 0, 'unsaved edits are preserved')
    H.assert_true(vim.bo.modified, 'the modified flag remains set')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
  end)

  H.it('refuses directory moves that would carry clean status-filtered descendants', function()
    require('direct.config').setup({ map_default_keys = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local directory = H.mkdir(root, 'dir')
    init_repo(root)
    H.mkfile(directory, 'changed.txt', 'before')
    H.mkfile(directory, 'clean.txt', 'clean')
    git(root, 'add', '.')
    git(root, 'commit', '-qm', 'baseline')
    H.mkfile(directory, 'changed.txt', 'after')

    local listing = require('direct').list(root)
    pcall(vim.cmd, 'DirectToggleGitStatus')
    local row = row_of(H.buf_lines(), 'dir/')
    listing:expand(row)
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, { 'moved/' })
    H.capture_messages()
    H.assert_nil(listing:sync(), 'moving a filtered directory is refused')
    H.assert_true(H.exists(root, 'dir/clean.txt'), 'the hidden clean child remains in place')
    H.assert_notified('directory contains hidden entry', vim.log.levels.ERROR)
  end)

  H.it('refuses a hidden toggle with unsaved edits without changing text', function()
    require('direct.config').setup({ map_default_keys = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'ws')
    H.mkfile(root, '.hidden', '')
    H.mkfile(root, 'visible', '')
    require('direct').list(root)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '.hidden', 'edited' })
    local buf = vim.api.nvim_get_current_buf()
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.bo[buf].modified = true
    H.capture_messages()
    pcall(vim.cmd, 'DirectToggleHidden')
    H.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before,
      'unsaved text is preserved')
    H.assert_true(vim.bo[buf].modified, 'modified remains set')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
  end)

  H.it('uses Git rules, keeps tracked ignored files and tracked descendant directories', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local nested = H.mkdir(root, 'nested')
    local kept = H.mkdir(root, 'kept')
    H.mkfile(root, '.gitignore', {
      '*.log', 'cache/', 'directory-only/', '!keep.log', '/anchored.tmp',
      'literal\\ name.tmp',
    })
    H.mkfile(nested, '.gitignore', '*.cache')
    H.mkfile(root, 'ignored.log', '')
    H.mkfile(root, 'keep.log', '')
    H.mkfile(root, 'anchored.tmp', '')
    H.mkfile(root, 'nested/anchored.tmp', '')
    H.mkfile(root, 'literal name.tmp', '')
    H.mkfile(root, 'cache/ignored.txt', '')
    H.mkfile(root, 'cache/tracked.txt', '')
    H.mkfile(root, 'directory-only/child.txt', '')
    H.mkfile(nested, 'ignored.cache', '')
    H.mkfile(nested, 'visible.tmp', '')
    H.mkfile(kept, 'tracked.log', '')
    init_repo(root)
    git(root, 'add', '-f', 'kept/tracked.log')
    git(root, 'add', '-f', 'cache/tracked.txt')

    local listing = require('direct').list(root)
    local lines = H.buf_lines()
    H.assert_false(contains(lines, 'ignored.log'), 'root ignore pattern applies')
    H.assert_true(contains(lines, 'keep.log'), 'negation re-includes a path')
    H.assert_false(contains(lines, 'anchored.tmp'), 'root-anchored pattern applies')
    H.assert_false(contains(lines, 'anchored.tmp'), 'nested paths are not root rows')
    H.assert_false(contains(lines, 'literal name.tmp'), 'escaped spaces use Git semantics')
    H.assert_true(contains(lines, 'cache/'),
      'directory with a tracked descendant remains visible')
    H.assert_false(contains(lines, 'directory-only/'),
      'directory-only Git patterns hide matching directories')
    H.assert_true(contains(lines, 'kept/'), 'tracked descendants keep their directory')
    listing:expand(row_of(H.buf_lines(), 'nested/'))
    H.assert_false(contains(H.buf_lines(), '  ignored.cache'), 'nested .gitignore applies')
    H.assert_true(contains(H.buf_lines(), '  anchored.tmp'),
      'root anchoring does not match the same basename in a child directory')
    H.assert_true(contains(H.buf_lines(), '  visible.tmp'), 'nested file not matched stays visible')
    listing:expand(row_of(H.buf_lines(), 'cache/'))
    H.assert_false(contains(H.buf_lines(), '  ignored.txt'), 'ignored child stays hidden')
    H.assert_true(contains(H.buf_lines(), '  tracked.txt'),
      'tracked descendant remains visible under an ignored directory')
    listing:expand(row_of(H.buf_lines(), 'kept/'))
    H.assert_true(contains(H.buf_lines(), '  tracked.log'),
      'tracked file remains visible even though its name matches ignore rules')
  end)

  H.it('leaves ignored paths visible by default when Git filtering is disabled', function()
    local config = require('direct.config')
    config.setup({ map_default_keys = false, git = { enabled = false } })
    H.assert_false(config.options.respect_gitignore, 'default remains disabled')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, '.gitignore', '*.tmp\n')
    H.mkfile(root, 'ignored.tmp', '')
    init_repo(root)
    local original_system = vim.system
    local git_calls = 0
    vim.system = function(...)
      git_calls = git_calls + 1
      return original_system(...)
    end
    require('direct').list(root)
    vim.system = original_system
    H.assert_true(contains(H.buf_lines(), 'ignored.tmp'),
      'Git ignore does not filter without opt-in')
    H.assert_eq(git_calls, 0, 'disabled Git-ignore filtering makes no Git calls')
  end)

  H.it('uses a nested repository own rules instead of its parent repository rules', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'outer')
    local nested = H.mkdir(root, 'nested')
    H.mkfile(root, '.gitignore', '/nested/keep.tmp\n')
    init_repo(root)
    H.mkfile(nested, '.gitignore', '!keep.tmp\n')
    H.mkfile(nested, 'keep.tmp', '')
    init_repo(nested)

    local listing = require('direct').list(root)
    listing:expand(row_of(H.buf_lines(), 'nested/'))
    H.assert_true(contains(H.buf_lines(), '  keep.tmp'),
      'the nested repository listing does not inherit the outer ignore rule')
  end)

  H.it('refuses sync after ignore rules change, then refreshes safely on re-list', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, '.gitignore', '*.log\n')
    H.mkfile(root, 'hidden.log', 'keep')
    H.mkfile(root, 'visible', 'keep')
    init_repo(root)
    local listing = require('direct').list(root)
    H.assert_false(contains(H.buf_lines(), 'hidden.log'), 'ignored path is omitted')

    H.mkfile(root, '.gitignore', '*.tmp\n')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new-file' })
    local before = vim.fn.readfile(root .. '/visible')
    H.capture_messages()
    local ok = listing:sync()
    H.assert_nil(ok, 'changed filter rules refuse sync')
    H.assert_true(vim.bo.modified, 'buffer remains modified')
    H.assert_true(H.exists(root, 'hidden.log'), 'hidden file is untouched')
    H.assert_eq(vim.fn.readfile(root .. '/visible'), before, 'visible file is untouched')
    H.assert_false(H.exists(root, 'new-file'), 'no filesystem action ran')
    H.assert_notified('ignore rules changed', vim.log.levels.ERROR)

    H.assert_true(listing:list(), 're-list refreshes the filter snapshot')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new-file' })
    H.assert_true(listing:sync(), 'sync succeeds against the refreshed snapshot')
    H.assert_true(H.exists(root, 'new-file'), 'the new visible addition is created')
  end)

  H.it('refuses sync when a directory becomes a Git repository after listing', function()
    require('direct.config').setup({ map_default_keys = false,
      respect_gitignore = true, show_hidden = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'plain')
    H.mkfile(root, 'visible', 'preserve')
    local listing = require('direct').list(root)
    H.assert_buf_eq({ 'visible' }, 0, 'the outside-repository listing is unfiltered')
    local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_true(state.directory_snapshots[1].respect_gitignore,
      'the directory records that Git filtering was enabled')
    H.assert_false(state.directory_snapshots[1].git_repo,
      'the directory records that no repository was found')

    init_repo(root)
    H.mkfile(root, '.gitignore', 'secret/\n')
    local secret = H.mkdir(root, 'secret')
    H.mkfile(secret, 'important.txt', 'must survive')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    vim.bo.modified = true

    local before = H.fs_snapshot(root)
    local history = require('direct.history')
    local history_calls = 0
    local original_log = history.log
    history.log = function(...) history_calls = history_calls + 1; return original_log(...) end
    H.capture_messages()
    local ok, reason = listing:sync()
    history.log = original_log

    H.assert_nil(ok, 'a new repository context refuses sync')
    H.assert_true(tostring(reason):find('re-list', 1, true) ~= nil,
      'the refusal asks for a fresh listing')
    H.assert_true(vim.bo.modified, 'the user edit remains pending')
    H.assert_eq(H.fs_snapshot(root), before, 'no filesystem changes occur')
    H.assert_eq(history_calls, 0, 'no history entries are written')
    H.assert_notified('re-list', vim.log.levels.ERROR)
    H.assert_true(H.exists(root, 'secret/important.txt'),
      'the newly ignored path is not used as a deletion source')

    H.assert_true(listing:list(), 're-list captures the new repository context')
    H.assert_buf_eq({ 'visible' }, 0, 'the Git-ignored directory is now filtered')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    vim.bo.modified = true
    H.assert_true(listing:sync(), 'sync succeeds against the refreshed snapshot')
    H.assert_false(H.exists(root, 'visible'), 'the requested visible deletion is applied')
    H.assert_true(H.exists(root, 'secret/important.txt'),
      'the ignored directory remains untouched after re-list')
  end)

  H.it('detects repository removal and a changed repository root', function()
    local git_api = require('direct.git')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'outer')
    local nested = H.mkdir(root, 'nested')
    init_repo(root)
    local parent_snapshot = git_api.ignore_snapshot(nested)
    H.assert_not_nil(parent_snapshot, 'the nested path initially uses the parent repository')

    init_repo(nested)
    local matches, err = git_api.ignore_snapshot_matches(parent_snapshot, nested)
    H.assert_false(matches, 'a newly-created nested repository changes the context')
    H.assert_true(tostring(err):find('re-list', 1, true) ~= nil,
      'the root change requires a fresh listing')

    local standalone = H.mkdir(sb.root, 'standalone')
    init_repo(standalone)
    local standalone_snapshot = git_api.ignore_snapshot(standalone)
    vim.fn.delete(standalone .. '/.git', 'rf')
    matches, err = git_api.ignore_snapshot_matches(standalone_snapshot, standalone)
    H.assert_false(matches, 'removing the repository changes the context')
    H.assert_true(tostring(err):find('re-list', 1, true) ~= nil,
      'the missing repository requires a fresh listing')
  end)

  H.it('refuses sync when a newly tracked ignored path changes the index snapshot', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, '.gitignore', '*.log\n')
    H.mkfile(root, 'visible', 'preserve')
    init_repo(root)
    local listing = require('direct').list(root)
    H.assert_false(contains(H.buf_lines(), 'new.log'), 'ignored log is not in list-time rows')

    H.mkfile(root, 'new.log', 'must survive')
    git(root, 'add', '-f', 'new.log')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'unrelated-new-file' })
    local history = require('direct.history')
    local history_calls = 0
    local original_log = history.log
    history.log = function(...) history_calls = history_calls + 1; return original_log(...) end
    H.capture_messages()
    local ok, reason = listing:sync()
    history.log = original_log

    H.assert_nil(ok, 'index membership change refuses sync')
    H.assert_true(tostring(reason):find('ignore rules changed', 1, true) ~= nil,
      'the refusal reports that the Git snapshot changed')
    H.assert_eq(vim.fn.readfile(root .. '/new.log'), { 'must survive' },
      'newly tracked file remains unchanged')
    H.assert_eq(vim.fn.readfile(root .. '/visible'), { 'preserve' },
      'unrelated visible file remains unchanged')
    H.assert_false(H.exists(root, 'unrelated-new-file'), 'no filesystem action ran')
    H.assert_eq(history_calls, 0, 'refusal occurs before history effects')
    H.assert_true(vim.bo.modified, 'the buffer edit remains pending')
    H.assert_notified('ignore rules changed', vim.log.levels.ERROR)

    H.assert_true(listing:list(), 're-list accepts the updated index snapshot')
    H.assert_true(contains(H.buf_lines(), 'new.log'), 'tracked ignored file is now visible')
  end)

  H.it('uses one tracked-index query for a recursive descendant walk', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local outer = H.mkdir(root, 'outer')
    local middle = H.mkdir(outer, 'middle')
    local nested = H.mkdir(middle, 'nested-repo')
    H.mkfile(nested, '.gitignore', '*.tmp\n')
    H.mkfile(nested, 'hidden.tmp', 'preserve')
    H.mkfile(root, '.gitignore', '*.log\n')
    init_repo(root)
    init_repo(nested)
    require('direct').list(root)
    local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
    local root_snapshot
    for _, snapshot in ipairs(state.directory_snapshots) do
      if snapshot.path == root then root_snapshot = snapshot; break end
    end
    H.assert_true(root_snapshot ~= nil, 'root Git snapshot is captured at list time')

    local original_system = vim.system
    local index_queries = 0
    vim.system = function(command, ...)
      for _, arg in ipairs(command) do
        if arg == 'ls-files' then index_queries = index_queries + 1; break end
      end
      return original_system(command, ...)
    end
    local hidden, err = require('direct.buffer_listing').hidden_descendant(
      outer, root_snapshot, state)
    vim.system = original_system

    H.assert_eq(hidden, nested .. '/hidden.tmp',
      'the nested repository uses its own ignore rules while being scanned')
    H.assert_eq(index_queries, 1,
      'the nested repo is discovered once; visits reuse each repository index snapshot')
    H.assert_nil(err, 'the raw descendant scan completed without error')

    H.mkfile(nested, 'new.tmp', 'must survive')
    git(nested, 'add', '-f', 'new.tmp')
    local matches, snapshot_err = require('direct.git').ignore_snapshot_matches(
      root_snapshot.git)
    H.assert_false(matches, 'the parent snapshot fingerprints nested-repo index membership')
    H.assert_true(tostring(snapshot_err):find('ignore rules changed', 1, true) ~= nil,
      'nested index change requires a fresh listing')
  end)

  H.it('snapshots info/exclude and configured global exclude sources', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local global = H.mkfile(sb.root, 'global-excludes', 'global.tmp\n')
    init_repo(root)
    H.mkfile(root, '.git/info/exclude', 'local.tmp\n')
    git(root, 'config', 'core.excludesFile', global)
    H.mkfile(root, 'local.tmp', '')
    H.mkfile(root, 'global.tmp', '')
    H.mkfile(root, 'visible', '')
    local listing = require('direct').list(root)
    H.assert_false(contains(H.buf_lines(), 'local.tmp'), 'info/exclude is applied')
    H.assert_false(contains(H.buf_lines(), 'global.tmp'), 'core.excludesFile is applied')

    H.mkfile(sb.root, 'global-excludes', 'other-global.tmp\n')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new-file' })
    H.capture_messages()
    H.assert_nil(listing:sync(), 'global exclude change invalidates the rule snapshot')
    H.assert_notified('ignore rules changed', vim.log.levels.ERROR)
    H.assert_false(H.exists(root, 'new-file'), 'the failed sync performs no additions')

    H.assert_true(listing:list(), 're-list accepts the changed global exclude')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new-file-2' })
    H.mkfile(root, '.git/info/exclude', 'other.tmp\n')
    H.capture_messages()
    H.assert_nil(listing:sync(), 'info/exclude change invalidates the refreshed snapshot')
    H.assert_notified('ignore rules changed', vim.log.levels.ERROR)
    H.assert_false(H.exists(root, 'new-file-2'), 'the second refusal is side-effect free')
  end)

  H.it('snapshots Git default global excludes and refuses before side effects', function()
    local sb = H.sandbox()
    local xdg = H.mkdir(sb.root, 'xdg')
    local home = H.mkdir(sb.root, 'home')
    local default_excludes = H.mkfile(xdg, 'git/ignore', 'hidden.tmp\n')
    H.with_env({ HOME = home, XDG_CONFIG_HOME = xdg }, function()
      require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
      local root = H.mkdir(sb.root, 'default-global-repo')
      H.mkfile(root, 'hidden.tmp', 'preserve')
      H.mkfile(root, 'visible', 'preserve')
      init_repo(root)
      local listing = require('direct').list(root)
      H.assert_false(contains(H.buf_lines(), 'hidden.tmp'),
        'Git default global excludes hide the file')

      H.mkfile(xdg, 'git/ignore', 'other.tmp\n')
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'added-after-change' })
      local before = H.fs_snapshot(root)
      local history = require('direct.history')
      local history_calls = 0
      local original_log = history.log
      history.log = function(...) history_calls = history_calls + 1; return original_log(...) end
      H.capture_messages()
      local ok = listing:sync()
      history.log = original_log

      H.assert_nil(ok, 'changing the default global excludes refuses sync')
      H.assert_eq(H.fs_snapshot(root), before, 'refusal has no filesystem effects')
      H.assert_eq(history_calls, 0, 'refusal writes no history')
      H.assert_true(vim.bo.modified, 'the buffer edit remains pending')
      H.assert_notified('ignore rules changed', vim.log.levels.ERROR)

      H.assert_true(listing:list(), 're-list accepts the changed default excludes')
      H.assert_true(contains(H.buf_lines(), 'hidden.tmp'),
        'the formerly ignored file is visible after re-list')
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'added-after-relist' })
      H.assert_true(listing:sync(), 'sync succeeds against the new default excludes')
      H.assert_true(H.exists(root, 'added-after-relist'), 'new state can be applied')
    end)
    H.assert_true(H.exists(sb.root, 'xdg/git/ignore'),
      'the test used the default XDG excludes path: ' .. default_excludes)
  end)

  H.it('fingerprints a missing default global excludes file so creation is detected', function()
    local sb = H.sandbox()
    local home = H.mkdir(sb.root, 'home')
    local default_home_excludes = vim.fs.joinpath(home, '.config', 'git', 'ignore')
    H.with_env({ HOME = home, XDG_CONFIG_HOME = '' }, function()
      require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
      local root = H.mkdir(sb.root, 'missing-default-repo')
      H.mkfile(root, 'newly-ignored.tmp', 'preserve')
      H.mkfile(root, 'visible', 'preserve')
      init_repo(root)
      local listing = require('direct').list(root)
      H.assert_true(contains(H.buf_lines(), 'newly-ignored.tmp'),
        'missing default exclude file leaves the file visible')

      H.mkfile(home, '.config/git/ignore', 'newly-ignored.tmp\n')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '.git/', 'visible' })
      local before = H.fs_snapshot(root)
      H.capture_messages()
      H.assert_nil(listing:sync(), 'creating the default excludes file refuses sync')
      H.assert_eq(H.fs_snapshot(root), before, 'the formerly visible file is not deleted')
      H.assert_notified('ignore rules changed', vim.log.levels.ERROR)

      H.assert_true(listing:list(), 're-list captures the newly-created file')
      H.assert_false(contains(H.buf_lines(), 'newly-ignored.tmp'),
        'the new default rule now hides the file')
    end)
    H.assert_true(vim.uv.fs_stat(default_home_excludes) ~= nil,
      'the test used HOME/.config/git/ignore')
  end)

  H.it('fingerprints the default global excludes for nested repositories', function()
    local sb = H.sandbox()
    local xdg = H.mkdir(sb.root, 'xdg')
    local home = H.mkdir(sb.root, 'home')
    H.mkfile(xdg, 'git/ignore', 'nested-hidden.tmp\n')
    H.with_env({ HOME = home, XDG_CONFIG_HOME = xdg }, function()
      require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
      local root = H.mkdir(sb.root, 'outer-repo')
      local nested = H.mkdir(root, 'nested')
      H.mkfile(nested, 'nested-hidden.tmp', 'preserve')
      H.mkfile(nested, 'visible', 'preserve')
      init_repo(root)
      init_repo(nested)
      local listing = require('direct').list(root)
      listing:expand(row_of(H.buf_lines(), 'nested/'))
      H.assert_false(contains(H.buf_lines(), '  nested-hidden.tmp'),
        'the default global excludes apply in a nested repository')

      H.mkfile(xdg, 'git/ignore', 'other.tmp\n')
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { '  added' })
      local before = H.fs_snapshot(root)
      H.capture_messages()
      H.assert_nil(listing:sync(), 'nested default excludes change refuses sync')
      H.assert_eq(H.fs_snapshot(root), before, 'nested refusal has no filesystem effects')
      H.assert_true(vim.bo.modified, 'the nested listing edit remains pending')
      H.assert_notified('ignore rules changed', vim.log.levels.ERROR)
    end)
  end)

  H.it('preserves repository-relative Git ignore matching through a symlink alias', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'aliased-repo')
    H.mkfile(root, '.gitignore', 'hidden.tmp\n')
    H.mkfile(root, 'hidden.tmp', 'preserve')
    H.mkfile(root, 'visible', 'preserve')
    init_repo(root)
    local alias = vim.fs.joinpath(sb.root, 'repo-alias')
    H.assert_true(vim.uv.fs_symlink(root, alias), 'repository alias symlink is created')

    local listing = require('direct').list(alias)
    H.assert_false(contains(H.buf_lines(), 'hidden.tmp'),
      'ignored file stays hidden when listed through the alias')
    H.mkfile(root, '.gitignore', 'other.tmp\n')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'added-through-alias' })
    local before = H.fs_snapshot(root)
    H.capture_messages()
    H.assert_nil(listing:sync(), 'changed ignore rules refuse sync through the alias')
    H.assert_eq(H.fs_snapshot(root), before, 'alias refusal has no filesystem effects')
    H.assert_true(vim.bo.modified, 'the alias listing edit remains pending')
    H.assert_notified('ignore rules changed', vim.log.levels.ERROR)

    H.assert_true(listing:list(), 're-list through the alias refreshes safely')
    H.assert_true(contains(H.buf_lines(), 'hidden.tmp'),
      'the formerly ignored entry is visible through the alias')
  end)

  H.it('matches a literal backslash filename in Git ignore rules on POSIX', function()
    if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then return end
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'backslash-repo')
    H.mkfile(root, '.gitignore', 'literal\\\\name.tmp\n')
    H.mkfile(root, 'literal\\name.tmp', 'hidden')
    H.mkfile(root, 'visible', '')
    init_repo(root)

    require('direct').list(root)
    H.assert_false(contains(H.buf_lines(), 'literal\\name.tmp'),
      'POSIX backslash filename is matched as a literal Git path character')
  end)

  H.it('keeps dot-hidden, Git-ignore, and wildignore filtering independent', function()
    require('direct.config').setup({ map_default_keys = false,
      respect_gitignore = true, show_hidden = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, '.gitignore', 'git-only\n')
    H.mkfile(root, '.dot', '')
    H.mkfile(root, 'git-only', '')
    H.mkfile(root, 'wild-only', '')
    init_repo(root)
    H.with_option('wildignore', 'wild-only', function()
      require('direct').list(root)
    end)
    H.assert_buf_eq({ '' }, 0, 'the enabled filters form a union')
  end)

  H.it('does not turn newly appearing Git-ignored entries into delete sources', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, '.gitignore', '*.log\n')
    H.mkfile(root, 'listed.txt', 'listed')
    init_repo(root)
    local listing = require('direct').list(root)
    H.mkfile(root, 'appeared.log', 'must survive')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '.git/', '.gitignore' })
    H.assert_true(listing:sync(), 'the visible deletion syncs')
    H.assert_false(H.exists(root, 'listed.txt'), 'listed visible path is deleted')
    H.assert_true(H.exists(root, 'appeared.log'), 'new ignored path is never a delete source')
  end)

  H.it('refuses parent moves containing ignored descendants and validates unfolded rules', function()
    require('direct.config').setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local parent = H.mkdir(root, 'parent')
    H.mkfile(root, '.gitignore', '*.log\n')
    H.mkfile(parent, 'hidden.log', 'preserve')
    H.mkfile(parent, 'visible.txt', 'visible')
    init_repo(root)
    local listing = require('direct').list(root)
    local parent_row
    for row, line in ipairs(H.buf_lines()) do
      if line == 'parent/' then parent_row = row end
    end
    listing:expand(parent_row)
    H.assert_false(contains(H.buf_lines(), '  hidden.log'), 'child ignore is applied on expansion')
    local before = vim.fn.readfile(parent .. '/hidden.log')
    listing:collapse(parent_row)
    vim.api.nvim_buf_set_lines(0, parent_row - 1, parent_row, false, { 'moved/' })
    H.capture_messages()
    H.assert_nil(listing:sync(), 'moving parent with filtered descendants is refused')
    H.assert_true(H.exists(parent, 'hidden.log'), 'filtered descendant remains in place')
    H.assert_eq(vim.fn.readfile(parent .. '/hidden.log'), before, 'hidden bytes are unchanged')
    H.assert_notified('directory contains hidden entry', vim.log.levels.ERROR)
  end)

  H.it('fails a Git filter query safely but leaves non-repository listings unfiltered', function()
    local config = require('direct.config')
    config.setup({ map_default_keys = false, respect_gitignore = true })
    local sb = H.sandbox()
    local plain = H.mkdir(sb.root, 'plain')
    H.mkfile(plain, 'file.txt', '')
    require('direct').list(plain)
    H.assert_buf_eq({ 'file.txt' }, 0, 'outside a repository Git filtering has no effect')

    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, '.gitignore', '*.tmp\n')
    H.mkfile(root, 'hidden.tmp', '')
    init_repo(root)
    local git = require('direct.git')
    local restore = H.stub(git, 'ignored_paths', function() return nil, 'forced check-ignore failure' end)
    H.capture_messages()
    require('direct').list(root)
    restore()
    H.assert_notified('forced check-ignore failure', vim.log.levels.ERROR)
    H.assert_false(contains(H.buf_lines(), 'hidden.tmp'),
      'failed listing does not replace the previous buffer with unverifiable rows')
  end)
end)
