// node --test
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync, spawn, spawnSync } = require("node:child_process")
const { createHash } = require("node:crypto")
const assert = require("node:assert/strict")
const available = name => spawnSync("bash", ["-c", "command -v -- \"$1\"", "bash", name]).status === 0
const cli = path.resolve(__dirname, "../bin/notification-center")
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
// Every CLI invocation uses synthetic sources and a private scratch archive.
// Long retention keeps fixed timestamps valid without touching the real store.
function fixture(t, overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "nc-test-"))
  const src = path.join(root, "src")
  const history = path.join(src, "history")
  const store = path.join(root, "store")
  fs.mkdirSync(history, { recursive: true })
  const env = { ...process.env, NC_SRC_DIR: src, NC_SRC_HISTORY: history,
    NC_STORE: store, NC_KEEP_DAYS: "36500", ...overrides }
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const run = (...args) => JSON.parse(execFileSync(cli, args, { env, encoding: "utf8", timeout: 15000 }))
  // Qt replaces aggregate files with a rename rather than writing them in place.
  const atomic = (name, value) => {
    const target = path.join(src, name)
    fs.writeFileSync(`${target}.tmp`, JSON.stringify(value))
    fs.renameSync(`${target}.tmp`, target)
  }
  const hash = file => createHash("sha256").update(fs.readFileSync(file)).digest("hex")
  const watch = () => {
    const child = spawn(cli, ["watch"], { env, detached: true, stdio: ["ignore", "pipe", "pipe"] })
    let output = "", errors = ""
    child.stdout.on("data", chunk => { output += chunk })
    child.stderr.on("data", chunk => { errors += chunk })
    const closed = new Promise(resolve => child.once("close", resolve))
    // Stop the detached process group, including inotifywait, before finishing.
    t.after(async () => {
      try { process.kill(-child.pid, "SIGTERM") } catch (e) { if (e.code !== "ESRCH") throw e }
      await closed
    })
    const entries = () => output.split("\n").filter(Boolean).map(line => JSON.parse(line))
    // The watcher may still be starting. Repeat idempotent rewrites until the
    // public stdout stream confirms ingestion instead of assuming a ready time.
    const until = async (key, rewrite = () => {}) => {
      const deadline = Date.now() + 10000
      while (Date.now() < deadline) {
        if (entries().some(row => row.key === key)) return
        assert.equal(child.exitCode, null, errors)
        rewrite()
        await delay(200)
      }
      assert.fail(`watch did not print ${key}: ${output} ${errors}`)
    }
    return { entries, until }
  }
  return { root, src, history, store, run, atomic, hash, watch }
}
module.exports = { fixture, available }
