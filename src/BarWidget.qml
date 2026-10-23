import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "caseonline.omarchy.office365"

  // Where this plugin was installed, so the QML can find its own graph.py
  // without depending on a fixed path.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  readonly property string barLabel: String(setting("label", "")).trim()
  readonly property string barIcon: String(setting("icon", "󰇮"))
  readonly property bool tintOnUnread: setting("tintOnUnread", true) !== false

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  function refresh() {
    service.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract the bar uses to route summon/hide/toggle and to draw the
  // open-panel mark: these have to live on the widget in the bar slot, not on
  // the panel nested inside it.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    // Account hues resolve against the theme; this is what they fall back to
    // before the palette has been read.
    fallbackColor: root.bar ? root.bar.foreground : "#7aa2f7"
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Rendered by the shell's own Text item, so it is cleaned here rather than
    // pinned to plain text there.
    text: Model.plainText(root.barLabel !== "" ? root.barLabel : root.barIcon)
    // A text label needs more room than a glyph does.
    slotSize: root.barLabel !== "" ? Style.bar.statusSlot * 2 : Style.bar.iconSlot
    // Colour, not a count: the panel is where the numbers live. And only for
    // mail that is in the list - a backlog further down the mailbox leaves the
    // icon plain, so a tint keeps meaning "something arrived" rather than
    // fading into the permanent state of an inbox nobody empties.
    active: root.tintOnUnread && service.newUnreadCount > 0
    // One line per mailbox, so a combined widget says what it is holding
    // without opening the panel.
    tooltipText: {
      if (!service.configured) return "Office 365: add a mailbox in settings"
      var lines = []
      var views = service.views
      for (var i = 0; i < views.length; i++) {
        var view = views[i]
        // From the mailbox, and about to be drawn by the shell's tooltip.
        var who = Model.plainText(view.username !== "" ? view.username : view.alias)
        if (view.busy) lines.push(who + ": signed in, loading…")
        else if (!view.loaded) lines.push(who + ": loading…")
        else if (view.ok) lines.push(who + " · " + Model.unreadSummary(view, service.freshUnread))
        else if (view.errorCode === "auth_required") lines.push(who + ": sign in")
        else lines.push(who + ": " + Model.plainText(view.errorMessage))
      }
      if (service.errorCode !== "") lines.push(Model.plainText(service.errorMessage))
      return lines.join("\n")
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) service.focusApp("")
      else root.togglePanel()
    }
  }
}
