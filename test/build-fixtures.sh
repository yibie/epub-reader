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
printf '%s' 'application/epub+zip' >"$malicious_dir/mimetype"
printf '%s' 'escape' >"$malicious_dir/escape.txt"
find "$malicious_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/malicious-path.epub"
(cd "$malicious_dir" &&
  zip -X0q "$output_dir/malicious-path.epub" mimetype)
(cd "$malicious_dir/nested" &&
  zip -Xq "$output_dir/malicious-path.epub" ../escape.txt)

glob_dir="$work_dir/glob"
mkdir -p "$glob_dir"
printf '%s' 'application/epub+zip' >"$glob_dir/mimetype"
printf '%s' 'a' >"$glob_dir/a*"
printf '%s' 'bc' >"$glob_dir/abc"
find "$glob_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/glob-member.epub"
(cd "$glob_dir" && zip -X0q "$output_dir/glob-member.epub" mimetype)
(cd "$glob_dir" && zip -X9q -nw "$output_dir/glob-member.epub" 'a*' abc)

collision_dir="$work_dir/collision"
mkdir -p "$collision_dir/one" "$collision_dir/two"
printf '%s' 'application/epub+zip' >"$collision_dir/mimetype"
printf '%s' 'upper' >"$collision_dir/one/A.xhtml"
printf '%s' 'lower' >"$collision_dir/two/a.xhtml"
find "$collision_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/case-collision.epub"
(cd "$collision_dir" &&
  zip -X0q "$output_dir/case-collision.epub" mimetype)
(cd "$collision_dir" &&
  zip -X9qj "$output_dir/case-collision.epub" one/A.xhtml two/a.xhtml)

directory_dir="$work_dir/directories"
mkdir -p "$directory_dir/one" "$directory_dir/two"
printf '%s' 'application/epub+zip' >"$directory_dir/mimetype"
find "$directory_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/directory-entries.epub"
(cd "$directory_dir" &&
  zip -X0q "$output_dir/directory-entries.epub" mimetype)
(cd "$directory_dir" &&
  zip -X0q "$output_dir/directory-entries.epub" one/ two/)

ratio_dir="$work_dir/ratio"
mkdir -p "$ratio_dir"
printf '%s' 'application/epub+zip' >"$ratio_dir/mimetype"
printf '%04096d' 0 >"$ratio_dir/payload.txt"
find "$ratio_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/high-ratio.epub"
(cd "$ratio_dir" && zip -X0q "$output_dir/high-ratio.epub" mimetype)
(cd "$ratio_dir" && zip -X9q "$output_dir/high-ratio.epub" payload.txt)
