# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Knutsi/omarchy-yr-plugin/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Knutsi/omarchy-yr-plugin/releases/tag/v0.1.0
