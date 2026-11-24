#!/usr/bin/env bash
# Pre-commit check for files that will become public.
# Looks at STAGED files under content/ and quartz/static/ (both are published as-is).
#
# Bypass once (for example the CV, where the employer name is intended):
#   SKIP_PUBLISH_CHECK=1 git commit ...
# The bypass turns off EVERY check below (words, secrets, image size, metadata), not just the word list.
# Technical posts about networking (192.168.x.x, API keys in examples) will trip the secret check on purpose.
set -u

if [ "${SKIP_PUBLISH_CHECK:-0}" = "1" ]; then
  echo "check-publish: SKIPPED (SKIP_PUBLISH_CHECK=1) - words, secrets, image size and metadata were NOT checked"; exit 0
fi

ROOT=$(git rev-parse --show-toplevel) || exit 1
TERMS_FILE="${BANNED_TERMS_FILE:-$ROOT/.private/banned-terms.txt}"
MAX_IMAGE_BYTES="${MAX_IMAGE_BYTES:-1048576}"   # 1 MB
fail=0

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# ---- private word list: must exist, be readable, be non-empty and be valid ----
if [ ! -r "$TERMS_FILE" ]; then
  echo "check-publish: private word list missing or unreadable: $TERMS_FILE"
  echo "  Create it (one regular expression per line; lines starting with # are comments). Default place: .private/banned-terms.txt (git-ignored)."
  echo "  Example patterns: scripts/banned-terms.example.txt"
  exit 1
fi
# The list lives inside the project, so it must be git-ignored and never tracked or staged.
case "$TERMS_FILE" in
  "$ROOT"/*)
    rel="${TERMS_FILE#"$ROOT"/}"
    if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      echo "check-publish: $rel is TRACKED by git (it was added with -f or before it was ignored)."
      echo "  Remove it from git now: git rm --cached -- $rel   (and rewrite history if it was ever pushed)"; exit 1
    fi
    if ! git check-ignore --no-index -q -- "$rel"; then
      echo "check-publish: $rel is NOT git-ignored. Add '.private/' to .gitignore first (the list must never be committed)."; exit 1
    fi
    ;;
esac
# Clean the list: drop a UTF-8 BOM, Windows line ends (CR) and trailing spaces, then comment and blank lines.
# (A CR or BOM left in a pattern would make it never match: the check would silently do nothing.)
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//' "$TERMS_FILE" \
  | grep -vE '^[[:space:]]*(#|$)' > "$tmp/terms" || true
if [ ! -s "$tmp/terms" ]; then
  echo "check-publish: word list has no patterns: $TERMS_FILE"; exit 1
fi
grep -E -f "$tmp/terms" /dev/null >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "check-publish: word list contains an invalid regular expression: $TERMS_FILE"
  echo "  Find it with: while read -r p; do echo x | grep -E -e \"\$p\" >/dev/null 2>&1; [ \$? -eq 2 ] && echo \"bad: \$p\"; done < <(grep -vE '^[[:space:]]*(#|\$)' \"$TERMS_FILE\")"
  exit 1
fi

# ---- secret shapes that are never OK in a public repo ----
SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----'
SECRET_RE+='|(password|passwd|secret|api[_-]?key|token|aws[_-]?secret[_-]?access[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{6,}'
SECRET_RE+='|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{10,}'
SECRET_RE+='|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}'
SECRET_RE+='|(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'

# -z and quotepath=false: file names with spaces or non-ASCII characters (for example Chinese) arrive intact.
mapfile -d '' -t files < <(git -c core.quotepath=false diff --cached --name-only -z --diff-filter=ACMR -- content quartz/static)
[ "${#files[@]}" -eq 0 ] && exit 0

have_exiftool=0; command -v exiftool >/dev/null 2>&1 && have_exiftool=1
warned_exif=0

# grep wrapper: 0 = match, 1 = no match, anything else = grep itself failed (fail closed).
scan() { # scan <label> <file> <grep args...> ; prints matches
  local label=$1 f=$2; shift 2
  git show ":$f" | grep -InEi "$@" > "$tmp/out" 2>"$tmp/err"
  local rc=$?
  if [ $rc -eq 0 ]; then
    sed "s|^|BLOCK  $f: $label -> line |" "$tmp/out" | cut -c1-160; fail=1
  elif [ $rc -ne 1 ]; then
    echo "BLOCK  $f: $label check could not run (grep exit $rc): $(head -1 "$tmp/err")"; fail=1
  fi
}

for f in "${files[@]}"; do
  case "$f" in content/templates/*) continue ;; esac   # ignored by the build

  # The file name becomes part of the public URL and repo, so it is checked for private words too.
  if printf '%s\n' "$f" | grep -qEi -f "$tmp/terms"; then
    echo "BLOCK  $f: the file NAME contains a private word"; fail=1
  fi

  if ! size=$(git cat-file -s ":$f" 2>/dev/null); then
    echo "BLOCK  $f: cannot read the staged file"; fail=1; continue
  fi

  case "${f,,}" in
    *.png|*.jpg|*.jpeg|*.jfif|*.gif|*.webp|*.avif|*.heic|*.bmp|*.tif|*.tiff|*.svg|*.ico)
      case "${f,,}" in *.svg|*.ico) ;; *)
        if [ "$size" -gt "$MAX_IMAGE_BYTES" ]; then
          echo "BLOCK  $f: image is $((size/1024)) KB (limit $((MAX_IMAGE_BYTES/1024)) KB). Compress or resize it."; fail=1
        fi ;;
      esac
      if [ $have_exiftool -eq 1 ]; then
        if git show ":$f" | exiftool -q -q -gps:all - 2>/dev/null | grep -q .; then
          echo "BLOCK  $f: image contains GPS location data. Strip it: exiftool -all= <file>"; fail=1
        fi
      elif [ $warned_exif -eq 0 ]; then
        echo "warn   exiftool is not installed: image GPS data and PDF metadata are NOT checked"; warned_exif=1
      fi
      ;;
    *.pdf)
      echo "warn   $f: PDF text is not scanned for private words; check it by eye"
      if [ $have_exiftool -eq 1 ]; then
        if git show ":$f" | exiftool -s3 -Author -Creator -Producer -Company -Title - 2>/dev/null | grep -q '[^[:space:]]'; then
          echo "BLOCK  $f: PDF carries author/creator/producer metadata. Strip it: exiftool -all= <file>  (then qpdf --linearize or re-export)"; fail=1
        fi
      elif [ $warned_exif -eq 0 ]; then
        echo "warn   exiftool is not installed: image GPS data and PDF metadata are NOT checked"; warned_exif=1
      fi
      ;;
  esac

  # Text checks (grep -I skips binary files). Patterns that start with '-' need -e.
  scan "private word" "$f" -f "$tmp/terms"
  scan "secret-like text" "$f" -e "$SECRET_RE"

  case "$f" in
    *.md)
      # Only look inside the first front-matter block.
      fm=$(git show ":$f" | awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}')
      printf '%s\n' "$fm" | grep -Eq '^publish:[[:space:]]*true' || echo "warn   $f: no 'publish: true' in front matter (it will NOT be published)"
      printf '%s\n' "$fm" | grep -Eq '^(date|created):' || echo "warn   $f: no 'date:' in front matter"
      ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo; echo "check-publish: commit blocked. Fix the lines above, or bypass once with SKIP_PUBLISH_CHECK=1 (skips ALL checks)."; exit 1
fi
echo "check-publish: OK (${#files[@]} file(s) checked)"
