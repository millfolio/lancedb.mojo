#!/usr/bin/env bash
#
# Stage all changes, commit with the standard Co-Authored-By trailer (no GPG
# prompt), AND push. One approvable command — do NOT chain `&& git push` onto it.
# `push -u origin HEAD` works for the first push (sets upstream) and every later one.
#
#   tools/commit.sh "<commit message>"
set -euo pipefail

MSG="${1:?usage: tools/commit.sh \"message\"}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

git -C "$ROOT" add -A
git -C "$ROOT" -c commit.gpgsign=false commit \
  -m "$MSG" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git -C "$ROOT" push -u origin HEAD
