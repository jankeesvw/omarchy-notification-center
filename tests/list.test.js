// node --test
const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const cli = path.join(__dirname, "../bin/notification-center")
const hasJq = (() => {
  try { execFileSync("jq", ["--version"]); return true } catch (e) { return false }
})()

// A scratch store with more entries than the limits below. Made-up content.
function store(count) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nc-list-"))
  const lines = []
  for (let i = 1; i <= count; i++)
    lines.push(JSON.stringify({ key: `${1700000000000 + i}-1`, app: "Example", summary: `s${i}`, body: "b", timestamp: 1700000000000 + i }))
  fs.writeFileSync(path.join(dir, "archive.jsonl"), lines.join("\n") + "\n")
  return dir
}

function list(dir, ...args) {
  return execFileSync(cli, ["list", ...args], { env: { ...process.env, NC_STORE: dir }, stdio: ["ignore", "pipe", "ignore"] }).toString()
}

// Service.qml parses this with JSON.parse, so it has to be one array and
// nothing after it, also when there is more in the archive than the limit.
test("list prints exactly one array", { skip: !hasJq && "jq is not installed" }, () => {
  const dir = store(600)
  try {
    assert.strictEqual(JSON.parse(list(dir, "3")).length, 3)
    assert.strictEqual(JSON.parse(list(dir)).length, 200)
    assert.strictEqual(JSON.parse(list(dir, "1000")).length, 600)
    assert.deepStrictEqual(JSON.parse(list(dir, "0")), [])
    assert.deepStrictEqual(JSON.parse(list(dir, "abc")), [])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
