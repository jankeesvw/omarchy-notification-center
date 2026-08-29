import QtQuick
import Quickshell

ShellRoot {
  Service { id: service }

  Timer {
    interval: 50
    running: true
    onTriggered: {
      service.markSeen()
      second.restart()
    }
  }

  Timer {
    id: second
    interval: 10
    onTriggered: service.markSeen()
  }

  Timer {
    interval: 700
    running: true
    onTriggered: Qt.quit()
  }
}
