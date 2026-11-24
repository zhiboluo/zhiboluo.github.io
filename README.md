---
scope: project
updated: 2026-11-24
version: "1.0"
created: 2026-11-24
---

# zhiboluo.github.io

Personal site of Zhibo Luo: a blog, a CV and notes. Live at https://zhiboluo.github.io/

It is a [Quartz](https://quartz.jzhao.xyz/) v5 site. Pushing to `main` builds it with GitHub Actions and publishes it on GitHub Pages (`.github/workflows/deploy.yml`). Nothing here costs money.

**This repository is public. Everything committed is public, even a page that the site does not show.**

## Add a post

1. Write the note somewhere private. When it is ready, copy it to `content/blog/yyyy-mm-dd-short-title.md` (lower case, hyphens, no spaces). Copy its images to `content/assets/` and keep each under 1 MB.
2. Start from `content/templates/post.md`. Every page needs this front matter:
   ```yaml
   ---
   title: Post title
   description: One sentence. Shown on the home page card and in link previews.
   date: 2026-11-24        # the day you wrote it; the home page and the blog list sort by it
   updated: 2026-12-01     # only after you edit it later
   tags: [notes]
   publish: true           # without this the page is NOT published
   ---
   ```
3. Preview: `npm ci` once, then `npx quartz build --serve` and open http://localhost:8080 (if that address is busy, add `--port 8081`).
4. `git add content && git commit -S -m "post: title"`, then `git push`. The Actions run takes one to three minutes.

Other front matter: `draft: true` (never published), `unlisted: true` (published, but not in lists, search, feed or sitemap).

## Safety check before every commit

`scripts/check-publish.sh` runs as a git hook and blocks a commit that contains private words, secrets, large or located images, PDF metadata, unreadable or unknown file types, or symlinks. It looks at `content/`, `quartz/static/` and this README.

One-time setup on each clone:

```bash
git config core.hooksPath .githooks
sudo apt install libimage-exiftool-perl      # image and PDF metadata checks
```

Then create `.private/banned-terms.txt` (git-ignored, never committed): one regular expression per line, `#` for comments. Use `scripts/banned-terms.example.txt` as a starting point. Keep a backup copy elsewhere, because a fresh clone does not have it and the hook blocks commits until it exists.

Self-test: `scripts/test-check-publish.sh` (run it after any change to the check). A one-time bypass exists (`SKIP_PUBLISH_CHECK=1 git commit ...`); it turns off every check, so read the file yourself first.

The check does not see commit messages, text inside screenshots, or the text of PDFs.

## Update Quartz

```bash
git status                  # must be clean
npx quartz upgrade          # merges upstream/v5 into this branch
npx quartz plugin doctor    # add --fix if it asks
npx quartz build            # check the result before pushing
```

Expect merge conflicts in files that were changed or removed here: `quartz/styles/custom.scss`, `quartz/components/Head.tsx` (a small patch so the home page and folder pages report `/` and `/blog/` as their address), `.github/workflows/` (only `deploy.yml` is kept) and the upstream `docs/`. `npx quartz restore` recovers `content/`; `git merge --abort` stops a half-done merge.

## Licence

Quartz is MIT licensed (`LICENSE.txt`, Copyright jackyzha0). The posts, the CV and the photo are © Zhibo Luo, all rights reserved.
