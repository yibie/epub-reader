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
build_epub epub3-edge "$source_dir/epub3-edge"

missing_media_source="$work_dir/epub3-missing-media-source"
cp -R "$source_dir/epub3-edge" "$missing_media_source"
perl -0pi -e 's/ id="chapter" href="text\/a%20b.xhtml" media-type="application\/xhtml\+xml"/ id="chapter" href="text\/a%20b.xhtml"/' \
  "$missing_media_source/EPUB/package.opf"
build_epub epub3-missing-media "$missing_media_source"

duplicate_url_source="$work_dir/epub3-duplicate-url-source"
cp -R "$source_dir/epub3-edge" "$duplicate_url_source"
perl -0pi -e 's|(<item id="chapter"[^>]*/>)|$1\n    <item id="duplicate" href="text/./a%20b.xhtml" media-type="application/xhtml+xml"/>|' \
  "$duplicate_url_source/EPUB/package.opf"
build_epub epub3-duplicate-url "$duplicate_url_source"

remote_spine_source="$work_dir/epub3-remote-spine-source"
cp -R "$source_dir/epub3-edge" "$remote_spine_source"
perl -0pi -e 's/<itemref idref="chapter"\/>/<itemref idref="remote"\/>/' \
  "$remote_spine_source/EPUB/package.opf"
build_epub epub3-remote-spine "$remote_spine_source"

root_relative_source="$work_dir/epub3-root-relative-source"
cp -R "$source_dir/epub3-edge" "$root_relative_source"
perl -0pi -e 's|href="text/a%20b.xhtml"|href="/EPUB/text/a%20b.xhtml"|' \
  "$root_relative_source/EPUB/package.opf"
build_epub epub3-root-relative "$root_relative_source"

empty_required_source="$work_dir/epub3-empty-required-source"
cp -R "$source_dir/epub3-edge" "$empty_required_source"
perl -0pi -e 's|media-type="audio/mpeg"|media-type=""|' \
  "$empty_required_source/EPUB/package.opf"
build_epub epub3-empty-required "$empty_required_source"

bad_version_source="$work_dir/epub3-bad-version-source"
cp -R "$source_dir/epub3-edge" "$bad_version_source"
perl -0pi -e 's/version="3.0"/version="3.bad"/' \
  "$bad_version_source/EPUB/package.opf"
build_epub epub3-bad-version "$bad_version_source"

remote_fragment_source="$work_dir/epub3-remote-fragment-source"
cp -R "$source_dir/epub3-edge" "$remote_fragment_source"
perl -0pi -e 's|audio.mp3"|audio.mp3#track"|' \
  "$remote_fragment_source/EPUB/package.opf"
build_epub epub3-remote-fragment "$remote_fragment_source"

remote_duplicate_source="$work_dir/epub3-remote-duplicate-source"
cp -R "$source_dir/epub3-edge" "$remote_duplicate_source"
perl -0pi -e 's|(<item id="remote"[^>]*/>)|$1\n    <item id="remote-duplicate" href="https://EXAMPLE.com:443/audio%2Emp3" media-type="audio/mpeg"/>|' \
  "$remote_duplicate_source/EPUB/package.opf"
build_epub epub3-remote-duplicate "$remote_duplicate_source"

remote_dot_duplicate_source="$work_dir/epub3-remote-dot-duplicate-source"
cp -R "$source_dir/epub3-edge" "$remote_dot_duplicate_source"
perl -0pi -e 's|(<item id="remote"[^>]*/>)|$1\n    <item id="remote-dot-duplicate" href="https://example.com/a/../audio.mp3" media-type="audio/mpeg"/>|' \
  "$remote_dot_duplicate_source/EPUB/package.opf"
build_epub epub3-remote-dot-duplicate "$remote_dot_duplicate_source"

remote_encoded_dot_duplicate_source="$work_dir/epub3-remote-encoded-dot-duplicate-source"
cp -R "$source_dir/epub3-edge" "$remote_encoded_dot_duplicate_source"
perl -0pi -e 's|(<item id="remote"[^>]*/>)|$1\n    <item id="remote-encoded-dot-duplicate" href="https://example.com/a/%2e%2e/audio.mp3" media-type="audio/mpeg"/>|' \
  "$remote_encoded_dot_duplicate_source/EPUB/package.opf"
build_epub epub3-remote-encoded-dot-duplicate "$remote_encoded_dot_duplicate_source"

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

full_fold_dir="$work_dir/full-fold-collision"
mkdir -p "$full_fold_dir"
printf '%s' 'application/epub+zip' >"$full_fold_dir/mimetype"
printf '%s' 'long-s' >"$full_fold_dir/ſ.xhtml"
printf '%s' 'ascii-s' >"$full_fold_dir/s.xhtml"
find "$full_fold_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/full-fold-collision.epub"
python3 -c '
import sys, zipfile
archive, names = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(archive, "w") as output:
    mimetype = zipfile.ZipInfo("mimetype", (2020, 1, 1, 0, 0, 0))
    mimetype.compress_type = zipfile.ZIP_STORED
    output.writestr(mimetype, b"application/epub+zip")
    for name in names:
        member = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
        member.compress_type = zipfile.ZIP_DEFLATED
        output.writestr(member, name.encode("utf-8"))
' "$output_dir/full-fold-collision.epub" ſ.xhtml s.xhtml

forbidden_dir="$work_dir/ocf-forbidden"
mkdir -p "$forbidden_dir"
pua_name=$(printf 'private-\356\200\200.xhtml')
printf '%s' 'application/epub+zip' >"$forbidden_dir/mimetype"
printf '%s' 'forbidden' >"$forbidden_dir/$pua_name"
find "$forbidden_dir" -exec touch -t 202001010000 {} +
rm -f "$output_dir/ocf-forbidden.epub"
python3 -c '
import sys, zipfile
archive, name = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive, "w") as output:
    mimetype = zipfile.ZipInfo("mimetype", (2020, 1, 1, 0, 0, 0))
    mimetype.compress_type = zipfile.ZIP_STORED
    output.writestr(mimetype, b"application/epub+zip")
    member = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
    member.compress_type = zipfile.ZIP_DEFLATED
    output.writestr(member, b"forbidden")
' "$output_dir/ocf-forbidden.epub" "$pua_name"

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
