import QtQuick
import Quickshell
import Quickshell.Io
import "components/AppIcons.js" as AppIcons

import "Store.js" as Store

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

  // Do Not Disturb, for panels the shell gives no route to
  // omarchy.notifications: a third-party entry is only handed its own service.
  // Read from the state file that service writes back on every change, and set
  // through its IPC target, so a toggle from anywhere else shows up here too.
  readonly property QtObject notifications: dndBridge

  QtObject {
    id: dndBridge
    property bool doNotDisturb: false

    function setDoNotDisturb(value) {
      doNotDisturb = !!value
      Quickshell.execDetached(["omarchy-shell", "notifications", "setDnd", value ? "on" : "off"])
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        dndBridge.doNotDisturb = JSON.parse(text()).dnd === true
      } catch (e) {
      }
    }
  }

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
    Store.set(root)
    readSeen()
    load()
  }

  Component.onDestruction: Store.clear(root)

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

    function state(): string {
      return JSON.stringify({
        entries: root.entries.length,
        newest: root.entries.length > 0 ? root.entries[0].summary : "",
        unread: root.unread,
        watching: watchProc.running,
        loaded: root.loaded,
        lastSeen: root.lastSeen,
        dnd: dndBridge.doNotDisturb
      })
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }

  // The name-to-icon index a row falls back on is a snapshot of the desktop
  // entries, so it is thrown away whenever an app is installed or removed.
  // Here rather than on the row, for the same reason the watcher is: one
  // index for the shell, not one per monitor.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { AppIcons.reset() }
  }
}
