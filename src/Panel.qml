import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup for one widget: merged unread mail on the left, merged agenda on the
// right, with a coloured rail per row saying which mailbox an item came from.
// ipcTarget stays empty on purpose - the widget is multi-instance, and every
// instance registering the same IPC target would collide.
Panel {
  id: root
  moduleName: "caseonline.omarchy.office365"
  // Each widget can claim its own IPC name, which is what lets a keybinding
  // summon this particular one: set "ipcTarget": "mail" on the widget and
  // bind `omarchy-shell mail toggle`. Empty means no handler at all, so
  // several widgets cannot fight over one name.
  ipcTarget: String(setting("ipcTarget", "")).trim()
  manageIpc: ipcTarget !== ""

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property bool openedFromHotkey: false
  property bool configuring: false

  // The bar identifies panels by the widget mounted in its slot.
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color accent: root.bar ? root.bar.urgent : Color.urgent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)

  readonly property var views: service ? service.views : []
  readonly property bool combined: !!service && service.combined
  // Nothing configured at all: the settings form is then the whole panel, so
  // the first thing a new user sees is the mailbox they need to add rather
  // than a sentence telling them to go looking for it.
  readonly property bool needsSetup: !!service && !service.configured
  readonly property bool showSettings: configuring || needsSetup
  // Mail and agenda sit side by side once there is something to show; setup,
  // sign-in, settings and error states are single-column by nature.
  readonly property bool showColumns: !!service && service.anySignedIn && !service.loggingIn && !showSettings
  // Every mailbox is still waiting on its first answer. A mailbox that has
  // answered - even with an error - is no longer loading, which is what keeps
  // a failed fetch from leaving placeholder rows pulsing forever under an
  // error message.
  readonly property bool awaitingFirstData: {
    if (!service || !service.configured) return false
    for (var i = 0; i < views.length; i++)
      if (views[i].loaded && !views[i].busy) return false
    return true
  }

  // Signed in, nothing fetched yet. Its own state rather than a line of text:
  // the placeholder rows below hold the panel at full width, which is what
  // stops the filter pills wrapping and then unwrapping as data arrives.
  readonly property bool firstLoad: !!service && service.configured && !showSettings
                                    && !service.loggingIn && pendingAccounts.length === 0
                                    && !showColumns && awaitingFirstData
  readonly property int columnGap: Style.spacing.xxl
  readonly property bool previewing: !!service && service.previewMail !== null

  // ---- how wide the popup wants to be ----
  //
  // A drawn agenda needs room a list does not, and how much depends on how
  // many days it is showing. The mail column keeps its width and the popup
  // grows around the grid, so mail and calendar are always both there - a week
  // that hid the mail to fit would give that up exactly when there is most to
  // keep track of.
  readonly property bool timelineView: !!service && service.agendaView === "timeline" && !previewing
  readonly property real mailColumnWidth: Style.space(340)
  readonly property real agendaColumnWidth: {
    if (!timelineView) return Style.space(340)
    var days = service ? service.agendaDays : 3
    if (days <= 1) return Style.space(300)
    if (days <= 3) return Style.space(520)
    return Style.space(1080)
  }
  readonly property real wantedWidth: mailColumnWidth + agendaColumnWidth
                                      + columnGap * 2 + Style.space(1)

  // Keyboard cursor into the mail list. -1 until an arrow key is pressed, so
  // opening the panel with the mouse shows no cursor.
  property int cursorIndex: -1
  readonly property var mailRows: service ? service.mail : []

  function moveCursor(step) {
    var count = mailRows.length
    if (count === 0) { cursorIndex = -1; return }
    if (cursorIndex < 0) {
      // First keypress starts at whatever is open, else at the top.
      var start = 0
      if (service && service.previewMail) {
        var at = service.indexOfMail(service.previewMail.id)
        if (at >= 0) start = at
      }
      cursorIndex = start
      return
    }
    cursorIndex = Math.max(0, Math.min(count - 1, cursorIndex + step))
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= mailRows.length) return
    if (service) service.showPreview(mailRows[cursorIndex])
  }

  // Delete what the cursor is on, or what is being read when there is no
  // cursor yet.
  function deleteAtCursor() {
    if (!service) return
    if (cursorIndex >= 0 && cursorIndex < mailRows.length) service.deleteMail(mailRows[cursorIndex])
    else if (service.previewMail) service.deletePreviewed()
  }

  // Mailboxes still waiting for a first sign-in, which the panel offers to
  // start one at a time.
  readonly property var pendingAccounts: {
    var pending = []
    for (var i = 0; i < views.length; i++)
      if (!views[i].ok && !views[i].busy && views[i].errorCode === "auth_required") pending.push(views[i])
    return pending
  }

  // What a chip says about one mailbox, in the order the states actually
  // happen: still working, then signed in, then needing attention.
  function chipStatus(view) {
    if (view.busy) return "loading…"
    if (view.ok) return Model.unreadLabel(view)
    if (!view.loaded) return "…"
    if (view.errorCode === "auth_required") return "sign in"
    return "error"
  }

  function chipIsAlert(view) {
    return !view.busy && view.loaded && !view.ok
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    // Filters are a way of looking at the panel now, not a setting: reopening
    // starts from the whole picture again.
    cursorIndex = -1
    if (service) {
      service.clearFilters()
      service.refresh()
    }
  }

  function openFromHotkey() {
    openedFromHotkey = true
    cursorIndex = -1
    root.controller.show()
    // Filters are a way of looking at the panel now, not a setting: reopening
    // starts from the whole picture again.
    if (service) {
      service.clearFilters()
      service.refresh()
    }
    // Deferred: showing hands over to the popout coordinator, which closes the
    // previous panel and clears this shared flag on the way out.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function openItem(url, alias) {
    if (service) service.openUrl(url, alias)
    root.close()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Placeholder rows are laid out in the same two columns as real data, so
    // the panel is already at its final width when the data lands. Capped at
    // four fifths of the room available, so a week never fills the screen.
    contentWidth: panel.fittedContentWidth(
      root.showColumns || root.firstLoad ? root.wantedWidth : Style.space(380),
      panel.availableCardWidth > 0 ? panel.availableCardWidth * 0.8 : 0)

    // Changing range redraws at a different width; easing it stops the popup
    // snapping between sizes.
    Behavior on contentWidth { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // Wraps the key catcher so keys it does not claim - Delete in particular -
    // bubble up to a handler of our own.
    Item {
      anchors.fill: parent

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
          root.deleteAtCursor()
          event.accepted = true
        }
      }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteAtCursor()
      // Letters the catcher does not claim itself; f and u mirror the pills.
      onTextKey: function(text) {
        if (!root.service) return
        if (text === "f") root.service.focusedOnly = !root.service.focusedOnly
        else if (text === "u") root.service.unreadOnly = !root.service.unreadOnly
      }
      // Escape backs out one layer at a time: the meeting you picked, then the
      // message you opened, then the panel.
      onCloseRequested: {
        if (root.service && root.service.selectedEvent) root.service.selectEvent(null)
        else if (root.previewing) root.service.closePreview()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.xxl

        // ---------------- header ----------------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerText.implicitHeight, headerActions.implicitHeight)

          Column {
            id: headerText
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              text: root.service ? root.service.primaryTitle : "Office 365"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) root.service.focusApp("")
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              text: {
                if (!root.service) return ""
                if (root.combined || root.views.length !== 1) return ""
                var view = root.views[0]
                var parts = []
                if (view.username !== "" && view.username !== root.service.primaryTitle) parts.push(view.username)
                if (view.ok) parts.push(Model.unreadSummary(view))
                return parts.join(" · ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            // Fetching spins this rather than announcing itself in text: a
            // line that appears and disappears pushes the whole panel around
            // every few minutes.
            // Fetching tints this rather than announcing itself in text: a
            // line that appears and disappears pushes the whole panel around
            // every few minutes. It is a colour rather than a spin because an
            // icon glyph does not sit in the middle of its own line box, so
            // turning it wobbles - and the theme accent is not otherwise used
            // in this panel, where the urgent colour already means unread.
            // The button keeps its hover background and tooltip; only the
            // glyph turns, and it turns about its own painted centre so the
            // icon does not wobble.
            PanelActionButton {
              id: refreshButton
              readonly property bool spinning: !!root.service && root.service.loading
              iconText: ""
              tooltipText: spinning ? "Updating…" : "Refresh"
              foreground: root.fg
              visible: !!root.service && root.service.configured && !root.showSettings
              onClicked: if (root.service) root.service.refresh()

              SpinIcon {
                anchors.fill: parent
                text: "󰑐"
                fontFamily: root.fontFamily
                fontSize: Style.font.icon
                color: root.fg
                spinning: refreshButton.spinning
              }
            }

            // Hidden while there is nothing configured: the form is already
            // open and there is nothing behind it to go back to.
            PanelActionButton {
              visible: !root.needsSetup
              iconText: root.configuring ? "󰅖" : "󰒓"
              tooltipText: root.configuring ? "Close settings" : "Settings"
              foreground: root.fg
              onClicked: root.configuring = !root.configuring
            }
          }
        }

        // ---------------- filters ----------------
        // Doubles as the legend the row rails are read against and as the
        // controls for what is below, which is what lets the columns drop
        // their headings.
        //
        // Only once there is something to filter: pills over an empty panel
        // are controls for nothing, and while the panel is still narrow they
        // wrap onto a second line.
        Flow {
          width: parent.width
          spacing: Style.spacing.sm
          visible: root.showColumns

          Repeater {
            model: root.combined ? root.views : []

            FilterPill {
              required property var modelData
              label: modelData.short
              detail: root.chipStatus(modelData)
              dotColor: modelData.color
              alert: root.chipIsAlert(modelData)
              selected: !!root.service && root.service.filterAlias === modelData.alias
              faded: !!root.service && root.service.filterAlias !== "" && root.service.filterAlias !== modelData.alias
              fg: root.fg
              dim: root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.toggleFilter(modelData.alias)
            }
          }

          FilterPill {
            label: "Focused"
            detail: root.service && root.service.focusedOnly ? "on" : ""
            selected: !!root.service && root.service.focusedOnly
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.focusedOnly = !root.service.focusedOnly
          }

          FilterPill {
            label: "Unread"
            detail: root.service && root.service.unreadOnly ? "on" : ""
            selected: !!root.service && root.service.unreadOnly
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.unreadOnly = !root.service.unreadOnly
          }
        }

        PanelSeparator { width: parent.width }

        // ---------------- settings ----------------
        Loader {
          id: settingsLoader
          width: parent.width
          // Built on demand, so the form always opens with the settings the
          // widget currently has rather than a stale copy.
          active: root.showSettings
          visible: root.showSettings
          sourceComponent: Component {
            SettingsForm {
              service: root.service
              fg: root.fg
              dim: root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              onDone: root.configuring = false
            }
          }
        }

        // ---------------- setup / sign-in ----------------
        Column {
          width: parent.width
          spacing: Style.spacing.lg
          visible: !root.showSettings && !!root.service
                   && (root.service.loggingIn || root.pendingAccounts.length > 0)

          // One row per mailbox still needing a sign-in.
          Column {
            visible: !!root.service && !root.service.loggingIn && root.pendingAccounts.length > 0
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.service && root.service.anySignedIn
                ? "These mailboxes still need a sign-in."
                : "Sign in to show unread mail and your agenda. Works with Microsoft 365 and Outlook.com accounts."
            }

            Repeater {
              model: root.pendingAccounts

              Row {
                required property var modelData
                spacing: Style.spacing.lg

                Rectangle {
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: modelData.color
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.alias
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Button {
                  text: "Sign in"
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.startLogin(modelData.alias)
                }
              }
            }
          }

          // Device-code sign-in in progress.
          Column {
            visible: !!root.service && root.service.loggingIn
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.service && root.service.userCode !== ""
                ? "Signing in " + root.service.loginAlias + ". Enter this code on the Microsoft page:"
                : (root.service ? root.service.loginMessage : "")
            }

            Rectangle {
              visible: !!root.service && root.service.userCode !== ""
              width: parent.width
              implicitHeight: codeText.implicitHeight + Style.spacing.xxl
              radius: Style.space(6)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)

              Text {
                textFormat: Text.PlainText
                id: codeText
                anchors.centerIn: parent
                text: root.service ? root.service.userCode : ""
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
                font.letterSpacing: 3
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) Quickshell.clipboardText = root.service.userCode
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !!root.service && root.service.userCode !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: "The code is on your clipboard - paste it in the browser. If the page offers an account you did not mean, choose \"Use another account\"."
            }

            Row {
              spacing: Style.spacing.lg

              Button {
                text: "Open sign-in page"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                visible: !!root.service && root.service.verificationUri !== ""
                onClicked: if (root.service) root.service.openVerificationPage()
              }

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.cancelLogin()
              }
            }
          }
        }

        // ---------------- first load ----------------
        // Between a sign-in landing and its first fetch returning there is
        // nothing else to show: no data yet, and nothing left to sign in.
        // Placeholder rows in the real two-column layout, so the panel arrives
        // at the size and shape it is about to have. The spinning refresh icon
        // in the header already says what is happening.
        Row {
          id: skeletonColumns
          width: parent.width
          visible: root.firstLoad
          spacing: root.columnGap

          readonly property real usable: width - root.columnGap * 2 - Style.space(1)
          readonly property real columnWidth: usable * root.mailColumnWidth
                                              / (root.mailColumnWidth + root.agendaColumnWidth)
          readonly property real agendaWidth: usable - columnWidth

          SkeletonList {
            width: skeletonColumns.columnWidth
            fg: root.fg
            fontFamily: root.fontFamily
            groups: [5]
            lines: root.service && root.service.previewLine
              ? [{ w: 0.42, small: false }, { w: 0.86, small: false }, { w: 0.62, small: true }]
              : [{ w: 0.42, small: false }, { w: 0.86, small: false }]
          }

          Rectangle {
            width: Style.space(1)
            height: parent.height
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          }

          // Grouped by day, the way the agenda it stands in for is.
          SkeletonList {
            width: skeletonColumns.agendaWidth
            fg: root.fg
            fontFamily: root.fontFamily
            groups: [3, 2]
            headings: true
            lines: [{ w: 0.34, small: true }, { w: 0.82, small: false }]
          }
        }

        // ---------------- mail + agenda ----------------
        Row {
          id: columns
          width: parent.width
          visible: root.showColumns
          spacing: root.columnGap

          // Split in the ratio the panel asked to be wide in, so a narrower
          // screen shrinks both columns rather than cutting one off.
          readonly property real usable: width - root.columnGap * 2 - Style.space(1)
          readonly property real columnWidth: usable * root.mailColumnWidth
                                              / (root.mailColumnWidth + root.agendaColumnWidth)
          readonly property real agendaWidth: usable - columnWidth

          MailList {
            id: mailColumn
            width: columns.columnWidth
            mails: root.service ? root.service.mail : []
            unreadOnly: !!root.service && root.service.unreadOnly
            showPreviewLine: !root.service || root.service.previewLine
            showAccount: root.combined && (!root.service || root.service.filterAlias === "")
            selectedId: root.service && root.service.previewMail ? String(root.service.previewMail.id) : ""
            cursorIndex: root.cursorIndex
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            onActivated: function(mail) {
              if (!root.service) return
              root.cursorIndex = root.service.indexOfMail(mail.id)
              root.service.showPreview(mail)
            }
            onDeleteRequested: function(mail) { if (root.service) root.service.deleteMail(mail) }
          }

          Rectangle {
            width: Style.space(1)
            height: parent.height
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          }

          // The right column is the agenda until a message is opened, then it
          // becomes the reading pane for that message.
          AgendaTimeline {
            width: columns.agendaWidth
            visible: root.timelineView
            grid: root.service ? root.service.timeline
                               : ({ days: [], window: { startMinutes: 420, endMinutes: 1320 }, fits: {} })
            showAccount: root.combined && (!root.service || root.service.filterAlias === "")
            selectedEvent: root.service ? root.service.selectedEvent : null
            // The mail column decides how tall the popup is, so the grid
            // scales itself to that rather than leaving a gap beside it.
            availableHeight: mailColumn.implicitHeight
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            onEventClicked: function(event) { if (root.service) root.service.selectEvent(event) }
            onExpandRequested: if (root.service) root.service.expandWindow()
            onOpenRequested: function(url, alias) { root.openItem(url, alias) }
            onJoinRequested: function(url, alias) { root.openItem(url, alias) }
          }

          AgendaList {
            width: columns.agendaWidth
            visible: !root.previewing && !root.timelineView
            agenda: root.service ? root.service.agenda : ({ groups: [], hidden: 0 })
            showAccount: root.combined && (!root.service || root.service.filterAlias === "")
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            onOpenRequested: function(url, alias) { root.openItem(url, alias) }
            onJoinRequested: function(url, alias) { root.openItem(url, alias) }
          }

          MailPreview {
            width: columns.agendaWidth
            visible: root.previewing
            // Read from the merged list, so the override applied to this id
            // shows here too rather than only on the row.
            mail: {
              if (!root.service || !root.service.previewMail) return null
              var id = String(root.service.previewMail.id)
              var list = root.service.mail
              for (var i = 0; i < list.length; i++) if (String(list[i].id) === id) return list[i]
              return root.service.previewMail
            }
            detail: root.service ? root.service.previewDetail : null
            loading: !!root.service && root.service.previewLoading
            error: root.service ? root.service.previewError : ""
            fg: root.fg
            dim: root.dim
            accent: root.accent
            fontFamily: root.fontFamily
            canWrite: !!root.service && !!root.service.previewMail
                      && root.service.canWrite(root.service.previewMail.alias)
            actionRunning: !!root.service && root.service.actionRunning
            actionError: root.service ? root.service.actionError : ""
            onCloseRequested: if (root.service) root.service.closePreview()
            onOpenRequested: {
              if (root.service) root.service.openPreviewed()
              root.close()
            }
            onMarkRequested: function(read) { if (root.service) root.service.markPreviewed(read) }
            onDeleteRequested: if (root.service) root.service.deletePreviewed()
            onWriteAccessRequested: {
              if (root.service && root.service.previewMail)
                root.service.startLogin(String(root.service.previewMail.alias), true)
            }
          }
        }

        // ---------------- errors ----------------
        // Shown under whatever data survived, so one broken mailbox never
        // blanks the panel.
        ProblemList {
          width: parent.width
          visible: !root.showSettings
          views: root.views
          warnings: root.service ? root.service.warnings : []
          errorMessage: root.service && root.service.errorCode !== ""
            ? Model.oneLine(root.service.errorMessage, 200) : ""
          accent: root.accent
          fontFamily: root.fontFamily
        }
      }
    }
    }
  }
}
