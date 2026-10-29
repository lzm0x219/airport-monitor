#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <version-tag> <notes-directory> <output-file>" >&2
  exit 2
fi

tag=$1
notes_dir=$2
output_file=$3

if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Expected a stable version tag such as v1.0.0; got: $tag" >&2
  exit 1
fi

notes_file="$notes_dir/$tag.md"
if [[ ! -f "$notes_file" ]] || ! LC_ALL=C grep -q '[^[:space:]]' "$notes_file"; then
  echo "Missing or empty release notes: $notes_file" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_file")"
cp "$notes_file" "$output_file"
