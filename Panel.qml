import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "components"
import "Store.js" as Store
import "lib/SlackLink.js" as SlackLink

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

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string slackLogPath:
    (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config")
    + "/Slack/logs/default/browser.log"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
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
  readonly property bool groupingDefault: setting("groupNotifications", false)
  // The header switch wins once it has been pressed; until then the setting
  // decides.
  readonly property bool grouping: store && store.groupingChoice !== ""
    ? store.groupingChoice === "on" : groupingDefault
  readonly property string groupRules: setting("groupRules", defaultGroupRules)

  readonly property string defaultGroupRules:
    "Mail=thunderbird|mail; VPN=vpn; Network=internet|router|local network; "
    + "Screenshots=screenshot; Crashes=process crashed; Reminders=reminder"

  // ------------------------------------------------------------- the service
  //
  // Only for Do Not Disturb, which belongs to whoever is receiving the
  // notifications rather than to whoever is keeping them. A cloned service is
  // enabled under its own id, so the built-in name has to be resolved to
  // whichever copy is actually running, or the toggle silently does nothing on
  // exactly the machines that cared enough to clone it.
  readonly property var notificationService: {
    var host = bar && bar.shell ? bar.shell : null
    if (host && typeof host.serviceFor === "function") {
      var id = "omarchy.notifications"
      if (host.pluginRegistry && typeof host.pluginRegistry.resolveEnabledId === "function")
        id = host.pluginRegistry.resolveEnabledId(id)
      var s = host.serviceFor(id)
      if (s) return s
    }
    // A facade without services, or a third-party entry the shell will not
    // hand the built-in service to: take the bridge the archive holds.
    return store && store.notifications ? store.notifications : null
  }

  readonly property bool dnd: notificationService ? notificationService.doNotDisturb : false

  function toggleDnd() {
    if (notificationService) notificationService.setDoNotDisturb(!notificationService.doNotDisturb)
  }

  // ------------------------------------------------------------- the store
  //
  // The archive is a shell service, not a child of this widget. Omarchy
  // builds a bar per monitor, and a Process in here would be one watcher
  // per screen: unread and clear would stick to whichever copy you clicked.
  property var store: null

  function bindStore() {
    if (store) {
      pushSettings()
      return
    }
    var host = bar && bar.shell ? bar.shell : null
    var s = host && typeof host.serviceFor === "function"
      ? host.serviceFor("jankeesvw.notification-center") : null
    // Replacement bars hand widgets a service-less facade; see Store.js.
    if (!s) s = Store.get()
    if (!s) return
    store = s
    pushSettings()
    rebuild()
  }

  function pushSettings() {
    if (!store) return
    store.keepDays = keepDays
    store.maxItems = maxItems
    store.showPreview = showPreview
  }

  onBarChanged: bindStore()
  onKeepDaysChanged: pushSettings()
  onMaxItemsChanged: pushSettings()
  onShowPreviewChanged: pushSettings()

  Timer {
    interval: 200
    running: root.store === null
    repeat: true
    onTriggered: root.bindStore()
  }

  Connections {
    target: root.store
    function onEntryAdded(entry) { root.handleEntryAdded(entry) }
    function onEntriesReset() { root.rebuild() }
  }

  // -------------------------------------------------------------------- state

  readonly property var entries: store ? store.entries : []
  property string filter: ""
  // What the rows are marked against. Opening the center makes everything in
  // it read, so marking against `lastSeen` would mean the list never once
  // shows you which of these you had not seen, because the marks would be gone by the
  // time it finished drawing. This holds the reading from the moment before
  // you opened it, which is the question you were asking.
  property double readMark: 0
  readonly property bool loaded: store ? store.loaded : false
  property bool searching: false
  property double now: Date.now()

  readonly property int unread: store ? store.unread : 0
  readonly property double lastSeen: store ? store.lastSeen : 0

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
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

  Process { id: focusProc }

  function remove(key) {
    if (store) store.remove(key)
  }

  function clearAll() {
    if (store) store.clearAll()
  }

  function handleEntryAdded(entry) {
    if (!entry || !entry.key) return
    if (root.opened && store) store.markSeen()
    if (!matches(entry)) return
    // A new one can move a whole group to the top, which is not an insert.
    if (grouping) {
      rebuild()
      return
    }
    rows.insert(0, rowFor(entry))
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

  // kind is "entry" for one notification, "group" for a collapsed group drawn
  // as its newest member, and "header" for the line above an open group. day
  // is the section the row is filed under, which for a group is the day of its
  // newest member; ownDay is the day the notification itself arrived.
  function rowFor(entry, kind, group, count, day) {
    var ownDay = dayOf(Number(entry.timestamp || 0))
    return {
      kind: kind || "entry",
      group: String(group || ""),
      count: Number(count || 1),
      ownDay: ownDay,
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
      day: day || ownDay,
      time: Qt.formatDateTime(new Date(Number(entry.timestamp || 0)), "HH:mm")
    }
  }

  function rebuild() {
    rows.clear()
    if (!grouping) {
      for (var i = 0; i < entries.length; i++)
        if (matches(entries[i])) rows.append(rowFor(entries[i]))
      return
    }
    var groups = collectGroups()
    for (var g = 0; g < groups.length; g++) {
      var items = groups[g].items
      var name = groups[g].name
      var day = dayOf(Number(items[0].timestamp || 0))
      if (items.length === 1) {
        rows.append(rowFor(items[0], "entry", name, 1, day))
      } else if (expanded[name]) {
        rows.append(rowFor(items[0], "header", name, items.length, day))
        for (var j = 0; j < items.length; j++)
          rows.append(rowFor(items[j], "entry", name, 1, day))
      } else {
        rows.append(rowFor(items[0], "group", name, items.length, day))
      }
    }
  }

  onFilterChanged: rebuild()
  onGroupingChanged: rebuild()
  onGroupRulesChanged: rebuild()

  // ------------------------------------------------------------- grouping
  //
  // Off by default. When on, everything that belongs together is one stacked
  // card under the day of its newest member, and a click opens it in place.
  // Which group a notification is in comes from the rules first, "Name=regex"
  // separated by semicolons and matched against the app, its icon and the
  // summary, never the body: a mail about a VPN invoice is still mail. What no
  // rule claims is grouped by app, and a notification with no app worth the
  // name (notify-send, omarchy's own helpers) by its summary, so ten "Download
  // complete" are one group and not lumped in with the battery warnings.

  property var expanded: ({})

  readonly property var rules: {
    var out = []
    var parts = String(groupRules || "").split(/[;\n]/)
    for (var i = 0; i < parts.length; i++) {
      var at = parts[i].indexOf("=")
      if (at <= 0) continue
      var name = parts[i].slice(0, at).trim()
      var pattern = parts[i].slice(at + 1).trim()
      if (name === "" || pattern === "") continue
      try {
        out.push({ name: name, re: new RegExp(pattern, "i") })
      } catch (e) {
      }
    }
    return out
  }

  function groupOf(entry) {
    var app = String(entry.app || "")
    var haystack = app + "\n" + String(entry.appIcon || "") + "\n" + String(entry.summary || "")
    for (var i = 0; i < rules.length; i++)
      if (rules[i].re.test(haystack)) return rules[i].name
    if (app !== "" && !/^(omarchy-action|notify-send)$/i.test(app)) return app
    var summary = String(entry.summary || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()
    return summary !== "" ? summary : (app !== "" ? app : "Other")
  }

  // Groups in the order of their newest member, which is the order the
  // entries are already in.
  function collectGroups() {
    var groups = []
    var byName = {}
    for (var i = 0; i < entries.length; i++) {
      if (!matches(entries[i])) continue
      var name = groupOf(entries[i])
      if (!byName[name]) {
        byName[name] = { name: name, items: [] }
        groups.push(byName[name])
      }
      byName[name].items.push(entries[i])
    }
    return groups
  }

  function toggleGrouping() {
    if (!store || typeof store.setGrouping !== "function") return
    store.setGrouping(!grouping)
  }

  function toggleGroup(name) {
    var next = {}
    for (var k in expanded) next[k] = expanded[k]
    if (next[name]) delete next[name]
    else next[name] = true
    expanded = next
    // Rebuilding the model throws the view back to the top, which is the
    // last place you want to be after opening a group halfway down.
    var y = list.contentY
    rebuild()
    Qt.callLater(function() {
      list.contentY = Math.max(0, Math.min(y, list.contentHeight - list.height))
    })
  }

  // Everything in the group that is showing, so clearing a group while a
  // search is open clears what the search found and not the rest of it.
  function removeGroup(name) {
    var keys = []
    for (var i = 0; i < entries.length; i++)
      if (matches(entries[i]) && groupOf(entries[i]) === name) keys.push(String(entries[i].key))
    if (keys.length === 0 || !store) return
    if (typeof store.removeMany === "function") store.removeMany(keys)
    else for (var j = 0; j < keys.length; j++) store.remove(keys[j])
  }

  // The heading a notification is filed under. Days rather than hours, because
  // what you remember about a notification you are hunting for is which day it
  // was, and because a list broken into hours is a list that is mostly
  // headings.
  function dayOf(timestamp) {
    var when = new Date(timestamp)
    var now = new Date()
    var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (timestamp >= midnight) return "Today"
    if (timestamp >= midnight - 86400000) return "Yesterday"
    // Within the week the weekday is the better handle: "Tuesday" is how you
    // remember it, "17 August" is how you would have to work it out.
    if (timestamp >= midnight - 6 * 86400000) return Qt.formatDateTime(when, "dddd")
    if (when.getFullYear() === now.getFullYear()) return Qt.formatDateTime(when, "d MMMM")
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
    // Slack gets one step more: the conversation the notification was about,
    // looked up in Slack's own log by lib/SlackLink.js. Whatever that cannot
    // place is focused like everything else.
    if (clickAction === "Auto" && row.app.toLowerCase() === "slack") {
      slackLog.app = row.app
      slackLog.stamp = row.timestamp
      slackLog.path = root.slackLogPath
      root.close()
      return
    }
    focusApp(row.app)
    root.close()
  }

  // Chat apps rarely register an action and simply expect a click to bring
  // their window up. This is the helper the notification service uses for the
  // same fallback, so a click here lands where a click on the toast would have.
  function focusApp(app) {
    focusProc.command = [root.omarchyPath + "/bin/omarchy-hyprland-focus-app", app]
    focusProc.running = true
  }

  // Read on click and let go straight after: the log runs to megabytes.
  FileView {
    id: slackLog
    property string app: ""
    property double stamp: 0
    printErrors: false
    onLoaded: root.openSlack(SlackLink.resolve(text(), stamp))
    onLoadFailed: root.openSlack("")
  }

  function openSlack(url) {
    slackLog.path = ""
    focusApp(slackLog.app)
    if (url !== "") Qt.openUrlExternally(url)
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: bindStore()

  onOpenedChanged: {
    if (!opened) {
      searching = false
      filter = ""
      search.text = ""
      if (Object.keys(expanded).length > 0) {
        expanded = ({})
        rebuild()
      }
      return
    }
    now = Date.now()
    if (store) store.load()
    readMark = lastSeen
    if (store) store.markSeen()
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

    // The Highlight marker: no shape added beside the bell, the bell itself
    // recoloured. BarIconButton already draws its glyph in activeColor while
    // active, which is the same mechanism the bar's own indicators use to say
    // a thing wants you, so this is that state rather than a second drawing of
    // it. Accent instead of the inherited urgent, because unread mail is not
    // an emergency.
    active: root.badge === "Highlight" && root.unread > 0
    activeColor: Commons.Color.accent
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

  // The Dot marker, drawn over the bell rather than beside it: a bar that
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
    color: Commons.Color.accent
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
    color: Commons.Color.accent

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
      color: Commons.Color.background
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
    // fittedContentHeight() clamps against availableCardHeight, which collapses
    // to its 120px minimum under a screen-sized bar window (see
    // usableCardHeight below), so the same fit is done here against the
    // corrected ceiling: the content plus the card insets, never taller than
    // the space the screen actually has.
    contentHeight: Math.round(Math.min(
      Math.max(popup.verticalContentInset, content.implicitHeight + popup.verticalContentInset),
      popup.usableCardHeight))

    // The stock omarchy bar window is only as tall as the bar strip, so the
    // screen minus that window is the space a panel has. Shibumi draws its
    // strip inside a screen-sized window instead, which makes KeyboardPanel
    // mistake the whole screen for the bar and collapse to its 120px safety
    // minimum - a card a few entries tall no matter how much room there is.
    // Measure the strip itself when the window is screen-sized; both bars
    // expose barSize, so this works under either host.
    readonly property real usableCardHeight: {
      if (barH >= screenH && root.bar && Number(root.bar.barSize) > 0)
        return Math.max(120, screenH - (Number(root.bar.barSize) + gap + margin))
      return availableCardHeight
    }

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

            // Search is a button rather than a field standing open. An open
            // field takes the keyboard the moment the panel appears, and this
            // panel can be opened from a key binding while you are typing
            // somewhere else, which is exactly how it ends up eating a
            // sentence out of the window underneath.
            // Grouping on and off without a trip to the settings, since
            // whether a stack helps depends on what the day has been like.
            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              // U+F0328, nf-md-layers.
              iconText: "\uDB80\uDF28"
              tooltipText: root.grouping ? "Show every notification on its own" : "Group notifications"
              foreground: root.grouping ? Commons.Color.accent : root.foreground
              fontFamily: root.fontFamily
              visible: root.entries.length > 0
              onClicked: root.toggleGrouping()
            }

            PanelActionButton {
              // Anchored rather than left to the Row, which stacks its
              // children from the top: an icon button and a text button are
              // not the same height, and the difference shows as a word
              // sitting above a row of glyphs.
              anchors.verticalCenter: parent.verticalCenter
              // U+F0349, nf-md-magnify.
              iconText: "\uDB80\uDF49"
              tooltipText: "Search these notifications  ( / )"
              foreground: root.searching ? Commons.Color.accent : root.foreground
              fontFamily: root.fontFamily
              visible: root.entries.length > 0
              onClicked: root.searching ? root.endSearch() : root.startSearch()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.dnd ? "\uDB80\uDC9B" : "\uDB80\uDC9A"
              tooltipText: root.dnd ? "Allow notifications" : "Silence notifications"
              foreground: root.dnd ? Commons.Color.accent : root.foreground
              fontFamily: root.fontFamily
              enabled: root.notificationService !== null
              onClicked: root.toggleDnd()
            }

            // A word rather than a glyph. The other control in this row
            // silences and this one empties the panel, and a picture of a
            // broom is not the place to find out which is which.
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "Clear"
              tooltipText: "Empty the panel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              enabled: root.entries.length > 0
              onClicked: root.clearAll()
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
                            popup.usableCardHeight - popup.verticalContentInset - chrome)
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

          delegate: Item {
            id: cell
            required property var model

            readonly property bool isHeader: model.kind === "header"
            readonly property bool isGroup: model.kind === "group"

            width: list.width - list.lane
            height: isHeader ? groupHeader.height : row.implicitHeight

            // The line above an open group: its name, and the two things you
            // do to a group as a whole.
            Item {
              id: groupHeader
              visible: cell.isHeader
              width: parent.width
              height: visible ? Math.max(groupTitle.implicitHeight, groupActions.height) : 0

              Text {
                textFormat: Text.PlainText
                id: groupTitle
                anchors.left: parent.left
                anchors.leftMargin: Style.space(2)
                anchors.right: groupActions.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: cell.model.group + "  \u00b7  " + cell.model.count
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.foreground
                opacity: 0.7
              }

              Row {
                id: groupActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Show less"
                  tooltipText: "Fold this group back into one card"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.toggleGroup(cell.model.group)
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\u00d7"
                  tooltipText: "Dismiss every notification in this group"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.removeGroup(cell.model.group)
                }
              }
            }

            NotificationRow {
              id: row
              visible: !cell.isHeader
              width: parent.width
              app: cell.model.app
              appIcon: cell.model.appIcon
              summary: cell.model.summary
              body: cell.model.body
              image: cell.model.image
              preview: cell.model.preview
              glyph: cell.model.glyph
              timestamp: cell.model.timestamp
              now: root.now
              urgency: cell.model.urgency
              unread: cell.model.timestamp > root.readMark
              showBody: root.showBody
              showPreview: root.showPreview
              foreground: root.foreground
              fontFamily: root.fontFamily
              stackCount: cell.isGroup ? cell.model.count : 1
              groupName: cell.isGroup ? cell.model.group : ""
              dayPrefix: cell.model.ownDay !== cell.model.day ? cell.model.ownDay : ""

              // A collapsed group opens on a click, and its × takes the whole
              // group with it: the card stands for all of them.
              onClicked: cell.isGroup ? root.toggleGroup(cell.model.group) : root.activate(cell.model)
              onRemoveRequested: cell.isGroup ? root.removeGroup(cell.model.group) : root.remove(cell.model.key)
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
}
