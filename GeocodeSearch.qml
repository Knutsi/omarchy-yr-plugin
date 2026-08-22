import QtQuick
import "Model.js" as Model

// Three-source place search with debounce and merge. Set `query`; read
// `suggestions`. Sources answer at different times, so the list is
// re-merged as each arrives; a source still busy with an older query is
// re-run for the current one as soon as it finishes.
Item {
  id: root

  property string query: ""
  property int limit: Model.SUGGESTION_LIMIT
  property int debounceMs: 300
  property var suggestions: []
  readonly property bool running: openMeteo.running || kartverket.running || photon.running
  readonly property var sources: [openMeteo, kartverket, photon]

  // Query the current suggestions were computed for.
  property string answeredQuery: ""

  onQueryChanged: {
    var q = query.replace(/^\s+|\s+$/g, "")
    if (q.length < 2) {
      debounce.stop()
      clear()
      return
    }
    debounce.restart()
  }

  function clear() {
    for (var i = 0; i < sources.length; i++) sources[i].clear()
    suggestions = []
    answeredQuery = ""
  }

  function dispatch() {
    var q = query.replace(/^\s+|\s+$/g, "")
    var requests = Model.geocodeRequests(q)
    for (var i = 0; i < requests.length; i++) sourceFor(requests[i].source).search(q, requests[i].command)
    // Sources that already answered this exact query show their cached rows.
    recompute(q)
  }

  function recompute(q) {
    var bySource = {}
    var any = false
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].doneQuery === q) { bySource[sources[i].source] = sources[i].results; any = true }
    }
    if (!any) return
    suggestions = Model.mergeSuggestions(bySource, limit)
    answeredQuery = q
  }

  function sourceFor(name) {
    if (name === "kartverket") return kartverket
    if (name === "photon") return photon
    return openMeteo
  }

  function handleAnswer(source, forQuery) {
    var q = query.replace(/^\s+|\s+$/g, "")
    if (forQuery !== q) {
      // Stale: ask again for the query that is current now.
      if (q.length >= 2) dispatch()
      return
    }
    recompute(q)
  }

  Timer {
    id: debounce
    interval: root.debounceMs
    onTriggered: root.dispatch()
  }

  GeocodeSource { id: openMeteo; source: "open-meteo"; onAnswered: function(s, q) { root.handleAnswer(s, q) } }
  GeocodeSource { id: kartverket; source: "kartverket"; onAnswered: function(s, q) { root.handleAnswer(s, q) } }
  GeocodeSource { id: photon; source: "photon"; onAnswered: function(s, q) { root.handleAnswer(s, q) } }
}
