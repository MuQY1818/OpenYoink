# README badges

These SVGs are served from the repository so a badge provider's GitHub token
pool or API errors cannot replace the README header with an error message.
`data.json` records the release, star count, release-asset download total and
sampling time. The count badges include that date in their accessible title.
Counts are snapshots, not live counters.

Refresh from the repository root with Node.js 18+ and an authenticated GitHub CLI:

```bash
node Scripts/update-readme-badges.mjs
```

`Scripts/make-release.sh` refreshes badges during packaging with `--version X.Y.Z`,
before uploading that release. If GitHub is unavailable in that mode, it updates
the release badge and keeps the previous dated counts. A manual refresh without
an explicit version fails without rewriting files when GitHub is unavailable.
Commit `docs/badges/` along with the release metadata. No scheduled job is used.

The MIT badge is verified against the local `LICENSE`; the macOS badge matches
the application's minimum supported version. Neither depends on GitHub API
license detection. No credentials are embedded in these files or image URLs.
