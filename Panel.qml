import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "components"

// A notification center for Omarchy: everything you were sent, still there
// when you go back for it.
//
// Omarchy already writes every notification to disk: one JSON file per popup
// under ~/.local/state/omarchy/notifications/, moved into history/ when it
// leaves the screen. That is where these come from, and nothing here writes to
// those directories. What it is not is a history you can read: it holds ten
// files, deletes the eleventh, and deletes the icon it was keeping for it at
// the same time. Ten is the right number for a service whose job is replaying
// the toasts you just missed, and far too few for the question this panel
// exists to answer, which is "what did that say".
//
// So `bin/notification-center` copies each file out of there the moment it
// lands, into an archive kept for as long as you asked for, icon and all. It
// follows the directory with inotify rather than polling it, so a notification
// is in the archive before its toast has finished appearing.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.notification-center"
  ipcTarget: "jankeesvw.notification-center"

  // The store sits next to this file, so the plugin runs from wherever it was
  // installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/notification-center").toString().replace(/^file:\/\//, "")
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ----------------------------------------------------------------- settings

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int listHeight: setting("listHeight", 0)
  readonly property string badge: setting("badge", "Dot")
  readonly property int keepDays: setting("keepDays", 30)
  readonly property int maxItems: setting("maxItems", 1000)
  readonly property string clickAction: setting("clickAction", "Auto")
  readonly property bool showBody: setting("showBody", true)
  readonly property bool showPreview: setting("showPreview", true)
  readonly property string grouping: setting("grouping", "By app")
  property bool groupingEnabled: grouping !== "Off"

  // How many the panel holds in memory. The archive can be far longer; this is
  // how far back the list scrolls before it stops, and it is a list you scan
  // rather than page through. Anything older is still on disk and still
  // searchable from the command line.
  readonly property int pageSize: 500

  // ------------------------------------------------------------- the service
  //
  // Only for Do Not Disturb, which belongs to whoever is receiving the
  // notifications rather than to whoever is keeping them. A cloned service is
  // enabled under its own id, so the built-in name has to be resolved to
  // whichever copy is actually running, or the toggle silently does nothing on
  // exactly the machines that cared enough to clone it.
  readonly property var notificationService: {
    var host = bar && bar.shell ? bar.shell : null
    if (!host || typeof host.serviceFor !== "function") return null
    var id = "omarchy.notifications"
    if (host.pluginRegistry && typeof host.pluginRegistry.resolveEnabledId === "function")
      id = host.pluginRegistry.resolveEnabledId(id)
    return host.serviceFor(id)
  }

  readonly property bool dnd: notificationService ? notificationService.doNotDisturb : false

  function toggleDnd() {
    if (notificationService) notificationService.setDoNotDisturb(!notificationService.doNotDisturb)
  }

  // -------------------------------------------------------------------- state

  // Newest first, which is both the order they are read in and the order the
  // store hands them over.
  property var entries: []
  property string filter: ""
  // When the center was last opened. Everything newer is unread, and it is the
  // store that remembers it: unread has to survive a shell restart or the
  // count resets itself every time you change a theme.
  property double lastSeen: 0
  // What the rows are marked against. Opening the center makes everything in
  // it read, so marking against `lastSeen` would mean the list never once
  // shows you which of these you had not seen, because the marks would be gone by the
  // time it finished drawing. This holds the reading from the moment before
  // you opened it, which is the question you were asking.
  property double readMark: 0
  property bool loaded: false
  // Whether the search field is up and holding the keyboard. Off by default,
  // and off again the moment the panel closes.
  property bool searching: false
  // Kept above the delegates so rebuilding after an individual dismissal does
  // not collapse the group that contained it.
  property string expandedGroup: ""
  property int rebuildGeneration: 0
  // Ticks so "4m ago" ages on screen instead of freezing at whatever it said
  // when the panel opened. Only while the panel is open: nothing behind a
  // closed panel is being read.
  property double now: Date.now()

  readonly property int unread: {
    var count = 0
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].timestamp > lastSeen) count++
      else break   // newest first, so the first read one ends it
    }
    return count
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var previousDay = Qt.formatDateTime(new Date(root.now), "yyyy-MM-dd")
      root.now = Date.now()
      if (previousDay !== Qt.formatDateTime(new Date(root.now), "yyyy-MM-dd"))
        root.rebuild()
    }
  }

  // The watcher is what keeps the list live, and this is what keeps the list
  // honest: a watcher that died, or a notification that arrived in the gap
  // between two shell restarts, would otherwise leave the panel quietly stale
  // for as long as you left it open. Only while it is open, and free when
  // nothing has changed, because the read above rebuilds nothing it does not
  // have to.
  Timer {
    interval: 10000
    running: root.opened
    repeat: true
    onTriggered: root.load()
  }

  function startSearch() {
    searching = true
    Qt.callLater(function() { if (root.searching) search.forceActiveFocus() })
  }

  function endSearch() {
    searching = false
    filter = ""
    search.text = ""
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  // ------------------------------------------------------------------- store

  function storeCommand(args) {
    return [root.script].concat(args)
  }

  // Retention is the store's business, but the numbers are the user's, so they
  // travel with every call rather than living in a config file of their own.
  readonly property var storeEnvironment: ({
    "NC_KEEP_DAYS": String(root.keepDays),
    "NC_MAX_ITEMS": String(root.maxItems),
    "NC_PREVIEWS": root.showPreview ? "1" : "0"
  })

  // The one long-running process: it follows the notification directories and
  // prints each archived notification as a line of JSON. Everything the panel
  // knows arrives either through here or through the load below.
  Process {
    id: watchProc
    command: root.storeCommand(["watch"])
    environment: root.storeEnvironment
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    // A watcher that died takes the live half of the panel with it and says
    // nothing, so it is picked back up. The delay is what keeps a store that
    // fails immediately, with no jq or no inotifywait, from becoming a process
    // being spawned in a loop.
    onExited: restartWatch.restart()
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: if (!watchProc.running) watchProc.running = true
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
        // Rebuilding throws away the scroll position and every delegate with
        // it, so it only happens when the answer actually differs from what is
        // already on screen. That is what lets this run on a timer.
        if (wasLoaded && !root.differsFrom(data)) {
          root.entries = data
          return
        }
        root.entries = data
        root.rebuild()
      }
    }
  }

  // Whether a fresh read says something the panel is not already showing.
  // Length and the newest key between them catch everything that matters here:
  // arrivals land at the top, removals change the count.
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

  function readSeen() {
    if (seenProc.running) return
    seenProc.command = root.storeCommand(["seen"])
    seenProc.running = true
  }

  Process { id: markProc; environment: root.storeEnvironment }

  // Opening the center is reading it. There is no separate "mark all read",
  // because there is no state a notification can be in here other than seen or
  // not yet seen, and looking at the list is what changes that.
  function markSeen() {
    var stamp = Date.now()
    root.lastSeen = stamp
    if (markProc.running) return
    markProc.command = root.storeCommand(["seen", String(stamp)])
    markProc.running = true
  }

  Process { id: removeProc; environment: root.storeEnvironment }
  Process { id: clearProc; environment: root.storeEnvironment }
  Process { id: focusProc }

  function remove(key) {
    if (!key) return
    var next = []
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key !== key) next.push(entries[i])
    entries = next
    if (!removeRow(String(key))) rebuild()
    // Queued rather than dropped when one is already running: a run of
    // dismissals is exactly how this gets used, and each one is a file the
    // store still has to be told about.
    Quickshell.execDetached(root.storeCommand(["remove", String(key)]))
  }

  // Update one visible row without clearing the ListModel. In particular this
  // keeps an expanded group's delegate alive, so deleting one child does not
  // disturb the ListView's geometry or scroll anchor.
  function removeRow(key) {
    for (var i = 0; i < rows.count; i++) {
      var current = rows.get(i)
      if (String(current.key) === key && Number(current.groupCount) <= 1) {
        rows.remove(i)
        return true
      }
      if (Number(current.groupCount) <= 1 || current.groupMembers === "") continue
      // The newest member determines this row's order and outer day section.
      // Let a full rebuild reposition the group when that member is removed.
      if (String(current.key) === key) return false

      var members
      try {
        members = JSON.parse(current.groupMembers)
      } catch (e) {
        continue
      }
      var remaining = []
      var found = false
      var urgency = 0
      for (var member = 0; member < members.length; member++) {
        if (String(members[member].key) === key) {
          found = true
          continue
        }
        remaining.push(members[member])
        urgency = Math.max(urgency, Number(members[member].urgency || 0))
      }
      if (!found) continue
      if (remaining.length === 0) {
        rows.remove(i)
        expandedGroup = ""
        return true
      }

      var replacement = rowFor(remaining[0])
      if (remaining.length > 1) {
        replacement.groupCount = remaining.length
        replacement.groupMembers = JSON.stringify(remaining)
        replacement.groupIdentity = String(current.groupIdentity)
        replacement.groupUrgency = urgency
      } else if (expandedGroup === String(current.groupIdentity)) {
        expandedGroup = ""
      }
      rows.set(i, replacement)
      return true
    }
    return false
  }

  function removeMany(keys) {
    if (!keys || keys.length === 0) return
    var removing = {}
    var args = ["remove"]
    for (var i = 0; i < keys.length; i++) {
      var key = String(keys[i] || "")
      if (key === "" || removing[key]) continue
      removing[key] = true
      args.push(key)
    }
    if (args.length === 1) return

    var next = []
    for (var j = 0; j < entries.length; j++)
      if (!removing[String(entries[j].key)]) next.push(entries[j])
    entries = next
    rebuild()
    Quickshell.execDetached(root.storeCommand(args))
  }

  function clearAll() {
    entries = []
    rebuild()
    if (clearProc.running) return
    clearProc.command = root.storeCommand(["clear"])
    clearProc.running = true
  }

  // A notification that has just been archived, straight off the watcher.
  function absorb(line) {
    var entry
    try {
      entry = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!entry || !entry.key) return
    // The bar runs once per monitor and each copy has its own watcher, so the
    // same notification arrives here as many times as you have screens.
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key === entry.key) return

    var next = [entry].concat(entries)
    if (next.length > pageSize) next = next.slice(0, pageSize)
    entries = next

    // Reading it as it lands is still reading it.
    if (root.opened) markSeen()
    if (!matches(entry)) return

    // A new arrival may belong in an existing stack, so this cannot always be
    // represented by inserting one row. Rebuild only the in-memory view.
    rebuild()
    // A card inserted above the scroll position is a card you never see: the
    // list holds its offset, so the new one lands out of sight and the panel
    // looks like it missed it. Only when you are already at the top, though,
    // because yanking the list back up under somebody who is reading further
    // down is worse than making them scroll.
    if (root.opened && list.atYBeginning) Qt.callLater(function() {
      if (root.opened) list.positionViewAtBeginning()
    })
  }

  // ----------------------------------------------------------------- the list

  ListModel { id: rows }

  function matches(entry) {
    if (filter === "") return true
    var needle = filter.toLowerCase()
    return String(entry.app || "").toLowerCase().indexOf(needle) >= 0
        || String(entry.summary || "").toLowerCase().indexOf(needle) >= 0
        || String(entry.body || "").toLowerCase().indexOf(needle) >= 0
  }

  function rowFor(entry) {
    return {
      key: String(entry.key || ""),
      app: String(entry.app || ""),
      appIcon: String(entry.appIcon || ""),
      summary: String(entry.summary || ""),
      body: String(entry.body || ""),
      image: String(entry.image || ""),
      preview: String(entry.preview || ""),
      file: String(entry.file || ""),
      glyph: String(entry.glyph || ""),
      urgency: Number(entry.urgency || 0),
      timestamp: Number(entry.timestamp || 0),
      day: dayOf(Number(entry.timestamp || 0)),
      time: Qt.formatDateTime(new Date(Number(entry.timestamp || 0)), "HH:mm"),
      groupCount: 1,
      groupMembers: "",
      groupIdentity: "",
      groupUrgency: Number(entry.urgency || 0)
    }
  }

  function normalizedGroupText(value) {
    return String(value || "")
      .replace(/<img[^>]*>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase()
  }

  function groupKey(entry) {
    var app = normalizedGroupText(entry.app)
    if (app === "") return ""
    var mode = grouping === "Off" ? "By app" : grouping
    if (mode === "By app") return app
    if (mode !== "Similar") return ""
    var summary = normalizedGroupText(entry.summary)
    return summary === "" ? "" : app + "\n" + summary
  }

  function rebuild() {
    var generation = ++rebuildGeneration
    var savedContentY = list.contentY
    var wasAtBeginning = list.atYBeginning
    var anchorIdentity = ""
    var anchorKey = ""
    var anchorOffset = 0
    if (!wasAtBeginning && rows.count > 0) {
      var anchorIndex = list.indexAt(1, list.contentY + list.height / 2)
      if (anchorIndex >= 0) {
        var anchorRow = rows.get(anchorIndex)
        var anchorItem = list.itemAtIndex(anchorIndex)
        anchorIdentity = String(anchorRow.groupIdentity || "")
        anchorKey = String(anchorRow.key || "")
        if (anchorItem) anchorOffset = list.contentY - anchorItem.y
      }
    }
    rows.clear()
    var visible = []
    for (var i = 0; i < entries.length; i++)
      if (matches(entries[i])) visible.push(entries[i])

    // Search results stay individual so a match is never hidden in a stack.
    if (filter !== "" || !groupingEnabled) {
      for (var plain = 0; plain < visible.length; plain++)
        rows.append(rowFor(visible[plain]))
      restoreScroll(generation, savedContentY, wasAtBeginning,
                    anchorIdentity, anchorKey, anchorOffset)
      return
    }

    var grouped = []
    var positions = {}
    for (var item = 0; item < visible.length; item++) {
      var entry = visible[item]
      var key = groupKey(entry)
      // Days divide the notifications inside a stack, not the stack itself.
      var identity = key
      // Prefix map keys so app names such as "constructor" and "__proto__"
      // cannot collide with properties inherited from Object.prototype.
      var positionKey = "$" + identity
      if (identity !== "" && positions[positionKey] !== undefined) {
        var existing = grouped[positions[positionKey]]
        existing.members.push(entry)
        existing.urgency = Math.max(existing.urgency, Number(entry.urgency || 0))
      } else {
        if (identity !== "") positions[positionKey] = grouped.length
        grouped.push({
          latest: entry,
          members: [entry],
          urgency: Number(entry.urgency || 0),
          identity: identity
        })
      }
    }

    var expansionFound = expandedGroup === ""
    for (var group = 0; group < grouped.length; group++) {
      var row = rowFor(grouped[group].latest)
      row.groupCount = grouped[group].members.length
      row.groupUrgency = grouped[group].urgency
      if (row.groupCount > 1) {
        row.groupMembers = JSON.stringify(grouped[group].members)
        row.groupIdentity = grouped[group].identity
        if (row.groupIdentity === expandedGroup) expansionFound = true
      }
      rows.append(row)
    }
    if (!expansionFound) expandedGroup = ""
    restoreScroll(generation, savedContentY, wasAtBeginning,
                  anchorIdentity, anchorKey, anchorOffset)
  }

  function restoreScroll(generation, contentY, wasAtBeginning,
                         anchorIdentity, anchorKey, anchorOffset) {
    Qt.callLater(function() {
      if (generation !== rebuildGeneration) return
      if (wasAtBeginning) {
        list.positionViewAtBeginning()
        return
      }

      if (anchorIdentity !== "" || anchorKey !== "") {
        for (var i = 0; i < rows.count; i++) {
          var row = rows.get(i)
          if (!rowMatchesAnchor(row, anchorIdentity, anchorKey)) continue
          let targetIndex = i
          list.positionViewAtIndex(targetIndex, ListView.Beginning)
          Qt.callLater(function() {
            if (generation !== rebuildGeneration) return
            var item = list.itemAtIndex(targetIndex)
            if (item) {
              var maxY = list.originY + Math.max(0, list.contentHeight - list.height)
              list.contentY = Math.max(list.originY,
                                       Math.min(item.y + anchorOffset, maxY))
            }
          })
          return
        }
      }

      var maxY = list.originY + Math.max(0, list.contentHeight - list.height)
      list.contentY = Math.max(list.originY, Math.min(contentY, maxY))
    })
  }

  function rowMatchesAnchor(row, groupIdentity, key) {
    if (groupIdentity !== "" && String(row.groupIdentity || "") === groupIdentity)
      return true
    if (key === "") return false
    if (String(row.key || "") === key) return true
    if (!row.groupMembers) return false
    try {
      var members = JSON.parse(row.groupMembers)
      for (var i = 0; i < members.length; i++)
        if (String(members[i].key || "") === key) return true
    } catch (e) {
    }
    return false
  }

  onFilterChanged: {
    expandedGroup = ""
    rebuild()
  }
  onGroupingChanged: {
    groupingEnabled = grouping !== "Off"
    rebuild()
  }
  onGroupingEnabledChanged: {
    expandedGroup = ""
    rebuild()
  }

  // The heading a notification is filed under. Days rather than hours, because
  // what you remember about a notification you are hunting for is which day it
  // was, and because a list broken into hours is a list that is mostly
  // headings.
  function dayOf(timestamp) {
    var when = new Date(timestamp)
    var current = new Date(root.now || Date.now())
    var today = Date.UTC(current.getFullYear(), current.getMonth(), current.getDate()) / 86400000
    var thatDay = Date.UTC(when.getFullYear(), when.getMonth(), when.getDate()) / 86400000
    var daysAgo = today - thatDay
    if (daysAgo <= 0) return "Today"
    if (daysAgo === 1) return "Yesterday"
    // Within the week the weekday is the better handle: "Tuesday" is how you
    // remember it, "17 August" is how you would have to work it out.
    if (daysAgo <= 6) return Qt.formatDateTime(when, "dddd")
    if (when.getFullYear() === current.getFullYear()) return Qt.formatDateTime(when, "d MMMM")
    return Qt.formatDateTime(when, "d MMMM yyyy")
  }

  // --------------------------------------------------------------- activating

  // What a click on an old notification should do.
  //
  // Not what the notification asked for. A notification arrives carrying a
  // shell command, chosen by whoever sent it, and anything on this machine can
  // send one. Keeping that command and running it later is an attacker's
  // command waiting for a click, which is worth nothing next to the one thing
  // people actually want back: the picture. So what the store keeps is at most
  // an absolute path to an image, and that is opened by argument rather than
  // through a shell, so a hostile path is a file that fails to open instead of
  // a command that runs.
  function activate(row) {
    if (!row || clickAction === "Nothing") return
    if (clickAction === "Auto" && row.file !== "") {
      Quickshell.execDetached(["xdg-open", row.file])
      root.close()
      return
    }
    // The app name is on the notification too, so it is the sender's to choose,
    // and the focus helper matches it as a regular expression: an app calling
    // itself ".*" would focus whichever window that hit first. Only something
    // shaped like a name gets through.
    if (!/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(row.app)) return
    // Chat apps rarely register an action and simply expect a click to bring
    // their window up. This is the helper the notification service uses for
    // the same fallback, so a click here lands where a click on the toast
    // would have.
    focusProc.command = [root.omarchyPath + "/bin/omarchy-hyprland-focus-app", row.app]
    focusProc.running = true
    root.close()
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: {
    readSeen()
    load()
  }

  onOpenedChanged: {
    if (!opened) {
      searching = false
      filter = ""
      search.text = ""
      return
    }
    now = Date.now()
    // The watcher keeps the list current while the panel is closed, so this is
    // not a refresh so much as a reconciliation: it is the one moment worth
    // spending a read on catching whatever a restart or a crashed watcher
    // missed.
    load()
    readMark = lastSeen
    markSeen()
  }

  // --------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    // A bell, and a bell with a line through it while notifications are
    // silenced. The second is the same glyph the shell's own DND indicator
    // uses, so the bar never shows two different pictures of one state.
    // U+F009B (bell-off) and U+F009A (bell), written as surrogate pairs so the
    // source survives editors that mangle private-use codepoints. The first is
    // the glyph the shell's own DND indicator uses, so the bar never shows two
    // different pictures of one state.
    text: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
    dimmed: root.dnd
    tooltipText: {
      if (root.dnd) return root.unread > 0
        ? "Silenced · " + root.unread + " new" : "Notifications silenced"
      if (root.unread === 1) return "1 new notification"
      if (root.unread > 1) return root.unread + " new notifications"
      return "Notifications"
    }

    onPressed: function(b) {
      // Right-click silences without opening anything, because deciding you
      // want quiet and wanting to read the backlog are opposite impulses.
      if (b === Qt.RightButton) {
        root.toggleDnd()
        return
      }
      root.toggle()
    }
  }

  // Where the panel hangs from: a zero-width point far past the right edge of
  // any screen. Invisible, in the layout for nothing, and read only for its
  // position; see the anchor comment on the panel itself.
  Item {
    id: rightAnchor
    anchors.top: button.top
    anchors.bottom: button.bottom
    x: 1000000
    width: 1
    visible: false
  }

  // The unread marker, drawn over the bell rather than beside it: a bar that
  // changes width every time a message arrives is a bar that twitches all day.
  Rectangle {
    id: dot
    visible: root.badge === "Dot" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(3)
    anchors.top: button.top
    anchors.topMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
  }

  Rectangle {
    id: countBadge
    visible: root.badge === "Count" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(1)
    anchors.top: button.top
    anchors.topMargin: Style.space(3)
    width: Math.max(countText.implicitWidth + Style.space(6), Style.space(12))
    height: Style.space(12)
    radius: height / 2
    color: Color.accent

    Text {
      textFormat: Text.PlainText
      id: countText
      anchors.centerIn: parent
      // Past ninety-nine the number has stopped being information and the
      // badge is only saying "a lot", which it can say in three characters.
      text: root.unread > 99 ? "99+" : String(root.unread)
      font.family: root.fontFamily
      font.pixelSize: Math.max(8, Style.font.caption - Style.space(3))
      font.bold: true
      color: Color.background
    }
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: popup
    // Anchored to a point past the right edge of the screen rather than to the
    // bell. KeyboardPanel clamps its card inside the screen, so an anchor out
    // there always resolves to hard against the right edge, whatever the bar
    // has been rearranged into since. This is the one panel in the bar with a
    // fixed home: a notification center that opened in a different place
    // depending on how many widgets were to its left would be a notification
    // center you have to look for.
    anchorItem: rightAnchor
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has the focus it owns every key, including the
      // ones this would otherwise read as navigation.
      blocked: root.searching
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { list.flick(0, dy > 0 ? -900 : 900) }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        // "/" is the only key that starts a search, because a panel that
        // started filtering on any keypress would be a panel that swallows
        // whatever you were typing in the window underneath.
        if (text === "/") root.startSearch()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // -------------------------------------------------------- header

        Item {
          id: header
          width: parent.width
          height: Math.max(title.implicitHeight, actions.height)

          PanelSectionHeader {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "NOTIFICATIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: actions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "Group"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: root.groupingEnabled ? 0.8 : 0.5
              }

              ToggleSwitch {
                id: groupSwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: root.groupingEnabled
                cursorRing: false
                foreground: root.foreground
                onToggled: root.groupingEnabled = !root.groupingEnabled

                PanelToolTip {
                  visible: groupSwitch.containsMouse
                  text: root.groupingEnabled
                    ? "Show every notification separately"
                    : "Group notifications " + (root.grouping === "Similar"
                        ? "by conversation" : "by app")
                  fontFamily: root.fontFamily
                }
              }
            }

            // Search is a button rather than a field standing open. An open
            // field takes the keyboard the moment the panel appears, and this
            // panel can be opened from a key binding while you are typing
            // somewhere else, which is exactly how it ends up eating a
            // sentence out of the window underneath.
            PanelActionButton {
              // Anchored rather than left to the Row, which stacks its
              // children from the top: an icon button and a text button are
              // not the same height, and the difference shows as a word
              // sitting above a row of glyphs.
              anchors.verticalCenter: parent.verticalCenter
              // U+F0349, nf-md-magnify.
              iconText: "\uDB80\uDF49"
              tooltipText: "Search these notifications  ( / )"
              foreground: root.searching ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              visible: root.entries.length > 0
              onClicked: root.searching ? root.endSearch() : root.startSearch()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
              tooltipText: root.dnd ? "Allow notifications" : "Silence notifications"
              foreground: root.dnd ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              enabled: root.notificationService !== null
              onClicked: root.toggleDnd()
            }

            // A word rather than a glyph. Everything in this row is
            // destructive in a different way, one silences and one deletes,
            // and a picture of a broom is not the place to find that out.
            Button {
              id: clearButton
              anchors.verticalCenter: parent.verticalCenter
              // Deleting a month of notifications is one click away from
              // silencing them, and there is no undo. A second click is
              // cheaper than a dialog and enough to make it deliberate; it
              // forgets itself after a few seconds so the panel is never left
              // armed.
              property bool armed: false

              text: armed ? "Sure?" : "Clear"
              tooltipText: armed
                ? "Click again to delete every notification kept here"
                : "Delete every notification kept here"
              foreground: armed ? Color.urgent : root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              enabled: root.entries.length > 0
              onClicked: {
                if (armed) {
                  armed = false
                  disarm.stop()
                  root.clearAll()
                } else {
                  armed = true
                  disarm.restart()
                }
              }

              Timer {
                id: disarm
                interval: 4000
                onTriggered: clearButton.armed = false
              }
            }
          }
        }

        // -------------------------------------------------------- search

        TextField {
          id: search
          width: parent.width
          visible: root.searching
          placeholderText: "Search"
          foreground: root.foreground
          onTextChanged: root.filter = text
          Keys.onEscapePressed: root.endSearch()
          Keys.onDownPressed: list.flick(0, -900)
          Keys.onUpPressed: list.flick(0, 900)
        }

        // ---------------------------------------------------------- list

        ListView {
          id: list
          width: parent.width
          // Grows with what it holds and stops at the bottom of the screen,
          // which is where macOS puts the end of its notification column. The
          // ceiling is what is left of the screen once the header, the search
          // field and the footer have had their share, so the panel fills the
          // display without ever being taller than it.
          //
          // Search is counted in whether it is showing or not: opening it must
          // not push the footer out through the bottom of the card.
          readonly property int cap: {
            if (root.listHeight > 0) return Style.space(root.listHeight)
            var chrome = header.height + search.implicitHeight + foot.implicitHeight
                       + content.spacing * 3
            return Math.max(Style.space(240),
                            popup.availableCardHeight - popup.verticalContentInset - chrome)
          }

          height: Math.min(contentHeight, cap)
          visible: rows.count > 0
          clip: true
          model: rows
          spacing: Style.space(6)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { id: listScroll; policy: ScrollBar.AsNeeded }

          // The scrollbar gets a lane of its own on the right. Sharing one
          // with the cards puts it on top of the dismiss button in the corner
          // of every one of them, and the button you are aiming at is the one
          // you miss.
          readonly property real lane: Style.space(10)

          section.property: "day"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            id: daySection
            required property string section
            width: list.width - list.lane
            height: dayLabel.implicitHeight + Style.space(14)

            PanelSectionHeader {
              id: dayLabel
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
              text: daySection.section.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          delegate: NotificationGroup {
            id: row
            required property var model

            width: list.width - list.lane
            notificationKey: model.key
            app: model.app
            appIcon: model.appIcon
            summary: model.summary
            body: model.body
            image: model.image
            preview: model.preview
            file: model.file
            glyph: model.glyph
            timestamp: model.timestamp
            now: root.now
            urgency: model.urgency
            groupUrgency: model.groupUrgency
            unread: model.timestamp > root.readMark
            readMark: root.readMark
            count: model.groupCount
            membersJson: model.groupMembers
            groupIdentity: model.groupIdentity
            expanded: model.groupIdentity !== ""
              && root.expandedGroup === model.groupIdentity
            showBody: root.showBody
            showPreview: root.showPreview
            foreground: root.foreground
            fontFamily: root.fontFamily

            onActivateRequested: function(entry) { root.activate(entry) }
            onRemoveRequested: function(key) { root.remove(key) }
            onRemoveAllRequested: function(keys) { root.removeMany(keys) }
            onToggleRequested: function(identity) {
              root.expandedGroup = root.expandedGroup === identity ? "" : identity
            }
          }
        }

        // --------------------------------------------------------- empty

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: rows.count === 0
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(22)
          bottomPadding: Style.space(22)
          text: !root.loaded ? "Reading the archive\u2026"
              : root.filter !== "" ? "Nothing matches \u201c" + root.filter + "\u201d"
              : "Nothing has come in yet"
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.55
        }

        // ---------------------------------------------------------- foot

        Text {
          textFormat: Text.PlainText
          id: foot
          width: parent.width
          visible: root.entries.length > 0 && root.filter === ""
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(2)
          text: root.entries.length === 1
            ? "1 notification kept"
            : root.entries.length + " notifications kept \u00b7 " + root.keepDays + " days"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.4
        }
      }
    }
  }


  // Lets the panel be filled without waiting a week for real traffic:
  //
  //   omarchy-shell jankeesvw.notification-center.test seed 25
  //   omarchy-shell jankeesvw.notification-center.test clear
  //
  // Synthetic input does not reach this shell, so a test hook is the only way
  // to see what a full list looks like.
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

    function setGrouping(enabled: bool): string {
      root.groupingEnabled = enabled
      return enabled ? "grouping enabled" : "grouping disabled"
    }

    // What the panel believes right now. For working out whether a
    // notification reached the list, which is otherwise a question you can
    // only answer by looking at the screen.
    function state(): string {
      return JSON.stringify({
        opened: root.opened,
        entries: root.entries.length,
        rows: rows.count,
        newest: root.entries.length > 0 ? root.entries[0].summary : "",
        unread: root.unread,
        watching: watchProc.running,
        searching: root.searching,
        grouping: root.groupingEnabled
          ? (root.grouping === "Off" ? "By app" : root.grouping)
          : "Off"
      })
    }
  }

  Timer {
    id: reloadAfterSeed
    interval: 600
    onTriggered: root.load()
  }
}
