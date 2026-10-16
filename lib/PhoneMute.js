.pragma library

// Muting the phone without muting the desktop.
//
// A phone bridge (KDE Connect, GSConnect, Valent) mirrors every notification
// the phone gets onto the desktop, which is welcome right up until the phone is
// on the desk beside you buzzing about the same thing. Do Not Disturb is the
// wrong tool for that: it silences the calendar and the build along with it.
//
// Every one of these bridges sends its notifications under its own name, so
// the name is how a phone notification is told apart. Nothing about the device
// is needed or looked at.

// The names the bridges send their notifications under, and the ids they go by
// elsewhere. Compared with case, spaces and punctuation ignored, so
// "KDE Connect", "KDEConnect" and "kdeconnect" are one name.
//
//   KDE Connect  app name is the translated "Name" from kdeconnect.notifyrc,
//                usually "KDE Connect"; the icon is "kdeconnect" whatever the
//                language, which is what catches the translations.
//   GSConnect    GLib.set_application_name('GSConnect') in its daemon.
//   Valent       g_set_application_name("Valent") in its main.c.
var DEFAULT_APPS = "KDE Connect, org.kde.kdeconnect.daemon, GSConnect, org.gnome.Shell.Extensions.GSConnect, Valent, ca.andyholmes.Valent"

// Session bus names the bridge daemons own while they are running. One of
// these on the bus is reason enough to offer the switch before the first
// notification from the phone has arrived.
var BUS_NAMES = ["org.kde.kdeconnect", "org.gnome.Shell.Extensions.GSConnect", "ca.andyholmes.Valent"]

// The longest a toast stays up in Omarchy before expiring on its own. An
// entry older than this has no toast left to take down.
var MAX_POPUP_MS = 30000

function normalize(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "")
}

// The setting is one string, names separated by commas or newlines. Left empty
// it falls back to the defaults rather than matching nothing: a switch that
// silently stops working is worse than one that ignores a blank field.
function parseApps(setting) {
  var parts = Array.isArray(setting) ? setting : String(setting || "").split(/[,\n]/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var name = normalize(parts[i])
    if (name !== "" && out.indexOf(name) === -1) out.push(name)
  }
  return out.length > 0 ? out : parseApps(DEFAULT_APPS)
}

// A themed icon name is compared like an app name; a path or URL is a picture
// the sender chose and says nothing about who sent it.
function iconName(value) {
  var s = String(value || "")
  return /[\/:]/.test(s) ? "" : normalize(s)
}

function isPhone(entry, apps) {
  if (!entry) return false
  var names = apps || parseApps(DEFAULT_APPS)
  var app = normalize(entry.app)
  var icon = iconName(entry.appIcon)
  for (var i = 0; i < names.length; i++) {
    if (names[i] === app) return true
    if (icon !== "" && names[i] === icon) return true
  }
  return false
}

function anyPhone(entries, apps) {
  var list = entries || []
  for (var i = 0; i < list.length; i++)
    if (isPhone(list[i], apps)) return true
  return false
}

// `busctl --user list --acquired --no-legend`: one name per line, first column.
function busHasBridge(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var name = lines[i].trim().split(/\s+/)[0]
    if (BUS_NAMES.indexOf(name) !== -1) return true
  }
  return false
}

// Whether this archived entry is a phone toast that is still on screen and
// should be taken off it. Under Do Not Disturb nothing reached the screen in
// the first place, and an entry past the longest toast lifetime has already
// gone by itself. The toast is addressed by its summary, so one without a
// summary cannot be addressed at all.
function shouldSilence(entry, muted, dnd, apps, now) {
  if (!muted || dnd || !entry) return false
  if (String(entry.summary || "") === "") return false
  if (!isPhone(entry, apps)) return false
  var age = Number(now) - Number(entry.timestamp || 0)
  return age > -5000 && age < MAX_POPUP_MS
}

function parseState(text) {
  try {
    var data = JSON.parse(String(text || ""))
    return { muted: !!(data && data.muted === true) }
  } catch (e) {
    return { muted: false }
  }
}

function serializeState(muted) {
  return JSON.stringify({ muted: !!muted }) + "\n"
}
