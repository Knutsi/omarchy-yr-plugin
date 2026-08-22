import QtQuick
import Quickshell.Io

// One process, one request. `start(argv, tag)` runs the command; `finished`
// fires after the process exited, with the tag the caller supplied so late
// answers can be recognised. The signal is delivered from the event loop
// (Qt.callLater), after Quickshell has cleared `running`, so a handler may
// immediately start the next request on the same object — chaining from
// StdioCollector.onStreamFinished or straight out of onExited is not safe.
Item {
  id: root

  property bool running: false
  readonly property string tag: proc.tag

  signal finished(string tag, string stdout, int exitCode)

  function start(argv, requestTag) {
    if (running || proc.running) return false
    running = true
    proc.tag = String(requestTag || "")
    proc.command = argv
    proc.running = true
    return true
  }

  function cancel() {
    if (proc.running) proc.running = false
    running = false
  }

  Process {
    id: proc
    property string tag: ""
    stdout: StdioCollector { id: collector; waitForEnd: true }
    onExited: function(exitCode) {
      var doneTag = proc.tag
      var text = String(collector.text || "")
      Qt.callLater(function() {
        root.running = false
        root.finished(doneTag, text, exitCode)
      })
    }
  }
}
