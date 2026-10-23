import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One instance per bar widget. Owns every mailbox the widget carries: their
// merged data, the refresh timer, and one sign-in state machine that works on
// a single account at a time. Everything runs through graph.py, which is the
// only thing that ever holds a token.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""
  property color fallbackColor: "#7aa2f7"

  // ---- configuration --------------------------------------------------

  // v2 stores a list of mailboxes. A v1 entry has a single "account" string
  // with its per-mailbox keys at the top level; fold that into a one-element
  // list so existing setups keep working untouched.
  readonly property var accountConfigs: {
    var list = Model.arrayFrom(settings ? settings["accounts"] : undefined)
    if (list.length > 0) {
      var cleaned = []
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].account || "").trim() !== "") cleaned.push(list[i])
      }
      return cleaned
    }
    var legacy = String(setting("account", "")).trim()
    if (legacy === "") return []
    return [{
      account: legacy,
      short: setting("short", ""),
      color: setting("color", ""),
      webUrl: setting("webUrl", ""),
      openCommand: setting("openCommand", ""),
      focusMatch: setting("focusMatch", ""),
      clientId: setting("clientId", ""),
      authority: setting("authority", "")
    }]
  }

  readonly property int mails: intSetting("mails", 5, 1, 25)
  readonly property string calendarMode: String(setting("calendar", "3day"))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 180, 60, 3600)
  readonly property bool dedupeEvents: setting("dedupeEvents", true) !== false
  // Off unless asked for: turning it on is what makes the plugin want
  // permission to change mail, and the default stays read-only.
  readonly property bool markReadOnOpen: setting("markReadOnOpen", false) === true
  readonly property bool previewLine: setting("previewLine", true) !== false
  // Whether the panel opens already narrowed to Outlook's Focused mail.
  readonly property bool focusedByDefault: setting("focusedByDefault", false) === true
  // The same for the unread filter, for a widget you keep as an inbox rather
  // than as a record of everything that arrived.
  readonly property bool unreadByDefault: setting("unreadByDefault", false) === true
  // The agenda as a day-grouped list or as a drawn time grid. The list is the
  // default until the grid has earned it.
  readonly property string agendaView: String(setting("agendaView", "list")) === "timeline" ? "timeline" : "list"
  readonly property int dayStartMinutes: Model.minutesFromClock(setting("dayStart", "07:00"), 7 * 60)
  readonly property int dayEndMinutes: Model.minutesFromClock(setting("dayEnd", "22:00"), 22 * 60)
  readonly property bool showWeekends: setting("showWeekends", true) !== false
  readonly property bool configured: accountConfigs.length > 0
  readonly property bool combined: accountConfigs.length > 1

  // ---- state ----------------------------------------------------------

  // Last successful snapshot. Kept across failures so a flaky network shows
  // stale data rather than an empty panel.
  property var snapshot: null
  // The theme's named colours, for resolving a mailbox's "blue" or "magenta".
  // Not called `palette`: this is an Item, and QQuickItem has a palette of its
  // own that a property of that name would shadow.
  property var themePalette: ({})
  property bool loading: false
  property string errorCode: ""
  property string errorMessage: ""
  property bool saving: false
  property string saveError: ""
  signal settingsSaved()

  // Mailboxes whose sign-in just landed and whose first fetch is still in
  // flight. They are signed in but have no data yet, which is neither of the
  // states the panel would otherwise show.
  property var busy: ({})

  // Sign-in runs for one mailbox at a time.
  property string loginAlias: ""
  property bool loggingIn: false
  property string userCode: ""
  property string verificationUri: ""
  property string loginMessage: ""

  // ---- derived --------------------------------------------------------

  readonly property var views: Model.accountViews(accountConfigs, snapshot, themePalette, fallbackColor, busy, loading)

  // Partial failures inside mailboxes that did answer. Taken from every
  // mailbox rather than the filtered ones: a calendar nobody can read is still
  // unreadable while you are looking at another account.
  readonly property var warnings: Model.collectWarnings(views)

  // View filters. Deliberately not persisted: they are a way to look at the
  // panel right now, and both reset when it is reopened.
  property string filterAlias: ""
  property bool unreadOnly: false
  property bool focusedOnly: false

  // Settings arrive after this object is built, so pick the defaults up when
  // they resolve rather than only at construction.
  onFocusedByDefaultChanged: focusedOnly = focusedByDefault
  onUnreadByDefaultChanged: unreadOnly = unreadByDefault

  function toggleFilter(alias) {
    filterAlias = filterAlias === alias ? "" : alias
  }

  function clearFilters() {
    filterAlias = ""
    unreadOnly = unreadByDefault
    focusedOnly = focusedByDefault
    selectedEvent = null
    expandedStart = -1
    expandedEnd = -1
    closePreview()
    mailState = ({ read: ({}), deleted: ({}), held: ({}) })
  }

  // ---- reading pane ---------------------------------------------------

  // The message being read, its fetched body, and the state of getting it.
  // Bodies are far too big to carry in the list fetch, so one is pulled only
  // when a message is opened.
  property var previewMail: null
  property var previewDetail: null
  property bool previewLoading: false
  property string previewError: ""

  function showPreview(mail) {
    if (!mail || !mail.id) return
    // Clicking the message already open closes it, the same way the filter
    // pills toggle.
    if (previewMail && previewMail.id === mail.id) {
      closePreview()
      return
    }
    previewMail = mail
    holdOnly(mail.id)
    previewDetail = null
    previewError = ""
    previewLoading = true
    if (messageProc.running) messageProc.running = false
    var command = ["python3", helper(), "message", "--account", String(mail.alias), "--id", String(mail.id)]
    // Demo mode has to reach the reading pane too, or opening a synthetic row
    // asks Graph about an id it has never seen.
    if (setting("demo", false) === true) command.push("--demo")
    messageProc.command = command
    messageProc.running = true
  }

  function closePreview() {
    holdOnly("")
    previewMail = null
    previewDetail = null
    previewError = ""
    previewLoading = false
  }

  property string actionError: ""
  // Marks are queued rather than dropped while one is in flight: opening the
  // next message before the previous mark returned must still mark both.
  property var markQueue: []
  readonly property bool actionRunning: markProc.running || deleteProc.running || markQueue.length > 0

  function markMessage(id, alias, read) {
    if (!id || !canWrite(alias)) return
    actionError = ""
    // Show it at once; the queue catches up and a failure puts it back.
    withState("read", id, read === true)
    var queued = markQueue.slice()
    queued.push({ id: String(id), alias: String(alias), read: read === true })
    markQueue = queued
    pumpMarks()
  }

  function pumpMarks() {
    if (markProc.running || markQueue.length === 0) return
    var next = markQueue[0]
    markProc.command = ["python3", helper(), "mark",
                        "--account", next.alias,
                        "--id", next.id,
                        next.read ? "--read" : "--unread"]
    markProc.running = true
  }

  function markPreviewed(read) {
    if (!previewMail) return
    markMessage(previewMail.id, previewMail.alias, read)
  }

  function indexOfMail(id) {
    for (var i = 0; i < mail.length; i++) if (String(mail[i].id) === String(id)) return i
    return -1
  }

  // Deleting works on any row, not only the one being read: the list offers
  // it directly, and so does the keyboard.
  function deleteMail(row) {
    if (!row || deleteProc.running || !canWrite(row.alias)) return
    actionError = ""
    // Remembered now, while the row is still in the list, so the message that
    // takes its place can be opened once it is gone.
    deleteProc.targetIndex = indexOfMail(row.id)
    deleteProc.wasReading = !!previewMail && String(previewMail.id) === String(row.id)
    deleteProc.command = ["python3", helper(), "delete",
                          "--account", String(row.alias),
                          "--id", String(row.id)]
    deleteProc.running = true
  }

  function deletePreviewed() {
    deleteMail(previewMail)
  }

  function openPreviewed() {
    if (!previewMail) return
    var link = previewDetail && previewDetail.webLink ? previewDetail.webLink : previewMail.webLink
    openUrl(link, previewMail.alias)
  }

  readonly property var filteredViews: {
    if (filterAlias === "") return views
    var kept = []
    for (var i = 0; i < views.length; i++) if (views[i].alias === filterAlias) kept.push(views[i])
    return kept
  }

  // What the user has done that the server has not confirmed yet, keyed by
  // message id. Keyed by id rather than by whatever is open, so a slow reply
  // about one message can never land on another.
  property var mailState: ({ read: ({}), deleted: ({}), held: ({}) })

  // The state the list is actually built from: the pending changes above, plus
  // the row being read so it keeps its place in the list.
  readonly property var listState: ({
    read: mailState.read,
    deleted: mailState.deleted,
    held: mailState.held,
    pinned: previewMail
  })

  function withState(field, id, value) {
    var next = { read: ({}), deleted: ({}), held: ({}) }
    for (var group in mailState) for (var key in mailState[group]) next[group][key] = mailState[group][key]
    if (value === undefined) delete next[field][String(id)]
    else next[field][String(id)] = value
    mailState = next
  }

  // Exactly one message is held in the unread view at a time: the one open.
  function holdOnly(id) {
    var next = { read: ({}), deleted: ({}), held: ({}) }
    for (var group in mailState) if (group !== "held") for (var key in mailState[group]) next[group][key] = mailState[group][key]
    if (id) next.held[String(id)] = true
    mailState = next
  }

  readonly property var mail: Model.mergeMail(filteredViews, unreadOnly, mails, listState, focusedOnly)
  readonly property var agenda: Model.mergeEvents(filteredViews, new Date(), 20, dedupeEvents)

  // ---- timeline -------------------------------------------------------

  // Opening the window up to fit a stray early meeting lasts as long as the
  // panel is open, no longer: it is a way of looking at today, not a setting.
  property int expandedStart: -1
  property int expandedEnd: -1
  readonly property int windowStart: expandedStart >= 0 ? expandedStart : dayStartMinutes
  readonly property int windowEnd: expandedEnd >= 0 ? expandedEnd : dayEndMinutes

  readonly property int agendaDays: Model.calendarDays(calendarMode)

  readonly property var timeline: Model.dayGrid(filteredViews, new Date(), {
    days: agendaDays,
    startMinutes: windowStart,
    endMinutes: windowEnd,
    showWeekends: showWeekends,
    dedupe: dedupeEvents
  })

  // The meeting whose details are showing. Clicking the one already selected
  // clears it, the same way the filter pills and the reading pane toggle.
  property var selectedEvent: null

  function selectEvent(event) {
    if (!event) { selectedEvent = null; return }
    selectedEvent = selectedEvent && String(selectedEvent.id) === String(event.id) ? null : event
  }

  function expandWindow() {
    expandedStart = timeline.fits.startMinutes
    expandedEnd = timeline.fits.endMinutes
  }

  readonly property int unreadCount: {
    var total = 0
    for (var i = 0; i < views.length; i++) total += views[i].unreadCount
    return total
  }
  // Of that, how much is actually in the list - mail that has just arrived, as
  // against a backlog sitting further down the mailbox. The bar tints on this
  // rather than on unreadCount: one old unread message nobody intends to open
  // would otherwise keep the icon lit for good, and an icon that never goes
  // out cannot tell you that something came in.
  //
  // Every mailbox rather than filteredViews, and mailState rather than
  // listState, for the same reason: the alias filter and the reading pane are
  // ways of looking at the panel, and neither should change what the bar says
  // is waiting.
  readonly property var freshUnread: Model.freshUnread(views, mails, mailState)
  readonly property int newUnreadCount: freshUnread.total
  readonly property int shownMailCount: mail.length
  readonly property bool anySignedIn: {
    for (var i = 0; i < views.length; i++) if (views[i].ok) return true
    return false
  }
  readonly property bool anyNeedsSignIn: {
    for (var i = 0; i < views.length; i++) if (views[i].loaded && views[i].errorCode === "auth_required") return true
    return false
  }
  readonly property string primaryTitle: {
    if (!configured) return "Office 365"
    if (combined) return String(setting("label", "")).trim() || "Mail"
    var view = views.length > 0 ? views[0] : null
    if (!view) return "Office 365"
    if (view.displayName !== "") return view.displayName
    if (view.username !== "") return view.username
    return view.alias
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var parsed = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(min, Math.min(max, parsed))
  }

  function helper() {
    return pluginDir + "/graph.py"
  }

  function viewFor(alias) {
    for (var i = 0; i < views.length; i++) if (views[i].alias === alias) return views[i]
    return null
  }

  // Whether this mailbox may change mail. Read-only mailboxes hide the
  // actions rather than offering buttons that would fail.
  function canWrite(alias) {
    var view = viewFor(String(alias || ""))
    return !!view && view.write === true
  }

  function markBusy(alias) {
    var next = {}
    for (var key in busy) next[key] = busy[key]
    next[alias] = true
    busy = next
  }

  // ---- fetching -------------------------------------------------------

  function refresh() {
    if (!configured || fetchProc.running || pluginDir === "") return
    loading = true
    var command = ["python3", helper(), "fetch",
                   "--mails", String(mails),
                   "--days", String(Model.calendarDays(calendarMode))]
    for (var i = 0; i < accountConfigs.length; i++)
      command = command.concat(["--account", String(accountConfigs[i].account).trim()])
    // "demo": true in shell.json fills the widget with synthetic data, for
    // working on the layout without every mailbox being signed in.
    if (setting("demo", false) === true) command.push("--demo")
    fetchProc.command = command
    fetchProc.running = true
    loadPalette()
  }

  // A refresh asked for that could not be started yet.
  //
  // Saving settings is the case this exists for. The write finishing means
  // shell.json is on disk, not that the shell has noticed and handed the new
  // values to this object - so refreshing there fetches the accounts and range
  // being replaced. It can also be dropped outright, since refresh() gives way
  // to a fetch already in flight. Both are waited out here.
  property bool refreshQueued: false

  function queueRefresh() {
    refreshQueued = true
    // In case the settings never arrive: saving values identical to the
    // current ones gives the watcher nothing to report, and the panel would
    // sit stale until the next poll. Deliberately not run here: waiting for
    // the settings is the whole point.
    refreshDeadline.restart()
  }

  function runQueuedRefresh() {
    if (!refreshQueued || !configured || fetchProc.running || pluginDir === "") return
    refreshQueued = false
    refreshDeadline.stop()
    refresh()
  }

  // The settings this object was waiting for. Anything else that changes them
  // gets the same treatment, which is what it should have had anyway.
  onSettingsChanged: runQueuedRefresh()

  Timer {
    id: refreshDeadline
    interval: 2000
    // If a fetch is still running this does nothing, and fetchProc picks the
    // queued refresh up when it exits.
    onTriggered: root.runQueuedRefresh()
  }

  // Theme colours, which the settings form needs before anything is
  // configured - the colour swatches on the very first mailbox would
  // otherwise all be grey.
  function loadPalette() {
    if (paletteProc.running || pluginDir === "") return
    paletteProc.command = ["python3", helper(), "palette"]
    paletteProc.running = true
  }

  function applyFetch(raw) {
    var parsed = Model.parseJson(raw, null)
    if (!parsed) {
      errorCode = "bad_output"
      errorMessage = "Could not read the helper's response"
      return
    }
    if (parsed.ok === false) {
      var error = parsed.error || {}
      errorCode = String(error.code || "error")
      errorMessage = String(error.message || "Something went wrong")
      return
    }
    // Per-account failures live inside the snapshot; the instance itself is
    // only in error when the whole fetch failed.
    snapshot = parsed
    // Every fetch covers every mailbox, so whatever was waiting on one now has
    // its real state.
    busy = ({})
    mailState = Model.pruneOverrides(views, mailState)
    errorCode = ""
    errorMessage = ""
  }

  // ---- sign-in --------------------------------------------------------

  function startLogin(alias, wantWrite) {
    if (!configured || loginStartProc.running) return
    var config = configFor(alias)
    if (!config) return
    loginAlias = alias
    loggingIn = true
    userCode = ""
    verificationUri = ""
    loginMessage = "Starting sign-in…"
    var command = ["python3", helper(), "login-start", "--account", alias]
    if (wantWrite === true) command.push("--write")
    var clientId = String(config.clientId || "").trim()
    var authority = String(config.authority || "").trim()
    if (clientId !== "") command = command.concat(["--client-id", clientId])
    if (authority !== "") command = command.concat(["--authority", authority])
    loginStartProc.command = command
    loginStartProc.running = true
  }

  function configFor(alias) {
    for (var i = 0; i < accountConfigs.length; i++)
      if (String(accountConfigs[i].account).trim() === alias) return accountConfigs[i]
    return null
  }

  function cancelLogin() {
    if (loginNotifyId > 0) {
      notify("Sign-in cancelled", "No changes were made", false)
      loginNotifyId = 0
    }
    loggingIn = false
    loginAlias = ""
    userCode = ""
    verificationUri = ""
    loginMessage = ""
    loginPollTimer.running = false
  }

  // Opening the sign-in page with the mailbox's own browser profile is what
  // stops the browser handing back whichever account it was already signed
  // into - the page arrives already knowing who this should be.
  function openVerificationPage() {
    if (verificationUri === "") return
    var config = configFor(loginAlias)
    var command = config ? config.openCommand : ""
    Quickshell.execDetached(Model.openArgv(command, verificationUri))
  }

  function signOut(alias) {
    if (removeProc.running) return
    removeProc.command = ["python3", helper(), "remove", "--account", alias]
    removeProc.running = true
  }

  // ---- actions --------------------------------------------------------

  function openUrl(url, alias) {
    if (!url) return
    var config = alias ? configFor(alias) : (accountConfigs.length > 0 ? accountConfigs[0] : null)
    Quickshell.execDetached(Model.openArgv(config ? config.openCommand : "", String(url)))
  }

  // Opening the browser takes focus, which dismisses the popup and takes the
  // device code with it. A notification outlives the panel; make it critical
  // so it stays put until dismissed, since the code expires in 15 minutes and
  // there is no way back to it once the panel is gone.
  function notify(summary, body, critical) {
    var command = ["notify-send", "-a", "Office 365"]
    if (critical === true) command = command.concat(["-u", "critical"])
    // Replace the code notification rather than stacking on it, so finishing
    // a sign-in clears the code that is no longer needed.
    if (loginNotifyId > 0) command = command.concat(["-r", String(loginNotifyId)])
    Quickshell.execDetached(command.concat([String(summary), String(body)]))
  }

  // Id of the standing device-code notification, so it can be replaced.
  property int loginNotifyId: 0

  function notifyCode(summary, body) {
    notifyProc.command = ["notify-send", "-a", "Office 365", "-u", "critical", "-p",
                          String(summary), String(body)]
    notifyProc.running = true
  }

  // Bring a mailbox's own Outlook window forward when it has a match
  // configured; otherwise just open it on the web.
  function focusApp(alias) {
    var config = alias ? configFor(alias) : (accountConfigs.length > 0 ? accountConfigs[0] : null)
    if (!config) return
    var webUrl = String(config.webUrl || "https://outlook.office.com/mail/")
    var match = String(config.focusMatch || "").trim()
    if (match === "") {
      openUrl(webUrl, config.account)
      return
    }
    // One string, because that is what omarchy-launch-or-focus takes - and it
    // evaluates it as shell text, so the argument boundaries have to be put
    // back in as quotes rather than lost to a plain join.
    var launch = Model.shellCommand(Model.openArgv(config.openCommand, webUrl))
    Quickshell.execDetached(["omarchy-launch-or-focus", match, launch])
  }

  // Starts a save, and says whether it started: writing shell.json is another
  // process, so a caller that wants to know the outcome has to wait for
  // settingsSaved or saveError rather than for this to return.
  function saveSettings(patch) {
    if (saveProc.running || pluginDir === "") return false
    saving = true
    saveError = ""
    // The instance id is what tells two widgets holding the same mailbox
    // apart. It is empty until the first save, which is when config.py stamps
    // one into this entry.
    saveProc.command = ["python3", pluginDir + "/config.py",
                        "--plugin-id", "caseonline.omarchy.office365",
                        "--instance", String(setting("instance", "")),
                        "--match", JSON.stringify(settings || {}),
                        "--set", JSON.stringify(patch || {})]
    saveProc.running = true
    return true
  }

  onConfiguredChanged: if (configured) refresh()
  onPluginDirChanged: {
    loadPalette()
    if (configured) refresh()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.configured
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Retry sooner than the normal cadence after a transient failure, so a
    // laptop coming back from suspend refills the panel quickly.
    id: retryTimer
    interval: 20000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: loginPollTimer
    interval: 5000
    repeat: true
    running: false
    onTriggered: {
      if (loginPollProc.running || root.loginAlias === "") return
      loginPollProc.command = ["python3", root.helper(), "login-poll", "--account", root.loginAlias]
      loginPollProc.running = true
    }
  }

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode === 0) root.applyFetch(fetchOut.text)
      else {
        root.errorCode = "helper_failed"
        root.errorMessage = Model.oneLine(fetchErr.text || "The helper could not be run", 160)
      }
      if (root.errorCode !== "") retryTimer.restart()
      // A refresh that had to give way to this one.
      root.runQueuedRefresh()
    }
  }

  Process {
    id: messageProc
    running: false
    stdout: StdioCollector { id: messageOut; waitForEnd: true }
    stderr: StdioCollector { id: messageErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.previewLoading = false
      var parsed = Model.parseJson(messageOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.previewError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(messageErr.text || "Could not open this message", 160)
        return
      }
      root.previewDetail = parsed
      root.previewError = ""
      // Only after the message really opened, and only where it was asked for
      // and permitted.
      if (root.markReadOnOpen && root.previewMail && root.previewMail.read !== true
          && root.canWrite(root.previewMail.alias))
        root.markMessage(root.previewMail.id, root.previewMail.alias, true)
    }
  }

  Process {
    id: notifyProc
    running: false
    stdout: StdioCollector { id: notifyOut; waitForEnd: true }
    onExited: {
      var id = parseInt(String(notifyOut.text || "").trim(), 10)
      root.loginNotifyId = isFinite(id) && id > 0 ? id : 0
    }
  }

  Process {
    id: markProc
    running: false
    stdout: StdioCollector { id: markOut; waitForEnd: true }
    onExited: function(exitCode) {
      var done = root.markQueue.length > 0 ? root.markQueue[0] : null
      root.markQueue = root.markQueue.slice(1)
      var parsed = Model.parseJson(markOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error ? String(parsed.error.message) : "Could not change this message"
        // Put the row back the way it was, for that message specifically.
        if (done) root.withState("read", done.id, !done.read)
      }
      root.pumpMarks()
      if (root.markQueue.length === 0) root.refresh()
    }
  }

  Process {
    id: deleteProc
    running: false
    stdout: StdioCollector { id: deleteOut; waitForEnd: true }
    property int targetIndex: -1
    property bool wasReading: false
    onExited: function(exitCode) {
      var parsed = Model.parseJson(deleteOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.actionError = parsed && parsed.error ? String(parsed.error.message) : "Could not delete this message"
        return
      }
      // Hide it now; the next fetch simply stops returning it. Reading `mail`
      // after this sees the list without it.
      if (parsed.id) root.withState("deleted", parsed.id, true)

      // Carry on down the list rather than dropping back to the agenda -
      // but only when the message deleted was the one being read. Deleting
      // some other row from the list must not move the pane.
      if (deleteProc.wasReading) {
        var next = Model.nextAfterRemoval(root.mail, deleteProc.targetIndex)
        if (next) root.showPreview(next)
        else root.closePreview()
      }
      deleteProc.targetIndex = -1
      deleteProc.wasReading = false
      root.refresh()
    }
  }

  Process {
    id: paletteProc
    running: false
    stdout: StdioCollector { id: paletteOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(paletteOut.text, null)
      if (exitCode === 0 && parsed && parsed.colors) root.themePalette = parsed.colors
    }
  }

  Process {
    id: loginStartProc
    running: false
    stdout: StdioCollector { id: loginStartOut; waitForEnd: true }
    stderr: StdioCollector { id: loginStartErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(loginStartOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.loggingIn = false
        root.loginAlias = ""
        root.loginMessage = ""
        root.errorCode = "login_failed"
        root.errorMessage = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(loginStartErr.text || "Could not start sign-in", 160)
        return
      }
      root.userCode = String(parsed.userCode || "")
      root.verificationUri = String(parsed.verificationUri || "https://microsoft.com/devicelogin")
      root.loginMessage = "Waiting for you to finish signing in…"
      loginPollTimer.interval = Math.max(3, Number(parsed.interval || 5)) * 1000
      loginPollTimer.running = true
      // Clipboard first, so the code is already there to paste by the time the
      // browser has focus.
      Quickshell.clipboardText = root.userCode
      root.notifyCode("Sign in to " + root.loginAlias,
                      "Code " + root.userCode + " - copied, paste it in the browser")
      root.openVerificationPage()
    }
  }

  Process {
    id: loginPollProc
    running: false
    stdout: StdioCollector { id: loginPollOut; waitForEnd: true }
    onExited: function() {
      var parsed = Model.parseJson(loginPollOut.text, null)
      if (!parsed) return
      if (parsed.ok === false) {
        loginPollTimer.running = false
        root.loggingIn = false
        root.loginAlias = ""
        root.loginMessage = ""
        root.errorCode = String((parsed.error || {}).code || "login_failed")
        root.errorMessage = String((parsed.error || {}).message || "Sign-in failed")
        return
      }
      if (parsed.status === "pending") {
        // The endpoint asks us to back off when we poll too eagerly.
        if (parsed.slowDown === true) loginPollTimer.interval += 5000
        return
      }
      loginPollTimer.running = false
      // The panel is usually closed by now, so say which account actually
      // arrived - that is the moment a wrong account is worth catching.
      var who = String(parsed.username || "")
      root.notify("Signed in" + (root.loginAlias !== "" ? " · " + root.loginAlias : ""),
                  who !== "" ? who : "Mailbox is signed in", false)
      root.loginNotifyId = 0
      // Hold this mailbox in a "signed in, loading" state until its first
      // fetch returns, rather than letting it fall back to "sign in".
      if (root.loginAlias !== "") root.markBusy(root.loginAlias)
      root.loggingIn = false
      root.loginAlias = ""
      root.userCode = ""
      root.loginMessage = ""
      root.errorCode = ""
      root.errorMessage = ""
      root.refresh()
    }
  }

  Process {
    id: saveProc
    running: false
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.saving = false
      var parsed = Model.parseJson(saveOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.saveError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(saveErr.text || "Could not save settings", 160)
        return
      }
      root.saveError = ""
      root.settingsSaved()
      // Not refresh(): shell.json is written, but the new settings have not
      // reached this object yet.
      root.queueRefresh()
    }
  }

  Process {
    id: removeProc
    running: false
    onExited: root.refresh()
  }
}
