#!/usr/bin/env bash
# setup_fixtures.sh — Build a throwaway git repo + non-git dir fixture at runtime.
#
# Usage: setup_fixtures.sh <dest_root>
#
# Creates <dest_root>/gitdiff-repo (a real git repo: a.txt/b.txt/we[ir]d.txt
# tracked at HEAD, untracked.txt untracked) and <dest_root>/non_git_dir (c.txt,
# NOT a git repo). Prints the two paths as:
#   FIXTURE_REPO=<path> FIXTURE_NON_GIT=<path>
#
# The `:(literal)` pathspec is critical: we[ir]d.txt contains glob-magic
# characters, so a plain `git add we[ir]d.txt` matches weid/werd.txt and never
# the literal file. We also never use `git add .`/`-A` (which would wrongly
# track untracked.txt and break the untracked-file test).
set -euo pipefail

DEST="${1:?usage: setup_fixtures.sh <dest_root>}"
REPO_SRC="$(dirname "$0")/fixtures/gitdiff-repo"
NONGIT_SRC="$(dirname "$0")/fixtures/non_git_dir"

REPO="$DEST/gitdiff-repo"
NONGIT="$DEST/non_git_dir"
rm -rf "$REPO" "$NONGIT"
mkdir -p "$REPO" "$NONGIT"

# Non-git dir first (simplest): just copy c.txt.
cp "$NONGIT_SRC/c.txt" "$NONGIT/"

# Git repo: copy the plain files, then init + commit the tracked set.
cp "$REPO_SRC/a.txt" "$REPO_SRC/b.txt" "$REPO_SRC/untracked.txt" "$REPO/"
cp "$REPO_SRC/we[ir]d.txt" "$REPO/"
git init -q "$REPO"
git -C "$REPO" -c user.name=test -c user.email=test@example.com add a.txt b.txt ':(literal)we[ir]d.txt'
git -C "$REPO" -c user.name=test -c user.email=test@example.com commit -qm init

printf 'FIXTURE_REPO=%s\nFIXTURE_NON_GIT=%s\n' "$REPO" "$NONGIT"