package = 'luacov-reporters'
version = '0.1.0-1'

source = {
  url = 'git+https://github.com/tarantool/luacov-reporters.git',
  tag = '0.1.0',
}

description = {
  summary = 'Additional summary and SonarQube reporters for LuaCov',
  homepage = 'https://github.com/tarantool/luacov-reporters',
  license = 'MIT',
}

dependencies = {
  'lua >= 5.1',
}

build = {
  type = 'builtin',
  modules = {
    ['luacov.reporters_utils'] = 'luacov/reporters_utils.lua',
    ['luacov.reporter.sonar'] = 'luacov/reporter/sonar.lua',
    ['luacov.reporter.summary'] = 'luacov/reporter/summary.lua',
  },
}
