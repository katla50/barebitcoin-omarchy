import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail popup: current BTC/NOK price, bid/ask, a price chart with day/week/
// month/year periods, and the threshold form.
//
// The chart's history comes from CoinGecko (Bare Bitcoin's public API has no
// historical price endpoint); the live price in the header is Bare Bitcoin's
// own quote. Thresholds are editable right here: saving writes
// ~/.config/barebitcoin-plugin/config.json through save-config.sh, and the
// running price-watch.sh helper picks the new values up on its next poll.
Panel {
  id: root
  moduleName: "io.github.katla50.barebitcoin"
  ipcTarget: "io.github.katla50.barebitcoin"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not
  // this nested panel, so the popout coordinator compares against that.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Injected by BarWidget so the panel and the pill never disagree.
  property var feed: null
  property bool showBidAsk: true

  readonly property color textColor: Color.popups.text
  readonly property color mutedColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.55)
  readonly property color accent: (bar && bar.accent !== undefined) ? bar.accent : Color.accent
  readonly property color upColor: "#2ea043"
  readonly property color downColor: (bar && bar.urgent !== undefined) ? bar.urgent : Color.urgent

  // Chart state. `chartPoints` mirrors the feed so the Canvas can repaint on
  // change without reaching into a possibly-null feed.
  property var chartPoints: []
  property string chartPeriod: "year"
  property string chartError: ""
  readonly property var periodLabels: [["day", "Dag"], ["week", "Uke"], ["month", "Måned"], ["year", "År"]]

  readonly property var loc: Qt.locale()
  readonly property string configDir: Quickshell.env("HOME") + "/.config/barebitcoin-plugin"

  // Saved thresholds, mirrored from config.json. Only these are drawn as
  // guide lines — unsaved text in the form must not move the chart.
  property real savedUpper: NaN
  property real savedLower: NaN
  property string saveStatus: ""
  property bool saveError: false

  function money(value) {
    return Math.round(value).toLocaleString(loc, "f", 0) + " kr"
  }

  function compactMoney(value) {
    if (value >= 1000000) return (value / 1000000).toLocaleString(loc, "f", 2) + "M"
    return (value / 1000).toLocaleString(loc, "f", 0) + "k"
  }

  function open() {
    root.controller.show()
    configProbe.running = true
    if (root.feed !== null) root.feed.loadHistory(root.chartPeriod, false)
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function pickPeriod(period) {
    root.chartPeriod = period
    root.hoverIndex = -1
    if (root.feed !== null) root.feed.loadHistory(period, false)
  }

  function digitsOnly(text) {
    return String(text).replace(/[^0-9.]/g, "")
  }

  function saveThresholds() {
    if (saveProcess.running) return
    // The fields are the source of truth while editing: reading them here
    // (instead of mirrored properties) keeps a binding from rewriting the
    // text under the cursor on every keystroke.
    var upper = digitsOnly(upperField.text)
    var lower = digitsOnly(lowerField.text)
    var interval = String(intervalField.text).replace(/[^0-9]/g, "")
    if (interval === "") interval = "60"

    saveProcess.command = ["sh", Qt.resolvedUrl("save-config.sh").toString().replace("file://", ""),
                           root.configDir, upper, lower, interval]
    root.saveStatus = ""
    saveProcess.running = true
  }

  function loadForm(text) {
    var doc
    try {
      doc = JSON.parse(String(text || "{}"))
    } catch (e) {
      return
    }

    var upper = doc.upper_threshold_nok === null || doc.upper_threshold_nok === undefined
      ? "" : String(doc.upper_threshold_nok)
    var lower = doc.lower_threshold_nok === null || doc.lower_threshold_nok === undefined
      ? "" : String(doc.lower_threshold_nok)
    var interval = doc.poll_interval_seconds === undefined
      ? "60" : String(doc.poll_interval_seconds)

    // Never clobber a field the user is typing in: the periodic config
    // refresh lands mid-edit and used to wipe half-typed numbers.
    if (!upperField.activeFocus) upperField.text = upper
    if (!lowerField.activeFocus) lowerField.text = lower
    if (!intervalField.activeFocus) intervalField.text = interval

    root.savedUpper = upper === "" ? NaN : Number(upper)
    root.savedLower = lower === "" ? NaN : Number(lower)
    chart.requestPaint()
  }

  function pointsUsable(pts) {
    return pts !== null && pts !== undefined && pts.length > 1
  }

  // A guide line only exists for a saved threshold that is actually inside
  // the chart's price range.
  readonly property bool thresholdLineVisible: {
    var s = root.chartStats
    if (s === null) return false
    var upper = !isNaN(root.savedUpper) && root.savedUpper >= s.min && root.savedUpper <= s.max
    var lower = !isNaN(root.savedLower) && root.savedLower >= s.min && root.savedLower <= s.max
    return upper || lower
  }

  // Min/max/change for the visible period, shared by the Canvas and the
  // corner labels.
  readonly property var chartStats: {
    var pts = root.chartPoints
    if (!pointsUsable(pts)) return null
    var min = Infinity, max = -Infinity
    for (var i = 0; i < pts.length; i++) {
      var v = Number(pts[i][1])
      if (v < min) min = v
      if (v > max) max = v
    }
    var first = Number(pts[0][1])
    var last = Number(pts[pts.length - 1][1])
    return {
      min: min,
      max: max,
      first: first,
      last: last,
      change: first > 0 ? (last - first) / first : 0
    }
  }

  // Padded price range and the pixel mapping, defined once so the Canvas
  // paint and the hover marker cannot drift apart.
  readonly property var chartRange: {
    var s = root.chartStats
    if (s === null) return null
    var span = s.max - s.min
    if (span <= 0) span = Math.max(1, s.max * 0.01)
    var padY = span * 0.08
    var lo = s.min - padY
    var hi = s.max + padY
    return { min: lo, max: hi, span: hi - lo }
  }

  function chartPointX(index) {
    var n = root.chartPoints.length
    if (n < 2) return 0
    return (index / (n - 1)) * chart.width
  }

  function chartPointY(value) {
    var r = root.chartRange
    if (r === null || chart.height <= 0) return 0
    return 6 + (chart.height - 12) * (1 - (value - r.min) / r.span)
  }

  // ---- Hover readout -----------------------------------------------------
  property int hoverIndex: -1

  function updateHover(mouseX) {
    var n = root.chartPoints.length
    if (n < 2 || chart.width <= 0) {
      root.hoverIndex = -1
      return
    }
    var i = Math.round((mouseX / chart.width) * (n - 1))
    root.hoverIndex = Math.max(0, Math.min(n - 1, i))
  }

  // Norwegian month abbreviations, spelled out instead of relying on the
  // shell process locale (which can be C/English and render "Jan").
  readonly property var monthsShort: ["jan", "feb", "mar", "apr", "mai", "jun",
                                      "jul", "aug", "sep", "okt", "nov", "des"]

  function two(value) {
    return value < 10 ? "0" + value : String(value)
  }

  function hoverLabel() {
    if (root.hoverIndex < 0 || root.hoverIndex >= root.chartPoints.length) return ""
    var point = root.chartPoints[root.hoverIndex]
    var date = new Date(Number(point[0]))
    var day = date.getDate() + ". " + root.monthsShort[date.getMonth()]
    var time = root.two(date.getHours()) + ":" + root.two(date.getMinutes())
    var label

    if (root.chartPeriod === "day") label = time
    else if (root.chartPeriod === "week") label = day + " " + time
    else if (root.chartPeriod === "month") label = day
    else label = root.monthsShort[date.getMonth()] + " " + date.getFullYear()

    return label + " · " + root.money(Number(point[1]))
  }

  Process {
    id: configProbe
    command: ["sh", "-c", "cat \"$HOME/.config/barebitcoin-plugin/config.json\" 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadForm(String(text || ""))
    }
  }

  Process {
    id: saveProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") {
          root.saveError = true
          root.saveStatus = err
        }
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() === "saved") {
          root.saveError = false
          root.saveStatus = "Lagret — gjelder fra neste poll"
          configProbe.running = true
          statusTimer.restart()
        }
      }
    }
    onExited: function (code, status) {
      if (code !== 0 && root.saveStatus === "") {
        root.saveError = true
        root.saveStatus = "Kunne ikke lagre (exit " + code + ")"
      }
    }
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: if (!root.saveError) root.saveStatus = ""
  }

  Timer {
    interval: 11000
    repeat: true
    running: root.opened
    onTriggered: configProbe.running = true
  }

  onFeedChanged: {
    if (root.feed !== null) root.feed.loadHistory(root.chartPeriod, false)
  }

  onHoverIndexChanged: chart.requestPaint()

  Connections {
    target: root.feed
    ignoreUnknownSignals: true
    function onHistoryPointsChanged() {
      root.chartPoints = root.feed !== null ? root.feed.historyPoints : []
      chart.requestPaint()
    }
    function onHistoryLoadingChanged() { chart.requestPaint() }
    function onHistoryErrorChanged() {
      root.chartError = root.feed !== null ? root.feed.historyError : ""
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---- Header ------------------------------------------------------
        Item {
          width: parent.width
          height: titleLabel.implicitHeight

          Text {
            id: titleLabel
            anchors.left: parent.left
            width: parent.width - sourceLabel.implicitWidth - Style.space(12)
            text: "BTC/NOK"
            color: root.textColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            id: sourceLabel
            anchors.right: parent.right
            anchors.baseline: titleLabel.baseline
            text: "Bare Bitcoin"
            color: root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Current price, shared with the pill --------------------------
        Item {
          width: parent.width
          height: priceText.implicitHeight

          Text {
            id: priceText
            anchors.left: parent.left
            anchors.top: parent.top
            text: root.feed !== null && root.feed.hasData ? root.money(root.feed.price) : "—"
            color: root.textColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
          }

          Text {
            anchors.right: parent.right
            anchors.baseline: priceText.baseline
            text: {
              if (root.feed === null) return "laster…"
              if (root.feed.hasData) {
                var age = root.feed.ageSeconds
                return age >= 0 ? "oppdatert for " + age + " s siden" : ""
              }
              return root.feed.error !== "" ? root.feed.error : "laster…"
            }
            color: root.feed !== null && root.feed.error !== "" && !root.feed.hasData
              ? root.downColor
              : root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          visible: root.showBidAsk
          width: parent.width
          text: {
            if (root.feed === null || !root.feed.hasData || isNaN(root.feed.bid) || isNaN(root.feed.ask))
              return "Bid/ask ikke tilgjengelig"
            return "Bid " + root.money(root.feed.bid) + "  ·  Ask " + root.money(root.feed.ask)
          }
          color: root.mutedColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator {
          width: parent.width
          foreground: root.textColor
        }

        // ---- Period selector and change ----------------------------------
        Row {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.periodLabels

            Button {
              required property var modelData
              readonly property bool isCurrent: root.chartPeriod === modelData[0]
              width: Style.space(62)
              text: modelData[1]
              selected: isCurrent
              bordered: true
              fontSize: Style.font.bodySmall
              foreground: root.textColor
              accent: root.accent
              onClicked: root.pickPeriod(modelData[0])
            }
          }

          Item { width: Style.space(6); height: 1 }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.chartStats !== null
              ? (root.chartStats.change >= 0 ? "+" : "")
                + (root.chartStats.change * 100).toFixed(1) + " %"
              : ""
            color: root.chartStats !== null && root.chartStats.change < 0
              ? root.downColor : root.upColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        // ---- Chart -------------------------------------------------------
        Item {
          width: parent.width
          height: Style.space(150)

          Canvas {
            id: chart
            anchors.fill: parent
            visible: root.pointsUsable(root.chartPoints)
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              var w = width
              var h = height
              var pad = 6
              ctx.clearRect(0, 0, w, h)

              var pts = root.chartPoints
              var stats = root.chartStats
              var range = root.chartRange
              if (!root.pointsUsable(pts) || stats === null || range === null) return

              // Horizontal grid at 25/50/75 %.
              ctx.strokeStyle = Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.10)
              ctx.lineWidth = 1
              for (var g = 1; g < 4; g++) {
                var gy = pad + (h - 2 * pad) * (g / 4)
                ctx.beginPath()
                ctx.moveTo(0, gy)
                ctx.lineTo(w, gy)
                ctx.stroke()
              }

              function xAt(i) { return root.chartPointX(i) }
              function yAt(v) { return root.chartPointY(v) }

              // Area fill under the line.
              ctx.beginPath()
              ctx.moveTo(xAt(0), yAt(Number(pts[0][1])))
              for (var i = 1; i < pts.length; i++) ctx.lineTo(xAt(i), yAt(Number(pts[i][1])))
              ctx.lineTo(w, h)
              ctx.lineTo(0, h)
              ctx.closePath()
              ctx.fillStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
              ctx.fill()

              // The line itself.
              ctx.beginPath()
              ctx.moveTo(xAt(0), yAt(Number(pts[0][1])))
              for (var j = 1; j < pts.length; j++) ctx.lineTo(xAt(j), yAt(Number(pts[j][1])))
              ctx.strokeStyle = root.accent
              ctx.lineWidth = 2
              ctx.lineJoin = "round"
              ctx.stroke()

              // Dot on the newest point.
              var lastX = xAt(pts.length - 1)
              var lastY = yAt(Number(pts[pts.length - 1][1]))
              ctx.beginPath()
              ctx.arc(lastX - 2, lastY, 3, 0, Math.PI * 2)
              ctx.fillStyle = root.accent
              ctx.fill()

              // Saved alert thresholds as orange guide lines. Only values that
              // are actually saved in config.json get a line, and only when
              // they fall inside the visible price range.
              var thresholdColor = "#f7931e"
              var lines = [
                { value: root.savedUpper, label: "varsel over" },
                { value: root.savedLower, label: "varsel under" }
              ]
              ctx.setLineDash([6, 4])
              ctx.lineWidth = 1.5
              for (var k = 0; k < lines.length; k++) {
                var tv = lines[k].value
                if (isNaN(tv) || tv < stats.min || tv > stats.max) continue
                var ty = yAt(tv)
                ctx.beginPath()
                ctx.moveTo(0, ty)
                ctx.lineTo(w, ty)
                ctx.strokeStyle = thresholdColor
                ctx.stroke()
              }
              ctx.setLineDash([])

              // Hover marker: vertical guide and a dot on the nearest sample.
              if (root.hoverIndex >= 0 && root.hoverIndex < pts.length) {
                var hx = xAt(root.hoverIndex)
                var hy = yAt(Number(pts[root.hoverIndex][1]))

                ctx.strokeStyle = Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.35)
                ctx.lineWidth = 1
                ctx.setLineDash([3, 3])
                ctx.beginPath()
                ctx.moveTo(hx, 0)
                ctx.lineTo(hx, h)
                ctx.stroke()
                ctx.setLineDash([])

                ctx.beginPath()
                ctx.arc(hx, hy, 4, 0, Math.PI * 2)
                ctx.fillStyle = root.accent
                ctx.fill()
                ctx.strokeStyle = root.textColor
                ctx.lineWidth = 1.5
                ctx.stroke()
              }
            }
          }

          MouseArea {
            id: chartMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: Qt.CrossCursor
            onPositionChanged: root.updateHover(mouseX)
            onExited: root.hoverIndex = -1
          }

          // Readout follows the cursor, clamped so it never leaves the chart.
          Rectangle {
            id: hoverBubble
            visible: root.hoverIndex >= 0
            readonly property real anchorX: root.chartPointX(root.hoverIndex)
            readonly property real anchorY: root.hoverIndex >= 0
              ? root.chartPointY(Number(root.chartPoints[root.hoverIndex][1]))
              : 0
            width: hoverLabelText.implicitWidth + Style.space(10)
            height: hoverLabelText.implicitHeight + Style.space(6)
            x: Math.max(0, Math.min(parent.width - width, anchorX - width / 2))
            y: Math.max(0, Math.min(parent.height - height, anchorY - height - Style.space(8)))
            color: Color.popups.background
            border.color: Color.popups.border
            border.width: 1
            radius: Style.cornerRadius

            Text {
              id: hoverLabelText
              anchors.centerIn: parent
              text: root.hoverLabel()
              color: root.textColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            anchors.centerIn: parent
            visible: !root.pointsUsable(root.chartPoints)
            text: root.feed !== null && root.feed.historyLoading
              ? "laster historikk…"
              : (root.chartError !== "" ? root.chartError : "ingen historikk")
            color: root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: parent.left
            anchors.top: parent.top
            visible: root.chartStats !== null
            text: root.chartStats !== null ? "maks " + root.compactMoney(root.chartStats.max) : ""
            color: root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            visible: root.chartStats !== null
            text: root.chartStats !== null ? "min " + root.compactMoney(root.chartStats.min) : ""
            color: root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          text: "Historikk: CoinGecko (BTC/NOK) · nåpris: Bare Bitcoin"
          color: root.mutedColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.thresholdLineVisible
          text: "Oransje stiplet linje = lagret prisvarsel"
          color: "#f7931e"
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator {
          width: parent.width
          foreground: root.textColor
        }

        // ---- Threshold form ----------------------------------------------
        Text {
          width: parent.width
          text: "Prisvarsel"
          color: root.textColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Column {
            width: (parent.width - Style.space(8)) / 2
            spacing: Style.space(3)

            Text {
              text: "Varsle over (NOK)"
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: upperField
              width: parent.width
              placeholderText: "av"
              foreground: root.textColor
              accent: root.accent
              onAccepted: root.saveThresholds()
            }
          }

          Column {
            width: (parent.width - Style.space(8)) / 2
            spacing: Style.space(3)

            Text {
              text: "Varsle under (NOK)"
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: lowerField
              width: parent.width
              placeholderText: "av"
              foreground: root.textColor
              accent: root.accent
              onAccepted: root.saveThresholds()
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Column {
            width: (parent.width - Style.space(8)) / 2
            spacing: Style.space(3)

            Text {
              text: "Poll hvert (sek, min. 30)"
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: intervalField
              width: parent.width
              placeholderText: "60"
              foreground: root.textColor
              accent: root.accent
              onAccepted: root.saveThresholds()
            }
          }

          Button {
            anchors.bottom: parent.bottom
            width: (parent.width - Style.space(8)) / 2
            text: "Lagre innstillinger"
            bordered: true
            foreground: root.textColor
            accent: root.accent
            onClicked: root.saveThresholds()
          }
        }

        Text {
          width: parent.width
          text: root.saveStatus
          visible: root.saveStatus !== ""
          color: root.saveError ? root.downColor : root.upColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          text: "Tomt felt = terskelen er av. Endringer gjelder fra neste poll."
          color: root.mutedColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        PanelSeparator {
          width: parent.width
          foreground: root.textColor
        }

        // ---- Links -------------------------------------------------------
        Text {
          text: "Kjøp bitcoin hos Bare Bitcoin →"
          color: root.textColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: bbLink.containsMouse

          MouseArea {
            id: bbLink
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Qt.openUrlExternally("https://barebitcoin.no/invitert/uHgWAMQr")
          }
        }

        Text {
          text: "Rediger config.json direkte →"
          color: root.mutedColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: configLink.containsMouse

          MouseArea {
            id: configLink
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Quickshell.execDetached(["xdg-open", root.configDir + "/config.json"])
          }
        }
      }
    }
  }
}
