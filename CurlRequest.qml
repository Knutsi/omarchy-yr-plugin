import QtQuick
import Quickshell.Io

// One process, one request. `start(argv, tag)` runs the command; `finished`
// fires from onExited (the only reliable point to chain the next request —
// StdioCollector's onStreamFinished can run while `running` is still true)
// with the tag the caller supplied, so late answers can be recognised.
Item {
  id: root

  readonly property bool running: proc.running
  readonly property string tag: proc.tag

  signal finished(string tag, string stdout, int exitCode)

  function start(argv, requestTag) {
    if (proc.running) return false
    proc.tag = String(requestTag || "")
    proc.command = argv
    proc.running = true
    return true
  }

  function cancel() {
    if (proc.running) proc.running = false
  }

  Process {
    id: proc
    property string tag: ""
    stdout: StdioCollector { id: collector; waitForEnd: true }
    onExited: function(exitCode) {
      root.finished(proc.tag, String(collector.text || ""), exitCode)
    }
  }
}
