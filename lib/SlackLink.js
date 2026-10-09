.pragma library

// The Slack conversation a notification was about, out of Slack's own log.
//
// Slack's desktop app logs every notification it raises to browser.log, the
// text redacted and the ids kept, a millisecond or two before the notification
// service stamps it. The entry nearest an archived notification's timestamp is
// the one it came from. The summary is never read, so this works in any
// language and no sender-chosen text reaches the link.

var HEADER = /^\[(\d\d)\/(\d\d)\/(\d\d), (\d\d):(\d\d):(\d\d):(\d{3})\] info: Store: NEW_NOTIFICATION/gm

// The log stamps local time with no zone, so it is read back as local time.
function logTime(m) {
  return new Date(2000 + Number(m[3]), Number(m[1]) - 1, Number(m[2]),
                  Number(m[4]), Number(m[5]), Number(m[6]), Number(m[7])).getTime()
}

// Each entry is a header line and a pretty-printed object closed by a "}" at
// the start of a line. One that does not parse, cut off at the end of the file
// or otherwise, is skipped.
function parse(text) {
  var entries = []
  var m
  HEADER.lastIndex = 0
  while ((m = HEADER.exec(text)) !== null) {
    var start = text.indexOf("{", HEADER.lastIndex)
    var end = text.indexOf("\n}", start)
    if (start < 0 || end < 0) break
    try {
      var d = JSON.parse(text.slice(start, end + 2))
      entries.push({ atMs: logTime(m), team: d.teamId, channel: d.channel,
                     ts: d.msg, threadTs: d.thread_ts })
    } catch (e) {
    }
  }
  return entries
}

function nearest(entries, stampMs) {
  var best = null
  for (var i = 0; i < entries.length; i++) {
    var gap = Math.abs(entries[i].atMs - stampMs)
    if (gap <= 1000 && (!best || gap < Math.abs(best.atMs - stampMs))) best = entries[i]
  }
  return best
}

function isId(value, re) {
  return typeof value === "string" && re.test(value)
}

// Only ids of the right shape make it into a link. Enterprise Grid logs the
// organisation (E...) where a plain workspace logs its team (T...).
function link(entry) {
  if (!entry) return ""
  if (!isId(entry.team, /^[TE][A-Z0-9]{2,20}$/)) return ""
  if (!isId(entry.channel, /^[CDG][A-Z0-9]{2,20}$/)) return ""
  var ts = /^\d{9,11}\.\d{6}$/
  var url = "slack://channel?team=" + entry.team + "&id=" + entry.channel
  if (isId(entry.ts, ts)) url += "&message=" + entry.ts
  if (isId(entry.threadTs, ts)) url += "&thread_ts=" + entry.threadTs
  return url
}

function resolve(text, stampMs) {
  return link(nearest(parse(text), stampMs))
}
