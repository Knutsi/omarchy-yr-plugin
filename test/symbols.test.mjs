import { test } from "node:test"
import assert from "node:assert/strict"
import { Model, ALL_SYMBOL_CODES } from "./helpers/load.mjs"

test("all 83 MET symbol codes map to a glyph and a label", () => {
  assert.equal(ALL_SYMBOL_CODES.length, 83)
  for (const code of ALL_SYMBOL_CODES) {
    const glyph = Model.iconForSymbol(code)
    assert.equal(glyph.length, 1, `${code} → ${JSON.stringify(glyph)}`)
    assert.ok(glyph.codePointAt(0) >= 0xe300, code)
    const label = Model.symbolLabel(code)
    assert.ok(label.length > 0 && !/_/.test(label), `${code} → ${label}`)
  }
  assert.equal(Model.symbolLabel("lightssleetshowersandthunder_day"), "Light sleet showers and thunder")
  assert.equal(Model.symbolLabel("lightssnowshowersandthunder_night"), "Light snow showers and thunder")
  assert.equal(Model.symbolLabel("heavysnowshowers_polartwilight"), "Heavy snow showers")
  assert.equal(Model.symbolLabel("clearsky_night"), "Clear sky")
  assert.equal(Model.symbolLabel(""), "")
})

test("day/night variants differ; polar twilight renders as day; unknown falls back", () => {
  assert.notEqual(Model.iconForSymbol("clearsky_day"), Model.iconForSymbol("clearsky_night"))
  assert.equal(Model.iconForSymbol("fair_polartwilight"), Model.iconForSymbol("fair_day"))
  assert.equal(Model.iconForSymbol("unknown_code_xyz"), Model.iconForSymbol("cloudy"))
  assert.equal(Model.glyphFamily("lightssnowshowersandthunder"), "thunder")
  assert.equal(Model.glyphFamily("heavysleetshowers"), "sleetshowers")
  assert.equal(Model.GLYPH_UNAVAILABLE.length, 1)
})
