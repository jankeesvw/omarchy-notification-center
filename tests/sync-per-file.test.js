// node --test
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { fixture, available } = require("./notification-fixture")
const skip = !available("jq")

test("the per-file layout is still archived", { skip }, t => {
  const f = fixture(t)
  fs.writeFileSync(path.join(f.history, "1793000000000-7.json"), JSON.stringify({
    app: "Example", summary: "Older", exec: "xdg-open https://example.com/legacy"
  }))
  f.atomic("1793000005000-8.json", { timestamp: 1793000005000, summary: "Popup" })
  assert.deepEqual(f.run("sync"), { ok: true, synced: true })
  const rows = f.run("list")
  assert.deepEqual(rows.map(r => [r.key, r.timestamp]), [
    ["1793000005000-8", 1793000005000], ["1793000000000-7", 1793000000000]
  ])
  assert.equal(rows[1].link, "https://example.com/legacy")
  assert.ok(rows.every(r => !Object.hasOwn(r, "exec")))
})

test("watch still archives a per-file popup moved into history", {
  skip: skip || !available("inotifywait") || !available("setpriv"), timeout: 20000
}, async t => {
  const f = fixture(t)
  const watcher = f.watch()
  await watcher.until("1793000000000-7", () => {
    const popup = path.join(f.root, "1793000000000-7.json")
    fs.writeFileSync(popup, JSON.stringify({ timestamp: 1793000000000, summary: "Moved" }))
    fs.renameSync(popup, path.join(f.history, "1793000000000-7.json"))
  })
  assert.deepEqual(watcher.entries().map(r => r.key), ["1793000000000-7"])
  assert.deepEqual(f.run("list").map(r => r.key), ["1793000000000-7"])
})

test("sync with no history.json is a no-op", { skip }, t => {
  const f = fixture(t)
  assert.deepEqual(f.run("sync"), { ok: true, synced: true })
  assert.deepEqual(f.run("list"), [])
})
