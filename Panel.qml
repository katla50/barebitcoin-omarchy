import QtQuick
import qs.Commons
import qs.Ui

// Detail popup: current BTC/NOK price, bid/ask and the threshold state from
// ~/.config/barebitcoin-plugin/config.json, plus a link to barebitcoin.no.
//
// Alerts are not configured here — thresholds live in the config file the
// price-watch.sh helper polls, so a threshold edit takes effect on the next
// poll without a shell restart. The panel mirrors that file on an 11 s beat
// so edits show up quickly when the panel is open.
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
  readonly property color upColor: "#2ea043"

  // Mirrored config values; empty means "no threshold / default interval".
  property string cfgUpper: ""
  property string cfgLower: ""
  property string cfgInterval: ""
  readonly property string configDir: Quickshell.env("HOME") + "/.config/barebitcoin-plugin"

  readonly property var loc: Qt.locale()

  function money(value) {
    return Math.round(value).toLocaleString(loc, "f", 0) + " kr"
  }

  function open() {
    root.controller.show()
    configProbe.running = true
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: configProbe
    command: ["sh", "-c", "cat \"$HOME/.config/barebitcoin-plugin/config.json\" 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var doc
        try {
          doc = JSON.parse(String(text || "{}"))
        } catch (e) {
          return
        }
        root.cfgUpper = doc.upper_threshold_nok === null || doc.upper_threshold_nok === undefined
          ? "" : String(doc.upper_threshold_nok)
        root.cfgLower = doc.lower_threshold_nok === null || doc.lower_threshold_nok === undefined
          ? "" : String(doc.lower_threshold_nok)
        root.cfgInterval = doc.poll_interval_seconds === undefined
          ? "" : String(doc.poll_interval_seconds)
      }
    }
  }

  Timer {
    interval: 11000
    repeat: true
    running: root.opened
    onTriggered: configProbe.running = true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---- Header: name and data source.
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

        // ---- Current price, shared with the pill.
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
              ? (root.bar ? root.bar.urgent : Color.urgent)
              : root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- Bid/ask spread.
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

        // ---- Thresholds as configured; alerts fire from price-watch.sh.
        Text {
          width: parent.width
          text: "Varselsterskler (config.json)"
          color: root.textColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: {
            var lines = []
            lines.push("Øvre: " + (root.cfgUpper !== "" ? root.money(parseFloat(root.cfgUpper)) : "av"))
            lines.push("Nedre: " + (root.cfgLower !== "" ? root.money(parseFloat(root.cfgLower)) : "av"))
            if (root.cfgInterval !== "")
              lines.push("Intervall: " + root.cfgInterval + " s (min. 30)")
            return lines.join("\n")
          }
          color: root.mutedColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          text: "Rediger terskler i config.json →"
          color: root.textColor
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

        Text {
          text: "Sjekk kurs og kjøp på barebitcoin.no →"
          color: root.textColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: bbLink.containsMouse

          MouseArea {
            id: bbLink
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Qt.openUrlExternally("https://barebitcoin.no/")
          }
        }
      }
    }
  }
}
