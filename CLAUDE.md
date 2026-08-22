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

## Engineering invariants

External input is hostile. Anything that enters the long-lived shell process
— HTTP bodies, process stdout, files — must have:

- an explicit size ceiling: curl `--max-filesize` **and** a pre-parse length
  check (`responseTooLarge` / `MAX_BYTES_*` in `Model.js`), asserted by a test;
- a time bound (`--max-time`) and bounded retries;
- a parser that fails closed on garbage (try/catch → the empty value).

New network calls go through `curlCommand()`/`metCommand()` — never build a
curl argv inline; `test/meta.test.mjs` counts the `["curl"` literals and
checks every builder's output for both bounds. When adding any
external-input path, answer explicitly: what happens at 10 GB, at 0 bytes,
on garbage, on a hang, on HTTP 500 — and encode each answer as a test.

When a review (marketplace or otherwise) finds a class of mistake, do not
just fix the instance: add the invariant here and a test that enforces it.

## Release checklist

1. `npm test`, `npm run lint` (qmllint; only the inherent "unqualified access"
   / "member not found on QObject" warnings are acceptable), `npm run validate`.
   CI (`.github/workflows/test.yml`) runs `npm test` on every push and PR.
2. Run Claude Code's `/security-review` on the release diff; a finding is
   fixed **and** turned into an invariant + test above before proceeding.
3. Bump the version in `manifest.json`, `package.json` **and** `Model.js` (`VERSION`) together (`npm test` checks they match); add a
   dated entry to `CHANGELOG.md`.
4. `omarchy restart shell` and check the pill and popup by hand.
5. Merge to `main`, tag `vX.Y.Z`, create the GitHub release.
6. Marketplace: a listed plugin is updated via the "verify-plugin" issue form
   with the new 40-char HEAD SHA; a pending submission is re-validated by
   editing the open submission issue.
