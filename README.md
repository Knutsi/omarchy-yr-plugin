# omarchy-yr-plugin

yr.no weather for the [Omarchy](https://omarchy.org) bar. A theme-tinted
Nerd Font glyph and the temperature in the bar, with a popup showing the
current conditions, a yr-style hour-by-hour graph, and a four-day forecast —
all from **MET Norway's** Locationforecast API, the same data that powers
[yr.no](https://www.yr.no).

```
  17°        ← bar pill (glyph + temperature; glyph only in vertical bars)
```

The popup, top to bottom:

1. **Current weather** — glyph, temperature, location (with a search
   button), condition, wind / humidity / rain in the coming hour.
2. **Next 24 hours** — symbols along the top, temperature curve,
   precipitation bars with amounts, hour labels.
3. **Next 4 days** — symbol, day, high / low.
4. **Settings** — `°C | °F | K` and `Location`, which opens a search view
   in place of the whole popup: type a city, pick a match, or go back to
   automatic (IP-based) location.

Plugin id: `knutsi.weather-yr`. Requires Omarchy 4.0 or newer (the
Quickshell-based shell with third-party plugin support).

## Install

```bash
omarchy plugin add https://github.com/Knutsi/omarchy-yr-plugin.git --enable
```

`--enable` places the pill in the bar's center section. To put it somewhere
specific:

```bash
omarchy bar put knutsi.weather-yr --after omarchy.clock
omarchy bar move knutsi.weather-yr --section right --index 0
```

It can live next to the stock `omarchy.weather` pill or replace it
(`omarchy bar put omarchy.weather` brings the stock one back).

Update later with `omarchy plugin update knutsi.weather-yr`; remove with
`omarchy plugin remove knutsi.weather-yr`.

## Using it

| Action | Result |
|---|---|
| Left click | Open / close the popup |
| Middle click | Force a refresh (re-detects the location too) |
| Right click | Desktop notification with the current conditions |
| Click the location name, its 🔍 button, or the `Location` settings button | Opens the search view: type a city, pick with ↑/↓ + Enter or click; Esc / ✕ goes back; "Use automatic location" returns to IP auto-detect |
| `°C` / `°F` / `K` buttons, or click the unit next to the big temperature | Switch units (persisted in shell.json) |
| Click the "updated HH:MM" stamp | Fetch the forecast again (also re-detects the IP location) |
| Tab / Shift-Tab in the popup | Move to the neighbouring bar panel |

IPC, e.g. for keybindings:

```bash
omarchy-shell shell toggle knutsi.weather-yr      # open/close the popup
omarchy-shell knutsi.weather-yr refresh           # force refresh
omarchy-shell knutsi.weather-yr edit              # open with the location search focused
omarchy-shell knutsi.weather-yr toggleUnit        # °C → °F → K → °C
omarchy-shell knutsi.weather-yr unit imperial     # set a unit directly
```

## Location

The plugin shares Omarchy's weather location with the stock widget, so
setting it once applies to both:

```bash
omarchy-weather-location                          # show the current location
omarchy-weather-location --set "Bergen" 60.3913,5.3221
omarchy-weather-location --clear                  # back to auto-detect
```

The state lives in `~/.local/state/omarchy/settings/weather.json` as
`{"name": ..., "latitude": ..., "longitude": ...}` and is watched, so edits
take effect immediately.

Without stored coordinates the position is detected from your public IP
address (via [ipwho.is](https://ipwho.is), falling back to
[geojs.io](https://www.geojs.io)). That is city-level at best and can be
off by a lot on CG-NAT / satellite connections, so set the location
explicitly if the forecast looks wrong. The lookup happens once per shell
session (and on middle-click), not on every refresh.

### Why no GPS?

Omarchy laptops rarely have a GNSS receiver, and Omarchy does not ship
[geoclue](https://gitlab.freedesktop.org/geoclue/geoclue) (Wi-Fi
positioning). If you install geoclue with a
[beaconDB](https://beacondb.net) backend, a future version could read it;
until then the stored location or the IP lookup is what there is.

## Settings

Settings are keys on the widget's entry in `~/.config/omarchy/shell.json`,
set with `omarchy bar set`:

| Key | Default | Meaning |
|---|---|---|
| `refreshMinutes` | `15` | Minutes between forecast fetches. Clamped to ≥ 10 — MET Norway asks desktop clients not to poll more often. |
| `unit` | `metric` | `metric` (°C, m/s, mm), `imperial` (°F, mph, in) or `kelvin` (K, m/s, mm). Always metric unless you change it — the system locale is deliberately ignored. |
| `barFormat` | `icon-temp` | `icon-temp` shows glyph + temperature; `icon` shows only the glyph. |
| `graphHours` | `24` | Hours in the hour-by-hour graph (6–48; MET's hourly data runs ~60 h ahead). |

```bash
omarchy bar set knutsi.weather-yr refreshMinutes 30
omarchy bar set knutsi.weather-yr unit kelvin
omarchy bar set knutsi.weather-yr barFormat icon
omarchy bar set knutsi.weather-yr graphHours 48
```

## How it talks to MET Norway

- Endpoint: `https://api.met.no/weatherapi/locationforecast/2.0/compact`
- Coordinates are rounded to four decimals, the request identifies itself
  (`User-Agent: omarchy-yr-plugin/<version> github.com/Knutsi/omarchy-yr-plugin`),
  responses are gzip-compressed, and every refresh sends `If-Modified-Since`
  so an unchanged forecast costs a `304` with no body.
- Refreshes are jittered by up to a minute so many installs never line up.
- `403`/`429` responses are not retried until the next interval. Network
  failures retry three times, 2.5 s apart, while the last good forecast
  stays on screen.
- The "current" hour is re-derived from the cached forecast every minute, so
  the bar keeps up between fetches.

## Theme

Everything is drawn with the active Omarchy theme: the bar's foreground
colour and font for the pill and popup, `accent` for hover/selection and the
precipitation bars, `urgent` (the theme's red) for the temperature curve.
Glyphs are from the Nerd Fonts weather set, the same family the stock weather
pill uses, so the two look like siblings. Switching themes restyles the widget
instantly.

## Development

```
manifest.json    plugin manifest
BarWidget.qml    bar pill + popup loader
Panel.qml        data fetching, location handling, popup UI
HourlyGraph.qml  the hour-by-hour graph (Canvas)
Model.js         pure helpers (parsing, symbol → glyph, hourly/daily rollups) — unit-tested
test/            node --test suite with a recorded MET response
```

```bash
node --test                                   # unit tests (Node ≥ 20)
omarchy plugin validate .                     # manifest/layout check
```

Cloning the repo straight into `~/.config/omarchy/plugins/knutsi.weather-yr`
is the quickest dev loop. The shell notices saved files and re-registers the
plugin, but a bar slot that is already mounted keeps its running instance
(Omarchy 4.0.0) — run `omarchy restart shell` to see QML changes.

## Credits and licence

- Weather data from [MET Norway](https://api.met.no/), licensed under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) /
  [NLOD 2.0](https://data.norge.no/nlod/en/2.0).
- City search by [Open-Meteo geocoding](https://open-meteo.com/en/docs/geocoding-api)
  (CC BY 4.0), IP lookup by [ipwho.is](https://ipwho.is) and [geojs.io](https://www.geojs.io).
- Popup and location handling adapted from Omarchy's stock `omarchy.weather`
  plugin (MIT).

This plugin is MIT licensed — see [LICENSE](LICENSE).
