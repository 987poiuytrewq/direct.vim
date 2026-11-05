#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
NVIM=${NVIM:-nvim}
ASCIINEMA=${ASCIINEMA:-asciinema}
EXPECT=${EXPECT:-expect}
CAST_DIR=${CAST_DIR:-"$SCRIPT_DIR/casts"}
MODE=record
FORCE=0

usage() {
  cat <<'EOF'
Usage: demo.sh [--check] [--force]

Records one continuous tour organized as three folders you enter in sequence:
file edits, nested moves, and directory copy/paste.

Options:
  --check   run the tour headlessly and verify its filesystem results;
            does not require asciinema and does not create a recording
  --force   replace an existing recording

Set CAST_DIR to choose another recording directory.
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
if [[ "$MODE" == record ]] && ! command -v "$EXPECT" >/dev/null 2>&1; then
  echo "demo: Expect is required to send real keystrokes: $EXPECT" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo 'demo: Git is required to create the demo repository' >&2
  exit 1
fi

create_fixture() {
  local workspace=$1

  mkdir -p "$workspace/01-file-edits" \
    "$workspace/02-browse-and-move/move-from" \
    "$workspace/02-browse-and-move/move-to" \
    "$workspace/03-copy-and-paste/copy-from/examples" \
    "$workspace/03-copy-and-paste/copy-to"
  mkdir -p "$workspace/01-file-edits/.demo-settings"
  printf 'Visible hidden-file example.\n' > "$workspace/01-file-edits/.env.example"
  printf 'Visible hidden-folder example.\n' \
    > "$workspace/01-file-edits/.demo-settings/.editor-settings"
  printf 'This file is modified in Git.\n' > "$workspace/01-file-edits/edit-me.txt"
  printf 'Rename this file in the tour.\n' > "$workspace/01-file-edits/rename-me.txt"
  printf 'Delete, then restore, this file.\n' > "$workspace/01-file-edits/delete-me.txt"
  printf 'Copy this folder.\n' > "$workspace/03-copy-and-paste/copy-from/copy-me.txt"
  printf 'This nested example comes along too.\n' \
    > "$workspace/03-copy-and-paste/copy-from/examples/nested-example.txt"
  printf 'Move this file into move-to/.\n' \
    > "$workspace/02-browse-and-move/move-from/move-me.txt"

  git -C "$workspace" init -q
  git -C "$workspace" config user.name 'Direct Demo'
  git -C "$workspace" config user.email 'direct-demo@example.invalid'
  git -C "$workspace" add 01-file-edits 02-browse-and-move 03-copy-and-paste
  git -C "$workspace" commit -qm 'Create demo repository'
  printf 'This file has changed since the Git commit.\n' \
    > "$workspace/01-file-edits/edit-me.txt"
  printf 'A new, untracked file inside move-from/.\n' \
    > "$workspace/02-browse-and-move/move-from/added-in-git.txt"
}

validate_fixture() {
  local workspace=$1
  local git_status

  [[ -f "$workspace/01-file-edits/renamed-file.txt" \
    && -f "$workspace/01-file-edits/created-file.txt" \
    && -d "$workspace/01-file-edits/created-folder" ]] \
    && [[ ! -e "$workspace/01-file-edits/rename-me.txt" \
      && ! -e "$workspace/01-file-edits/delete-me.txt" ]] \
    && [[ -f "$workspace/02-browse-and-move/move-me.txt" \
      && ! -e "$workspace/02-browse-and-move/move-from/move-me.txt" ]] \
    && [[ -f "$workspace/03-copy-and-paste/copy-to/copy-from/copy-me.txt" \
      && -f "$workspace/03-copy-and-paste/copy-to/copy-from/examples/nested-example.txt" ]] \
    || { echo 'demo: tour did not produce the expected filesystem changes' >&2; return 1; }

  git_status=$(git -C "$workspace" status --porcelain)
  [[ "$git_status" == *' M 01-file-edits/edit-me.txt'* \
    && "$git_status" == *'?? 02-browse-and-move/move-from/added-in-git.txt'* ]] \
    || { echo 'demo: tour is missing its expected Git changes' >&2; return 1; }
}

run_tour() (
  local sandbox workspace cast_file command
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/direct-demo.XXXXXX")
  trap 'rm -rf -- "$sandbox"' EXIT
  workspace="$sandbox/workspace"
  mkdir -p "$workspace" "$sandbox/data"
  create_fixture "$workspace"

  export XDG_DATA_HOME="$sandbox/data"
  export DIRECT_DEMO_REPO="$REPO_ROOT"
  export DIRECT_DEMO_SCRIPT_DIR="$SCRIPT_DIR"

  if [[ "$MODE" == check ]]; then
    echo 'Checking the continuous demo tour'
    export DIRECT_DEMO_SCENARIO_FILE="$SCRIPT_DIR/tour.vim"
    "$NVIM" --headless -u "$SCRIPT_DIR/init.lua" \
      -c 'execute "source " . fnameescape($DIRECT_DEMO_SCENARIO_FILE)' \
      -- "$workspace"
  else
    mkdir -p "$CAST_DIR"
    cast_file="$CAST_DIR/tour.cast"
    if [[ -e "$cast_file" && $FORCE -ne 1 ]]; then
      echo "demo: recording already exists: $cast_file (pass --force to replace it)" >&2
      return 1
    fi
    printf -v command '%q ' "$NVIM" -u "$SCRIPT_DIR/init.lua" -- "$workspace"
    echo "Recording the demo tour -> $cast_file"
    "$EXPECT" -f "$SCRIPT_DIR/drive.expect" \
      "$ASCIINEMA" "$cast_file" "$command" "$FORCE"
  fi

  validate_fixture "$workspace"
  echo 'Passed: demo tour'
)

run_tour
