// node --test
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { spawn } = require("node:child_process")
const { fixture, available } = require("./notification-fixture")
const skip = !available("jq") || !available("inotifywait") || !available("setpriv")
const cli = path.resolve(__dirname, "../bin/notification-center")
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const alive = pid => {
  try { return !/^\d+ \(.*\) Z/.test(fs.readFileSync(`/proc/${pid}/stat`, "utf8")) } catch { return false }
}
const children = pid => {
  try {
    return fs.readdirSync(`/proc/${pid}/task`).flatMap(task =>
      fs.readFileSync(`/proc/${pid}/task/${task}/children`, "utf8").split(" ").filter(Boolean).map(Number))
  } catch { return [] }
}

test("Service.qml starts watch under setpriv --pdeathsig TERM", () => {
  const service = fs.readFileSync(path.join(__dirname, "../Service.qml"), "utf8")
  assert.match(service,
    /id: watchProc\n(?:\s*\/\/.*\n)*\s*command: \["setpriv", "--pdeathsig", "TERM"\]\.concat\(root\.storeCommand\(\["watch"\]\)\)/)
})

test("watch started that way ends, with its inotifywait, when the shell is SIGKILLed", {
  skip, timeout: 20000
}, async t => {
  const f = fixture(t)
  const env = { ...process.env, NC_SRC_DIR: f.src, NC_SRC_HISTORY: f.history, NC_STORE: f.store,
    NC_KEEP_DAYS: "36500" }
  // A stand-in for the shell: it starts watch the way Service.qml does and
  // reports its pid, then waits on it.
  const shell = spawn("bash", ["-c", 'setpriv --pdeathsig TERM "$1" watch > /dev/null & echo $!; wait',
    "bash", cli], { env, stdio: ["ignore", "pipe", "ignore"] })
  const watchPid = Number(await new Promise(resolve => shell.stdout.once("data", resolve)))
  let pids = [watchPid]
  t.after(() => { for (const pid of pids) try { process.kill(pid, "SIGKILL") } catch {} })

  let deadline = Date.now() + 10000
  while (!children(watchPid).length && Date.now() < deadline) await delay(100)
  pids = [watchPid, ...children(watchPid)]
  assert.ok(pids.length > 1, "watch did not start its inotifywait")

  shell.kill("SIGKILL")
  deadline = Date.now() + 5000
  while (pids.some(alive) && Date.now() < deadline) await delay(100)
  assert.deepEqual(pids.filter(alive), [])
})
