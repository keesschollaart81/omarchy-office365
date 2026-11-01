import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Settings for one widget, in two levels: a list of the mailboxes it carries,
// and a page per mailbox. Editing one mailbox is then a short page instead of
// a section inside a long form. Edits are held locally until Save, which
// writes them into this instance's own entry in shell.json.
Item {
  id: root

  property var service: null
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal done()

  implicitHeight: form.implicitHeight

  // -1 is the index, -2 the calendar, -3 mail; anything from 0 up is that
  // mailbox's own page.
  readonly property int pageList: -1
  readonly property int pageCalendar: -2
  readonly property int pageMail: -3
  property int editing: pageList

  // Working copies, so Cancel really cancels.
  property string vLabel: ""
  property string vIcon: ""
  property string vCalendar: "3day"
  property int vMails: 5
  property int vRefresh: 180
  property bool vTint: true
  property bool vMarkRead: false
  property bool vPreviewLine: true
  property bool vFocusedDefault: false
  property string vAgendaView: "list"
  property string vDayStart: "07:00"
  property string vDayEnd: "22:00"
  property bool vShowWeekends: true
  // One entry per mailbox. Kept as a plain array and replaced wholesale on
  // every edit, which is what makes the Repeaters rebuild.
  property var rows: []
  property var advancedOpen: ({})

  // Set between pressing Save and hearing back. Writing shell.json is another
  // process, so the answer arrives well after the button is released: closing
  // on the press would throw the edits away and hide the error in the case
  // where the write failed, which reads as a save that worked.
  property bool closeWhenSaved: false

  readonly property var calendarValues: ["1day", "3day", "week"]
  readonly property var calendarLabels: ["Today", "3 days", "Week"]
  // A few glyphs worth picking for a mail widget, so choosing one does not
  // mean going and looking up a Nerd Font codepoint. The field beside them
  // still takes anything else.
  //
  // Every one of these was rendered and looked at before it went in the
  // list: plenty of plausible-looking Material codepoints are missing from
  // the bar font and draw as an empty box, and plenty of the ones that do
  // render turn out to be a coffee cup.
  readonly property var iconChoices: [
    "󰇮", "󰇯", "󰇰", "󰂚", "󰭹",
    "󰃭", "󰸗", "󰅐", "󰀄", "󰓎"
  ]
  readonly property var hues: ["blue", "green", "magenta", "yellow", "cyan", "orange", "red", "brown"]

  function setting(name, fallback) {
    if (!service || !service.settings) return fallback
    var value = service.settings[name]
    return value === undefined || value === null ? fallback : value
  }

  function hueColor(name, index) {
    return Model.resolveColor(name, service ? service.themePalette : ({}), index, root.dim)
  }

  function load() {
    vLabel = String(setting("label", ""))
    vIcon = String(setting("icon", ""))
    vCalendar = String(setting("calendar", "3day"))
    vMails = parseInt(String(setting("mails", 5)), 10) || 5
    vRefresh = parseInt(String(setting("refreshIntervalSec", 180)), 10) || 180
    vTint = setting("tintOnUnread", true) !== false
    vMarkRead = setting("markReadOnOpen", false) === true
    vPreviewLine = setting("previewLine", true) !== false
    vFocusedDefault = setting("focusedByDefault", false) === true
    vAgendaView = String(setting("agendaView", "list")) === "timeline" ? "timeline" : "list"
    vDayStart = String(setting("dayStart", "07:00"))
    vDayEnd = String(setting("dayEnd", "22:00"))
    vShowWeekends = setting("showWeekends", true) !== false

    var loaded = []
    var configs = service ? service.accountConfigs : []
    for (var i = 0; i < configs.length; i++) {
      loaded.push({
        account: String(configs[i].account || ""),
        short: String(configs[i].short || ""),
        color: String(configs[i].color || ""),
        clientId: String(configs[i].clientId || ""),
        authority: String(configs[i].authority || ""),
        webUrl: String(configs[i].webUrl || ""),
        // Not editable here - a command with arguments does not survive a
        // single text field - but carried through so saving never drops it.
        // Normalised to a real array, since config arrays arrive as JSValue
        // lists that would not survive JSON.stringify on save, and since the
        // older string form has to come through this too.
        openCommand: Model.commandArgv(configs[i].openCommand),
        focusMatch: String(configs[i].focusMatch || "")
      })
    }
    rows = loaded
    editing = pageList
    // With nothing configured, this form is the whole panel - so start on the
    // page that adds a mailbox rather than on an empty list with a button.
    if (loaded.length === 0 && service && !service.configured) addRow()
  }

  function updateRow(index, key, value) {
    var copy = rows.slice()
    var entry = {}
    for (var k in copy[index]) entry[k] = copy[index][k]
    entry[key] = value
    copy[index] = entry
    rows = copy
  }

  function addRow() {
    var copy = rows.slice()
    copy.push({ account: "", short: "", color: "", clientId: "", authority: "", webUrl: "", openCommand: [], focusMatch: "" })
    rows = copy
    editing = copy.length - 1
  }

  function removeRow(index) {
    var copy = rows.slice()
    copy.splice(index, 1)
    rows = copy
    editing = pageList
  }

  function toggleAdvanced(index) {
    var next = {}
    for (var key in advancedOpen) next[key] = advancedOpen[key]
    next[index] = !next[index]
    advancedOpen = next
  }

  function viewFor(alias) {
    return service ? service.viewFor(String(alias || "").trim()) : null
  }

  function statusFor(alias) {
    if (String(alias || "").trim() === "") return "no alias yet"
    var view = viewFor(alias)
    if (!view) return "not signed in"
    if (view.busy) return "signed in, loading…"
    if (!view.loaded) return "checking…"
    if (view.ok) return view.username !== "" ? view.username : "signed in"
    if (view.errorCode === "auth_required") return "not signed in"
    return view.errorMessage
  }

  function needsSignIn(alias) {
    var view = viewFor(alias)
    return !!view && !view.busy && view.loaded && !view.ok && view.errorCode === "auth_required"
  }

  function canWrite(alias) {
    return !!service && service.canWrite(String(alias || "").trim())
  }

  function isSignedIn(alias) {
    var view = viewFor(alias)
    return !!view && (view.ok || view.busy)
  }

  function save() {
    if (!service) return
    var accounts = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (String(row.account).trim() === "") continue
      var entry = { account: String(row.account).trim() }
      if (String(row.short).trim() !== "") entry.short = String(row.short).trim()
      if (String(row.color).trim() !== "") entry.color = String(row.color).trim()
      if (String(row.clientId).trim() !== "") entry.clientId = String(row.clientId).trim()
      if (String(row.authority).trim() !== "") entry.authority = String(row.authority).trim()
      if (String(row.webUrl).trim() !== "") entry.webUrl = String(row.webUrl).trim()
      if (String(row.focusMatch).trim() !== "") entry.focusMatch = String(row.focusMatch).trim()
      if (row.openCommand && row.openCommand.length > 0) entry.openCommand = row.openCommand
      accounts.push(entry)
    }

    // Empty strings tell config.py to drop a key, so clearing a field restores
    // the plugin default rather than storing "". The v1 single-account keys go
    // with it: the account list is where mailboxes live now.
    var started = service.saveSettings({
      accounts: accounts,
      label: vLabel.trim(),
      icon: vIcon.trim(),
      calendar: vCalendar,
      agendaView: vAgendaView,
      dayStart: vDayStart.trim(),
      dayEnd: vDayEnd.trim(),
      showWeekends: vShowWeekends,
      mails: vMails,
      refreshIntervalSec: vRefresh,
      tintOnUnread: vTint,
      markReadOnOpen: vMarkRead,
      previewLine: vPreviewLine,
      focusedByDefault: vFocusedDefault,
      account: "", short: "", color: "", clientId: "", authority: "", webUrl: "", focusMatch: ""
    })
    // Closed by onSettingsSaved, or not at all if the write failed. A second
    // press while the first is still running must not clear this.
    if (started === true) closeWhenSaved = true
  }

  // The panel injects `service` after this form is constructed, so loading
  // only on completion would read an empty settings object and leave every
  // field blank. Reload when the service arrives, and again when shell.json is
  // rewritten underneath us.
  Component.onCompleted: load()
  onServiceChanged: load()

  Connections {
    target: root.service
    function onSettingsChanged() { root.load() }
    // shell.json is written. Only now is there nothing left to lose by closing.
    function onSettingsSaved() {
      if (!root.closeWhenSaved) return
      root.closeWhenSaved = false
      root.done()
    }
  }

  Column {
    id: form
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.spacing.xxl

    // ==================== list ====================
    Column {
      width: parent.width
      spacing: Style.spacing.xxl
      visible: root.editing === root.pageList

      Column {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          text: "MAILBOXES"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }

        Repeater {
          model: root.rows

          SettingsRow {
            required property var modelData
            required property int index
            width: parent.width
            showDot: true
            dotColor: root.hueColor(modelData.color, index)
            title: String(modelData.account).trim() === "" ? "New mailbox" : modelData.account
            detail: root.statusFor(modelData.account)
            alert: root.needsSignIn(modelData.account)
            fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
            onClicked: root.editing = index
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.rows.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: "No mailboxes yet."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Button {
          text: "Add mailbox"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.addRow()
        }
      }

      // ---- what the panel shows ----
      // Two pages rather than a dozen controls in a column: mail and the
      // calendar each have enough settings of their own now, and an index of
      // places to go is easier to scan than a wall of switches.
      Column {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          text: "SHOW"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }

        SettingsRow {
          width: parent.width
          title: "Mail"
          detail: {
            var parts = [root.vMails + (root.rows.length > 1 ? " per mailbox" : " newest")]
            if (root.vFocusedDefault) parts.push("starts on Focused")
            if (root.vMarkRead) parts.push("marks read when opened")
            return parts.join(" · ")
          }
          fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
          onClicked: root.editing = root.pageMail
        }

        SettingsRow {
          width: parent.width
          title: "Calendar"
          detail: {
            var index = root.calendarValues.indexOf(root.vCalendar)
            var range = root.calendarLabels[index < 0 ? 1 : index]
            if (root.vAgendaView !== "timeline") return range + " · as a list"
            return range + " · " + root.vDayStart + "–" + root.vDayEnd
          }
          fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
          onClicked: root.editing = root.pageCalendar
        }
      }

      // ---- widget appearance ----
      Column {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          text: "BAR"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }

        Row {
          width: parent.width
          spacing: Style.spacing.lg

          TextField {
            width: (parent.width - Style.spacing.lg) / 2
            text: root.vLabel
            placeholderText: "label, e.g. MAIL"
            foreground: root.fg
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.vLabel = text
          }

          TextField {
            width: (parent.width - Style.spacing.lg) / 2
            text: root.vIcon
            placeholderText: "icon glyph"
            foreground: root.fg
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.vIcon = text
          }
        }

        // Dimmed while a label is set, because the label is what the bar will
        // actually show - picking an icon there would otherwise appear to do
        // nothing at all.
        Flow {
          width: parent.width
          spacing: Style.spacing.sm
          opacity: root.vLabel.trim() === "" ? 1.0 : 0.4

          Behavior on opacity { NumberAnimation { duration: 140 } }

          Repeater {
            model: root.iconChoices

            Rectangle {
              id: choice
              required property var modelData
              readonly property bool selected: root.vIcon === choice.modelData
              width: Style.space(30)
              height: width
              radius: Style.space(5)
              color: choice.selected ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                                     : (choiceHover.containsMouse
                                        ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
                                        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04))
              border.width: choice.selected ? Style.space(1) : 0
              border.color: root.accent

              Behavior on color { ColorAnimation { duration: 120 } }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: choice.modelData
                color: choice.selected ? root.accent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
              }

              MouseArea {
                id: choiceHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Clicking the one already chosen clears it, back to the
                // default glyph - the same toggle as the filter pills.
                onClicked: root.vIcon = choice.selected ? "" : String(choice.modelData)
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.vLabel.trim() !== ""
            ? "The label is shown instead of an icon. Clear it to use one of these, or type any other Nerd Font glyph."
            : "One icon for the whole widget. Pick one, or type any other Nerd Font glyph; leave it empty for the default."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(tintLabel.implicitHeight, tintSwitch.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: tintLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Highlight while unread"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          ToggleSwitch {
            id: tintSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.vTint
            foreground: root.fg
            accent: root.accent
            onToggled: root.vTint = !root.vTint
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Colours the bar icon while any mailbox here has unread mail, so it stands out without showing a number."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- fetching ----
      // Not on either page: one poll brings back both.
      Column {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          text: "UPDATES"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(refreshLabel.implicitHeight, refreshField.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: refreshLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Refresh every (seconds)"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          NumberField {
            id: refreshField
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            value: root.vRefresh
            from: 60
            to: 3600
            stepSize: 30
            foreground: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            onModified: function(v) { root.vRefresh = v }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "How often every mailbox here is asked for new mail and meetings."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ==================== mail ====================
    Column {
      width: parent.width
      spacing: Style.spacing.lg
      visible: root.editing === root.pageMail

      Item {
        implicitWidth: mailBackRow.implicitWidth
        implicitHeight: mailBackRow.implicitHeight

        Row {
          id: mailBackRow
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            text: "󰅁"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: "MAIL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.editing = root.pageList
        }
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(mailsLabel.implicitHeight, mailsField.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: mailsLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Mails to show"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        NumberField {
          id: mailsField
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          value: root.vMails
          from: 1
          to: 25
          stepSize: 1
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          onModified: function(v) { root.vMails = v }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.rows.length > 1
          ? "Rows in the merged list, read and unread. Every mailbox is fetched this deep, so the list fills up whichever one the newest mail is in."
          : "The newest mail, read and unread. Use the Unread filter in the panel to narrow it down."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(focusedLabel.implicitHeight, focusedSwitch.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: focusedLabel
          anchors.left: parent.left
          anchors.right: focusedSwitch.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "Start on Focused"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: focusedSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.vFocusedDefault
          foreground: root.fg
          accent: root.accent
          onToggled: root.vFocusedDefault = !root.vFocusedDefault
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Open with Outlook's Other mail hidden. Press f in the panel to switch it either way, u for unread."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(previewLabel.implicitHeight, previewSwitch.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: previewLabel
          anchors.left: parent.left
          anchors.right: previewSwitch.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "Preview line"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: previewSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.vPreviewLine
          foreground: root.fg
          accent: root.accent
          onToggled: root.vPreviewLine = !root.vPreviewLine
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "A line of the message body under each subject."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(markLabel.implicitHeight, markSwitch.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: markLabel
          anchors.left: parent.left
          anchors.right: markSwitch.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "Mark read when opened"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: markSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.vMarkRead
          foreground: root.fg
          accent: root.accent
          onToggled: root.vMarkRead = !root.vMarkRead
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.vMarkRead
          ? "Needs permission to change mail. Grant it per mailbox from the mailbox's own page - until then, opening a message leaves it unread."
          : "Opening a message in the panel leaves it unread. Turning this on needs permission to change mail."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ==================== calendar ====================
    Column {
      width: parent.width
      spacing: Style.spacing.lg
      visible: root.editing === root.pageCalendar

      Item {
        implicitWidth: calendarBackRow.implicitWidth
        implicitHeight: calendarBackRow.implicitHeight

        Row {
          id: calendarBackRow
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            text: "󰅁"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: "CALENDAR"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.editing = root.pageList
        }
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(viewLabel.implicitHeight, viewGroup.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: viewLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Show as"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        ButtonGroup {
          id: viewGroup
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          options: ["List", "Grid"]
          value: root.vAgendaView === "timeline" ? "Grid" : "List"
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          onChanged: function(v) { root.vAgendaView = v === "Grid" ? "timeline" : "list" }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "A grid draws meetings at the size and position their times give them, the way Outlook does. The panel widens to make room for it."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(rangeLabel.implicitHeight, rangeGroup.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: rangeLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Days"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        ButtonGroup {
          id: rangeGroup
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          options: root.calendarLabels
          value: {
            var index = root.calendarValues.indexOf(root.vCalendar)
            return root.calendarLabels[index < 0 ? 1 : index]
          }
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          onChanged: function(v) {
            var index = root.calendarLabels.indexOf(v)
            if (index >= 0) root.vCalendar = root.calendarValues[index]
          }
        }
      }

      // Grid-only from here down: the list has no hours to bound and no
      // columns to leave out.
      Column {
        width: parent.width
        spacing: Style.spacing.lg
        visible: root.vAgendaView === "timeline"

        Row {
          width: parent.width
          spacing: Style.spacing.lg

          LabeledField {
            width: (parent.width - Style.spacing.lg) / 2
            label: "Day starts"
            placeholder: "07:00"
            value: root.vDayStart
            fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
            onEdited: function(v) { root.vDayStart = v }
          }

          LabeledField {
            width: (parent.width - Style.spacing.lg) / 2
            label: "Day ends"
            placeholder: "22:00"
            value: root.vDayEnd
            fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
            onEdited: function(v) { root.vDayEnd = v }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "The hours the grid draws, so a day fits at a useful size. Nothing is hidden by it - meetings outside these hours appear as a line at the top or bottom that opens the day up when clicked."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(weekendLabel.implicitHeight, weekendSwitch.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: weekendLabel
            anchors.left: parent.left
            anchors.right: weekendSwitch.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: "Show weekends"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          ToggleSwitch {
            id: weekendSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.vShowWeekends
            foreground: root.fg
            accent: root.accent
            onToggled: root.vShowWeekends = !root.vShowWeekends
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Leaving them out gives the working days more room across."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ==================== one mailbox ====================
    // A Repeater rather than one reused page: each mailbox owns its own text
    // fields, so moving between mailboxes cannot leave the previous one's
    // typing behind in a field whose binding was broken by editing it.
    // Keyed on the count, not the array: rows is replaced on every keystroke,
    // and a Repeater over it would rebuild the page - and the field being
    // typed in - after each character.
    Repeater {
      model: root.rows.length

      Column {
        id: page
        readonly property var modelData: root.rows[index] || ({})
        required property int index
        width: parent.width
        spacing: Style.spacing.xxl
        visible: root.editing === page.index

        Column {
          width: parent.width
          spacing: Style.spacing.lg

          // Back to the list. The MouseArea sits outside the Row: a Row
          // refuses to lay out children that anchor to it.
          Item {
            implicitWidth: backRow.implicitWidth
            implicitHeight: backRow.implicitHeight

            Row {
              id: backRow
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: "󰅁"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Mailboxes"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.editing = root.pageList
            }
          }

          // Only for the very first mailbox, where this page is the first
          // thing the widget ever shows and "no alias yet" needs a sentence
          // around it to make sense.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !!root.service && !root.service.configured
            wrapMode: Text.WordWrap
            text: "Name this mailbox, then Save and sign in. Works with Microsoft 365 and Outlook.com accounts, and you can add more later."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // Status opposite the action it invites. Nothing to say until the
          // mailbox has a name - "no alias yet" only repeats the empty field
          // below it.
          Item {
            width: parent.width
            visible: String(page.modelData.account).trim() !== ""
            implicitHeight: Math.max(pageStatus.implicitHeight, pageActions.implicitHeight)

            Text {
              textFormat: Text.PlainText
              id: pageStatus
              anchors.left: parent.left
              anchors.right: pageActions.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: root.statusFor(page.modelData.account)
              color: root.needsSignIn(page.modelData.account) ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Row {
              id: pageActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Button {
                text: "Sign in"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                visible: root.needsSignIn(page.modelData.account)
                onClicked: if (root.service) root.service.startLogin(String(page.modelData.account).trim())
              }

              Button {
                text: "Sign out"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                visible: root.isSignedIn(page.modelData.account)
                onClicked: if (root.service) root.service.signOut(String(page.modelData.account).trim())
              }
            }
          }

          // Read-only is the default. Granting more is an explicit act, and
          // it costs a sign-in, so say both things plainly.
          Item {
            width: parent.width
            implicitHeight: Math.max(writeText.implicitHeight, writeButton.implicitHeight)
            visible: root.isSignedIn(page.modelData.account)

            Text {
              textFormat: Text.PlainText
              id: writeText
              anchors.left: parent.left
              anchors.right: writeButton.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: root.canWrite(page.modelData.account)
                    ? "Can mark and delete mail"
                    : "Read-only access"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              id: writeButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: !root.canWrite(page.modelData.account)
              text: "Allow changes…"
              tooltipText: "Signs in again, asking for permission to change mail"
              bordered: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: if (root.service) root.service.startLogin(String(page.modelData.account).trim(), true)
            }
          }

          LabeledField {
            width: parent.width
            label: "Alias"
            placeholder: "e.g. work"
            hint: "Names this mailbox's sign-in, and the file its tokens live in. Letters, digits, dot, dash and underscore. Changing it switches to a different account's tokens."
            // Held to what can name a token file one-to-one, matching
            // graph.py's ALIAS_ALLOWED. Two aliases that differed only in
            // punctuation would otherwise share one mailbox's tokens.
            validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9._-]*/ }
            value: page.modelData.account
            fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
            onEdited: function(v) { root.updateRow(page.index, "account", v) }
          }

          LabeledField {
            width: parent.width
            label: "Short label"
            placeholder: "e.g. VI"
            hint: "Shown next to this mailbox's mail and meetings."
            value: page.modelData.short
            fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
            onEdited: function(v) { root.updateRow(page.index, "short", v) }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              text: "Colour"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.sm

              Repeater {
                model: root.hues

                Rectangle {
                  required property var modelData
                  width: Style.space(18)
                  height: width
                  radius: width / 2
                  color: root.hueColor(modelData, 0)
                  border.width: page.modelData.color === modelData ? Style.space(2) : 0
                  border.color: root.fg

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.updateRow(page.index, "color", modelData)
                  }
                }
              }
            }
          }

          // ---- advanced ----
          Text {
            textFormat: Text.PlainText
            text: (root.advancedOpen[page.index] ? "▾  " : "▸  ") + "ADVANCED"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleAdvanced(page.index)
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.advancedOpen[page.index] === true

            LabeledField {
              width: parent.width
              label: "Outlook web address"
              placeholder: "https://outlook.office.com/mail/"
              hint: "Use outlook.live.com for a personal account."
              value: page.modelData.webUrl
              fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
              onEdited: function(v) { root.updateRow(page.index, "webUrl", v) }
            }

            LabeledField {
              width: parent.width
              label: "Focus window matching"
              placeholder: "window class or title regex"
              hint: "Clicking the panel header brings this window forward instead of opening the web app."
              value: page.modelData.focusMatch
              fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
              onEdited: function(v) { root.updateRow(page.index, "focusMatch", v) }
            }

            LabeledField {
              width: parent.width
              label: "App registration - client id"
              placeholder: "leave empty for the bundled one"
              value: page.modelData.clientId
              fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
              onEdited: function(v) { root.updateRow(page.index, "clientId", v) }
            }

            LabeledField {
              width: parent.width
              label: "App registration - authority"
              placeholder: "common"
              hint: "common, organizations, consumers, or a tenant id. Changing either means signing in again."
              value: page.modelData.authority
              fg: root.fg; dim: root.dim; accent: root.accent; fontFamily: root.fontFamily
              onEdited: function(v) { root.updateRow(page.index, "authority", v) }
            }
          }

          PanelSeparator {
            width: parent.width
            visible: removeButton.visible
          }

          // Nothing to remove on the blank mailbox a fresh widget opens on:
          // it would only lead back to an empty list.
          Button {
            id: removeButton
            visible: !!root.service && (root.service.configured || root.rows.length > 1)
            text: "Remove this mailbox"
            bordered: true
            foreground: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.removeRow(page.index)
          }
        }
      }
    }

    // ==================== actions ====================
    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: !!root.service && root.service.saveError !== ""
      wrapMode: Text.WordWrap
      text: root.service ? root.service.saveError : ""
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Save is on both levels, so nothing is lost by walking back to the list.
    Row {
      spacing: Style.spacing.lg

      Button {
        text: root.service && root.service.saving ? "Saving…" : "Save"
        bordered: true
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: root.save()
      }

      Button {
        text: root.editing !== root.pageList ? "Back" : "Cancel"
        bordered: true
        foreground: root.dim
        fontFamily: root.fontFamily
        onClicked: {
          if (root.editing !== root.pageList) {
            root.editing = root.pageList
            return
          }
          root.closeWhenSaved = false
          root.load()
          root.done()
        }
      }
    }
  }
}
