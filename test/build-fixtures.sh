#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
source_dir="$project_dir/test/fixtures-src"
output_dir="$project_dir/test/fixtures"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/epub-reader-fixtures.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

mkdir -p "$output_dir"

build_epub() {
  name=$1
  content_dir=$2
  staging_dir="$work_dir/$name"
  archive="$output_dir/$name.epub"

  mkdir -p "$staging_dir"
  cp -R "$content_dir"/. "$staging_dir"/
  printf '%s' 'application/epub+zip' >"$staging_dir/mimetype"
  find "$staging_dir" -exec touch -t 202001010000 {} +
  rm -f "$archive"
  (cd "$staging_dir" && zip -X0q "$archive" mimetype)
  (cd "$staging_dir" && zip -X9qrD "$archive" META-INF)
  if [ -d "$staging_dir/OEBPS" ]; then
    (cd "$staging_dir" && zip -X9qrD "$archive" OEBPS)
  fi
  if [ -d "$staging_dir/EPUB" ]; then
    (cd "$staging_dir" && zip -X9qrD "$archive" EPUB)
  fi
}

build_epub epub2 "$source_dir/epub2"
build_epub epub3 "$source_dir/epub3"

malicious_dir="$work_dir/malicious"
mkdir -p "$malicious_dir/nested"
printf '%s' 'escape' >"$malicious_dir/escape.txt"
touch -t 202001010000 "$malicious_dir/escape.txt"
rm -f "$output_dir/malicious-path.epub"
(cd "$malicious_dir/nested" &&
  zip -Xq "$output_dir/malicious-path.epub" ../escape.txt)
