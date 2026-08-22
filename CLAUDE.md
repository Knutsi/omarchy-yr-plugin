# Working on this plugin

## Check the marketplace guidelines first — every time

Before making code changes, and **always** before cutting a release or
submitting an update to the marketplace, fetch and re-read the current
Omarchy plugin guides — they change, so do not rely on memory:

- https://omarchyplugins.com/develop.html — plugin contract, manifest fields,
  validation rules (no `omarchy.*` ids, no symlinks inside the plugin folder,
  every entry point must exist), theming (use the bar's foreground/font).
- https://omarchyplugins.com/publish.html — required repo files, manifest
  fields, how submissions and updates are validated and approved.

Make sure the change and the release still satisfy them before proceeding.
The marketplace repo (HANCORE-linux/omarchy-plugin-marketplace:
SUBMISSION.md, VERIFICATION.md, SECURITY.md) has the detailed rules; its
security baseline statically flags literal `sudo`/`pkexec`/package-manager
commands anywhere in plugin code, so keep those in the README only.

## Release checklist

1. `npm test`, `npm run lint` (qmllint; only the inherent "unqualified access"
   / "member not found on QObject" warnings are acceptable), `npm run validate`.
2. Bump the version in `manifest.json`, `package.json` **and** `Model.js` (`VERSION`) together (`npm test` checks they match); add a
   dated entry to `CHANGELOG.md`.
3. `omarchy restart shell` and check the pill and popup by hand.
4. Merge to `main`, tag `vX.Y.Z`, create the GitHub release.
5. Marketplace: a listed plugin is updated via the "verify-plugin" issue form
   with the new 40-char HEAD SHA; a pending submission is re-validated by
   editing the open submission issue.
