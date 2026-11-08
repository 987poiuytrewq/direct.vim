#!/usr/bin/env bash
set -u

nvim=${NVIM:-nvim}

if DIRECT_COVERAGE=1 "$nvim" --headless -l tests/run.lua; then
  test_status=0
else
  test_status=$?
fi

if [[ -f coverage/luacov.stats.out ]]; then
  if "$nvim" --headless -l tests/coverage_report.lua; then
    report_status=0
  else
    report_status=$?
  fi
else
  echo 'coverage stats were not generated' >&2
  report_status=1
fi

if [[ -f coverage/summary.out ]]; then
  sed -n '/^Summary$/,$p' coverage/summary.out
fi

if (( test_status != 0 )); then
  exit "$test_status"
fi
exit "$report_status"
