import QtQuick
import Quickshell
import Quickshell.Io

// Price feed for Bare Bitcoin's public BTC/NOK endpoint, fed line by line
// from the price-watch.sh helper process.
//
// The helper does the work that should not run inside the long-lived shell
// process: reading ~/.config/barebitcoin-plugin/config.json, the GET against
// https://api.bb.no/v1/price/nok, threshold crossing detection with persisted
// re-arm state, and notify-send. It prints the endpoint's JSON verbatim on
// each successful poll and {"error": ...} lines on failure, so this file is
// a thin parser over that stream. A failed poll never blanks a working price.
Item {
  id: feed

  property real price: NaN
  property real bid: NaN
  property real ask: NaN
  property string timestamp: ""
  property string error: ""
  readonly property bool hasData: !isNaN(price)

  // Milliseconds since the last successful poll, for the panel's "updated"
  // line and the pill's staleness hint.
  property var lastSuccessAt: null
  readonly property int ageSeconds: lastSuccessAt === null
    ? -1
    : Math.max(0, Math.round((Date.now() - lastSuccessAt) / 1000))

  readonly property string configDir: Quickshell.env("HOME") + "/.config/barebitcoin-plugin"

  Process {
    id: watcher
    running: true
    command: ["sh", Qt.resolvedUrl("price-watch.sh").toString().replace("file://", ""),
              feed.configDir]

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (data) {
        var doc
        try {
          doc = JSON.parse(data)
        } catch (e) {
          return
        }
        if (typeof doc.price === "number") {
          feed.price = doc.price
          feed.bid = typeof doc.bid === "number" ? doc.bid : NaN
          feed.ask = typeof doc.ask === "number" ? doc.ask : NaN
          feed.timestamp = typeof doc.timestamp === "string" ? doc.timestamp : ""
          feed.error = ""
          feed.lastSuccessAt = Date.now()
        } else if (typeof doc.error === "string" && !feed.hasData) {
          feed.error = doc.error
        }
      }
    }

    // The helper owns its own retry pace; if it ever dies (config dir
    // vanished mid-run, killed process) restart it after a short beat.
    onExited: function (code, status) {
      feed.error = "watcher stopped (exit " + code + ")"
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    interval: 30000
    onTriggered: {
      feed.error = ""
      watcher.running = true
    }
  }
}
