import QtQuick
import "Model.js" as Model

// Fetches one MET Norway resource politely: identifying User-Agent, gzip,
// `If-Modified-Since` from the previous `Last-Modified` (an unchanged
// resource costs a 304 with no body). Each request carries a key (the
// location it was made for); a response whose key no longer matches the
// current one is dropped, so a fetch that was in flight during a location
// change can never be stored as the new location's data.
Item {
  id: root

  property string url: ""
  property string key: ""          // identity of what `url` is for
  property int maxTimeSec: Model.TIMEOUT_FORECAST_S
  property string lastModified: ""
  readonly property bool running: request.running
  property int status: -1          // last HTTP status (0 = transport error)

  signal succeeded(string body, string key)
  signal notModified(string key)
  signal failed(int status, string key)

  // A fetch asked for while a (possibly cancelled) process is still winding
  // down is remembered and issued as soon as that process is gone.
  property bool pending: false

  function fetch() {
    if (!url) return false
    if (request.start(Model.metCommand(url, lastModified, maxTimeSec), key)) return true
    pending = true
    return false
  }

  // Forget the validator so the next fetch is unconditional.
  function reset() {
    lastModified = ""
    request.cancel()
  }

  onKeyChanged: reset()

  CurlRequest {
    id: request
    onFinished: function(tag, stdout, exitCode) {
      if (root.pending) {
        root.pending = false
        Qt.callLater(root.fetch)
      }
      if (tag !== root.key) return
      var response = Model.parseCurlResponse(stdout)
      root.status = response.status
      if (response.status === 304) { root.notModified(tag); return }
      if (response.status === 200 && response.body !== "") {
        root.lastModified = response.lastModified
        root.succeeded(response.body, tag)
        return
      }
      root.failed(response.status, tag)
    }
  }
}
