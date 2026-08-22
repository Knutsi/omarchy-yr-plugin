import QtQuick
import "Model.js" as Model

// One place-search provider. `queryTag` is the query a running request is
// for; `doneQuery` the last query answered — kept apart so that a finished
// query can be asked again (reopening the search with the same text) while
// an in-flight one is not duplicated.
Item {
  id: root

  required property string source
  readonly property bool running: request.running
  property string doneQuery: ""
  property var results: []

  signal answered(string source, string query, var rows)

  function search(query, argv) {
    if (request.running) return false
    if (query === doneQuery) return false
    return request.start(argv, query)
  }

  function clear() {
    request.cancel()
    doneQuery = ""
    results = []
  }

  CurlRequest {
    id: request
    onFinished: function(tag, stdout, exitCode) {
      root.doneQuery = tag
      root.results = Model.parseGeocodeResponse(root.source, stdout, tag)
      root.answered(root.source, tag, root.results)
    }
  }
}
