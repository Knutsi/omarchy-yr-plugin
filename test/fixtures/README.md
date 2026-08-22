# Test fixtures

Recorded API responses, fetched with the plugin's User-Agent. Refresh them
by re-running the listed requests; tests that assert specific values
(Sanderstølen coordinates, Oslo's region, alert levels) may need updating.

| File | Source | Captured |
|---|---|---|
| `locationforecast-compact.json` | `https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.9127&lon=10.7461` | 2026-08-21 |
| `headers-200.txt` | response headers of the request above (`curl -D`) | 2026-08-21 |
| `textforecast-landoverview.json` | `https://api.met.no/weatherapi/textforecast/3.0/landoverview` | 2026-08-22 |
| `metalerts-oslo.json` | `https://api.met.no/weatherapi/metalerts/2.0/current.json?lat=59.9127&lon=10.7461` | 2026-08-22 |
| `open-meteo-oslo.json` | `https://geocoding-api.open-meteo.com/v1/search?name=Oslo&count=5&language=en&format=json` | 2026-08-22 |
| `kartverket-sanderstolen.json` | `https://api.kartverket.no/stedsnavn/v1/navn?sok=Sanderst%C3%B8len&fuzzy=true&utkoordsys=4258&treffPerSide=10` | 2026-08-22 |
| `kartverket-punkt.json` | `https://api.kartverket.no/stedsnavn/v1/punkt?nord=60.8274&ost=9.13895&koordsys=4258&radius=500&treffPerSide=5` | 2026-08-22 |
| `photon-sanderstolen.json` | `https://photon.komoot.io/api/?q=Sanderst%C3%B8len&limit=5&lang=en` | 2026-08-22 |
| `photon-reverse.json` | `https://photon.komoot.io/reverse?lat=60.8274&lon=9.13895&limit=1` | 2026-08-22 |
| `yr-search-honefoss.json` | `https://www.yr.no/api/v0/locations/search?q=H%C3%B8nefoss&language=en` (first 10 hits, `_links` removed) | 2026-08-22 |
| `yr-nearby-honefoss.json` | `https://www.yr.no/api/v0/locations/search?lat=60.1699&lon=10.2552&language=en` (first 10, `_links` removed) | 2026-08-22 |
| `yr-nearby-oslo.json` | `https://www.yr.no/api/v0/locations/search?lat=59.9127&lon=10.7461&language=en` (first 10, `_links` removed) | 2026-08-22 |

Data: MET Norway (CC BY 4.0 / NLOD 2.0), Kartverket (CC BY 4.0),
Open-Meteo (CC BY 4.0), OpenStreetMap contributors via Photon (ODbL),
yr.no location register (MET Norway / NRK).
