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

- an explicit size ceiling **at the source**, before the bytes are
  allocated in the shell — curl `--max-filesize`, `head -c` for files and
  for process output — **and** a pre-parse length check (`responseTooLarge` /
  `MAX_BYTES_*` in `Model.js`), asserted by a test. A file is never read
  through `FileView.text()`/`data()`: a `FileView` is a change watcher only
  (`preload: false`) and the bytes come through `readFileCommand()`
  (`head -c cap+1`, so an oversized file still trips the parser's ceiling
  instead of truncating into a valid-looking prefix). `CurlRequest`'s
  `collect: false` is **not** a ceiling: QProcess drains a child's stdout into
  its own buffer whether or not a collector is attached (measured ~1:1 with
  the bytes written), so it only spares the string copy — use it for helpers
  that print at most a line, and bound any noisy child at the source
  (`head -c` inside a fixed script, as for `where-am-i`);
- a time bound (`--max-time`) and bounded retries;
- a parser that fails closed on garbage (try/catch → the empty value);
- **plain-text rendering**: every string that may be shown is passed through
  `plainText()` in the parser that creates it (strips `<`/`>` and control
  characters, caps length), and every `Text`/`PanelSectionHeader` in plugin
  QML sets `textFormat: Text.PlainText`. Both layers are needed: the shell's
  own sinks the plugin feeds (bar tooltip via `PanelToolTip`/`Bar.qml`,
  `omarchy-notification-send`) are bare AutoText `Text`s we cannot configure,
  so the string itself must be markup-free. `test/rendering.test.mjs`
  enforces both (QML scan + tainted-fixture probe of every parser). The QML
  scan covers `Text`/`PanelSectionHeader` blocks only; a string handed to a
  shell component property (`tooltipText`, `Button.text`, …) is covered by
  the parser probe alone, so never bind one to a raw external value. A
  *formatter* that composes a displayable string out of a data object
  (`hourView`) counts as a parser here: probe it the same way, and build each
  field from the object's raw values — `iconForSymbol(point.symbolCode)`, not
  `point.icon` — so a caller cannot hand it a pre-rendered string to pass
  through;
- **child processes**: every argv is built by a `Model.js` builder
  (`curlCommand`, `metCommand`, `settingCommand`, `persistCommand`,
  `clearLocationCommand`, `notificationCommand`, `browserCommand`, the
  GeoClue commands) — never inline in QML, never `bar.run`/`bash -c` with
  data in it — carries a time bound (`--max-time` or coreutils `timeout`)
  when the plugin waits for it, and no positional starts with `-`
  (`positional()`; `omarchy-notification-send` re-scans its arguments for
  `--exec`). `test/meta.test.mjs` greps every `.qml` for command literals;
- **numbers from outside are range-checked** before they size anything
  (`validTempC`, `validCoords`/`strictNum`): one `air_temperature` of 1e7
  used to mean 260 000 graph ticks, 1e308 a `RangeError` in a binding;
- **table lookups keyed by an external string use `hasOwnProperty`**
  (`symbol_code: "constructor_day"` once returned `function Object()`);
- **URLs handed to a browser are literals plus numbers or a yr location id
  matching `YR_ID`** (`yrUrl`), and `browserCommand` refuses anything that is
  not one; the launch is argv via `omarchy-launch-browser`. yr facts that
  shaped this (verified 2026-08-22): `…/daily-table/1-84687` redirects to
  the full named path, so ids suffice and names are never needed; the ids
  come only from yr's own site API (`/api/v0/locations/search`; Kartverket's
  `stedsnummer` is unrelated, `2-<GeoNames id>` works only outside Norway);
  `?q=` is ignored when `lat`/`lon` are given; a nearest-by-coordinates list
  in a town is streets and bridges, so the name search comes first and the
  nearest search accepts populated places (category `C*`) only. Never write the name of the init tool that
  launcher uses internally anywhere in the plugin (README included): the
  marketplace baseline flags the word itself as a review capability;
- **no arrays through `omarchy bar set`**: `qs ipc call` spreads a JSON-array
  argument into separate arguments (a one-element list arrives as a bare
  object, longer ones fail with "too many arguments") — found the hard way
  with `places`. Scalars go through `settingCommand`; lists go in-process
  through `shell.updateEntryInline(pluginId, entry)` (`Service.savePlaces`),
  built from the shell's live entry;
- **a list read back from `settings` is not an `Array`**: after a shell
  restart the bar's settings push hands the plugin a QML sequence wrapper —
  indexable, with a `length`, but `Array.isArray` is false (the Tailscale
  panel tests `instanceof Array` for the same reason). `Model.toArray()`
  copies any array-like; every list parser must go through it. Verified by
  A/B restarts: `Array.isArray` alone → 0 places, `toArray` → the stored list.

New network calls go through `curlCommand()`/`metCommand()` — never build a
curl argv inline; `test/meta.test.mjs` counts the `["curl"` literals and
checks every builder's output for both bounds. When adding any
external-input path, answer explicitly: what happens at 10 GB, at 0 bytes,
on garbage, on a hang, on HTTP 500, when a field is
`<img src="http://…">`, when a number is 1e308, and when a string is
`--exec` or `constructor` — and encode each answer as a test.

Why "at the source" (marketplace review of v0.4.0, issue #1448, finding #3):
`FileView.text()` had loaded the whole user-writable `weather.json` before
`parseLocationFile()` applied its 256 KiB check — "an oversized file is
already allocated and retained in the long-lived shell before the limit
runs". A ceiling that runs after the allocation is not a ceiling.

Why the rendering rule exists (marketplace review of v0.3.2, issue #1448):
QtQuick `Text` defaults to `Text.AutoText`, which auto-detects markup and
renders it as StyledText — `<img src>` included, so a weather warning or a
geocoder result could make the long-lived shell fetch and decode an
attacker-chosen URL. MET warning names/areas/descriptions, tekstvarsel text,
location names and an unknown `symbol_code` all reached such sinks unescaped
(13 of them, including two shell-owned tooltips). Escaping is not a fix:
`&lt;` shows literally when AutoText is not triggered; the brackets have to go.

When a review (marketplace or otherwise) finds a class of mistake, do not
just fix the instance: add the invariant here and a test that enforces it.

## The shell's contract

The shell's objects are not the plugin's to write, and they change under it —
an Omarchy update lands without a plugin release:

- **the `bar` a plugin gets is a read-only facade**: since Omarchy 4.0.4 a
  third-party plugin's `bar` is `Ui/PluginBarApi.qml`, whose state properties
  are `readonly`, so writing one throws a TypeError. Call the facade's method
  (`setCenterHoverRevealSuppressed()`); an assignment is only the fallback
  for shells older than the facade (4.0.2 handed plugins the Bar itself,
  writable and without the setter), as in the stock weather panel.
  `test/lifecycle.test.mjs` flags a bar write with no setter check in front;
- **`close()` hides first**: every way out of the popup — Escape, a click
  outside, the pill, a popout switch, IPC — ends in `Panel.close()`, so
  anything that throws ahead of `controller.hide()` leaves a popup that only
  a shell restart removes. Cleanup goes after the hide.
  `test/lifecycle.test.mjs` runs the real `close()` against stand-in bars;
  `test/live/escape-closes-popup.sh` checks the running shell.

Why (0.3.0–0.5.0 on Omarchy 4.0.4): close() began by assigning the facade's
read-only `centerHoverRevealSuppressed`. Every close threw before hiding, the
popup stayed up with Escape, clicks and IPC all dead, and the shell log filled
with `Cannot assign to read-only property "centerHoverRevealSuppressed"`.

## Release checklist

1. `npm test`, `npm run lint` (qmllint; only the inherent "unqualified access"
   / "member not found on QObject" warnings are acceptable), `npm run validate`.
   CI (`.github/workflows/test.yml`) runs `npm test` on every push and PR.
2. Run Claude Code's `/security-review` on the release diff; a finding is
   fixed **and** turned into an invariant + test above before proceeding.
3. Bump the version in `manifest.json`, `package.json` **and** `Model.js` (`VERSION`) together (`npm test` checks they match); add a
   dated entry to `CHANGELOG.md`.
4. `omarchy restart shell` and check the pill and popup by hand; then
   `test/live/escape-closes-popup.sh` must pass.
5. Merge to `main`, tag `vX.Y.Z`, create the GitHub release.
6. Marketplace: a listed plugin is updated via the "verify-plugin" issue form
   with the new 40-char HEAD SHA; a pending submission is re-validated by
   editing the open submission issue.
