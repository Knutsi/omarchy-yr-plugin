# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]
### Added
- Saved places: the search box now opens empty with your last five searches
  listed under it, and up to five places can be pinned to the top. Stored
  as a `places` array on the widget's `shell.json` entry, the way
  Omarchy's own widgets keep small state.
- A globe button next to the location name opens the same location on
  yr.no (Norwegian site for a Norwegian locale): the place's own page when
  yr's register knows it — looked up by the name in use, then by the
  nearest town — and a coordinate page otherwise. The URL is fixed text plus
  a validated location id or the rounded coordinates, opened through
  `omarchy-launch-browser` as an argument list.
### Changed
- Enter in an empty search box no longer switches to automatic location;
  "Use automatic location" is the only way back. Search text is capped at
  100 characters.
- An unknown MET symbol code is only echoed as condition text when it is
  shaped like one.
### Security
- Hardening ahead of further marketplace review: temperatures outside
  −100…70 °C are dropped before they can size the graph (one such value
  could previously stall a paint or throw inside a binding); MET symbol
  codes are looked up with `hasOwnProperty` (`constructor_day` used to
  yield a function); the stored location file and GeoClue's output get the
  same size ceiling as HTTP bodies; a `Last-Modified` value is only sent
  back as `If-Modified-Since` when it is shaped like an HTTP date; every
  child process is now an argument list built and tested in `Model.js`
  (the notification used to go through a shell string), the helpers run
  under `timeout`, and a place name or forecast text can never start with
  a dash where a helper would read it as an option.
- README states plainly what data leaves the machine, to whom, and when.

## [0.3.3] — 2026-08-22
### Security
- Strings from outside the plugin (MET warnings and text forecasts, geocoder
  and IP-location names, the stored location file) are rendered as plain
  text: every parser strips angle brackets and control characters and caps
  field length (`plainText()`), and every `Text` in the plugin's QML sets
  `textFormat: Text.PlainText`. Previously a markup-shaped field (for example
  `<img src="…">` in a warning description) would be auto-detected as rich
  text and could make the shell load a remote resource. Raised by the
  marketplace security review (HANCORE-linux/omarchy-plugin-marketplace#1448).
- An unknown MET `symbol_code` is shown as condition text only when it is
  shaped like one (`[a-z_]`); the Photon reverse lookup's country code must be
  a two-letter code.
### Added
- `test/rendering.test.mjs`: every `Text`/`PanelSectionHeader` in plugin QML
  must be PlainText, and every parser is probed with tainted fixtures.

## [0.3.2] — 2026-08-22

### Added
- CI: GitHub Actions runs the test suite on every push and pull request.
- An invariant test: every curl invocation must carry both a time bound and a
  size ceiling, and new curl argv literals in `Model.js` fail the build.

### Security
- Every HTTP response is now size-capped — 256 KiB for the lookup services
  (geocoders, IP location, reverse lookup), 2 MiB for MET Norway — both at
  curl (`--max-filesize`) and again before JSON parsing, so a misbehaving or
  hostile endpoint can no longer grow the shell's memory without bound.
  Raised by the marketplace security review
  (HANCORE-linux/omarchy-plugin-marketplace#1448).

## [0.3.1] — 2026-08-22

### Changed
- The hourly graph is drawn in the theme foreground at varying opacity instead
  of `urgent`/`accent`, so themes with a bright red or a loud accent no longer
  make the temperature curve and rain bars shout.
- The GPS tooltip points to the README instead of quoting a `sudo pacman`
  command.

## [0.3.0] — 2026-08-22

### Changed
- Plugin id is now `io.github.knutsi.yr` (was `knutsi.weather-yr`) — the
  permanent marketplace id. Reinstall: `omarchy plugin remove knutsi.weather-yr`
  then `omarchy plugin add https://github.com/Knutsi/omarchy-yr-plugin.git --enable`.
- One shell-wide data service (`kinds: ["service", "bar-widget"]`): forecasts,
  warnings, text forecast, location and search are fetched once and shared by
  the per-monitor bar widgets. IPC verbs now act on every screen.
- Popup split into components (hero, graph, days, text forecast, settings,
  search view); `Panel.qml` is a thin view.
- English chrome everywhere the plugin writes text ("Tomorrow", "Yellow level");
  MET's own texts stay in their source language.

### Fixed
- Searching for the same place twice returned "No matches".
- "Use automatic location" hid the bar pill until the next refresh.
- A forecast fetched for the previous location could be kept for the new one
  and frozen by the `304 Not Modified` path.
- A name-only `weather.json` showed the wrong city under the saved name; the
  name is now geocoded once and its coordinates stored.
- Saving a location could leave the spinner stuck and disable Escape.
- The tekstvarsel toggle disappeared after a restart when turned off.
- Kelvin graph axis was labelled in degrees.
- Bar pill now shows an error glyph (with tooltip) when no forecast could be
  fetched, instead of vanishing.

## [0.2.0] — 2026-08-22

### Added
- Place search through Kartverket (Norway's place-name register) and Photon
  (OpenStreetMap) in addition to Open-Meteo — finds farms, hotels and seters.
- GPS / Wi-Fi positioning through GeoClue with a satellite button, detection
  of the service state and explanatory tooltips.
- Tekstvarsel (MET Textforecast 3.0) for the Norwegian land region, on by
  default, scrollable, with a toggle.
- Weather warnings (MET MetAlerts 2.0) as a coloured, expandable banner.
- Sunrise and sunset computed locally.

## [0.1.0] — 2026-08-21

### Added
- First release: theme-tinted bar pill, popup with current weather, hourly
  graph, daily forecast, units (°C/°F/K), location shared with Omarchy's stock
  weather widget, IP-based auto-detection.

[Unreleased]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Knutsi/omarchy-yr-plugin/releases/tag/v0.1.0
