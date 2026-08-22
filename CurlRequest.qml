import QtQuick
import Quickshell.Io

// One process, one request. `start(argv, tag)` runs the command; `finished`
// fires after the process exited, with the tag the caller supplied so late
// answers can be recognised. The signal is delivered from the event loop
// (Qt.callLater), after Quickshell has cleared `running`, so a handler may
// immediately start the next request on the same object — chaining from
// StdioCollector.onStreamFinished or straight out of onExited is not safe.
//
// `collect: false` attaches no collector: the output is not copied into a
// JS string. It is NOT a ceiling — QProcess still drains the pipe into its
// own buffer for the life of the process (measured: ~1:1 with the bytes
// written) — so it is only for helpers that print at most a line and whose
// exit code is all that matters. A noisy child must be bounded at the source.
Item {
  id: root

  property bool running: false
  property bool collect: true
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

  StdioCollector { id: collector; waitForEnd: true }

  Process {
    id: proc
    property string tag: ""
    stdout: root.collect ? collector : null
    onExited: function(exitCode) {
      var doneTag = proc.tag
      var text = root.collect ? String(collector.text || "") : ""
      Qt.callLater(function() {
        root.running = false
        root.finished(doneTag, text, exitCode)
      })
    }
  }
}
