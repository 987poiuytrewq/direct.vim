#!/usr/bin/env bash
set -euo pipefail

coverage_lua=.rocks/share/lua/5.1
coverage_tmp=.rocks/tmp

mkdir -p "$coverage_tmp"
rm -rf "$coverage_tmp"/* "$coverage_lua/luacov" "$coverage_lua/luacov.lua"
mkdir -p "$coverage_lua/src/luacov/reporter/html" "$coverage_lua/luacov"
trap 'rm -rf "$coverage_tmp"' EXIT

git clone --quiet --depth 1 --branch v0.17.0 \
  https://github.com/lunarmodules/luacov.git "$coverage_tmp/luacov"
cp -R "$coverage_tmp/luacov/src/." "$coverage_lua/"
cp -R "$coverage_tmp/luacov/src/luacov/reporter/html/static" \
  "$coverage_lua/src/luacov/reporter/html/"

git clone --quiet --depth 1 --branch 0.1.0 \
  https://github.com/tarantool/luacov-reporters.git "$coverage_tmp/luacov-reporters"
cp -R "$coverage_tmp/luacov-reporters/luacov/." "$coverage_lua/luacov/"

git clone --quiet --depth 1 --branch v0.11 \
  https://github.com/hishamhm/datafile.git "$coverage_tmp/datafile"
cp -R "$coverage_tmp/datafile/datafile.lua" "$coverage_tmp/datafile/datafile" "$coverage_lua/"
