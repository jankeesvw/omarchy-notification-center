// node --test
process.env.TZ = "Europe/Amsterdam"

const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// The module is a QML JavaScript library; minus its pragma it is plain script.
const source = fs.readFileSync(path.join(__dirname, "../lib/SlackLink.js"), "utf8")
const SlackLink = vm.createContext({})
vm.runInContext(source.replace(/^\.pragma library$/m, ""), SlackLink)

// One entry as Slack writes it to browser.log, the text redacted by Slack
// itself. Every id and value here is made up.
function entry(stamp, { teamId, channel, msg = "1790000000.000100", thread_ts }) {
  const thread = thread_ts === undefined ? "" : `\n  "thread_ts": ${JSON.stringify(thread_ts)},`
  return `[${stamp}] info: Store: NEW_NOTIFICATION 
{
  "title": "[REDACTED]",
  "subtitle": "[REDACTED]",
  "content": "[REDACTED]",
  "body": "[REDACTED]",
  "authorName": "[REDACTED]",
  "avatarImage": "[REDACTED]",
  "teamId": ${JSON.stringify(teamId)},
  "userId": "U0000ZZZZ",
  "msg": ${JSON.stringify(msg)},
  "channel": ${JSON.stringify(channel)},
  "channelName": "[REDACTED]",${thread}
  "launchUri": "[REDACTED]",
  "silent": true,
  "hasReply": true,
  "groupWindowsNotifications": true,
  "trace_id": "{\\"traceId\\":\\"0123456789abcdef\\",\\"parentSpanId\\":\\"0123456789abcdef\\"}",
  "id": "T0000AAAA_1790000000.000100",
  "sound": "none",
  "win32": {
    "workspaceName": "Example",
    "useComActivation": false
  },
  "mac": {
    "closeButtonOverride": false
  }
}
[${stamp}] info: Creating new Electron notification. 
[${stamp}] info: Store: SET_WINDOW_FRAME 
{
  "id": 1,
  "frame": {
    "x": 0
  }
}
`
}

const at = (y, mo, d, h, mi, s, ms) => new Date(y, mo - 1, d, h, mi, s, ms).getTime()

test("a channel message", () => {
  const log = entry("03/10/26, 09:15:31:630", { teamId: "T0000AAAA", channel: "C0000BBBB", msg: "1790000000.000200" })
  assert.strictEqual(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 31, 633)),
    "slack://channel?team=T0000AAAA&id=C0000BBBB&message=1790000000.000200")
})

test("a direct message in an Enterprise Grid org", () => {
  const log = entry("03/10/26, 09:15:31:630", { teamId: "E0000AAAA", channel: "D0000BBBB", msg: "1790000000.000200" })
  assert.strictEqual(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 31, 632)),
    "slack://channel?team=E0000AAAA&id=D0000BBBB&message=1790000000.000200")
})

test("a thread reply keeps its thread", () => {
  const log = entry("03/10/26, 09:15:31:630", {
    teamId: "T0000AAAA", channel: "C0000BBBB", msg: "1790000000.000200", thread_ts: "1790400000.000100" })
  assert.match(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 31, 631)), /&thread_ts=1790400000\.000100$/)
})

test("the nearest of two close entries wins, and nothing past a second", () => {
  const log =
    entry("03/10/26, 09:15:31:600", { teamId: "T0000AAAA", channel: "C0000FIRST", msg: "1790000000.000301" }) +
    entry("03/10/26, 09:15:31:640", { teamId: "T0000AAAA", channel: "C0000SECND", msg: "1790000000.000302" })
  assert.match(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 31, 642)), /id=C0000SECND/)
  assert.match(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 31, 601)), /id=C0000FIRST/)
  assert.strictEqual(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 33, 0)), "")
})

test("ids of the wrong shape make no link", () => {
  for (const fields of [
    { teamId: "T0000AAAA", channel: "C0000BBBB&id=x" },
    { teamId: "U0000AAAA", channel: "C0000BBBB" },
    { teamId: "T0000AAAA", channel: 42 },
  ]) {
    assert.strictEqual(SlackLink.resolve(entry("03/10/26, 09:15:31:630", fields), at(2026, 3, 10, 9, 15, 31, 630)), "")
  }
  const log = entry("03/10/26, 09:15:31:630", { teamId: "T0000AAAA", channel: "C0000BBBB", msg: "../../x" })
  assert.strictEqual(SlackLink.resolve(log, at(2026, 3, 10, 9, 15, 31, 630)), "slack://channel?team=T0000AAAA&id=C0000BBBB")
})

test("log stamps are local time, either side of a DST change", () => {
  const [winter] = SlackLink.parse(entry("01/15/26, 12:00:00:000", { teamId: "T0000AAAA", channel: "C0000BBBB" }))
  const [summer] = SlackLink.parse(entry("07/15/26, 12:00:00:000", { teamId: "T0000AAAA", channel: "C0000BBBB" }))
  assert.strictEqual(winter.atMs, Date.UTC(2026, 0, 15, 11))
  assert.strictEqual(summer.atMs, Date.UTC(2026, 6, 15, 10))
})

test("an entry cut off at the end of the file is skipped", () => {
  const whole = entry("03/10/26, 09:15:31:630", { teamId: "T0000AAAA", channel: "C0000BBBB" })
  const cut = entry("03/10/26, 09:15:31:900", { teamId: "T0000AAAA", channel: "C0000CCCC" }).slice(0, 120)
  assert.strictEqual(SlackLink.parse(whole + cut).length, 1)
  assert.match(SlackLink.resolve(whole + cut, at(2026, 3, 10, 9, 15, 31, 900)), /id=C0000BBBB/)
})
