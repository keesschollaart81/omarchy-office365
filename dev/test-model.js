#!/usr/bin/env node
// Unit tests for the pure parts of Model.js - the timeline packing in
// particular, where getting the columns wrong is easy to do and hard to see.
//
//   node dev/test-model.js
//
// Model.js is a QML library, so it is loaded by evaluating it here. A handful
// of its functions reach for Qt.locale(); those are stubbed rather than
// exercised, since date formatting is the shell's job, not this file's.

// Pinned before the first Date exists. The grid is laid out in local time
// throughout, so these tests need a zone of their own rather than whichever one
// the machine running them happens to be in - and one whose clocks change twice
// a year, because that is where the arithmetic gets interesting.
process.env.TZ = "Europe/Amsterdam"

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "src", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")

const Model = vm.createContext({
  Qt: { locale: () => "en_GB" },
  Date, Math, String, Number, JSON, isNaN, isFinite, parseInt, parseFloat, console
})
vm.runInContext(source, Model)

let failures = 0
let checks = 0

function check(name, actual, expected) {
  checks += 1
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failures += 1
    console.log(`  FAIL  ${name}\n        expected ${e}\n        got      ${a}`)
  }
}

function group(name, body) {
  console.log(name)
  body()
}

// A fixed "today" so nothing depends on when the tests are run.
const TODAY = new Date(2026, 7, 20, 12, 0, 0)

function iso(dayOffset, hour, minute) {
  const d = new Date(TODAY.getFullYear(), TODAY.getMonth(), TODAY.getDate() + dayOffset, hour, minute || 0)
  const p = (n) => (n < 10 ? "0" : "") + n
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:00`
}

function ev(id, dayOffset, from, to, extra) {
  return Object.assign({
    id, subject: id, start: iso(dayOffset, from[0], from[1]), end: iso(dayOffset, to[0], to[1]),
    isAllDay: false, location: "", organizer: "", webLink: "", free: false
  }, extra || {})
}

function view(alias, short, color, events) {
  return { alias, short, color, events }
}

function grid(views, options) {
  return Model.dayGrid(views, TODAY, Object.assign({ days: 1 }, options || {}))
}

function placement(day) {
  return day.timed.map((e) => `${e.id}:${e.column}/${e.columns}x${e.span}`)
}

group("packDay - columns", () => {
  // Nothing overlapping: everyone gets the full width.
  let g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [10, 0]),
    ev("b", 0, [10, 0], [11, 0])
  ])])
  check("back to back share column 0", placement(g.days[0]), ["a:0/1x1", "b:0/1x1"])

  // Two overlapping: side by side.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [10, 30]),
    ev("b", 0, [10, 0], [11, 0])
  ])])
  check("overlap splits in two", placement(g.days[0]), ["a:0/2x1", "b:1/2x1"])

  // Three overlapping at once - the 11:00 pile-up from the fixtures.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [11, 0], [12, 0]),
    ev("b", 0, [11, 30], [12, 30]),
    ev("c", 0, [11, 45], [12, 15])
  ])])
  check("three-way overlap", placement(g.days[0]), ["a:0/3x1", "b:1/3x1", "c:2/3x1"])

  // A long meeting with two short ones inside it, one after the other. The
  // shorts share a column because they do not overlap each other.
  g = grid([view("w", "W", "#fff", [
    ev("long", 0, [9, 0], [12, 0]),
    ev("s1", 0, [9, 30], [10, 0]),
    ev("s2", 0, [10, 30], [11, 0])
  ])])
  check("shorts reuse the freed column", placement(g.days[0]), ["long:0/2x1", "s1:1/2x1", "s2:1/2x1"])

  // Expand-right: b ends before c starts, so b can take c's column too.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [12, 0]),
    ev("b", 0, [9, 30], [10, 0]),
    ev("c", 0, [10, 30], [11, 0]),
    ev("d", 0, [10, 30], [11, 0])
  ])])
  check("a block grows into free columns", placement(g.days[0]), ["a:0/3x1", "b:1/3x2", "c:1/3x1", "d:2/3x1"])

  // Separate clusters are packed independently, so a morning pile-up does not
  // narrow the afternoon.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [10, 0]),
    ev("b", 0, [9, 30], [10, 30]),
    ev("c", 0, [14, 0], [15, 0])
  ])])
  check("clusters are independent", placement(g.days[0]), ["a:0/2x1", "b:1/2x1", "c:0/1x1"])
})

group("dayGrid - days", () => {
  const g = grid([view("w", "W", "#fff", [
    ev("today", 0, [9, 0], [10, 0]),
    ev("tomorrow", 1, [9, 0], [10, 0]),
    ev("later", 5, [9, 0], [10, 0])
  ])], { days: 3 })
  check("one slot per day, empty or not", g.days.length, 3)
  check("today is flagged", g.days.map((d) => d.isToday), [true, false, false])
  check("events land in their own day", g.days.map((d) => d.timed.map((e) => e.id)), [["today"], ["tomorrow"], []])
})

group("dayGrid - the visible window", () => {
  const g = grid([view("w", "W", "#fff", [
    ev("early", 0, [6, 0], [6, 30]),
    ev("inside", 0, [9, 0], [10, 0]),
    ev("late", 0, [23, 0], [23, 30])
  ])], { startMinutes: 7 * 60, endMinutes: 22 * 60 })
  check("out-of-window events are counted, not drawn", placement(g.days[0]), ["inside:0/1x1"])
  check("earlier count", g.days[0].earlier, 1)
  check("later count", g.days[0].later, 1)
  // What the window would have to be to hide nothing - the hidden ones are
  // exactly what this has to account for.
  check("the window that would fit everything", [g.fits.startMinutes, g.fits.endMinutes],
    [6 * 60, 23 * 60 + 30])

  // A meeting straddling the edge is drawn, and widens what would fit.
  const straddle = grid([view("w", "W", "#fff", [ev("dawn", 0, [6, 0], [8, 0])])])
  check("straddling the edge still draws", placement(straddle.days[0]), ["dawn:0/1x1"])
  check("fits opens up to include it", straddle.fits.startMinutes, 6 * 60)
})

group("dayGrid - all day", () => {
  const g = grid([view("w", "W", "#fff", [
    { id: "offsite", subject: "Offsite", start: iso(0, 0, 0), end: iso(2, 0, 0), isAllDay: true,
      location: "", organizer: "", webLink: "", free: false },
    ev("meeting", 0, [9, 0], [10, 0])
  ])], { days: 3 })
  check("all-day spans every day it touches", g.days.map((d) => d.allDay.map((e) => e.id)),
    [["offsite"], ["offsite"], []])
  check("and stays out of the grid", g.days.map((d) => d.timed.map((e) => e.id)), [["meeting"], [], []])

  // Two overlapping all-day events stack; the second gets its own row.
  const stacked = grid([view("w", "W", "#fff", [
    { id: "one", subject: "One", start: iso(0, 0, 0), end: iso(1, 0, 0), isAllDay: true, location: "", organizer: "", webLink: "", free: false },
    { id: "two", subject: "Two", start: iso(0, 0, 0), end: iso(1, 0, 0), isAllDay: true, location: "", organizer: "", webLink: "", free: false }
  ])])
  check("overlapping all-day bars stack", stacked.days[0].allDay.map((e) => e.row), [0, 1])
})

group("dayGrid - across midnight", () => {
  const g = Model.dayGrid([view("w", "W", "#fff", [
    { id: "night", subject: "Night", start: iso(0, 22, 0), end: iso(1, 1, 0), isAllDay: false,
      location: "", organizer: "", webLink: "", free: false }
  ])], TODAY, { days: 2, startMinutes: 0, endMinutes: 24 * 60 })
  check("appears on both days", g.days.map((d) => d.timed.map((e) => e.id)), [["night"], ["night"]])
  check("clipped to each day", g.days.map((d) => [d.timed[0].startMinutes, d.timed[0].endMinutes]),
    [[22 * 60, 24 * 60], [0, 60]])
  check("and knows it is cut", g.days.map((d) => [d.timed[0].continuesBefore, d.timed[0].continuesAfter]),
    [[false, true], [true, false]])
})

group("dayGrid - past and present", () => {
  const g = grid([view("w", "W", "#fff", [
    ev("done", 0, [9, 0], [10, 0]),
    ev("now", 0, [11, 30], [12, 30]),
    ev("soon", 0, [14, 0], [15, 0])
  ])])
  check("finished meetings are kept, flagged past", g.days[0].timed.map((e) => e.past), [true, false, false])
  check("the one happening now is flagged", g.days[0].timed.map((e) => e.current), [false, true, false])
})

group("dayGrid - two mailboxes", () => {
  // The same invitation in two mailboxes: different message ids, one iCalUId.
  const invite = (id) => ev(id, 0, [11, 0], [12, 0], { uid: "shared-uid", subject: "Sprint review" })
  const g = grid([
    view("work", "WRK", "#blue", [invite("work-copy")]),
    view("personal", "P", "#magenta", [invite("personal-copy")])
  ])
  check("the same meeting merges", g.days[0].timed.map((e) => e.id), ["work-copy"])
  check("keeping both colours", g.days[0].timed[0].colors, ["#blue", "#magenta"])

  const apart = Model.dayGrid([
    view("work", "WRK", "#blue", [invite("a")]),
    view("personal", "P", "#magenta", [invite("b")])
  ], TODAY, { days: 1, dedupe: false })
  check("unless dedupe is off", placement(apart.days[0]), ["a:0/2x1", "b:1/2x1"])

  // Two people's lunch, at the same time, called the same thing. Matching on
  // subject and start alone would hide one of them.
  const lunch = grid([
    view("work", "WRK", "#blue", [ev("lunch-work", 0, [12, 0], [13, 0], { uid: "one" })]),
    view("personal", "P", "#magenta", [ev("lunch-work", 0, [12, 0], [13, 0], { uid: "two" })])
  ])
  check("different meetings that look alike both stay",
        lunch.days[0].timed.map((e) => e.uid), ["one", "two"])

  // A mailbox that answered without an iCalUId has nothing to match on, and a
  // duplicate drawn twice beats a meeting quietly removed.
  const noUid = grid([
    view("work", "WRK", "#blue", [ev("m", 0, [11, 0], [12, 0])]),
    view("personal", "P", "#magenta", [ev("m", 0, [11, 0], [12, 0])])
  ])
  check("no identity means no merging", noUid.days[0].timed.length, 2)

  // Every occurrence of a series carries the series' uid, so the uid alone
  // would fold a daily standup into Monday.
  const series = Model.dayGrid([view("work", "WRK", "#blue", [
    ev("mon", 0, [9, 0], [9, 15], { uid: "standup" }),
    ev("tue", 1, [9, 0], [9, 15], { uid: "standup" })
  ])], TODAY, { days: 2 })
  check("a recurring series keeps every occurrence",
        series.days.map((d) => d.timed.length), [1, 1])
})

// A grid is labelled with wall-clock hours, so a block's position has to be
// read off the same clock. Elapsed milliseconds since midnight stop agreeing
// with it on the two days a year the clocks change.
group("daylight saving", () => {
  const at = (y, m, d, h, min) => {
    const p = (n) => (n < 10 ? "0" : "") + n
    return `${y}-${p(m)}-${p(d)}T${p(h)}:${p(min)}:00`
  }
  const dayOf = (y, m, d, events) =>
    Model.dayGrid([{ alias: "w", short: "W", color: "#fff", events }],
                  new Date(y, m - 1, d, 12, 0, 0), { days: 1, startMinutes: 0, endMinutes: 1440 })

  // Europe/Amsterdam springs forward at 02:00 on 2026-03-29: a 23-hour day.
  const spring = dayOf(2026, 3, 29, [{
    id: "s", subject: "Standup", start: at(2026, 3, 29, 9, 0), end: at(2026, 3, 29, 10, 0),
    isAllDay: false, location: "", organizer: "", webLink: "", free: false
  }])
  check("09:00 on the short day is drawn at 09:00",
        [spring.days[0].timed[0].startMinutes, spring.days[0].timed[0].endMinutes], [540, 600])

  // And falls back at 03:00 on 2026-10-25: a 25-hour day.
  const autumn = dayOf(2026, 10, 25, [{
    id: "a", subject: "Brunch", start: at(2026, 10, 25, 11, 0), end: at(2026, 10, 25, 12, 30),
    isAllDay: false, location: "", organizer: "", webLink: "", free: false
  }])
  check("11:00 on the long day is drawn at 11:00",
        [autumn.days[0].timed[0].startMinutes, autumn.days[0].timed[0].endMinutes], [660, 750])

  // The day boundary is the next midnight, not 24 hours on, so the day after a
  // change still holds its own events rather than borrowing the neighbour's.
  const across = Model.dayGrid([{ alias: "w", short: "W", color: "#fff", events: [
    { id: "sat", subject: "Sat", start: at(2026, 10, 24, 23, 30), end: at(2026, 10, 25, 0, 30),
      isAllDay: false, location: "", organizer: "", webLink: "", free: false }
  ] }], new Date(2026, 9, 24, 12, 0, 0), { days: 2, startMinutes: 0, endMinutes: 1440 })
  check("a meeting over midnight splits at midnight",
        across.days.map((d) => d.timed.map((e) => [e.startMinutes, e.endMinutes])),
        [[[1410, 1440]], [[0, 30]]])
})

group("clock settings", () => {
  check("07:00", Model.minutesFromClock("07:00", -1), 420)
  check("7:00", Model.minutesFromClock("7:00", -1), 420)
  check("bare hour", Model.minutesFromClock("7", -1), 420)
  check("midnight end", Model.minutesFromClock("24:00", -1), 1440)
  check("nonsense falls back", Model.minutesFromClock("elevenish", -1), -1)
  check("out of range falls back", Model.minutesFromClock("99:99", -1), -1)
  check("empty falls back", Model.minutesFromClock("", -1), -1)
  check("round trip", Model.clockFromMinutes(Model.minutesFromClock("21:45", 0)), "21:45")
})

// omarchy-launch-or-focus evaluates its command as shell text, so what goes in
// has to survive being taken apart again.
group("launch commands", () => {
  const cmd = (openCommand, url) => Model.shellCommand(Model.openArgv(openCommand, url))

  check("the default browser", cmd("", "https://x/y"), "xdg-open https://x/y")
  check("an argument with a space keeps its boundary",
        cmd(["microsoft-edge", "--profile-directory=Profile 1", "{url}"], "https://x/y"),
        "microsoft-edge '--profile-directory=Profile 1' https://x/y")
  check("a URL with shell characters is not reinterpreted",
        cmd(["firefox"], "https://x/y?a=1&b=2;rm"),
        "firefox 'https://x/y?a=1&b=2;rm'")
  check("a quote in a value closes and reopens",
        cmd(["app", "it's"], "https://x"),
        "app 'it'\\''s' https://x")
  check("plain words are left alone",
        cmd(["chromium", "--new-window"], "https://x"),
        "chromium --new-window https://x")

  // The v1 string form, which the settings form has to round-trip rather than
  // normalise away.
  check("a string command still runs",
        cmd("firefox --new-tab {url}", "https://x"),
        "firefox --new-tab https://x")
  check("a string command survives being read back",
        Model.commandArgv("firefox --new-tab {url}"),
        ["firefox", "--new-tab", "{url}"])
  check("an array command survives being read back",
        Model.commandArgv(["firefox", "{url}"]), ["firefox", "{url}"])
  check("nothing configured stays nothing", Model.commandArgv(""), [])
})

// A mailbox that answered without its calendar is not a mailbox with an empty
// calendar, and the panel has to be able to tell the difference.
group("partial failures", () => {
  const views = [
    { alias: "work", short: "WRK", color: "#blue", ok: true,
      warnings: [{ scope: "calendar", message: "Access is denied" }] },
    { alias: "personal", short: "P", color: "#magenta", ok: true, warnings: [] },
    { alias: "dead", short: "D", color: "#red", ok: false,
      warnings: [{ scope: "mail", message: "never shown, the account failed outright" }] }
  ]
  const found = Model.collectWarnings(views)
  check("only mailboxes that answered", found.map((w) => w.short), ["WRK"])
  check("carrying what failed and why", [found[0].scope, found[0].message],
        ["calendar", "Access is denied"])
  check("nothing wrong means nothing shown", Model.collectWarnings([views[1]]), [])
})

// "no unread mail" is a claim, and it must never rest on a request that failed.
group("how many are unread", () => {
  const known = { unreadCount: 3, unreadKnown: true }
  const floored = { unreadCount: 3, unreadKnown: false }
  const blind = { unreadCount: 0, unreadKnown: false }
  const empty = { unreadCount: 0, unreadKnown: true }

  check("the inbox's own number", Model.unreadLabel(known), "3")
  check("a floor is marked as one", Model.unreadLabel(floored), "3+")
  check("nothing to go on", Model.unreadLabel(blind), "?")
  check("an empty inbox still says so", Model.unreadSummary(empty), "no unread mail")
  check("and never on a failed count", Model.unreadSummary(blind), "unread count unavailable")
  check("phrased for a tooltip", Model.unreadSummary(floored), "3+ unread")

  // A mailbox from before this existed, or one that answered normally.
  check("a view with no flag is trusted",
        Model.unreadLabel({ unreadCount: 2 }), "2")
})

// A bar that lights up for an unread message from three weeks ago is a bar
// that is always lit, and one that is always lit says nothing when mail
// actually arrives. So "new" is what the list shows, and the backlog behind it
// is counted separately.
group("new mail against the backlog", () => {
  // Newest first, and dated so the cut falls where the test wants it.
  const msg = (id, day, read) => ({
    id: id, subject: "re: " + id, from: "someone", fromAddress: "a@b.c",
    received: `2026-08-${String(day).padStart(2, "0")}T09:00:00Z`,
    preview: "", webLink: "", important: false, hasAttachments: false,
    read: read, focused: true
  })
  const box = (alias, mail, unread, known) => ({
    alias: alias, short: alias.toUpperCase(), color: "#fff", ok: true,
    mail: mail, unreadCount: unread, unreadKnown: known !== false, write: true,
    events: [], folders: [], warnings: []
  })

  // Three newer messages sit on top of the unread one from the 1st, so with a
  // list of three it is out of view: backlog, not news.
  const buried = [box("work", [
    msg("d4", 4, true), msg("d3", 3, true), msg("d2", 2, true), msg("old", 1, false)
  ], 1)]
  check("an unread message the list cannot reach is not new",
        Model.freshUnread(buried, 3, {}).total, 0)
  check("and the bar phrase says only that it is unread",
        Model.unreadSummary(buried[0], Model.freshUnread(buried, 3, {})), "1 unread")

  // The same mailbox, one message having just landed unread.
  const arrived = [box("work", [
    msg("new", 5, false), msg("d4", 4, true), msg("d3", 3, true), msg("old", 1, false)
  ], 2)]
  const fresh = Model.freshUnread(arrived, 3, {})
  check("what is in the list is", fresh.total, 1)
  check("with the backlog kept apart from it",
        Model.unreadSummary(arrived[0], fresh), "1 new · 2 unread")

  // Nothing behind them: two numbers where one is the whole story.
  const allNew = [box("work", [msg("a", 5, false), msg("b", 4, false)], 2)]
  check("no backlog, so no second number",
        Model.unreadSummary(allNew[0], Model.freshUnread(allNew, 3, {})), "2 new")

  // A floor is still a floor, and the new count does not make it a count.
  const floored = [box("work", [msg("a", 5, false)], 1, false)]
  check("a floor stays marked as one",
        Model.unreadSummary(floored[0], Model.freshUnread(floored, 3, {})), "1 new · 1+ unread")

  // Marking it read is the point of marking it read: the tint has to go out
  // before the server agrees, or the bar argues with the panel for a round.
  check("an optimistic read drops it at once",
        Model.freshUnread(arrived, 3, { read: { "new": true } }).total, 0)
  check("as does deleting it",
        Model.freshUnread(allNew, 3, { deleted: { "a": true } }).total, 1)
  // Taking a row out makes room, and the backlog message that slides up into
  // the list is new by this definition. That is the definition working rather
  // than failing: it is in the list now, so opening the panel shows what the
  // lit icon is about.
  check("and the backlog slides up into the room it left",
        Model.freshUnread(arrived, 3, { deleted: { "new": true } }).total, 1)

  // Each mailbox on its own, because the tooltip names them one per line.
  const both = [
    box("work", [msg("w1", 5, false)], 4),
    box("home", [msg("h1", 4, true), msg("h2", 3, true)], 0)
  ]
  const split = Model.freshUnread(both, 5, {})
  check("counted per mailbox", [split.total, split.byAlias.work, split.byAlias.home || 0], [1, 1, 0])
  check("and one mailbox's news is not the other's",
        [Model.unreadSummary(both[0], split), Model.unreadSummary(both[1], split)],
        ["1 new · 4 unread", "no unread mail"])

  // The panel's own filters must not be able to redefine what arrived.
  // Filtering to unread pulls the backlog into view; the bar must not read
  // that as four things landing at once.
  const filtered = Model.mergeMail(buried, true, 3, {}, false)
  check("the unread filter does show the backlog", filtered.map((r) => r.id), ["old"])
  check("but it is still not new", Model.freshUnread(buried, 3, {}).total, 0)

  // Without a fresh count there is no claim to make about it, and the phrase
  // falls back to what it always said.
  check("no list, no claim", Model.unreadSummary(box("work", [], 7)), "7 unread")
})

group("the list view still works", () => {
  const merged = Model.mergeEvents([view("w", "W", "#fff", [
    ev("done", 0, [9, 0], [10, 0]),
    ev("soon", 0, [14, 0], [15, 0])
  ])], TODAY, 20, true)
  check("finished meetings stay dropped there", merged.groups[0].events.map((e) => e.id), ["soon"])
})

// Anything the shell draws for us cannot be pinned to Text.PlainText from here,
// so it has to arrive already unable to look like markup. Qt switches a string
// to rich text as soon as it finds a `<` that could open a tag, and rich text
// fetches what it is told to.
group("text handed to the shell", () => {
  const attack = '<img src="http://tracker.example/pixel.png">Invoice'
  check("a tag cannot survive", Model.plainText(attack).indexOf("<"), -1)
  check("the words do", Model.plainText(attack).indexOf("Invoice") >= 0, true)
  check("a closing tag cannot either",
        Model.plainText("</b><a href='http://x'>x</a>").indexOf("<"), -1)
  check("nor an html document",
        Model.plainText("<!DOCTYPE html><html><body>hi").indexOf("<"), -1)
  check("ordinary text is untouched",
        Model.plainText("Re: sprint 24 scope"), "Re: sprint 24 scope")
  check("an address keeps its name",
        Model.plainText("Priya Raman kees@example.com>"), "Priya Raman kees@example.com>")
  check("nothing is empty, not undefined", Model.plainText(undefined), "")
})

console.log(`\n${checks - failures}/${checks} passed`)
process.exit(failures ? 1 : 0)
