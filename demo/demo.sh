#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
NVIM=${NVIM:-nvim}
ASCIINEMA=${ASCIINEMA:-asciinema}
EXPECT=${EXPECT:-expect}
CAST_DIR=${CAST_DIR:-"$SCRIPT_DIR/casts"}
PLUGIN_DIR=${PLUGIN_DIR:-"$SCRIPT_DIR/.plugins"}
MODE=record
FORCE=0

usage() {
  cat <<'EOF'
Usage: demo.sh [--check] [--force]

Records one continuous tour of a small Neovim plugin project: browsing,
renaming, creating, deleting with undo, copying folders, and Git.

Options:
  --check   play the tour without recording it and verify the result;
            does not require asciinema
  --force   replace an existing recording

Set CAST_DIR to choose another recording directory, and PLUGIN_DIR to choose
where the demo's plugins are downloaded (default: demo/.plugins).
EOF
}

while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --check) MODE=check ;;
    --force) FORCE=1 ;;
    *)
      echo "demo: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v "$NVIM" >/dev/null 2>&1; then
  echo "demo: Neovim executable not found: $NVIM" >&2
  exit 1
fi
if [[ "$MODE" == record ]] && ! command -v "$ASCIINEMA" >/dev/null 2>&1; then
  echo "demo: asciinema executable not found: $ASCIINEMA (use --check to validate without recording)" >&2
  exit 1
fi
if ! command -v "$EXPECT" >/dev/null 2>&1; then
  echo "demo: Expect is required to send real keystrokes: $EXPECT" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo 'demo: Git is required to create the demo repository' >&2
  exit 1
fi

# The plugins most Neovim setups have, so the demo looks familiar. They are
# downloaded once, at pinned versions, into PLUGIN_DIR (ignored by Git).
PLUGINS=(
  "tokyonight.nvim https://github.com/folke/tokyonight.nvim v4.14.1"
  "nvim-web-devicons https://github.com/nvim-tree/nvim-web-devicons v0.100"
  "lualine.nvim https://github.com/nvim-lualine/lualine.nvim 221ce6b2d999187044529f49da6554a92f740a96"
  "bufferline.nvim https://github.com/akinsho/bufferline.nvim v4.9.1"
)

install_plugins() {
  local entry name url ref
  mkdir -p "$PLUGIN_DIR"
  for entry in "${PLUGINS[@]}"; do
    read -r name url ref <<<"$entry"
    [[ -d "$PLUGIN_DIR/$name" ]] && continue
    echo "Downloading $name"
    if ! git clone --quiet --filter=blob:none "$url" "$PLUGIN_DIR/$name" \
      || ! git -C "$PLUGIN_DIR/$name" checkout --quiet "$ref"; then
      rm -rf -- "${PLUGIN_DIR:?}/$name"
      echo "demo: could not download $name; the demo will use a plainer look" >&2
    fi
  done
}

# A small Neovim plugin project: committed to Git, then changed a little, so
# the very first frame shows icons, Git status and hidden ignored files.
create_fixture() {
  local root=$1
  mkdir -p "$root"/{.github/workflows,build,doc,examples/minimal,lua/my-plugin,plugin,tests}

  printf 'name: CI\non: [push]\n' > "$root/.github/workflows/ci.yml"
  printf 'build/\n*.log\n' > "$root/.gitignore"
  printf 'MIT License\n' > "$root/LICENSE"
  printf '# my-plugin\n\nA small Neovim plugin.\n' > "$root/README.md"
  printf '*my-plugin.txt*\n' > "$root/doc/my-plugin.txt"
  printf "require('my-plugin').setup()\n" > "$root/examples/minimal/init.lua"
  printf 'return {}\n' > "$root/lua/my-plugin/init.lua"
  printf 'return { enabled = true }\n' > "$root/lua/my-plugin/config.lua"
  printf 'return {}\n' > "$root/lua/my-plugin/utils.lua"
  printf "require('my-plugin')\n" > "$root/plugin/my-plugin.lua"
  local name
  for name in config init utils; do
    printf "describe('%s', function() end)\n" "$name" > "$root/tests/${name}_test.lua"
  done

  git -C "$root" init -q
  git -C "$root" config user.name 'Demo'
  git -C "$root" config user.email 'demo@example.invalid'
  git -C "$root" add -A
  git -C "$root" commit -qm 'Initial commit'

  # Ignored by .gitignore, so hidden from the listing.
  printf 'binary\n' > "$root/build/my-plugin.so"
  printf 'log\n' > "$root/debug.log"
  # Changes for the Git status column to show.
  printf '# my-plugin\n\nA small, fast Neovim plugin.\n' > "$root/README.md"
  printf 'return { enabled = true, verbose = false }\n' > "$root/lua/my-plugin/config.lua"
  printf 'Ideas:\n' > "$root/scratch.txt"
}

# The project as the tour should leave it.
validate_fixture() {
  local root=$1 path failed=0
  for path in \
    lua/my-plugin/strings.lua \
    tests/config_spec.lua tests/init_spec.lua tests/utils_spec.lua \
    docs/guide/getting-started.md \
    examples/minimal/init.lua examples/advanced/init.lua; do
    [[ -e "$root/$path" ]] || { echo "demo: expected $path to exist" >&2; failed=1; }
  done
  for path in lua/my-plugin/utils.lua tests/config_test.lua scratch.txt notes.txt; do
    [[ ! -e "$root/$path" ]] || { echo "demo: expected $path to be gone" >&2; failed=1; }
  done
  git -C "$root" diff --cached --name-only | grep -qx README.md \
    || { echo 'demo: expected README.md to be staged' >&2; failed=1; }
  ((failed == 0))
}

run_tour() (
  local sandbox workspace cast_file command socket
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/direct-demo.XXXXXX")
  trap 'rm -rf -- "$sandbox"' EXIT
  workspace="$sandbox/my-plugin"
  mkdir -p "$workspace" "$sandbox/data"
  create_fixture "$workspace"

  export XDG_DATA_HOME="$sandbox/data"
  export DIRECT_DEMO_REPO="$REPO_ROOT"
  export DIRECT_DEMO_WORKSPACE="$workspace"
  export DIRECT_DEMO_PLUGINS="$PLUGIN_DIR"

  # The socket lets drive.expect show captions without typing them.
  socket="$sandbox/nvim.sock"
  # Start inside the project, so messages show paths relative to it.
  cd "$workspace"
  printf -v command '%q ' "$NVIM" --listen "$socket" -u "$SCRIPT_DIR/init.lua" -- .
  if [[ "$MODE" == check ]]; then
    # The same tour, typed into a plain terminal instead of asciinema's.
    echo 'Checking the demo tour (this takes as long as a recording)'
    "$EXPECT" -f "$SCRIPT_DIR/drive.expect" \
      "" "" "$command" "$FORCE" "$NVIM" "$socket"
  else
    mkdir -p "$CAST_DIR"
    cast_file="$CAST_DIR/tour.cast"
    if [[ -e "$cast_file" && $FORCE -ne 1 ]]; then
      echo "demo: recording already exists: $cast_file (pass --force to replace it)" >&2
      return 1
    fi
    echo "Recording the demo tour -> $cast_file"
    "$EXPECT" -f "$SCRIPT_DIR/drive.expect" \
      "$ASCIINEMA" "$cast_file" "$command" "$FORCE" "$NVIM" "$socket"
  fi

  validate_fixture "$workspace"
  echo 'Passed: demo tour'
)

# The tour runs from inside the project, so make these paths absolute first.
[[ "$CAST_DIR" == /* ]] || CAST_DIR="$PWD/$CAST_DIR"
[[ "$PLUGIN_DIR" == /* ]] || PLUGIN_DIR="$PWD/$PLUGIN_DIR"

install_plugins
run_tour
