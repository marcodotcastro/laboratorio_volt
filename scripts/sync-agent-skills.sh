#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_DIR="$ROOT_DIR/skills"

[ -d "$CANONICAL_DIR" ] || {
  printf 'ERROR: canonical skills directory is missing: %s\n' "$CANONICAL_DIR" >&2
  exit 1
}

skill_count=0
while IFS= read -r skill_file; do
  skill_count=$((skill_count + 1))
done < <(find "$CANONICAL_DIR" -mindepth 2 -maxdepth 3 -type f -name SKILL.md -print)
[ "$skill_count" -gt 0 ] || {
  printf 'ERROR: no canonical SKILL.md files found in %s\n' "$CANONICAL_DIR" >&2
  exit 1
}

for adapter in .agents/skills .claude/skills .cursor/skills .opencode/skills; do
  adapter_path="$ROOT_DIR/$adapter"
  adapter_parent="$(dirname "$adapter_path")"
  mkdir -p "$adapter_parent"

  if [ -L "$adapter_path" ]; then
    [ "$(readlink "$adapter_path")" = "../skills" ] || {
      printf 'ERROR: adapter points somewhere else: %s\n' "$adapter_path" >&2
      exit 1
    }
  elif [ -e "$adapter_path" ]; then
    printf 'ERROR: refusing to replace an existing adapter: %s\n' "$adapter_path" >&2
    exit 1
  else
    ln -s ../skills "$adapter_path"
  fi
done

printf 'Synchronized %s canonical skills through agent adapters.\n' "$skill_count"
