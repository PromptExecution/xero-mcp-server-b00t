# Contributing

## Developing from WSL / an NTFS-backed mount

If you're cloning this repo from WSL onto an NTFS-backed path (`/mnt/c/...` or similar),
run once per clone:

```bash
git config core.fileMode false
```

Without it, files round-trip 644↔755 with zero content change, and `git status`/`git diff`
show every touched file as "modified." (Hit this reviewing #1 — the PR body had to
explain away ~130 spurious file-mode diffs before the real 114-line change was visible.)
