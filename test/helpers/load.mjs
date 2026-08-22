import { createRequire } from "node:module"
import { readFileSync } from "node:fs"

const require = createRequire(import.meta.url)
export const Model = require("../../Model.js")
export const fixture = name => readFileSync(new URL(`../fixtures/${name}`, import.meta.url), "utf8")
export const forecast = JSON.parse(fixture("locationforecast-compact.json"))
export const firstTime = Date.parse(forecast.properties.timeseries[0].time)

// All 83 symbol codes MET currently emits (metno/weathericons, weather/svg).
const VARIANT_BASES = [
  "clearsky", "fair", "partlycloudy",
  "lightrainshowers", "rainshowers", "heavyrainshowers",
  "lightrainshowersandthunder", "rainshowersandthunder", "heavyrainshowersandthunder",
  "lightsleetshowers", "sleetshowers", "heavysleetshowers",
  "lightssleetshowersandthunder", "sleetshowersandthunder", "heavysleetshowersandthunder",
  "lightsnowshowers", "snowshowers", "heavysnowshowers",
  "lightssnowshowersandthunder", "snowshowersandthunder", "heavysnowshowersandthunder"
]
const PLAIN = [
  "cloudy", "fog",
  "lightrain", "rain", "heavyrain", "lightrainandthunder", "rainandthunder", "heavyrainandthunder",
  "lightsleet", "sleet", "heavysleet", "lightsleetandthunder", "sleetandthunder", "heavysleetandthunder",
  "lightsnow", "snow", "heavysnow", "lightsnowandthunder", "snowandthunder", "heavysnowandthunder"
]
export const ALL_SYMBOL_CODES = [...VARIANT_BASES.flatMap(b => [`${b}_day`, `${b}_night`, `${b}_polartwilight`]), ...PLAIN]
