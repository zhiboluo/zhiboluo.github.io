#!/usr/bin/env bash
# Self-test for scripts/check-publish.sh. Builds a throwaway git repo in /tmp and runs the check against it.
# Never touches this repo or your real word list.   Usage: scripts/test-check-publish.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); O=$(mktemp -d); trap 'rm -rf "$T" "$O"' EXIT
cd "$T" || exit 1
git init -q; git config user.email t@t; git config user.name t
mkdir -p content/blog content/assets content/templates quartz/static scripts
cp "$HERE/check-publish.sh" scripts/
pass=0; failed=0
post() { printf -- '---\ntitle: t\ndate: 2026-11-24\npublish: true\n---\n%s\n' "$1"; }

# expect <name> <0|1> <text the output must contain, or ""> [env assignments...]
# A test that expects a block must also see the RIGHT reason, otherwise it could pass for the wrong one.
expect() {
  local name=$1 want=$2 needle=$3; shift 3
  git add -A -f -- content quartz/static 2>/dev/null
  env "$@" ./scripts/check-publish.sh >"$T/.out" 2>&1; local rc=$?
  git reset -q
  if [ "$rc" -eq "$want" ] && { [ -z "$needle" ] || grep -qF -- "$needle" "$T/.out"; }; then
    pass=$((pass+1)); echo "ok    $name"
  else
    failed=$((failed+1)); echo "FAIL  $name (exit $rc, wanted $want, needle: '$needle')"; sed 's/^/        /' "$T/.out" | head -5
  fi
}
clean() { rm -rf content/blog/* content/assets/* quartz/static/* content/templates/*; }
L="$O/terms.txt"; printf '# comment\nacmecorp\n\n\\.internal\\.\n' > "$L"
E="BANNED_TERMS_FILE=$L"

post hello > content/blog/a.md;                                   expect "clean post passes" 0 "OK (" "$E"; clean
post "I worked at AcmeCorp" > content/blog/a.md;                  expect "private word blocks" 1 "private word -> line" "$E"; clean
post "see build.internal.example" > content/blog/a.md;            expect "private word (regex with escapes) blocks" 1 "private word -> line" "$E"; clean
post hello > content/blog/acmecorp-notes.md;                      expect "private word in FILE NAME blocks" 1 "file NAME contains" "$E"; clean
post hello > "content/blog/我的笔记 with space.md";               expect "non-ASCII and spaced file name passes" 0 "OK (" "$E"; clean
post "password = hunter2hunter2" > content/blog/a.md;             expect "password blocks" 1 "secret-like text" "$E"; clean
post "aws_secret_access_key=abcdefghijklmnop1234" > content/blog/a.md; expect "aws secret key blocks" 1 "secret-like text" "$E"; clean
post "github_pat_ABCDEFGHIJKLMNOPQRSTUV" > content/blog/a.md;     expect "github_pat token blocks" 1 "secret-like text" "$E"; clean
post "sk-ant-abcdefghijklmnopqrstuvw" > content/blog/a.md;        expect "sk-ant token blocks" 1 "secret-like text" "$E"; clean
post "-----BEGIN OPENSSH PRIVATE KEY-----" > content/blog/a.md;   expect "private key header blocks" 1 "secret-like text" "$E"; clean
post "host 10.20.30.40" > content/blog/a.md;                      expect "private IP blocks" 1 "secret-like text" "$E"; clean
post "version 10.2, 110.20.30.40, 8.8.8.8, password manager" > content/blog/a.md; expect "harmless numbers and words pass" 0 "OK (" "$E"; clean
head -c 2000000 /dev/urandom > content/assets/big.png;            expect "2 MB image blocks" 1 "image is" "$E"; clean
head -c 2000000 /dev/urandom > quartz/static/big.png;             expect "2 MB image in quartz/static blocks" 1 "quartz/static/big.png: image is" "$E"; clean
printf 'contact acmecorp\n' > quartz/static/note.txt;             expect "private word in quartz/static blocks" 1 "quartz/static/note.txt: private word" "$E"; clean
printf -- '---\ntitle: x\ndate: 2026-11-24\n---\nSet publish: true later\n' > content/blog/a.md; expect "missing publish flag only warns" 0 "no 'publish: true'" "$E"; clean
post "AcmeCorp in a template" > content/templates/post.md;        expect "content/templates is skipped" 0 "OK (" "$E"; clean
post "AcmeCorp" > content/blog/a.md;                              expect "bypass skips every check" 0 "SKIPPED" "$E" SKIP_PUBLISH_CHECK=1; clean

# files the word scan cannot read, and file types that should never be published
printf -- '---\ntitle: t\ndate: 2026-11-24\npublish: true\n---\nWorked at AcmeCorp\n' | iconv -f UTF-8 -t UTF-16LE > content/blog/a.md
expect "UTF-16 text file blocks (word scan cannot read it)" 1 "not plain UTF-8 text" "$E"; clean
printf 'AcmeCorp internal notes\n' | iconv -f UTF-8 -t UTF-16LE > quartz/static/note.txt
expect "UTF-16 .txt in quartz/static blocks" 1 "not plain UTF-8 text" "$E"; clean
printf 'PK\003\004 binary with AcmeCorp inside' > content/assets/notes.docx
expect "unknown file type (.docx) blocks" 1 "file type is not allowed" "$E"; clean
printf 'x' > content/assets/README
expect "file without extension blocks" 1 "file type is not allowed" "$E"; clean
: > content/assets/.gitkeep
expect ".gitkeep is allowed" 0 "OK (" "$E"; clean
head -c 6000000 /dev/zero | tr '\0' 'a' > content/assets/big.txt
expect "6 MB text file blocks (size cap for every file)" 1 "KB (limit" "$E"; clean
post hello > "$O/outside.md"; ln -s "$O/outside.md" content/blog/linked.md
expect "symlink in content blocks" 1 "symlink" "$E"; clean
post "key sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD" > content/blog/a.md
expect "sk-proj OpenAI key blocks" 1 "secret-like text" "$E"; clean

# image and PDF metadata (needs exiftool; skipped with a notice if it is missing)
if command -v exiftool >/dev/null 2>&1; then
  # a tiny valid JPEG and PDF built here, so the test needs no outside files
  python3 - "$O" <<'PY'
import sys, base64
o = sys.argv[1]
open(o + "/clean.jpg", "wb").write(base64.b64decode(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/"
  "wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="))
objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>"]
out = b"%PDF-1.4\n"; offs = []
for i, ob in enumerate(objs, 1):
    offs.append(len(out)); out += b"%d 0 obj\n" % i + ob + b"\nendobj\n"
x = len(out)
out += b"xref\n0 4\n0000000000 65535 f \n" + b"".join(b"%010d 00000 n \n" % q for q in offs)
out += b"trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % x
open(o + "/clean.pdf", "wb").write(out)
PY
  cp "$O/clean.jpg" content/assets/clean.jpg
  expect "image without GPS passes (exiftool present)" 0 "OK (" "$E"; clean
  cp "$O/clean.jpg" content/assets/gps.jpg
  exiftool -q -overwrite_original -GPSLatitude=49.3 -GPSLatitudeRef=N -GPSLongitude=123.1 -GPSLongitudeRef=W content/assets/gps.jpg
  expect "image with GPS data blocks" 1 "GPS location data" "$E"; clean
  cp "$O/clean.pdf" quartz/static/clean.pdf
  expect "PDF without metadata passes with a warning" 0 "PDF text is not scanned" "$E"; clean
  cp "$O/clean.pdf" quartz/static/meta.pdf
  exiftool -q -overwrite_original -Author="Someone" -Producer="Some Tool" quartz/static/meta.pdf
  expect "PDF with author metadata blocks" 1 "author/creator/producer metadata" "$E"; clean
else
  echo "skip  metadata tests: exiftool is not installed"
fi

# word list problems must fail closed
post hello > content/blog/a.md
printf 'acmecorp\r\n' > "$L";                                      post "AcmeCorp" > content/blog/a.md; expect "list with Windows line ends still works" 1 "private word -> line" "$E"
printf '\xef\xbb\xbfacmecorp\n' > "$L";                           expect "list with BOM still works" 1 "private word -> line" "$E"
printf 'acmecorp   \n' > "$L";                                    post "AcmeCorp." > content/blog/a.md; expect "pattern with trailing spaces still works" 1 "private word -> line" "$E"
printf 'acmecorp\nC++(\n' > "$L";                                 expect "invalid regex in list blocks" 1 "invalid regular expression" "$E"
printf '\n# only comments\n' > "$L";                              expect "empty list blocks" 1 "no patterns" "$E"
expect "missing list blocks" 1 "missing or unreadable" "BANNED_TERMS_FILE=$O/nope.txt"
cp "$L" "$O/unreadable.txt"; chmod 000 "$O/unreadable.txt"
if [ "$(id -u)" != "0" ]; then expect "unreadable list blocks" 1 "missing or unreadable" "BANNED_TERMS_FILE=$O/unreadable.txt"; fi
clean

# list inside the project: must be ignored and untracked
mkdir -p .private; printf 'acmecorp\n' > .private/banned-terms.txt; post hello > content/blog/a.md
expect "project list that is not ignored blocks" 1 "NOT git-ignored" "BANNED_TERMS_FILE=$T/.private/banned-terms.txt"
echo ".private/" > .gitignore
expect "project list that is ignored works" 0 "OK (" "BANNED_TERMS_FILE=$T/.private/banned-terms.txt"
git add -f .private/banned-terms.txt
expect "project list tracked by git blocks" 1 "TRACKED by git" "BANNED_TERMS_FILE=$T/.private/banned-terms.txt"

echo; echo "passed: $pass   failed: $failed"
[ "$failed" -eq 0 ]
