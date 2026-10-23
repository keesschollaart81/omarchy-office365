.pragma library

// Pure helpers for the Office 365 widget. Kept free of QML types so they can
// be reasoned about (and unit tested) on their own.

var CALENDAR_RANGES = {
  "1day": { days: 1, label: "Today" },
  "3day": { days: 3, label: "Next 3 days" },
  "week": { days: 7, label: "This week" }
}

function calendarDays(mode) {
  var range = CALENDAR_RANGES[String(mode || "3day")]
  return range ? range.days : 3
}

function calendarLabel(mode) {
  var range = CALENDAR_RANGES[String(mode || "3day")]
  return range ? range.label : "Agenda"
}

// Graph returns local wall-clock times without a zone suffix (we ask for the
// system zone via the Prefer header) and up to seven fractional digits, which
// Date cannot parse. Trim to milliseconds and let the empty zone mean local.
function parseDate(value) {
  if (!value) return null
  var text = String(value).replace(/(\.\d{3})\d+/, "$1")
  var date = new Date(text)
  return isNaN(date.getTime()) ? null : date
}

function pad(value) {
  return (value < 10 ? "0" : "") + value
}

function timeOfDay(date) {
  if (!date) return ""
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// Compact age for a mail: "3m", "2h", "Tue", "14 Aug".
function relativeTime(value, now) {
  var date = parseDate(value)
  if (!date) return ""
  var reference = now || new Date()
  var seconds = Math.floor((reference.getTime() - date.getTime()) / 1000)
  if (seconds < 60) return "now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h"
  if (seconds < 7 * 86400) return date.toLocaleDateString(Qt.locale(), "ddd")
  return date.toLocaleDateString(Qt.locale(), "d MMM")
}

function sameDay(a, b) {
  return a && b && a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

function dayLabel(date, now) {
  if (!date) return ""
  var today = now || new Date()
  var tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1)
  if (sameDay(date, today)) return "Today"
  if (sameDay(date, tomorrow)) return "Tomorrow"
  return date.toLocaleDateString(Qt.locale(), "ddd d MMM")
}

// Hues an account falls back to, by position. Red is deliberately absent: the
// theme's urgent colour already means "unread" on the bar and "happening now"
// in the agenda, and a colour should mean one thing per surface.
var ACCOUNT_HUES = ["blue", "green", "magenta", "yellow", "cyan", "orange"]

// An account colour is a theme hue name, so switching theme re-tunes every
// account instead of leaving hardcoded hex fighting the new background. A raw
// #rrggbb still works for anyone who wants an exact colour.
function resolveColor(spec, palette, index, fallback) {
  var colors = palette || {}
  var value = String(spec || "").trim()
  if (value.charAt(0) === "#") return value
  var name = value !== "" ? value : ACCOUNT_HUES[index % ACCOUNT_HUES.length]
  return colors[name] || colors[ACCOUNT_HUES[index % ACCOUNT_HUES.length]] || fallback
}

// Pair each configured account with whatever the last fetch returned for it,
// so the panel can render colour, name, counts and per-account errors from one
// list - including accounts that failed, which must stay visible.
function accountViews(configs, snapshot, palette, fallback, busyMap, loading) {
  var fetched = {}
  var accounts = (snapshot && snapshot.accounts) || []
  for (var i = 0; i < accounts.length; i++) fetched[accounts[i].alias] = accounts[i]
  var busy = busyMap || {}

  var views = []
  for (var c = 0; c < (configs || []).length; c++) {
    var config = configs[c]
    var alias = String(config.account || "").trim()
    if (alias === "") continue
    var data = fetched[alias] || null
    var short = String(config.short || "").trim() || alias.substring(0, 3).toUpperCase()
    views.push({
      alias: alias,
      short: short,
      color: resolveColor(config.color, palette, c, fallback),
      config: config,
      ok: !!data && data.ok === true,
      loaded: !!data,
      // A mailbox is busy from the moment its sign-in completes until the
      // fetch that follows lands, and on a first load before any data exists.
      // Without this it would keep reading "sign in" while already signed in.
      busy: busy[alias] === true || (!data && loading === true),
      username: data && data.username ? data.username : "",
      displayName: data && data.displayName ? data.displayName : "",
      errorCode: data && data.error ? String(data.error.code || "") : "",
      errorMessage: data && data.error ? String(data.error.message || "") : "",
      // Whether this mailbox was signed in with permission to change mail.
      write: !!data && data.write === true,
      mail: data && data.mail ? data.mail : [],
      unreadCount: data && data.unreadCount ? Number(data.unreadCount) : 0,
      // False when the inbox would not say, and unreadCount is only a floor
      // taken from the rows that did arrive.
      unreadKnown: !data || data.unreadKnown !== false,
      events: data && data.events ? data.events : [],
      warnings: (data && data.warnings) || []
    })
  }
  return views
}

// Text handed to something the shell draws for us - a bar tooltip, a widget
// label - where a Text item in the shell's own code renders it and we cannot
// pin that item to Text.PlainText from here.
//
// Qt's AutoText decides a string is rich text the moment it finds a `<` that
// could open a tag, and rich text fetches what it is told to fetch. A display
// name or subject line arrives from a mailbox, so a crafted one could pull a
// remote resource into the shared shell process - the shape of a tracking
// pixel, and it would run whether or not the panel was ever opened. Taking the
// `<` away takes the decision away. Everything this is used on is a name, a
// subject or an error message, where a stray `<` is no loss.
//
// Text this plugin renders itself does not need this: those items set
// textFormat: Text.PlainText directly, which is the stronger fix.
function plainText(value) {
  if (value === undefined || value === null) return ""
  return String(value).replace(/</g, "")
}

// How many are unread, said only as precisely as it is known.
//
// The inbox is asked for the number directly; when that request fails, all
// that is left is however many unread rows the message queries returned, which
// is a floor and not a count. "3" and "3+" are different claims, and "no
// unread mail" is a claim that must never rest on a request that failed.
function unreadLabel(view) {
  if (!view) return "?"
  if (view.unreadKnown !== false) return String(view.unreadCount)
  return view.unreadCount > 0 ? String(view.unreadCount) + "+" : "?"
}

// Which unread messages are new, as against a backlog that has been sitting
// there.
//
// "New" is what the list shows: an unread message among the newest `limit`
// rows the mailboxes returned. One from three weeks ago has newer mail stacked
// on top of it, falls out of that window, and is backlog - which is the
// distinction the bar needs. "Something just landed" and "something is still
// sitting there" are different things to be told, and an indicator that lights
// up the same way for both eventually stops meaning either.
//
// Built from the unfiltered merge on purpose. Turning the panel's unread
// filter on pulls the whole backlog into view, and letting that redefine "new"
// would light the bar up because of a filter the user set by hand. The reading
// pane's pinned row is left out for the same reason: which message is open is
// not news about what arrived.
//
// Returns {total, byAlias} - the bar tints on the one number, and a tooltip
// naming three mailboxes needs them apart.
function freshUnread(views, limit, state) {
  var rows = mergeMail(views, false, limit, {
    read: (state && state.read) || {},
    deleted: (state && state.deleted) || {}
  }, false)

  var byAlias = {}
  var total = 0
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].read === true) continue
    var alias = String(rows[i].alias || "")
    byAlias[alias] = (byAlias[alias] || 0) + 1
    total++
  }
  return { total: total, byAlias: byAlias }
}

// How many of one mailbox's unread messages are new, never more than it says
// are unread at all. Both numbers come out of the same fetch, so a new row the
// folder count has not caught up with should not arise - but "3 new · 1
// unread" is nonsense to print, and the clamp costs nothing. Not applied when
// the count is only a floor, where the floor is the number in doubt.
function freshFor(view, fresh) {
  if (!view || !fresh) return 0
  var byAlias = fresh.byAlias || {}
  var count = Number(byAlias[String(view.alias)] || 0)
  if (view.unreadKnown === false) return count
  return Math.min(count, Number(view.unreadCount) || 0)
}

// The same, as a phrase for a tooltip: what has just arrived first, and the
// backlog behind it second. `fresh` is optional - left out, this says only how
// many are unread, which is all a caller without a list can honestly claim.
function unreadSummary(view, fresh) {
  if (!view) return ""
  var count = Number(view.unreadCount) || 0
  var arrived = freshFor(view, fresh)

  if (view.unreadKnown === false) {
    if (count <= 0) return "unread count unavailable"
    if (arrived > 0) return arrived + " new · " + count + "+ unread"
    return count + "+ unread"
  }
  if (count <= 0) return "no unread mail"
  // Nothing behind them: a second number here would add a figure and no fact.
  if (arrived >= count) return count + " new"
  if (arrived > 0) return arrived + " new · " + count + " unread"
  return count + " unread"
}

// Everything that went wrong inside a mailbox that otherwise answered: a
// calendar Graph refused, a mail query it rejected, a page that stopped
// half-way. The account is still `ok`, so nothing else in the panel says these
// are missing - and "no mail" or "nothing scheduled" is not what a permissions
// problem should look like.
function collectWarnings(views) {
  var out = []
  for (var v = 0; v < (views || []).length; v++) {
    var view = views[v]
    if (!view.ok) continue
    var warnings = view.warnings || []
    for (var w = 0; w < warnings.length; w++) {
      var message = oneLine(warnings[w].message, 160)
      if (message === "") continue
      out.push({
        alias: view.alias,
        short: view.short,
        color: view.color,
        scope: String(warnings[w].scope || ""),
        message: message
      })
    }
  }
  return out
}

// One mail list across mailboxes, newest first, cut to `limit` rows.
//
// Each mailbox is fetched to `limit` in its own right, so the merged list can
// always be filled: whichever mailboxes the newest messages come from, and
// whether or not the unread filter is on, there is enough to show `limit`
// rows without one noisy account being able to starve the others of a place
// in the list.
//
// `state` carries what the user has done that the server has not confirmed
// yet, all keyed by message id rather than by whatever happens to be open:
//   read    id -> true/false, an optimistic read flag
//   deleted id -> true, hidden until a fetch stops returning it
//   held    id -> true, kept in the unread view although it is read
//   pinned  the row being read, kept in the list even if a fetch no longer
//           returns it - marking an older message read drops it out of both
//           the newest and the newest-unread query, and it must not vanish
//           while its own reading pane is open
// Keying by id is what stops a slow reply to one message from landing on
// another one the user has since moved to.
function mergeMail(views, unreadOnly, limit, state, focusedOnly) {
  var overrides = (state && state.read) || {}
  var deleted = (state && state.deleted) || {}
  var held = (state && state.held) || {}
  var merged = []

  for (var v = 0; v < (views || []).length; v++) {
    var view = views[v]
    for (var m = 0; m < view.mail.length; m++) {
      var mail = view.mail[m]
      var id = String(mail.id)
      if (deleted[id] === true) continue

      var read = overrides[id] === undefined ? mail.read === true : overrides[id] === true
      // A message stays in the unread view while it is held, so it cannot go
      // out from under the pane reading it.
      if (unreadOnly === true && read && held[id] !== true) continue
      // Outlook's Other pile, hidden on request.
      if (focusedOnly === true && mail.focused === false) continue

      merged.push({
        id: mail.id,
        subject: mail.subject,
        from: mail.from,
        fromAddress: mail.fromAddress,
        received: mail.received,
        receivedAt: (parseDate(mail.received) || new Date(0)).getTime(),
        preview: mail.preview,
        webLink: mail.webLink,
        important: mail.important === true,
        hasAttachments: mail.hasAttachments === true,
        read: read,
        focused: mail.focused !== false,
        alias: view.alias,
        short: view.short,
        color: view.color,
        // Whether this row's mailbox may be acted on, so the list can offer
        // delete only where it would work.
        write: view.write === true
      })
    }
  }
  var pinned = state && state.pinned
  var pinnedId = pinned ? String(pinned.id) : ""
  if (pinnedId !== "" && deleted[pinnedId] !== true && !containsId(merged, pinnedId)) {
    var row = {}
    for (var key in pinned) row[key] = pinned[key]
    row.receivedAt = (parseDate(row.received) || new Date(0)).getTime()
    if (overrides[pinnedId] !== undefined) row.read = overrides[pinnedId] === true
    merged.push(row)
  }

  merged.sort(function(a, b) { return b.receivedAt - a.receivedAt })

  var cap = limit > 0 ? limit : merged.length
  if (merged.length <= cap) return merged

  var capped = merged.slice(0, cap)
  // The message being read always has a row, even when it sorts below the cut.
  if (pinnedId !== "" && !containsId(capped, pinnedId)) {
    for (var p = 0; p < merged.length; p++) {
      if (String(merged[p].id) === pinnedId) {
        capped = merged.slice(0, cap - 1)
        capped.push(merged[p])
        break
      }
    }
  }
  return capped
}

// After the row at `index` is removed, whichever row slid into its place is
// the natural one to read next; at the end of the list, step back to the last
// row instead of falling off it.
function nextAfterRemoval(list, index) {
  if (!list || list.length === 0) return null
  if (index < 0) return list[0]
  if (index < list.length) return list[index]
  return list[list.length - 1]
}

function containsId(list, id) {
  for (var i = 0; i < list.length; i++) if (String(list[i].id) === id) return true
  return false
}

// Drop optimistic flags the server has caught up with, so the overrides do
// not outlive their purpose and quietly mask later changes made elsewhere.
function pruneOverrides(views, state) {
  var overrides = (state && state.read) || {}
  var deleted = (state && state.deleted) || {}
  var seen = {}
  var serverRead = {}

  for (var v = 0; v < (views || []).length; v++) {
    var view = views[v]
    if (!view.ok) return state
    for (var m = 0; m < view.mail.length; m++) {
      var id = String(view.mail[m].id)
      seen[id] = true
      serverRead[id] = view.mail[m].read === true
    }
  }

  var nextRead = {}
  for (var key in overrides) {
    // Retire an override only once the server has actually caught up with it.
    // A message the fetch no longer carries keeps its flag: that is exactly
    // the message just marked read, which fell out of both queries, and
    // dropping it here would let its pinned row read as unread again.
    if (!seen[key] || serverRead[key] !== overrides[key]) nextRead[key] = overrides[key]
  }

  var nextDeleted = {}
  for (var gone in deleted) if (seen[gone]) nextDeleted[gone] = true

  return { read: nextRead, deleted: nextDeleted, held: (state && state.held) || {} }
}

// One agenda across mailboxes, grouped by day. Events keep epoch times and a
// duration alongside the display string, so a drawn calendar can size blocks
// from this same structure later.
function mergeEvents(views, now, maxEvents, dedupe) {
  var reference = now || new Date()
  var limit = maxEvents || 20
  var collected = []

  for (var v = 0; v < (views || []).length; v++) {
    var view = views[v]
    for (var e = 0; e < view.events.length; e++) {
      var event = view.events[e]
      var start = parseDate(event.start)
      var end = parseDate(event.end)
      if (!start) continue
      // Drop what has already finished so the agenda starts at what is next.
      if (end && end.getTime() <= reference.getTime()) continue

      collected.push({
        id: event.id,
        uid: String(event.uid || ""),
        subject: event.subject,
        location: event.location || "",
        organizer: event.organizer || "",
        webLink: event.webLink || "",
        // A Teams meeting you can join straight from the panel.
        joinUrl: event.joinUrl || "",
        onlineProvider: event.onlineProvider || "",
        free: event.free === true,
        isAllDay: event.isAllDay === true,
        startsAt: start.getTime(),
        endsAt: end ? end.getTime() : start.getTime(),
        durationMinutes: end ? Math.max(0, Math.round((end.getTime() - start.getTime()) / 60000)) : 0,
        timeRange: event.isAllDay ? "All day" : (timeOfDay(start) + "–" + timeOfDay(end)),
        current: !event.isAllDay && end && start.getTime() <= reference.getTime() && end.getTime() > reference.getTime(),
        aliases: [view.alias],
        shorts: [view.short],
        colors: [view.color]
      })
    }
  }

  collected.sort(function(a, b) {
    if (a.startsAt !== b.startsAt) return a.startsAt - b.startsAt
    return a.subject < b.subject ? -1 : (a.subject > b.subject ? 1 : 0)
  })

  if (dedupe !== false) collected = dedupeEvents(collected)

  var groups = []
  var byDay = {}
  var hidden = 0
  for (var i = 0; i < collected.length; i++) {
    if (i >= limit) { hidden += 1; continue }
    var when = new Date(collected[i].startsAt)
    var dayKey = when.getFullYear() + "-" + when.getMonth() + "-" + when.getDate()
    if (!byDay[dayKey]) {
      byDay[dayKey] = { key: dayKey, label: dayLabel(when, reference), events: [] }
      groups.push(byDay[dayKey])
    }
    byDay[dayKey].events.push(collected[i])
  }

  return { groups: groups, hidden: hidden }
}

// What makes two rows the same meeting.
//
// `uid` is Graph's iCalUId: the same string in every mailbox invited to a
// meeting, and different for unrelated ones. The start time goes in with it
// because the occurrences of a recurring series share a uid - without it, a
// daily standup would collapse into one block on Monday.
//
// Matching on subject and start time instead, as this used to, merges any two
// people's simultaneous "Lunch" or "Focus time" - hiding one of them and
// keeping only the first one's link. So a row with no uid is left alone: a
// duplicate on screen is a much smaller wrong than a meeting that vanished.
function eventIdentity(item) {
  var uid = String(item.uid || "")
  if (uid === "") return ""
  return uid + "|" + item.startsAt
}

// A meeting you are invited to from two mailboxes is one meeting. Keep both
// owners on it so its rail can show every colour involved.
function dedupeEvents(collected) {
  var unique = []
  var seen = {}
  for (var c = 0; c < collected.length; c++) {
    var item = collected[c]
    var key = eventIdentity(item)
    if (key !== "" && seen[key] !== undefined) {
      var kept = unique[seen[key]]
      for (var a = 0; a < item.aliases.length; a++) {
        if (kept.aliases.indexOf(item.aliases[a]) < 0) {
          kept.aliases.push(item.aliases[a])
          kept.shorts.push(item.shorts[a])
          kept.colors.push(item.colors[a])
        }
      }
      continue
    }
    if (key !== "") seen[key] = unique.length
    unique.push(item)
  }
  return unique
}

// ---------------------------------------------------------------------------
// Timeline
//
// The drawn agenda needs a different projection from the list. The list
// answers "what is next" and drops anything finished; a grid with a hole where
// the morning was is simply wrong, so the past is kept here and dimmed. Days
// are fixed slots rather than whatever days happen to have events, and a
// meeting crossing midnight belongs to both of them.
// ---------------------------------------------------------------------------

var MINUTES_PER_DAY = 1440

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function addDays(date, count) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + count)
}

function dayKeyOf(date) {
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
}

// "07:00" → 420. Anything unparseable falls back, so a hand-edited setting
// cannot produce an empty grid.
function minutesFromClock(value, fallback) {
  var match = /^\s*(\d{1,2})\s*[:.]?\s*(\d{2})?\s*$/.exec(String(value === undefined || value === null ? "" : value))
  if (!match) return fallback
  var hours = parseInt(match[1], 10)
  var minutes = match[2] ? parseInt(match[2], 10) : 0
  if (!isFinite(hours) || hours > 24 || minutes > 59) return fallback
  return Math.min(MINUTES_PER_DAY, hours * 60 + minutes)
}

function clockFromMinutes(minutes) {
  var whole = Math.max(0, Math.min(MINUTES_PER_DAY, Math.round(minutes)))
  return pad(Math.floor(whole / 60) % 24) + ":" + pad(whole % 60)
}

// Every event from every mailbox, unfiltered, as plain objects with real
// dates. The list's own collector drops the past, which is the one thing a
// grid must not do.
function gatherEvents(views, reference, dedupe) {
  var collected = []
  for (var v = 0; v < (views || []).length; v++) {
    var view = views[v]
    for (var e = 0; e < (view.events || []).length; e++) {
      var event = view.events[e]
      var start = parseDate(event.start)
      var end = parseDate(event.end)
      if (!start) continue
      if (!end || end.getTime() < start.getTime()) end = start
      collected.push({
        id: String(event.id || ""),
        // Graph's iCalUId - the same in every mailbox invited to this meeting.
        uid: String(event.uid || ""),
        subject: String(event.subject || "(no subject)"),
        location: event.location || "",
        organizer: event.organizer || "",
        webLink: event.webLink || "",
        // A Teams meeting you can join straight from the panel.
        joinUrl: event.joinUrl || "",
        onlineProvider: event.onlineProvider || "",
        free: event.free === true,
        isAllDay: event.isAllDay === true,
        startsAt: start.getTime(),
        endsAt: end.getTime(),
        durationMinutes: Math.max(0, Math.round((end.getTime() - start.getTime()) / 60000)),
        timeRange: event.isAllDay ? "All day" : (timeOfDay(start) + "–" + timeOfDay(end)),
        current: !event.isAllDay && start.getTime() <= reference.getTime() && end.getTime() > reference.getTime(),
        past: end.getTime() <= reference.getTime(),
        aliases: [view.alias],
        shorts: [view.short],
        colors: [view.color]
      })
    }
  }

  collected.sort(function(a, b) {
    if (a.startsAt !== b.startsAt) return a.startsAt - b.startsAt
    // Longer first, so a meeting that contains others is the one that gets the
    // leftmost column and the ones inside it stack to its right.
    if (a.endsAt !== b.endsAt) return b.endsAt - a.endsAt
    return a.subject < b.subject ? -1 : (a.subject > b.subject ? 1 : 0)
  })

  return dedupe === false ? collected : dedupeEvents(collected)
}

// Side-by-side placement for one day's timed events.
//
// Events that overlap form a cluster; within a cluster each event takes the
// first column still free at the moment it starts. A block then expands into
// the columns to its right for as long as nothing there overlaps it, so a lone
// short meeting beside a long one is not left needlessly narrow.
//
// Mutates and returns the list it is given: the objects are freshly built by
// the caller, and copying them again buys nothing.
function packDay(events) {
  var list = events || []
  var index = 0

  while (index < list.length) {
    // One cluster: everything that chains together by overlapping.
    var clusterEnd = list[index].endsAt
    var last = index + 1
    while (last < list.length && list[last].startsAt < clusterEnd) {
      clusterEnd = Math.max(clusterEnd, list[last].endsAt)
      last += 1
    }

    var cluster = list.slice(index, last)
    var columnEnds = []
    for (var c = 0; c < cluster.length; c++) {
      var event = cluster[c]
      var placed = -1
      for (var col = 0; col < columnEnds.length; col++) {
        if (columnEnds[col] <= event.startsAt) { placed = col; break }
      }
      if (placed < 0) {
        placed = columnEnds.length
        columnEnds.push(0)
      }
      columnEnds[placed] = event.endsAt
      event.column = placed
      event.span = 1
    }

    var columns = columnEnds.length
    for (var e = 0; e < cluster.length; e++) {
      cluster[e].columns = columns
      // Grow rightwards while the next column holds nothing overlapping.
      var span = 1
      while (cluster[e].column + span < columns && columnFree(cluster, cluster[e], cluster[e].column + span)) span += 1
      cluster[e].span = span
    }

    index = last
  }

  return list
}

function columnFree(cluster, event, column) {
  for (var i = 0; i < cluster.length; i++) {
    var other = cluster[i]
    if (other === event || other.column !== column) continue
    if (other.startsAt < event.endsAt && event.startsAt < other.endsAt) return false
  }
  return true
}

// The whole grid: fixed day slots, each with its all-day band and its packed
// timed events, plus what falls outside the visible hours.
//
// `options`: { dedupe, startMinutes, endMinutes, days, showWeekends }
function dayGrid(views, now, options) {
  var reference = now || new Date()
  var settings = options || {}
  var dayCount = Math.max(1, Math.min(14, settings.days || 3))
  var windowStart = settings.startMinutes === undefined ? 7 * 60 : settings.startMinutes
  var windowEnd = settings.endMinutes === undefined ? 22 * 60 : settings.endMinutes
  if (windowEnd <= windowStart) windowEnd = Math.min(MINUTES_PER_DAY, windowStart + 60)

  var collected = gatherEvents(views, reference, settings.dedupe)
  var today = startOfDay(reference)

  var days = []
  for (var d = 0; d < dayCount; d++) {
    var dayStart = addDays(today, d)
    if (settings.showWeekends === false && (dayStart.getDay() === 0 || dayStart.getDay() === 6)) continue
    days.push({
      key: dayKeyOf(dayStart),
      date: dayStart.getTime(),
      // The next calendar midnight, not 24 hours later: on the day the clocks
      // change one of those is an hour out, and everything drawn on the day
      // would be an hour out with it.
      endsAt: addDays(today, d + 1).getTime(),
      weekday: dayStart.getDay(),
      isToday: d === 0,
      isWeekend: dayStart.getDay() === 0 || dayStart.getDay() === 6,
      allDay: [],
      timed: [],
      earlier: 0,
      later: 0
    })
  }

  var earliest = MINUTES_PER_DAY
  var latest = 0

  for (var i = 0; i < collected.length; i++) {
    var event = collected[i]
    for (var slot = 0; slot < days.length; slot++) {
      var day = days[slot]
      var dayFrom = day.date
      var dayTo = day.endsAt
      // Zero-length events still belong to the day they start on.
      var overlaps = event.startsAt < dayTo
        && (event.endsAt > dayFrom || (event.endsAt === event.startsAt && event.startsAt >= dayFrom))
      if (!overlaps) continue

      var segment = segmentFor(event, dayFrom, dayTo)
      // An all-day event, or one covering the whole of this day, has no useful
      // position on a time axis - it belongs in the band above the grid.
      if (event.isAllDay || (segment.startMinutes <= 0 && segment.endMinutes >= MINUTES_PER_DAY)) {
        day.allDay.push(segment)
        continue
      }

      if (segment.endMinutes <= windowStart) { day.earlier += 1; segment.outside = "before" }
      else if (segment.startMinutes >= windowEnd) { day.later += 1; segment.outside = "after" }
      // Straddling an edge: drawn, but the block has to say it is cut or it
      // reads as a meeting that ends when the grid does.
      segment.clippedBefore = segment.startMinutes < windowStart
      segment.clippedAfter = segment.endMinutes > windowEnd
      // Measured over everything, including what the window is hiding: this is
      // what the panel offers to open up to.
      earliest = Math.min(earliest, segment.startMinutes)
      latest = Math.max(latest, segment.endMinutes)
      day.timed.push(segment)
    }
  }

  for (var p = 0; p < days.length; p++) {
    var visible = []
    for (var t = 0; t < days[p].timed.length; t++)
      if (!days[p].timed[t].outside) visible.push(days[p].timed[t])
    packDay(visible)
    days[p].timed = visible
    // All-day rows stack; a multi-day event keeps one row across every day it
    // touches so it reads as one bar.
    stackAllDay(days[p].allDay)
  }

  return {
    days: days,
    window: { startMinutes: windowStart, endMinutes: windowEnd },
    // What the window would have to be to hide nothing, so the panel can offer
    // to open up to it rather than guessing.
    fits: {
      startMinutes: earliest <= latest ? Math.min(windowStart, earliest) : windowStart,
      endMinutes: earliest <= latest ? Math.max(windowEnd, latest) : windowEnd
    }
  }
}

// Where a moment sits on a day's axis, as minutes past that day's midnight on
// the clock on the wall.
//
// Not elapsed time since midnight: on the day the clocks go forward, 09:00 is
// eight hours after midnight, and drawing it at minute 480 puts it in the 08:00
// row. The grid is labelled with wall-clock hours, so its positions have to be
// read off the same clock. The two agree on every other day of the year.
function minutesIntoDay(when, dayFrom, dayTo) {
  if (when <= dayFrom) return 0
  if (when >= dayTo) return MINUTES_PER_DAY
  var at = new Date(when)
  return Math.round(at.getHours() * 60 + at.getMinutes() + at.getSeconds() / 60)
}

// One event's slice of one day, in minutes from that day's midnight.
function segmentFor(event, dayFrom, dayTo) {
  var startMinutes = minutesIntoDay(Math.max(event.startsAt, dayFrom), dayFrom, dayTo)
  var endMinutes = minutesIntoDay(Math.min(event.endsAt, dayTo), dayFrom, dayTo)
  var segment = {
    id: event.id,
    uid: event.uid,
    subject: event.subject,
    location: event.location,
    organizer: event.organizer,
    webLink: event.webLink,
    joinUrl: event.joinUrl,
    onlineProvider: event.onlineProvider,
    free: event.free,
    isAllDay: event.isAllDay,
    startsAt: event.startsAt,
    endsAt: event.endsAt,
    durationMinutes: event.durationMinutes,
    timeRange: event.timeRange,
    current: event.current,
    past: event.past,
    aliases: event.aliases,
    shorts: event.shorts,
    colors: event.colors,
    startMinutes: startMinutes,
    endMinutes: Math.max(endMinutes, startMinutes),
    // Drawn open-ended rather than as two unrelated meetings.
    continuesBefore: event.startsAt < dayFrom,
    continuesAfter: event.endsAt > dayTo,
    // Set once the visible window is known: whether the grid, rather than
    // midnight, is what cuts this block off.
    clippedBefore: false,
    clippedAfter: false,
    outside: "",
    column: 0,
    columns: 1,
    span: 1,
    row: 0
  }
  return segment
}

// All-day bars that overlap in time go on separate rows; ones that do not can
// share a row.
function stackAllDay(bars) {
  var rowEnds = []
  for (var i = 0; i < bars.length; i++) {
    var placed = -1
    for (var r = 0; r < rowEnds.length; r++) {
      if (rowEnds[r] <= bars[i].startsAt) { placed = r; break }
    }
    if (placed < 0) {
      placed = rowEnds.length
      rowEnds.push(0)
    }
    rowEnds[placed] = bars[i].endsAt
    bars[i].row = placed
  }
  return bars
}

// Prefer a person's name, fall back to the address, then to something neutral.
function senderName(mail) {
  var name = String((mail && mail.from) || "").trim()
  if (name) return name
  var address = String((mail && mail.fromAddress) || "").trim()
  return address || "Unknown sender"
}

function oneLine(text, maxLength) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  var cap = maxLength || 120
  return value.length > cap ? value.substring(0, cap - 1) + "…" : value
}

// Arrays coming from shell.json arrive as JSValue lists that fail
// Array.isArray, so anything array-like has to be copied into a real array
// before standard array operations can be trusted. The shell's own components
// carry the same workaround.
function arrayFrom(value) {
  if (!value || typeof value === "string" || typeof value.length !== "number") return []
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

// The configured openCommand as argv, whichever form it was written in.
//
// The documented form is an array, but v1 wrote a string and hand-edited
// configs still do. Anything that reads the setting has to accept both -
// including the settings form, which rewrites the whole account: normalising a
// string to an empty array there silently drops the browser profile someone
// configured, and they find out the next time a link opens in the wrong place.
function commandArgv(openCommand) {
  var parts = arrayFrom(openCommand)
  if (parts.length > 0) return parts
  var text = String(openCommand || "").trim()
  return text === "" ? [] : text.split(/\s+/)
}

// Turn the configured openCommand into argv, with the URL in it.
function openArgv(openCommand, url) {
  var parts = commandArgv(openCommand)
  if (parts.length === 0) return ["xdg-open", url]

  var substituted = false
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].indexOf("{url}") >= 0) {
      parts[i] = parts[i].replace("{url}", url)
      substituted = true
    }
  }
  if (!substituted) parts.push(url)
  return parts
}

// Anything a shell would read as more than plain text. Deliberately strict:
// the cost of quoting a word that did not need it is nothing, and the cost of
// leaving one unquoted is a browser opening something else.
var SHELL_SAFE = /^[A-Za-z0-9_@%+=:,.\/-]+$/

// Turn argv into one string a shell will take apart again the same way.
//
// omarchy-launch-or-focus takes its command as a single argument and runs it
// through `eval`, so joining argv with spaces loses the boundaries: the
// documented `--profile-directory=Profile 1` arrives as two arguments and lands
// in the wrong browser profile, and a URL with an `&` in it would be worse than
// that. Single quotes because they suspend every expansion a shell does;
// a quote inside the word closes, escapes and reopens.
function shellCommand(parts) {
  var quoted = []
  for (var i = 0; i < parts.length; i++) {
    var part = String(parts[i])
    quoted.push(SHELL_SAFE.test(part) ? part : "'" + part.split("'").join("'\\''") + "'")
  }
  return quoted.join(" ")
}

function parseJson(raw, fallback) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return parsed && typeof parsed === "object" ? parsed : fallback
  } catch (error) {
    return fallback
  }
}
