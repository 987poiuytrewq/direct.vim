NVIM ?= nvim
GIT ?= git
SHELL := bash
LUACOV_VERSION ?= v0.17.0
LUACOV_REPORTERS_VERSION ?= 0.1.0
DATAFILE_VERSION ?= v0.11
COVERAGE_PLATFORM ?= local
COVERAGE_LUA := .rocks/share/lua/5.1
COVERAGE_TMP := .rocks/tmp

.PHONY: ci test coverage coverage-deps coverage-summary live-startup check-nvim

ci:
	$(MAKE) coverage
	$(MAKE) coverage-summary
	$(MAKE) live-startup

test: check-nvim
	$(NVIM) --headless -l tests/run.lua

coverage-deps:
	@mkdir -p $(COVERAGE_LUA) $(COVERAGE_TMP)
	@rm -rf $(COVERAGE_TMP)/luacov $(COVERAGE_TMP)/luacov-reporters
	@rm -rf $(COVERAGE_LUA)/luacov $(COVERAGE_LUA)/luacov.lua
	$(GIT) clone --quiet --depth 1 --branch $(LUACOV_VERSION) https://github.com/lunarmodules/luacov.git $(COVERAGE_TMP)/luacov
	cp -R $(COVERAGE_TMP)/luacov/src/. $(COVERAGE_LUA)/
	@mkdir -p $(COVERAGE_LUA)/src/luacov/reporter/html
	cp -R $(COVERAGE_TMP)/luacov/src/luacov/reporter/html/static $(COVERAGE_LUA)/src/luacov/reporter/html/
	$(GIT) clone --quiet --depth 1 --branch $(LUACOV_REPORTERS_VERSION) https://github.com/tarantool/luacov-reporters.git $(COVERAGE_TMP)/luacov-reporters
	cp -R $(COVERAGE_TMP)/luacov-reporters/luacov/. $(COVERAGE_LUA)/luacov/
	$(GIT) clone --quiet --depth 1 --branch $(DATAFILE_VERSION) https://github.com/hishamhm/datafile.git $(COVERAGE_TMP)/datafile
	cp -R $(COVERAGE_TMP)/datafile/datafile.lua $(COVERAGE_TMP)/datafile/datafile $(COVERAGE_LUA)/
	@rm -rf $(COVERAGE_TMP)

coverage: check-nvim coverage-deps
	@mkdir -p coverage
	@rm -f coverage/luacov.stats.out coverage/index.html coverage/summary.out
	@DIRECT_COVERAGE=1 $(NVIM) --headless -l tests/run.lua; test_status=$$?; \
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
	@printf '## Coverage (%s)\n\n' '$(COVERAGE_PLATFORM)' > coverage/summary.md
	@printf '```text\n' >> coverage/summary.md
	@cat coverage/summary.out >> coverage/summary.md
	@printf '```\n' >> coverage/summary.md
	@if test -n "$$GITHUB_STEP_SUMMARY"; then cat coverage/summary.md >> "$$GITHUB_STEP_SUMMARY"; else cat coverage/summary.md; fi

live-startup:
	bash tests/live_startup.sh

check-nvim:
	@command -v $(NVIM) >/dev/null 2>&1 || { echo 'Neovim >= 0.12 is required (set NVIM=/path/to/nvim if needed)' >&2; exit 1; }
	@$(NVIM) --headless -u NONE +'lua local v=vim.version(); if v.major == 0 and v.minor < 12 then vim.api.nvim_err_writeln("Neovim >= 0.12 is required"); vim.cmd("cquit 1") end' +qa
