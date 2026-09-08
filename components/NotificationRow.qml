import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui

// One notification, as it reads after the fact.
//
// Drawn as a card rather than a line in a list, which is the shape macOS
// settled on and the right one for a reason: a notification is a thing that
// arrived, with edges, and a run of them stacked down a panel reads as a pile
// of arrivals. The same content as a row in a table reads as a spreadsheet of
// them.
//
// It is deliberately the same shape as the toast this notification was: same
// rounded corner, same icon on the left, same summary over body. Coming here
// should feel like finding the toast you missed, still sitting where it landed.
Item {
  id: root

  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  // The picture the notification is about, as opposed to the icon of whatever
  // sent it: the frame a camera caught, the screenshot that was just taken.
  property string preview: ""
  property string glyph: ""
  property double timestamp: 0
  // Ticked by the panel so "3m" ages on screen instead of freezing at whatever
  // it said when the panel opened.
  property double now: 0
  property int urgency: 1
  property bool showBody: true
  property bool showPreview: true
  property bool unread: false
  // What this notification can still do: { buttons: [{kind, label, index}],
  // canReply, onPhone }, or null for a card that is only there to be read.
  property var actions: null
  // Whether the reply field is open on this card. Owned by the panel.
  property bool replying: false

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()
  signal removeRequested()
  signal buttonPressed(var button)
  signal replySent(string text)
  signal replyCancelled()

  readonly property var buttons: actions && actions.buttons ? actions.buttons : []
  readonly property bool hasButtons: buttons.length > 0

  onReplyingChanged: {
    if (replying) Qt.callLater(function() { if (root.replying) replyField.forceActiveFocus() })
    else replyField.text = ""
  }

  readonly property bool hovered: hover.hovered
  // Per-notification media first (an avatar, album art), then the app's own
  // icon. Both may be missing, and the fallback below covers that.
  readonly property string iconSource: image !== "" ? resolve(image) : resolve(appIcon)
  readonly property bool hasIcon: iconSource !== "" && icon.status !== Image.Error
  readonly property string initial: app === "" ? "?" : app.charAt(0).toUpperCase()
  readonly property bool hasPreview: showPreview && preview !== "" && previewImage.status !== Image.Error

  // The body arrives as notification markup: a subset of HTML, plus whatever
  // the sender felt like putting in. Images are stripped rather than rendered,
  // because one <img> would set the height of the card to the height of the
  // image.
  readonly property string cleanBody: String(body || "")
    .replace(/<img[^>]*>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim()

  // The summary gets the same treatment as the body, and for a sharper reason:
  // a notification's text is chosen by whoever sent it, and anything on this
  // machine can send one. Qt reads a string that looks like markup as rich
  // text unless told otherwise, and rich text fetches `<img src="http://...">`
  // for real — a request out of the shell process, to a host of the sender's
  // choosing, the moment the row is drawn. Every Text below is pinned to
  // PlainText; stripping the tags as well is what keeps `<b>` from showing up
  // as four visible characters.
  readonly property string cleanSummary: String(summary || "")
    .replace(/<img[^>]*>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim()

  // Recent things get a duration, older things get a clock. "4m ago" is how
  // you think about something that just happened; "16:04" is how you think
  // about something from this morning, and the day it happened on is already
  // written above the card.
  readonly property string when: {
    var age = Math.max(0, now - timestamp)
    if (age < 60000) return "now"
    if (age < 3600000) return Math.round(age / 60000) + "m ago"
    return Qt.formatDateTime(new Date(timestamp), "HH:mm")
  }

  function resolve(icon) {
    var value = String(icon || "")
    if (value === "") return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    // check=true, so an icon name the theme doesn't have comes back empty
    // instead of as Qt's broken-image placeholder.
    return Quickshell.iconPath(value, true)
  }

  implicitHeight: card.implicitHeight

  HoverHandler { id: hover }

  Rectangle {
    id: card
    anchors.left: parent.left
    anchors.right: parent.right
    implicitHeight: texts.implicitHeight + Style.space(20)

    // The theme has no colour for "slightly raised", so the card is made out
    // of the foreground at low opacity. That works in a light theme as well as
    // a dark one, which a hardcoded panel tint would not: the card is always
    // whatever contrasts with the panel it is on.
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                   root.hovered ? 0.11 : 0.06)
    radius: Style.space(12)

    Behavior on color { ColorAnimation { duration: 90 } }

    // Critical notifications keep the one piece of colour on the card: a bar
    // down the leading edge. Everything else on it is grey, so this reads from
    // across the room, which is the entire point of an urgent notification
    // still being urgent an hour later.
    Rectangle {
      visible: root.urgency === 2
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(6)
      width: Style.space(3)
      radius: width / 2
      color: Color.urgent
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.removeRequested()
        else root.clicked()
      }
    }

    // The icon slot is always the same size, filled or not. A list whose left
    // edge moves depending on whether an app shipped an icon is a list you
    // cannot scan down.
    Item {
      id: avatar
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      width: Style.space(32)
      height: Style.space(32)

      Rectangle {
        anchors.fill: parent
        radius: Style.space(9)
        visible: !root.hasIcon
        color: root.foreground
        opacity: 0.12
      }

      // The sender's initial, for the apps that send notifications without
      // ever saying what they are. Still tells two senders apart at a glance,
      // which is all the icon was doing.
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: !root.hasIcon && root.glyph === ""
        text: root.initial
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        color: root.foreground
        opacity: 0.7
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: !root.hasIcon && root.glyph !== ""
        text: root.glyph
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        color: root.foreground
        opacity: 0.8
      }

      Image {
        id: icon
        anchors.fill: parent
        visible: root.hasIcon
        source: root.iconSource
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
      }
    }

    Column {
      id: texts
      anchors.left: avatar.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      spacing: Style.space(1)

      // App and time on one line above the message, the way every chat client
      // arranges the same three facts. The app name is the quiet one: you
      // already know what Slack looks like, and what you came to read is
      // underneath.
      Item {
        width: parent.width
        height: appLabel.implicitHeight

        Text {
          textFormat: Text.PlainText
          id: appLabel
          anchors.left: parent.left
          width: parent.width - whenLabel.implicitWidth - Style.space(20)
          text: root.app
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.5
        }

        // Swapped for the dismiss button while the pointer is over the card.
        // They never coexist, so neither has to make room for the other, and
        // the corner stays quiet until you reach for it.
        Text {
          textFormat: Text.PlainText
          id: whenLabel
          anchors.right: parent.right
          visible: !root.hovered
          text: root.when
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.45
        }

        Rectangle {
          id: dismiss
          anchors.right: parent.right
          anchors.rightMargin: -Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          visible: root.hovered
          width: Style.space(16)
          height: width
          radius: width / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                         dismissMouse.containsMouse ? 0.25 : 0.15)

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            // A multiplication sign, not the letter x and not a Nerd Font
            // glyph: it is in every font, at every size, and it is the shape
            // everybody reads as "close".
            text: "×"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.8
          }

          MouseArea {
            id: dismissMouse
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.removeRequested()
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.summary !== ""
        text: root.cleanSummary
        elide: Text.ElideRight
        maximumLineCount: 1
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        color: root.foreground
      }

      // Two lines of message and no more. Long enough to tell you whether you
      // need to go and open the thing, short enough that one chatty app cannot
      // push a day of notifications off the bottom of the panel.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.showBody && root.cleanBody !== ""
        text: root.cleanBody
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.75
      }

      // The picture, when the notification came with one. Wide rather than a
      // thumbnail in the corner: a motion alert is entirely about what is in
      // the frame, and at thumbnail size the answer to "what set it off" is
      // still "go and open it". Cropped to a letterbox so a run of them keeps
      // the list scannable however tall the originals were.
      Item {
        width: parent.width
        // Enough to see what happened and not so much that two motion alerts
        // fill the panel. The extra sliver is the gap above the picture, kept
        // in the height rather than as a spacer item, so a card without a
        // picture collapses to nothing at all instead of to six pixels of
        // nothing.
        height: root.hasPreview
          ? Math.min(width * 9 / 16, Style.space(104)) + Style.space(6) : 0
        visible: root.hasPreview

        Image {
          id: previewImage
          anchors.fill: parent
          anchors.topMargin: Style.space(6)
          source: root.showPreview ? root.preview : ""
          // Decoded at the size it is drawn at, twice over for a HiDPI screen.
          // A list of camera frames decoded at their original size is a list
          // that costs tens of megabytes to scroll.
          sourceSize.width: Math.round(width * 2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          smooth: true

          // Square corners inside a rounded card look like a mistake, and
          // clipping does not round: an Item clips to its bounding box and
          // ignores the radius. So the picture is drawn through a mask shaped
          // like the corner it should have. The threshold and spread are what
          // give that edge its antialiasing; without them the curve comes out
          // as a staircase.
          layer.enabled: true
          layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: previewMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
          }
        }

        // The shape, never drawn itself: MultiEffect reads its alpha and
        // nothing else.
        Rectangle {
          id: previewMask
          anchors.fill: previewImage
          radius: Style.space(8)
          color: "black"
          visible: false
          layer.enabled: true
          layer.smooth: true
        }
      }

      // The notification's own buttons, the ones the toast had: Mark as
      // read, Archive, Like, and a Reply and a Clear when the phone still
      // holds it. Small and outlined, under the text, where every chat
      // client puts them. A card with none of them keeps its old shape.
      Flow {
        width: parent.width
        visible: root.hasButtons && !root.replying
        topPadding: root.hasButtons ? Style.space(6) : 0
        spacing: Style.space(4)

        Repeater {
          model: root.buttons

          Button {
            required property var modelData
            text: modelData.label
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(2)
            onClicked: root.buttonPressed(modelData)
          }
        }
      }

      // The reply, typed here and sent to the phone. Enter sends, Escape
      // puts the buttons back.
      Item {
        width: parent.width
        visible: root.replying
        height: root.replying ? replyField.implicitHeight + Style.space(6) : 0

        TextField {
          id: replyField
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          placeholderText: "Reply\u2026"
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          verticalPadding: Style.space(4)
          onAccepted: {
            var message = text.trim()
            if (message !== "") root.replySent(message)
          }
          Keys.onEscapePressed: root.replyCancelled()
        }
      }
    }

    // Unread marker: a dot in the accent colour on the leading edge, where an
    // unread mail sits in every mail client. Cleared the moment you open the
    // center, which is what makes it worth having.
    Rectangle {
      visible: root.unread && root.urgency !== 2
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(5)
      height: width
      radius: width / 2
      color: Color.accent
    }
  }
}
