#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
textui_dir=${TEXTUI_DIR:-/Users/chenyibin/Documents/emacs/package/textui}
emacs_bin=${EMACS:-emacs}

"$project_dir/test/build-fixtures.sh"

set -- -Q --batch -L "$textui_dir" -L "$project_dir" -L "$project_dir/test"
for test_file in "$project_dir"/test/*-test.el; do
  set -- "$@" -l "$test_file"
done

exec "$emacs_bin" "$@" -f ert-run-tests-batch-and-exit
