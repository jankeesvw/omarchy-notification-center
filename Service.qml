import QtQuick
import Quickshell
import Quickshell.Io
import "components/WebApps.js" as WebApps

import "Store.js" as Store
import "lib/PhoneMute.js" as PhoneMute

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

  property string phoneApps: PhoneMute.DEFAULT_APPS

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

  // ------------------------------------------------------- phone mute
  //
  // Notifications mirrored from a phone, muted on their own, with Do Not
  // Disturb left as it is. The notification service gives a plugin no say over
  // which toasts it shows, so this works after the fact: the archive below
  // sees every toast the moment the service writes it to disk, and a phone one
  // is taken straight back off the screen over the service's own IPC. It is
  // archived first, so a muted notification is still in the panel. Closing a
  // toast does not reach the phone: KDE Connect only dismisses on the phone
  // when asked through its own D-Bus method, and GSConnect and Valent send
  // through GNotification, which never tells an app its notification closed.
  property bool phoneMuted: false
  property bool phoneBridgeOnBus: false
  readonly property var phoneAppList: PhoneMute.parseApps(root.phoneApps)
  readonly property bool phoneBridgeSeen: PhoneMute.anyPhone(root.entries, root.phoneAppList)
  // Kept showing while muted, whatever else is true, or there would be no
  // way back from it.
  readonly property bool phoneAvailable: phoneMuted || phoneBridgeOnBus || phoneBridgeSeen

  // The IPC route to the notification service, a property so a test harness
  // can point it at something that is not the running shell.
  property var notificationsIpc: ["omarchy-shell", "notifications"]

  readonly property string phoneStatePath:
    (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy-notification-center/phone.json"

  function setPhoneMuted(value) {
    root.phoneMuted = !!value
    phoneState.setText(PhoneMute.serializeState(root.phoneMuted))
  }

  function silencePhoneToast(entry) {
    if (!PhoneMute.shouldSilence(entry, root.phoneMuted, dndBridge.doNotDisturb,
                                 root.phoneAppList, Date.now()))
      return false
    Quickshell.execDetached(root.notificationsIpc.concat(["dismiss", String(entry.summary)]))
    return true
  }

  FileView {
    id: phoneState
    path: root.phoneStatePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.phoneMuted = PhoneMute.parseState(text()).muted
  }

  // Only the bridges' own well-known names, from the list of names already
  // owned on the bus; nothing is asked of the bridge itself.
  Process {
    id: busProc
    command: ["busctl", "--user", "list", "--acquired", "--no-legend", "--no-pager"]
    stdout: StdioCollector {
      onStreamFinished: root.phoneBridgeOnBus = PhoneMute.busHasBridge(text)
    }
  }

  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!busProc.running) busProc.running = true
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
    silencePhoneToast(entry)
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
        dnd: dndBridge.doNotDisturb,
        phoneMuted: root.phoneMuted,
        phoneAvailable: root.phoneAvailable
      })
    }
  }

  // For a key binding, the way `notifications toggleDnd` is for the bell.
  IpcHandler {
    target: "jankeesvw.notification-center.phone"

    function state(): string {
      return root.phoneMuted ? "muted" : "unmuted"
    }

    function toggle(): string {
      root.setPhoneMuted(!root.phoneMuted)
      return state()
    }

    function set(value: string): string {
      var v = String(value || "").toLowerCase()
      root.setPhoneMuted(v === "on" || v === "true" || v === "1" || v === "yes" || v === "muted")
      return state()
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }

  // The origin-to-web-app index a row looks icons up in is a snapshot of the
  // desktop entries, so it is thrown away whenever an app is installed,
  // removed, or edited. Here rather than on the row for the same reason the
  // watcher is: one index for the shell, not one per monitor.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { WebApps.reset() }
  }
}
