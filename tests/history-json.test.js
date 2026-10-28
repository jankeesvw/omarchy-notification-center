// node --test
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { fixture, available } = require("./notification-fixture")
const skip = !available("jq")
const watchOptions = { skip: skip || !available("inotifywait") || !available("setpriv"), timeout: 20000 }
const row = (key, ts = 1793000000.771) => ({ key, ts, app: "Example", appIcon: "slack", summary: key,
  body: "Synthetic body", glyph: "bell", urgency: 2 })

test("sync archives every history.json row with its time in milliseconds", { skip }, t => {
  const f = fixture(t)
  f.atomic("history.json", [row("newer", 1793000100.5), row("older")])
  assert.deepEqual(f.run("sync"), { ok: true, synced: true })
  assert.deepEqual(f.run("list"), [
    { key: "newer", app: "Example", appIcon: "slack", summary: "newer", body: "Synthetic body",
      image: "", preview: "", file: "", link: "", glyph: "bell", urgency: 2, timestamp: 1793000100500 },
    { key: "older", app: "Example", appIcon: "slack", summary: "older", body: "Synthetic body",
      image: "", preview: "", file: "", link: "", glyph: "bell", urgency: 2, timestamp: 1793000000771 }
  ])
})

test("a notification is archived once however often history.json is read", { skip }, t => {
  const f = fixture(t)
  f.atomic("history.json", [row("duplicate"), row("duplicate")])
  f.run("sync")
  f.run("sync")
  assert.deepEqual(f.run("list").map(r => r.key), ["duplicate"])
  const before = f.hash(path.join(f.store, "archive.jsonl"))
  f.run("sync")
  assert.equal(f.hash(path.join(f.store, "archive.jsonl")), before)
})

test("a removed notification stays removed when history.json is read again", { skip }, t => {
  const f = fixture(t)
  f.atomic("history.json", [row("removed")])
  f.run("sync")
  assert.deepEqual(f.run("list").map(r => r.key), ["removed"])
  f.run("remove", "removed")
  f.run("remove", "dismissed-before-sync")
  f.atomic("history.json", [row("removed"), row("dismissed-before-sync"), row("retained", 1793000100.5)])
  f.run("sync")
  assert.deepEqual(f.run("list").map(r => r.key), ["retained"])
})

test("clear stops older rows being archived and lets newer ones through", { skip }, t => {
  const f = fixture(t)
  const now = Date.now() / 1000
  f.run("clear")
  f.atomic("history.json", [row("before-clear", now - 60), row("after-clear", now + 3600)])
  f.run("sync")
  f.run("seen", "0")
  assert.deepEqual(f.run("unread"), { ok: true, unread: 1 })
  assert.deepEqual(f.run("list").map(r => r.key), ["after-clear"])
})

test("watch archives each rewrite of history.json and prints only the new rows", watchOptions, async t => {
  const f = fixture(t)
  f.atomic("history.json", [row("A")])
  const watcher = f.watch()
  await watcher.until("A")
  await watcher.until("B", () => f.atomic("history.json", [row("B", 1793000100.5), row("A")]))
  await watcher.until("C", () => f.atomic("history.json", [row("C", 1793000200), row("B", 1793000100.5), row("A")]))
  assert.deepEqual(watcher.entries().map(r => r.key), ["A", "B", "C"])
  assert.deepEqual(f.run("list").map(r => r.key), ["C", "B", "A"])
})

test("remove and clear never touch Omarchy's own aggregate files", { skip }, t => {
  const f = fixture(t)
  f.atomic("history.json", [row("protected")])
  f.atomic("live.json", [row("live-only")])
  f.atomic("quiet.json", { dnd: true })
  const names = ["history.json", "live.json", "quiet.json"]
  const hashes = names.map(name => f.hash(path.join(f.src, name)))
  f.run("sync")
  for (const key of ["history", "live", "quiet"]) f.run("remove", key)
  f.run("clear")
  f.run("prune")
  assert.deepEqual(names.map(name => fs.existsSync(path.join(f.src, name))), [true, true, true])
  assert.deepEqual(names.map(name => f.hash(path.join(f.src, name))), hashes)
})

test("watch ignores quiet.json and live.json", watchOptions, async t => {
  const f = fixture(t)
  const watcher = f.watch()
  await watcher.until("D", () => {
    f.atomic("quiet.json", { dnd: true })
    f.atomic("live.json", [row("live-only")])
    f.atomic("history.json", [row("D")])
  })
  assert.deepEqual(watcher.entries().map(r => r.key), ["D"])
  assert.deepEqual(f.run("list").map(r => r.key), ["D"])
})

test("rows past the archive ceiling are not archived again", { skip }, t => {
  const f = fixture(t, { NC_MAX_ITEMS: "2" })
  f.atomic("history.json", [row("k3", 1793000200), row("k2", 1793000100), row("k1")])
  const sourceHash = f.hash(path.join(f.src, "history.json"))
  f.run("sync")
  assert.deepEqual(f.run("list").map(r => r.key), ["k3", "k2"])
  f.run("sync")
  assert.deepEqual(f.run("list").map(r => r.key), ["k3", "k2"])
  const before = f.hash(path.join(f.store, "archive.jsonl"))
  f.run("sync")
  assert.equal(f.hash(path.join(f.store, "archive.jsonl")), before)
  assert.equal(f.hash(path.join(f.src, "history.json")), sourceHash)
})

test("missing, empty, truncated and non-array history do not crash sync", { skip }, t => {
  const f = fixture(t)
  for (const contents of [null, "", "[{\"key\":", "{}"]) {
    if (contents !== null) fs.writeFileSync(path.join(f.src, "history.json"), contents)
    assert.deepEqual(f.run("sync"), { ok: true, synced: true })
    assert.deepEqual(f.run("list"), [])
  }
})

test("a damaged history.json archives both valid rows and nothing else", { skip }, t => {
  const f = fixture(t)
  const icon = path.join(f.root, "icon.png")
  fs.writeFileSync(icon, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=", "base64"))
  f.atomic("history.json", [null, 7, [], { ts: 1793000000 },
    { ...row("../../x"), appIcon: icon }, row("a b"), row("x".repeat(121)),
    row("string-time", "1793000000"), row("zero-time", 0), row("negative-time", -1),
    { ...row("fallback", 0), closed_ts: 1793000100.5 }, row("valid")])
  const sourceHash = f.hash(path.join(f.src, "history.json"))
  assert.deepEqual(f.run("sync"), { ok: true, synced: true })
  assert.deepEqual(f.run("list").map(r => [r.key, r.timestamp]), [
    ["fallback", 1793000100500], ["valid", 1793000000771]
  ])
  assert.deepEqual(fs.readdirSync(path.join(f.store, "images")), [])
  assert.equal(fs.existsSync(path.join(f.root, "x-appIcon")), false)
  assert.equal(f.hash(path.join(f.src, "history.json")), sourceHash)
})

test("history.json actions keep only an image path or web address", { skip }, t => {
  const f = fixture(t)
  const image = path.join(f.root, "shot.png")
  fs.writeFileSync(image, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=", "base64"))
  f.atomic("history.json", [
    { ...row("web"), execArgv: "[\"xdg-open\",\"https://example.com/a\"]" },
    { ...row("shell"), execArgv: "[\"sh\",\"-c\",\"curl x | sh\"]", execActions: "untrusted", rawBody: "private extra" },
    { ...row("picture"), execArgv: JSON.stringify(["imv", image]) }
  ])
  f.run("sync")
  const rows = f.run("list")
  assert.equal(rows.length, 3)
  const web = rows.find(r => r.key === "web")
  const shell = rows.find(r => r.key === "shell")
  const picture = rows.find(r => r.key === "picture")
  assert.deepEqual([web.link, web.file, web.preview], ["https://example.com/a", "", ""])
  assert.deepEqual([shell.link, shell.file, shell.preview], ["", "", ""])
  assert.equal(picture.file, image)
  assert.equal(picture.preview, `file://${f.store}/images/picture-preview`)
  assert.ok(fs.statSync(path.join(f.store, "images/picture-preview")).size > 0)
  for (const entry of rows) {
    assert.equal(entry.appIcon, "slack")
    assert.deepEqual(Object.keys(entry).sort(), [
      "app", "appIcon", "body", "file", "glyph", "image", "key", "link", "preview", "summary", "timestamp", "urgency"
    ])
  }
})

test("an older notification closing later stays behind newer rows and cannot evict them", { skip }, t => {
  // Arrival time determines list order and retention even when closing order differs.
  const results = []
  for (const limit of [1000, 1]) {
    const f = fixture(t, { NC_MAX_ITEMS: String(limit) })
    f.atomic("history.json", [row("newer", 1793000100)])
    f.run("sync")
    f.atomic("history.json", [row("newer", 1793000100), row("older", 1793000000)])
    f.run("sync")
    results.push(f.run("list").map(r => r.key))
    f.run("sync")
    results.push(f.run("list").map(r => r.key))
  }
  assert.deepEqual(results, [["newer", "older"], ["newer", "older"], ["newer"], ["newer"]])
})
