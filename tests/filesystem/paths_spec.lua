-- tests/paths_spec.lua -- sandbox helpers, data paths, hashing, and identity.

-- Proves sandbox()/fs_snapshot shape and the paths contract: absolute
-- root(), XDG precedence, sha256 digest, and path-identity comparison via
-- fs.same_path rather than string equality.

local H = require('tests.support.harness')
local paths = require('direct.paths')
local fs = require('direct.fs')

H.describe('paths', function()
  H.it('sandbox() roots exist and fs_snapshot has the expected shape', function()
    local sb = H.sandbox()

    H.assert_true(vim.uv.fs_stat(sb.root) ~= nil, 'sandbox root exists on disk')
    H.assert_true(vim.uv.fs_stat(sb.data_home) ~= nil, 'sandbox data_home exists on disk')
    H.assert_eq(vim.fn.isdirectory(sb.root), 1, 'sandbox root is a directory')
    H.assert_eq(vim.fn.isdirectory(sb.data_home), 1, 'sandbox data_home is a directory')

    -- XDG_DATA_HOME is pointed inside the sandbox for isolation.
    H.assert_eq(vim.env.XDG_DATA_HOME, sb.data_home,
      'sandbox redirects XDG_DATA_HOME into itself')

    H.mkdir(sb.root, 'sub')
    H.mkfile(sb.root, 'a.txt', { 'hello' })
    H.mkfile(sb.root, 'sub/b.txt', 'world')

    H.assert_true(H.exists(sb.root, 'a.txt'), 'exists() sees a created file')
    H.assert_eq(H.ls(sb.root), { 'a.txt', 'data', 'sub' }, 'ls() is sorted')
    H.assert_true(H.inode_of(sb.root .. '/a.txt') ~= nil, 'inode_of() reads a stat')

    -- fs_snapshot: globally sorted, directories trailing "/", files bare.
    H.assert_fs_eq(sb.root, {
      'a.txt',
      'data/',
      'sub/',
      'sub/b.txt',
    })
  end)

  H.it('root() absolutises relative inputs', function()
    for _, input in ipairs({ '.', '..', 'a/b' }) do
      local resolved = paths.root(input)
      H.assert_true(resolved:sub(1, 1) == '/',
        string.format('root(%q) is absolute: %s', input, resolved))
    end
    -- vim.fs.normalize alone leaves 'a/b' relative, so root() must not be just
    -- normalize().
    H.assert_eq(paths.root('.'), vim.fs.abspath(vim.fs.normalize('.')),
      "root('.') == abspath(normalize('.'))")
    H.assert_true(paths.root('a/b') ~= vim.fs.normalize('a/b'),
      'root() is not just vim.fs.normalize()')
  end)

  H.it('root() denotes the same directory as a stored buffer name (fs.same_path)', function()
    local sb = H.sandbox()
    local root = paths.root(sb.root)
    vim.cmd('enew')
    vim.api.nvim_buf_set_name(0, root)
    local name = vim.api.nvim_buf_get_name(0)
    -- attach compares nvim_buf_get_name(b) against root with fs.same_path,
    -- never `==`: nvim_buf_set_name resolves a symlinked prefix while
    -- paths.root() does not, so string equality would miss.
    H.assert_true(fs.same_path(name, root),
      'buffer name and root denote the same directory by ino+dev')
  end)

  H.it('data_home() honours a set XDG_DATA_HOME', function()
    local sb = H.sandbox()
    local xdg = sb.root .. '/data-alt'
    H.with_env({ XDG_DATA_HOME = xdg }, function()
      H.assert_eq(paths.data_home(), xdg, 'XDG_DATA_HOME is used')
    end)
  end)

  H.it('data_home() falls back to $HOME/.local/share', function()
    -- with_env restores HOME afterwards; XDG_DATA_HOME must be unset *inside*
    -- the window (a nil value cannot be a table-literal key, harness).
    H.with_env({ HOME = '/home/direct-probe' }, function()
      vim.env.XDG_DATA_HOME = nil
      H.assert_eq(paths.data_home(), '/home/direct-probe/.local/share',
        '$HOME/.local/share when XDG_DATA_HOME is unset')
    end)
  end)

  H.it('data_home() warns and uses stdpath when both are unset', function()
    H.capture_messages()
    H.with_env({ HOME = vim.env.HOME }, function()
      vim.env.XDG_DATA_HOME = nil
      vim.env.HOME = nil
      H.assert_eq(paths.data_home(), vim.fn.stdpath('data'),
        'stdpath fallback when both are unset')
    end)
    H.assert_notified('$XDG_DATA_HOME')
  end)

  H.it('data_dir() creates <data_home>/direct/<name> under the sandbox', function()
    local sb = H.sandbox()
    local dir = paths.data_dir('history')
    H.assert_eq(dir, sb.data_home .. '/direct/history', 'data_dir path')
    H.assert_eq(vim.fn.isdirectory(dir), 1, 'data_dir is created on demand')
  end)

  H.it('data_dir_path() is pure and ensure_data_dir() creates its result', function()
    local sb = H.sandbox()
    local expected = vim.fs.joinpath(sb.data_home, 'direct', 'history')
    local resolved = paths.data_dir_path('history')
    H.assert_eq(resolved, expected, 'pure resolver returns the expected path')
    H.assert_eq(vim.fn.isdirectory(vim.fs.dirname(resolved)), 0,
      'pure resolution did not create the data directory')
    H.assert_eq(paths.ensure_data_dir('history'), expected,
      'creating resolver returns the resolved path')
    H.assert_eq(vim.fn.isdirectory(expected), 1, 'creating resolver created it')
  end)

  H.it('valid_utf8 rejects malformed sequences and accepts Unicode', function()
    H.assert_true(paths.valid_utf8('naïve/猫'), 'valid multibyte text')
    H.assert_false(paths.valid_utf8('bad\255path'), 'invalid lead byte')
    H.assert_false(paths.valid_utf8('bad\192\128'), 'overlong sequence')
  end)

  H.it('data_dir() returns nil, err when <data_home>/direct is a file', function()
    local sb = H.sandbox()
    H.mkfile(sb.data_home, 'direct', { 'i am a file' })
    local dir, err = paths.data_dir('history')
    H.assert_nil(dir, 'data_dir returns nil when the data dir is occupied by a file')
    H.assert_true(type(err) == 'string' and #err > 0, 'data_dir carries an err string')
    H.assert_eq(vim.fn.isdirectory(sb.data_home .. '/direct'), 0, 'direct is still a file, not a dir')
    H.assert_eq(vim.fn.readfile(sb.data_home .. '/direct'), { 'i am a file' },
      'the occupying file is untouched')
  end)

  H.it('data_dir() returns nil, err on a read-only data home', function()
    local sb = H.sandbox()
    H.assert_true(vim.uv.fs_chmod(sb.data_home, tonumber('500', 8)) == true,
      'precondition: data home chmod 0500')
    local dir, err = paths.data_dir('register')
    H.assert_nil(dir, 'data_dir returns nil on a read-only data home')
    H.assert_true(type(err) == 'string' and #err > 0, 'data_dir carries an err string')
    -- Restore so sandbox teardown can remove the tree.
    pcall(vim.uv.fs_chmod, sb.data_home, tonumber('700', 8))
  end)

  H.it('digest() is sha256 over NUL-joined paths', function()
    -- Compare against a known digest, not vim.fn.sha256 itself, so a wrong
    -- separator or join is caught. The literal was produced with
    -- `printf 'a\0b\0c' | shasum -a 256` on nvim 0.12.5.
    local expected = '8badde10c760e9b702defb4b5e225de79c515b1d2a5cfb000e140f3c6fbb5629'
    H.assert_eq(paths.digest('a', 'b', 'c'), expected, 'varargs form')
    H.assert_eq(paths.digest({ 'a', 'b', 'c' }), expected, 'single list form')
    H.assert_eq(vim.fn.sha256('a\0b\0c'), expected, 'oracle agrees with vim.fn.sha256')
    H.assert_true(paths.digest('a', 'b') ~= paths.digest('b', 'a'),
      'argument order is significant (the caller sorts)')
  end)

  H.it('basename() strips a trailing slash', function()
    H.assert_eq(paths.basename('/a/b/'), 'b', 'trailing slash stripped')
    H.assert_eq(paths.basename('/a/b'), 'b', 'no trailing slash')
    H.assert_eq(paths.basename('dir1/'), 'dir1', 'bare directory')
  end)
end)
