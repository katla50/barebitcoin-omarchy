import QtQuick
import Quickshell
import Quickshell.Io

// Price feed for Bare Bitcoin's public BTC/NOK endpoint, fed line by line
// from the price-watch.sh helper process, plus price history for the chart.
//
// Live price: the helper does the work that should not run inside the
// long-lived shell process — reading ~/.config/barebitcoin-plugin/config.json,
// the GET against https://api.bb.no/v1/price/nok, threshold crossing detection
// with persisted re-arm state, and notify-send. It prints the endpoint's JSON
// verbatim on each successful poll and {"error": ...} lines on failure, so this
// file is a thin parser over that stream. A failed poll never blanks a
// working price.
//
// History: Bare Bitcoin's public API exposes no historical price endpoint
// (only /v1/price/nok and volume), so the chart uses CoinGecko's public
// BTC/NOK market chart — no key, GET only. It is labelled as such in the
// panel: the line is the market price, the live pill is Bare Bitcoin's own
// quote, and those differ by roughly the spread.
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

  // ---- History -----------------------------------------------------------
  readonly property var periodDays: ({ "day": 1, "week": 7, "month": 30, "year": 365 })
  property string historyPeriod: "year"
  property var historyPoints: []          // [[timestampMs, price], ...]
  property bool historyLoading: false
  property string historyError: ""
  // period -> { at: ms, points: [[t, p], ...] }; ten-minute freshness keeps
  // repeated panel opens from hammering CoinGecko's public rate limit.
  property var historyCache: ({})

  readonly property string userAgent: "io.github.katla50.barebitcoin/1.0 (Omarchy plugin)"

  function loadHistory(period, force) {
    if (!(period in feed.periodDays)) period = "year"

    var cached = feed.historyCache[period]
    if (!force && cached !== undefined && (Date.now() - cached.at) < 600000) {
      feed.historyPeriod = period
      feed.historyPoints = cached.points
      feed.historyError = ""
      return
    }

    feed.historyPeriod = period
    feed.historyLoading = true
    feed.historyError = ""

    var days = feed.periodDays[period]
    var request = new XMLHttpRequest()
    request.onreadystatechange = function () {
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (feed.historyPeriod !== period) return   // a newer period won
      feed.historyLoading = false

      if (request.status !== 200) {
        feed.historyError = request.status === 429
          ? "rate limited by CoinGecko — prøv igjen om litt"
          : "historikk utilgjengelig (" + request.status + ")"
        return
      }

      var doc
      try {
        doc = JSON.parse(request.responseText)
      } catch (e) {
        feed.historyError = "kunne ikke lese historikken"
        return
      }
      var rows = doc && doc.prices
      if (!Array.isArray(rows) || rows.length === 0) {
        feed.historyError = "ingen historikkpunkter"
        return
      }

      var points = feed.downsample(rows, 180)
      var cache = feed.historyCache
      cache[period] = { at: Date.now(), points: points }
      feed.historyCache = cache
      feed.historyPoints = points
    }

    request.open("GET", "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart"
      + "?vs_currency=nok&days=" + days + "&precision=2")
    request.setRequestHeader("User-Agent", feed.userAgent)
    request.send()
  }

  // Equal-width sampling keeps the shape while bounding the polyline the
  // Canvas has to paint; the last point is always the newest.
  function downsample(rows, target) {
    if (rows.length <= target) return rows
    var step = rows.length / target
    var out = []
    for (var i = 0; i < target; i++) out.push(rows[Math.floor(i * step)])
    out.push(rows[rows.length - 1])
    return out
  }

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
