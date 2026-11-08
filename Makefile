NVIM ?= nvim
COVERAGE_PLATFORM ?= local
DEMO_FONT ?= JetBrainsMono Nerd Font
DEMO_GIF ?= demo/tour.gif

.PHONY: ci test coverage coverage-deps coverage-summary live-startup demo demo-record demo-gif demo-check check-nvim

ci:
	$(MAKE) coverage
	$(MAKE) coverage-summary
	$(MAKE) live-startup

test: check-nvim
	$(NVIM) --headless -l tests/run.lua

coverage-deps:
	bash tests/install_coverage_deps.sh

coverage: check-nvim coverage-deps
	@mkdir -p coverage
	@rm -f coverage/luacov.stats.out coverage/index.html coverage/summary.out
	NVIM='$(NVIM)' bash tests/run_coverage.sh

coverage-summary:
	@test -s coverage/luacov.stats.out || { echo 'Run make coverage before make coverage-summary' >&2; exit 1; }
	@{ printf '## Coverage (%s)\n\n```text\n' '$(COVERAGE_PLATFORM)'; cat coverage/summary.out; printf '```\n'; } > coverage/summary.md
	@if test -n "$$GITHUB_STEP_SUMMARY"; then cat coverage/summary.md >> "$$GITHUB_STEP_SUMMARY"; else cat coverage/summary.md; fi

live-startup:
	bash tests/live_startup.sh

# The README demo: record the tour with asciinema, then convert it to a GIF
# with agg. DEMO_FONT must be a Nerd Font, so the icons render.
demo: demo-record demo-gif

demo-record: check-nvim
	NVIM='$(NVIM)' CAST_DIR='$(abspath demo/casts)' ./demo/demo.sh --force

demo-gif:
	@test -s demo/casts/tour.cast || { echo 'Run make demo-record before make demo-gif' >&2; exit 1; }
	@command -v agg >/dev/null 2>&1 || { echo 'agg is required to convert the recording (install it and ensure it is on PATH)' >&2; exit 1; }
	agg --font-family '$(DEMO_FONT)' demo/casts/tour.cast '$(DEMO_GIF)'

# Play the tour without recording it, and check its result.
demo-check: check-nvim
	NVIM='$(NVIM)' ./demo/demo.sh --check

check-nvim:
	@command -v $(NVIM) >/dev/null 2>&1 || { echo 'Neovim >= 0.12 is required (set NVIM=/path/to/nvim if needed)' >&2; exit 1; }
	@$(NVIM) --headless -u NONE -l tests/check_nvim.lua
