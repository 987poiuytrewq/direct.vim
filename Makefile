NVIM ?= nvim
LUAROCKS ?= luarocks
LUACOV_VERSION ?= 0.17.0

.PHONY: install test coverage coverage-summary check-nvim check-luarocks

install: check-nvim check-luarocks
	$(LUAROCKS) --lua-version=5.1 --tree=.rocks install luacov $(LUACOV_VERSION)
	@assets=$$(find .rocks/lib/luarocks/rocks-5.1/luacov -path '*/src/luacov/reporter/html/static' -type d -print -quit); \
	  test -n "$$assets" || { echo 'LuaCov HTML assets were not installed' >&2; exit 1; }; \
	  mkdir -p .rocks/share/lua/5.1/src/luacov/reporter/html; \
	  cp -R "$$assets" .rocks/share/lua/5.1/src/luacov/reporter/html/

test: check-nvim
	$(NVIM) --headless -l tests/run.lua

coverage: install
	@mkdir -p coverage
	@rm -f coverage/luacov.stats.out coverage/index.html coverage/summary.out
	@eval "$$($(LUAROCKS) --lua-version=5.1 --tree=.rocks path)"; \
	  DIRECT_COVERAGE=1 $(NVIM) --headless -l tests/run.lua; test_status=$$?; \
	  if test -f coverage/luacov.stats.out; then \
	    $(NVIM) --headless -l tests/coverage_report.lua; report_status=$$?; \
	  else \
	    echo 'coverage stats were not generated' >&2; report_status=1; \
	  fi; \
	  if test -f coverage/summary.out; then sed -n '/^Summary$$/,$$p' coverage/summary.out; fi; \
	  if test $$test_status -ne 0; then exit $$test_status; fi; \
	  exit $$report_status

coverage-summary:
	@test -s coverage/luacov.stats.out || { echo 'Run make coverage before make coverage-summary' >&2; exit 1; }
	@$(NVIM) --headless -l tests/coverage_summary.lua
	@if test -n "$$GITHUB_STEP_SUMMARY"; then cat coverage/summary.md >> "$$GITHUB_STEP_SUMMARY"; else cat coverage/summary.md; fi

check-nvim:
	@command -v $(NVIM) >/dev/null 2>&1 || { echo 'Neovim >= 0.12 is required (set NVIM=/path/to/nvim if needed)' >&2; exit 1; }
	@$(NVIM) --headless -u NONE +'lua local v=vim.version(); if v.major == 0 and v.minor < 12 then vim.api.nvim_err_writeln("Neovim >= 0.12 is required"); vim.cmd("cquit 1") end' +qa

check-luarocks:
	@command -v $(LUAROCKS) >/dev/null 2>&1 || { echo 'LuaRocks is required to install coverage tooling (set LUAROCKS=/path/to/luarocks if needed)' >&2; exit 1; }
