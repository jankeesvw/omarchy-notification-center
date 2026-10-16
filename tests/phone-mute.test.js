// node --test
const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// The module is a QML JavaScript library; minus its pragma it is plain script.
const source = fs.readFileSync(path.join(__dirname, "../lib/PhoneMute.js"), "utf8")
const PhoneMute = vm.createContext({})
vm.runInContext(source.replace(/^\.pragma library$/m, ""), PhoneMute)

const NOW = Date.UTC(2026, 2, 10, 9, 15, 31)

// Archive entries as bin/notification-center prints them. Made-up content.
function entry(app, extra = {}) {
  return {
    key: `${NOW}-7`,
    app,
    appIcon: "",
    summary: "Example sender",
    body: "Example message",
    timestamp: NOW,
    ...extra,
  }
}

test("the bridges are recognised by the names they send under", () => {
  for (const app of ["KDE Connect", "KDEConnect", "kdeconnect", "GSConnect", "Valent"])
    assert.ok(PhoneMute.isPhone(entry(app)), app)
})

test("a translated KDE Connect is recognised by its icon", () => {
  assert.ok(PhoneMute.isPhone(entry("Connexion KDE", { appIcon: "kdeconnect" })))
})

test("desktop notifications are not phone notifications", () => {
  for (const app of ["Slack", "Firefox", "notify-send", "omarchy-action", "Telegram Desktop", "", "Connect"])
    assert.ok(!PhoneMute.isPhone(entry(app)), JSON.stringify(app))
  assert.ok(!PhoneMute.isPhone(null))
})

test("a picture path is not mistaken for an icon name", () => {
  assert.ok(!PhoneMute.isPhone(entry("Example", { appIcon: "file:///tmp/kdeconnect" })))
  assert.ok(!PhoneMute.isPhone(entry("Example", { appIcon: "/usr/share/icons/kdeconnect" })))
})

test("the setting replaces the default list", () => {
  const apps = PhoneMute.parseApps("My Phone Bridge,\n  another-bridge ")
  assert.deepStrictEqual([...apps], ["myphonebridge", "anotherbridge"])
  assert.ok(PhoneMute.isPhone(entry("my.phone.bridge"), apps))
  assert.ok(!PhoneMute.isPhone(entry("KDE Connect"), apps))
})

test("an empty setting falls back to the default list", () => {
  for (const blank of ["", " , ", null, undefined])
    assert.ok(PhoneMute.isPhone(entry("KDE Connect"), PhoneMute.parseApps(blank)), String(blank))
})

test("the manifest default is the library default", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "../manifest.json"), "utf8"))
  const field = manifest.barWidget.schema.find((f) => f.key === "phoneApps")
  assert.strictEqual(manifest.barWidget.defaults.phoneApps, PhoneMute.DEFAULT_APPS)
  assert.strictEqual(field.defaultValue, PhoneMute.DEFAULT_APPS)
})

test("only a fresh phone toast is taken down, and only while muted", () => {
  const apps = PhoneMute.parseApps(PhoneMute.DEFAULT_APPS)
  const phone = entry("KDE Connect")
  assert.ok(PhoneMute.shouldSilence(phone, true, false, apps, NOW + 200))
  assert.ok(!PhoneMute.shouldSilence(phone, false, false, apps, NOW + 200), "not muted")
  assert.ok(!PhoneMute.shouldSilence(phone, true, true, apps, NOW + 200), "DND already kept it off screen")
  assert.ok(!PhoneMute.shouldSilence(phone, true, false, apps, NOW + 31000), "toast long gone")
  assert.ok(!PhoneMute.shouldSilence(entry("KDE Connect", { summary: "" }), true, false, apps, NOW), "no summary to address")
})

test("muting the phone leaves desktop notifications alone", () => {
  const apps = PhoneMute.parseApps(PhoneMute.DEFAULT_APPS)
  for (const app of ["Slack", "Firefox", "notify-send", "omarchy-action"])
    assert.ok(!PhoneMute.shouldSilence(entry(app), true, false, apps, NOW + 200), app)
})

test("the switch is offered once a phone notification has been kept", () => {
  assert.ok(PhoneMute.anyPhone([entry("Slack"), entry("GSConnect")]))
  assert.ok(!PhoneMute.anyPhone([entry("Slack"), entry("Firefox")]))
  assert.ok(!PhoneMute.anyPhone([]))
})

test("a bridge daemon on the session bus is found by its well-known name", () => {
  const bus = [
    "org.freedesktop.DBus                 1 systemd         user  -  -  -",
    "org.freedesktop.Notifications     4242 quickshell      user  :1.7  -  -",
    "org.kde.kdeconnect                4343 kdeconnectd     user  :1.9  -  -",
  ].join("\n")
  assert.ok(PhoneMute.busHasBridge(bus))
  assert.ok(PhoneMute.busHasBridge("ca.andyholmes.Valent 1 valent user :1.2 - -"))
  assert.ok(!PhoneMute.busHasBridge("org.freedesktop.DBus 1 x\norg.kde.kdeconnectx 2 y"))
  assert.ok(!PhoneMute.busHasBridge(""))
})

test("the mute state survives a round trip, and a bad file reads as unmuted", () => {
  assert.strictEqual(PhoneMute.parseState(PhoneMute.serializeState(true)).muted, true)
  assert.strictEqual(PhoneMute.parseState(PhoneMute.serializeState(false)).muted, false)
  for (const bad of ["", "{", "null", "[]", '{"muted":"yes"}'])
    assert.strictEqual(PhoneMute.parseState(bad).muted, false, bad)
})
