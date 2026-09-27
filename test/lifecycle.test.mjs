import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"

// The popup's close(), run for real. Every way out of the popup — Escape, a
// click outside, the pill, a popout switch, `omarchy-shell … hide` — ends in
// Panel.qml's close(), so a close() that throws before hiding leaves a popup
// that nothing but a shell restart removes. QML functions are plain JS: this
// lifts close() and its helper out of Panel.qml and runs them against
// stand-ins for the `bar` the shell hands a plugin.
// test/live/escape-closes-popup.sh checks the same thing in the running shell.

const dir = new URL("../", import.meta.url)
const panelQml = readFileSync(new URL("Panel.qml", dir), "utf8")

function qmlFunction(qml, name) {
  const start = qml.search(new RegExp("\\bfunction " + name + "\\("))
  assert.ok(start >= 0, "Panel.qml has no function " + name)
  let depth = 0
  for (let i = qml.indexOf("{", start); i < qml.length; i++) {
    if (qml[i] === "{") depth++
    else if (qml[i] === "}" && --depth === 0) return qml.slice(start, i + 1)
  }
  throw new Error("unbalanced braces in " + name)
}

// Just enough of the Panel's QML scope for close(): `root`, the `editing`
// flag and stopEditing(). Strict mode, because the QML engine refuses a write
// to a read-only property the way strict JS refuses one to a getter-only
// property: with a TypeError.
function panelOn(bar, editing = false) {
  const events = []
  const root = { bar, controller: { hide() { events.push("hide") } } }
  const close = new Function("root", "editing", "stopEditing", '"use strict"\n' +
    qmlFunction(panelQml, "setCenterHoverRevealSuppressed") + "\n" +
    qmlFunction(panelQml, "close") + "\nreturn close")(root, editing, () => events.push("stopEditing"))
  return { close, events }
}

// Omarchy 4.0.4+: a third-party plugin gets Ui/PluginBarApi.qml, where the
// flag is a `readonly property bool` and setCenterHoverRevealSuppressed()
// is the only way to change it.
function pluginBarApi(flag) {
  return {
    get centerHoverRevealSuppressed() { return flag },
    setCenterHoverRevealSuppressed(value) { flag = !!value }
  }
}

test("close() hides the popup on the shell's plugin bar facade (Omarchy 4.0.4+)", () => {
  const bar = pluginBarApi(true)
  const panel = panelOn(bar)
  panel.close()
  assert.deepEqual(panel.events, ["hide"])
  assert.equal(bar.centerHoverRevealSuppressed, false)
})

test("close() hides the popup on older shells that handed plugins the Bar itself", () => {
  const bar = { centerHoverRevealSuppressed: true }   // Omarchy 4.0.2: writable, no setter
  const panel = panelOn(bar)
  panel.close()
  assert.deepEqual(panel.events, ["hide"])
  assert.equal(bar.centerHoverRevealSuppressed, false)
})

test("close() hides first, before any cleanup that could throw", () => {
  const editing = panelOn(pluginBarApi(true), true)
  editing.close()
  assert.deepEqual(editing.events, ["hide", "stopEditing"])

  // A bar that refuses everything: the cleanup fails, the popup still goes.
  const refusing = panelOn({
    get centerHoverRevealSuppressed() { return true },
    setCenterHoverRevealSuppressed() { throw new TypeError("refused") }
  })
  assert.throws(() => refusing.close(), TypeError)
  assert.deepEqual(refusing.events, ["hide"])
})

test("no QML writes a bar property without trying the facade's setter first", () => {
  // Tripwire (CLAUDE.md "Engineering invariants"): the plugin's `bar` is a
  // read-only facade, so `bar.x = …` throws unless the shell is older than
  // the facade. Each such write must be the fallback behind `bar.setX()`.
  for (const file of readdirSync(dir).filter(f => f.endsWith(".qml"))) {
    const lines = readFileSync(new URL(file, dir), "utf8").split("\n")
    lines.forEach((line, i) => {
      const write = line.match(/\bbar\.([A-Za-z_]\w*)\s*=(?!=)/)
      if (!write) return
      const setter = "set" + write[1][0].toUpperCase() + write[1].slice(1)
      const before = lines.slice(Math.max(0, i - 3), i).join("\n")
      assert.ok(before.includes("typeof root.bar." + setter + ' === "function"'),
        file + ":" + (i + 1) + ": writes bar." + write[1] + " without trying bar." + setter + "() first")
    })
  }
})
