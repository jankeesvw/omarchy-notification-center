import QtQuick
import Quickshell
import qs.Commons

// A single notification until related arrivals give it something to stack.
// Expanded stacks use the ordinary notification row for every child, so all
// activation, preview, urgency and dismissal behavior stays identical.
Item {
  id: root

  property string notificationKey: ""
  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  property string preview: ""
  property string file: ""
  property string glyph: ""
  property double timestamp: 0
  property double now: 0
  property int urgency: 1
  property int groupUrgency: urgency
  property bool unread: false
  property double readMark: 0
  property int count: 1
  property string membersJson: ""
  property string groupIdentity: ""
  property bool showBody: true
  property bool showPreview: true
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  property bool expanded: false

  signal activateRequested(var entry)
  signal removeRequested(string key)
  signal removeAllRequested(var keys)
  signal toggleRequested(string identity)

  readonly property var members: {
    if (membersJson === "") return []
    try {
      var parsed = JSON.parse(membersJson)
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      return []
    }
  }

  function latestEntry() {
    return {
      key: notificationKey,
      app: app,
      appIcon: appIcon,
      summary: summary,
      body: body,
      image: image,
      preview: preview,
      file: file,
      glyph: glyph,
      urgency: urgency,
      timestamp: timestamp
    }
  }

  function dismissAll() {
    var keys = []
    for (var i = 0; i < members.length; i++)
      if (members[i].key) keys.push(String(members[i].key))
    removeAllRequested(keys)
  }

  implicitHeight: expanded
    ? expandedColumn.implicitHeight
    : collapsed.implicitHeight + (count > 1 ? Style.space(4) : 0)

  // Two quiet edges make the collapsed card read as a stack before the count
  // is read. They stay inset so they cannot be mistaken for another card.
  Rectangle {
    visible: !root.expanded && root.count > 1
    x: Style.space(8)
    y: Style.space(4)
    width: parent.width - Style.space(16)
    height: collapsed.implicitHeight
    radius: Style.space(12)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
  }

  Rectangle {
    visible: !root.expanded && root.count > 1
    x: Style.space(4)
    y: Style.space(2)
    width: parent.width - Style.space(8)
    height: collapsed.implicitHeight
    radius: Style.space(12)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)
  }

  NotificationRow {
    id: collapsed
    z: 1
    y: root.expanded ? groupHeader.height + Style.space(6) : 0
    width: parent.width
    app: root.app
    appIcon: root.appIcon
    summary: root.summary
    body: root.body
    image: root.image
    preview: root.preview
    glyph: root.glyph
    timestamp: root.timestamp
    now: root.now
    urgency: root.expanded ? root.urgency : root.groupUrgency
    unread: root.unread
    // Once expanded this is an ordinary summary notification. The group
    // header above it owns the count and collapse affordance.
    count: root.expanded ? 1 : root.count
    showBody: root.showBody
    showPreview: root.showPreview
    foreground: root.foreground
    fontFamily: root.fontFamily

    onClicked: {
      if (root.count > 1) root.toggleRequested(root.groupIdentity)
      else root.activateRequested(root.latestEntry())
    }
    onRemoveRequested: root.removeRequested(root.notificationKey)
  }

  Column {
    id: expandedColumn
    y: 0
    width: parent.width
    visible: root.expanded
    spacing: Style.space(6)

    Rectangle {
      id: groupHeader
      width: parent.width
      // Match the card's pre-expansion height, including the group action that
      // disappears below. A second click therefore lands on this collapse
      // target wherever the first click landed on the card.
      height: collapsed.implicitHeight + collapsed.groupActionHeight
      radius: Style.space(10)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleRequested(root.groupIdentity)
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(12)
        anchors.right: dismissAll.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.app + " \u00b7 " + root.count + " notifications"
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        color: root.foreground
      }

      Text {
        textFormat: Text.PlainText
        id: dismissAll
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "Dismiss all"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: dismissHover.hovered ? 1 : 0.65

        HoverHandler { id: dismissHover }
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.dismissAll()
        }
      }
    }

    // The summary card is positioned in this slot while expanded. Keeping the
    // slot in the column puts older notifications immediately beneath it while
    // allowing the group header and summary to exchange places.
    Item {
      width: parent.width
      height: collapsed.implicitHeight
    }

    Repeater {
      // The newest notification remains in the fixed summary card above, so
      // expansion adds only the older members rather than duplicating it.
      model: root.members.slice(1)

      NotificationRow {
        required property var modelData
        width: expandedColumn.width
        app: String(modelData.app || "")
        appIcon: String(modelData.appIcon || "")
        summary: String(modelData.summary || "")
        body: String(modelData.body || "")
        image: String(modelData.image || "")
        preview: String(modelData.preview || "")
        glyph: String(modelData.glyph || "")
        timestamp: Number(modelData.timestamp || 0)
        now: root.now
        urgency: Number(modelData.urgency || 0)
        unread: timestamp > root.readMark
        showBody: root.showBody
        showPreview: root.showPreview
        foreground: root.foreground
        fontFamily: root.fontFamily

        onClicked: root.activateRequested(modelData)
        onRemoveRequested: root.removeRequested(String(modelData.key || ""))
      }
    }
  }
}
