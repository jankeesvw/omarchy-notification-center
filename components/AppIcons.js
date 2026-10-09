.pragma library

// Finding the icon of an app that sent none.
//
// app_icon is optional in the notification spec, and plenty of senders leave
// it empty: Solstice does, and so does anything going through libnotify 0.8,
// which stopped passing `notify-send -i` through as app_icon and moved it to
// a desktop-entry hint the service never reads. What those notifications do
// carry is app_name — and that name is almost always the Name= of a desktop
// entry sitting in /usr/share/applications, which knows perfectly well what
// the app looks like.
//
// So rather than draw a letter in a grey box, the name is looked up there.
// Matching is done on three keys per entry, because senders
// disagree about what app_name means: the display name ("Solstice"), the
// desktop id ("dev.deedles.Trayscale", whose Name= is "Trayscale"), and the
// startup WM class, which is what a sender reaching for "the app's
// identifier" tends to reach for.
//
// The index is built once and thrown away whenever the application set
// changes, so an app installed while the shell is running is found without a
// restart.

var index = null

function reset() {
  index = null
}

function add(map, key, entry) {
  var k = String(key || "").trim().toLowerCase()
  if (k.length === 0) return
  var existing = map[k]
  // First entry wins — two apps can share a startup class (a browser and its
  // web apps), and the one that named itself is the better guess. The one
  // exception is an entry that declares no icon at all, which anything with
  // one should outrank.
  if (existing === undefined || (existing.icon === "" && entry.icon !== "")) map[k] = entry
}

function build(entries) {
  var map = ({})
  var list = entries || []
  for (var i = 0; i < list.length; i++) {
    var source = list[i]
    if (!source) continue
    // Copied rather than kept by reference: this index outlives the delegate
    // that built it, and holding desktop-entry objects from it would keep
    // them alive past the point the shell drops them.
    var entry = {
      name: String(source.name || ""),
      id: String(source.id || ""),
      startupClass: String(source.startupClass || ""),
      icon: String(source.icon || "")
    }
    add(map, entry.name, entry)
    add(map, entry.id, entry)
    add(map, entry.startupClass, entry)
  }
  return map
}

// The desktop entry an app_name belongs to, or null when nothing claims it.
function entryFor(appName, entries) {
  var wanted = String(appName || "").trim().toLowerCase()
  if (wanted.length === 0) return null
  if (index === null) index = build(entries)
  if (index.hasOwnProperty(wanted)) return index[wanted]
  // "Google Chrome" against google-chrome.desktop, "Time Machine" against
  // time-machine: the space is the only thing between them.
  var hyphenated = wanted.replace(/\s+/g, "-")
  if (index.hasOwnProperty(hyphenated)) return index[hyphenated]
  return null
}

// The icon NAME for an app_name, or "" when nothing matches. Resolving that
// name to something drawable is the caller's job, because only the caller
// knows whether it wants a themed lookup or a file URL.
//
// No themed lookup on the name itself as a last resort: an unconstrained
// theme lookup happily resolves an app called "Mail" or "Zoom" to a stock
// action icon, and a confidently wrong face is worse than the initial the row
// falls back to.
function lookup(appName, entries) {
  var entry = entryFor(appName, entries)
  return entry === null ? "" : entry.icon
}
