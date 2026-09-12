import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// BTC/NOK from Bare Bitcoin's public price endpoint in the bar.
//
// The pill is the current price; left click opens a detail panel with
// bid/ask and the active thresholds. Threshold alerts themselves fire from
// the price-watch.sh helper via notify-send, so they keep working even when
// the panel never opens. Middle click opens the config file in the default
// editor.
BarWidget {
  id: root
  moduleName: "io.github.katla50.barebitcoin"

  readonly property var loc: Qt.locale()

  // Manifest barWidget.defaults are merged into `settings` before the widget
  // sees them; the fallbacks only cover a hand-written shell.json entry.
  readonly property string icon: setting("icon", "₿")
  readonly property bool compact: setting("compact", false)
  readonly property bool showBidAsk: setting("showBidAsk", true)

  readonly property var feed: feedLoader.item
  readonly property bool feedReady: feed !== null && feed.hasData
  readonly property bool feedFailed: feed !== null && !feed.hasData && feed.error !== ""

  readonly property string priceText: {
    if (feedFailed) return "n/a"
    if (!feedReady) return "…"
    if (compact || vertical) return compactMoney(feed.price)
    return fullMoney(feed.price)
  }

  readonly property color pillColor: feed !== null && feed.error !== ""
    ? (bar ? bar.urgent : Color.urgent)
    : (bar ? bar.barForeground : Color.foreground)

  readonly property string configDir: Quickshell.env("HOME") + "/.config/barebitcoin-plugin"

  function openConfig() {
    Quickshell.execDetached(["xdg-open", configDir + "/config.json"])
  }

  function fullMoney(value) {
    return Math.round(value).toLocaleString(loc, "f", 0) + " kr"
  }

  function compactMoney(value) {
    if (value >= 1000000)
      return (value / 1000000).toLocaleString(loc, "f", 2) + "M kr"
    return (value / 1000).toLocaleString(loc, "f", 1) + "k kr"
  }

  // ---- Panel lifecycle. Shape contract for shell summon/hide routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar root.
  readonly property bool opened: panelLoader.item !== null && panelLoader.item.opened === true
  readonly property bool popoutSwitchClosing: panelLoader.item !== null && panelLoader.item.popoutSwitchClosing === true

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("feed" in target) target.feed = Qt.binding(function () { return feedLoader.item })
    if ("showBidAsk" in target) target.showBidAsk = Qt.binding(function () { return root.showBidAsk })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: feedLoader
    active: true
    source: Qt.resolvedUrl("Feed.qml")
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.katla50.barebitcoin"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    icon: root.icon
    text: root.priceText
    labelVisible: true
    tooltipText: {
      if (root.feedFailed) return "Bare Bitcoin: " + feed.error
      if (!root.feedReady) return "Bare Bitcoin BTC/NOK: loading…"
      return "BTC/NOK hos Bare Bitcoin: " + root.fullMoney(feed.price)
    }
    onPressed: function (b) {
      if (b === Qt.MiddleButton)
        root.openConfig()
      else
        root.togglePanel()
    }
  }
}
