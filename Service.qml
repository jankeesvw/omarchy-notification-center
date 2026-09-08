import QtQuick
import Quickshell
import Quickshell.Io

// The archive, mounted once for the shell.
//
// Omarchy builds a bar per monitor. If the watcher and the in-memory list
// lived on the widget, each screen would have its own lastSeen and its own
// entries, and marking read or clearing on one would leave the other as it
// was. The on-disk store is already shared; this is the QML owner of the
// processes that talk to it.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  property int keepDays: 30
  property int maxItems: 1000
  property bool showPreview: true
  property int pageSize: 500

  property var entries: []
  property double lastSeen: 0
  property bool loaded: false

  readonly property bool watching: watchProc.running

  readonly property int unread: {
    var count = 0
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].timestamp > lastSeen) count++
      else break
    }
    return count
  }

  readonly property string script:
    Qt.resolvedUrl("bin/notification-center").toString().replace(/^file:\/\//, "")

  readonly property var storeEnvironment: ({
    "NC_KEEP_DAYS": String(root.keepDays),
    "NC_MAX_ITEMS": String(root.maxItems),
    "NC_PREVIEWS": root.showPreview ? "1" : "0"
  })

  signal entryAdded(var entry)
  signal entriesReset()

  // ------------------------------------------------------------- doing things
  //
  // A notification is not only something to read. The toast it arrived as
  // carried buttons, and for anything KDE Connect relayed from the phone
  // those buttons still work long after the toast is gone: the phone keeps
  // the notification, and kdeconnectd keeps a handle to it. This half of the
  // service keeps enough to press them from the panel.
  //
  // Two sources, in the order they stop being available:
  //
  //  - The live toast. Omarchy's notification service holds the server
  //    object in `liveRefs` until the toast leaves the screen. While the
  //    archive is picking the file up, that object is still there, so its
  //    button labels are copied out here, keyed by the archive key. Labels
  //    are all KDE Connect needs later: the phone matches a button by its
  //    text.
  //  - The phone. `phone list` asks kdeconnectd what is still showing, and
  //    each of those is matched back to an archived entry by app and text.
  //    That match is what carries a press, a reply or a dismiss to the phone.

  property var notificationService: null
  // key -> { buttons: [label...], inlineReply: bool }, from the toast.
  property var liveActions: ({})
  // key -> the toast's server object, dropped when it closes.
  property var liveRefs: ({})
  // What `phone list` last said.
  property var phone: []
  // key -> the phone notification standing for that entry.
  property var phoneByKey: ({})
  // Bumped whenever any of the above changes, so a row can re-read.
  property int actionsVersion: 0
  // Whether a panel is open: the phone is polled only while someone looks.
  property bool watchingPhone: false

  function resolveNotificationService() {
    if (notificationService) return notificationService
    var host = root.shell
    if (!host || typeof host.serviceFor !== "function") return null
    var id = "omarchy.notifications"
    var registry = root.pluginRegistry || host.pluginRegistry
    if (registry && typeof registry.resolveEnabledId === "function")
      id = registry.resolveEnabledId(id)
    notificationService = host.serviceFor(id)
    return notificationService
  }

  function originalIdOf(key) {
    var parts = String(key || "").split("-")
    return parts.length === 2 ? Number(parts[1]) : -1
  }

  // Copy the toast's buttons while the toast still exists. The archive key
  // ends in the server's id for the notification, which is only meaningful
  // for this generation of the server, so the object it resolves to is
  // checked against the entry before anything is taken from it.
  function captureLive(entry) {
    var svc = resolveNotificationService()
    if (!svc || !svc.liveRefs) return
    var id = originalIdOf(entry.key)
    if (id < 0) return
    var ref = svc.liveRefs[id]
    if (!ref) return
    var buttons = []
    var inlineReply = false
    try {
      if (String(ref.appName || "") !== String(entry.app || "")) return
      if (String(ref.summary || "") !== String(entry.summary || "")) return
      inlineReply = !!ref.hasInlineReply
      var actions = ref.actions
      for (var i = 0; actions && i < actions.length; i++) {
        var action = actions[i]
        if (!action || action.identifier === "default") continue
        buttons.push(String(action.text || action.identifier || ""))
      }
    } catch (e) {
      return
    }
    var key = String(entry.key)
    var next = Object.assign({}, liveActions)
    next[key] = { buttons: buttons, inlineReply: inlineReply }
    liveActions = next
    var refs = Object.assign({}, liveRefs)
    refs[key] = ref
    liveRefs = refs
    try {
      ref.closed.connect(function() {
        if (root.liveRefs[key] === ref) {
          var after = Object.assign({}, root.liveRefs)
          delete after[key]
          root.liveRefs = after
          root.actionsVersion++
        }
      })
    } catch (e) {
    }
    actionsVersion++
  }

  // The freedesktop text is the phone's title and text run together, and
  // HTML-escaped on the way. Both sides are flattened to plain words before
  // they are compared.
  function flatten(text) {
    return String(text || "")
      .replace(/<[^>]+>/g, " ")
      .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
      .replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&apos;/g, "'")
      .replace(/\s+/g, " ")
      .trim()
  }

  function phoneMatches(entry, p) {
    if (String(entry.app || "") !== "KDE Connect") return false
    var summary = String(entry.summary || "")
    if (summary !== String(p.appName || "") && summary !== String(p.title || "")) return false
    var body = flatten(entry.body)
    var title = flatten(p.title), text = flatten(p.text)
    var candidates = [flatten(p.ticker), text, title, title + ": " + text, title + " " + text]
    for (var i = 0; i < candidates.length; i++)
      if (candidates[i] !== "" && candidates[i] === body) return true
    return false
  }

  // Pair every phone notification with the newest archived entry that reads
  // the same, each used once, so two identical messages get two cards with
  // a button each rather than one card that answers twice.
  function rebuildPhoneMap() {
    var map = {}
    var used = {}
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (String(entry.app || "") !== "KDE Connect") continue
      for (var j = 0; j < phone.length; j++) {
        var p = phone[j]
        if (used[p.id + "@" + p.device]) continue
        if (!phoneMatches(entry, p)) continue
        map[String(entry.key)] = p
        used[p.id + "@" + p.device] = true
        break
      }
    }
    phoneByKey = map
    actionsVersion++
  }

  // What a row can do right now. `version` is unused and only there so a
  // binding on it re-evaluates when actionsVersion moves.
  function actionsFor(entry, version) {
    var key = String(entry && entry.key || "")
    var live = liveActions[key] || null
    var ref = liveRefs[key] || null
    var p = phoneByKey[key] || null
    var buttons = []
    var canReply = !!(p && p.replyId)
    var labels = live ? live.buttons : []
    for (var i = 0; i < labels.length; i++) {
      // The phone answers through the reply field below, so the toast's
      // own "Reply" button would be a second door to the same room.
      if (canReply && /^reply$/i.test(labels[i])) continue
      if (ref || p) buttons.push({ kind: "action", label: labels[i], index: i })
    }
    if (canReply) buttons.push({ kind: "reply", label: "Reply", index: -1 })
    if (p && p.dismissable) buttons.push({ kind: "dismiss", label: "Clear on phone", index: -1 })
    return { buttons: buttons, canReply: canReply, onPhone: !!p }
  }

  function press(entry, button) {
    if (!entry || !button) return
    var key = String(entry.key)
    var p = phoneByKey[key] || null
    if (button.kind === "dismiss") {
      if (p) runPhone(["phone", "dismiss", p.device, p.id])
      return
    }
    if (button.kind !== "action") return
    // The toast, if it is still up: that reaches every app, not only the
    // phone, and for the phone it is the same packet kdeconnectd would send.
    var ref = liveRefs[key]
    if (ref) {
      try {
        var actions = ref.actions
        var seen = 0
        for (var i = 0; actions && i < actions.length; i++) {
          if (!actions[i] || actions[i].identifier === "default") continue
          if (seen++ === button.index) {
            actions[i].invoke()
            phoneRefresh.restart()
            return
          }
        }
      } catch (e) {
        // Torn down between the read and the click; fall through.
      }
    }
    if (p) runPhone(["phone", "action", p.device, p.internalId, button.label])
  }

  function reply(entry, text) {
    var p = phoneByKey[String(entry && entry.key || "")]
    var message = String(text || "").trim()
    if (!p || !p.replyId || message === "") return
    runPhone(["phone", "reply", p.device, p.id, message])
  }

  function runPhone(args) {
    Quickshell.execDetached(root.storeCommand(args))
    phoneRefresh.restart()
  }

  function refreshPhone() {
    if (phoneProc.running) return
    phoneProc.command = root.storeCommand(["phone", "list"])
    phoneProc.running = true
  }

  Process {
    id: phoneProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          return
        }
        if (!Array.isArray(data)) return
        root.phone = data
        root.rebuildPhoneMap()
      }
    }
  }

  // After a press: the phone needs a moment to drop the notification, and
  // kdeconnectd a moment to hear about it.
  Timer {
    id: phoneRefresh
    interval: 700
    onTriggered: root.refreshPhone()
  }

  Timer {
    interval: 10000
    running: root.watchingPhone
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshPhone()
  }

  onEntriesReset: rebuildPhoneMap()

  function storeCommand(args) {
    return [root.script].concat(args)
  }

  function differsFrom(data) {
    if (data.length !== entries.length) return true
    if (data.length === 0) return false
    return String(data[0].key) !== String(entries[0].key)
  }

  function load() {
    if (listProc.running) return
    listProc.command = root.storeCommand(["list", String(root.pageSize)])
    listProc.running = true
  }

  function readSeen() {
    if (seenProc.running) return
    seenProc.command = root.storeCommand(["seen"])
    seenProc.running = true
  }

  function markSeen() {
    var stamp = Date.now()
    root.lastSeen = stamp
    if (markProc.running) return
    markProc.command = root.storeCommand(["seen", String(stamp)])
    markProc.running = true
  }

  function remove(key) {
    if (!key) return
    var next = []
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key !== key) next.push(entries[i])
    entries = next
    entriesReset()
    Quickshell.execDetached(root.storeCommand(["remove", String(key)]))
  }

  // Detached, like remove and seed above it: a clear that arrives while the
  // previous one is still running used to return early and never happen, so
  // the list came back on the next sync and the button looked broken.
  function clearAll() {
    entries = []
    entriesReset()
    Quickshell.execDetached(root.storeCommand(["clear"]))
  }

  function absorb(line) {
    var entry
    try {
      entry = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!entry || !entry.key) return
    // close_write and moved_to both fire for one popup; the second is dropped
    // by key. One watcher for the shell, so this is no longer a per-screen race.
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key === entry.key) return

    var next = [entry].concat(entries)
    if (next.length > pageSize) next = next.slice(0, pageSize)
    entries = next
    captureLive(entry)
    if (String(entry.app || "") === "KDE Connect") phoneRefresh.restart()
    else rebuildPhoneMap()
    entryAdded(entry)
  }

  Process {
    id: watchProc
    command: root.storeCommand(["watch"])
    environment: root.storeEnvironment
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    onExited: restartWatch.restart()
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: if (!watchProc.running) watchProc.running = true
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.load()
  }

  Process {
    id: listProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          return
        }
        if (!Array.isArray(data)) return
        var wasLoaded = root.loaded
        root.loaded = true
        if (wasLoaded && !root.differsFrom(data)) return
        root.entries = data
        root.entriesReset()
      }
    }
  }

  Process {
    id: seenProc
    environment: root.storeEnvironment
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) root.lastSeen = Number(data.seen) || 0
        } catch (e) {
        }
      }
    }
  }

  Process { id: markProc; environment: root.storeEnvironment }

  Component.onCompleted: {
    readSeen()
    load()
  }

  IpcHandler {
    target: "jankeesvw.notification-center.test"

    function seed(count: int): string {
      Quickshell.execDetached(root.storeCommand(["seed", String(count > 0 ? count : 25)]))
      reloadAfterSeed.restart()
      return "seeding " + count
    }

    function clear(): string {
      root.clearAll()
      return "cleared"
    }

    function reload(): string {
      root.load()
      return "reloading"
    }

    // Press the newest entry's Nth button, as a click on the card would.
    function press(index: int): string {
      if (root.entries.length === 0) return "nothing to press"
      var entry = root.entries[0]
      var offer = root.actionsFor(entry, root.actionsVersion)
      var button = offer.buttons[index]
      if (!button) return "no button " + index + " on " + JSON.stringify(offer)
      root.press(entry, button)
      return "pressed " + button.label
    }

    function state(): string {
      return JSON.stringify({
        entries: root.entries.length,
        newest: root.entries.length > 0 ? root.entries[0].summary : "",
        unread: root.unread,
        watching: watchProc.running,
        loaded: root.loaded,
        lastSeen: root.lastSeen,
        phone: root.phone.length,
        matched: Object.keys(root.phoneByKey).length,
        live: Object.keys(root.liveActions).length
      })
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }
}
