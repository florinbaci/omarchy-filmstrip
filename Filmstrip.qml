import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Windows.js" as Windows

// Filmstrip: every open window at once in one row, with live previews and app
// icons, plus a strip of workspaces (grouped by screen) to drag windows onto.
// Opened with `omarchy-shell shell toggle io.github.florinbaci.filmstrip`.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.florinbaci.filmstrip"
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  readonly property string wallpaperPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property var rows: []
  property var targetScreen: null
  property bool multiMonitor: false
  // Set once the user moves the selection, so the settle rebuild keeps it.
  property bool userMoved: false
  // Workspace strip: [{ monitor, slots: [{ id, apps, active }] }]
  property var workspaceGroups: []
  property var workspaceRules: []
  // Address of the window being dragged, "" when not dragging.
  property string dragAddress: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color muted: Color.muted
  property string fontFamily: Style.font.menuFamily

  // Tighter gaps when many cards share the row.
  readonly property int gap: windowModel.count > 6 ? Style.space(14) : Style.space(22)
  // The selected card grows by this much; the row keeps room for it.
  readonly property real selectedScale: 1.10
  readonly property int edgePad: Style.space(32)
  // Up to this many cards always fit on screen; more scroll left and right.
  readonly property int fitCount: 10
  readonly property int captionHeight: Style.space(58)
  readonly property int cardRadius: Math.max(Style.cornerRadius, Style.space(14))
  readonly property var layout: Windows.rowLayout(
    windowModel.count, cardArea.width - root.edgePad * 2, cardArea.height / root.selectedScale, root.gap,
    root.targetScreen ? Math.max(1, root.targetScreen.width / Math.max(1, root.targetScreen.height)) : 16 / 9,
    root.captionHeight, root.fitCount, Style.space(560))

  // ---- shell overlay contract -------------------------------------------

  // payloadJson may preset the search, e.g. '{"filter":"ws2"}'.
  function open(payloadJson) {
    root.targetScreen = root.focusedScreen()
    root.filterText = root.payloadFilter(payloadJson)
    rulesQuery.running = true
    if (Hyprland.refreshToplevels) Hyprland.refreshToplevels()
    if (root.appLibrary && root.appLibrary.refreshIcons) root.appLibrary.refreshIcons()
    root.rebuild(true)
    root.userMoved = false
    root.opened = true
    settleTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function payloadFilter(payloadJson) {
    try {
      var payload = JSON.parse(String(payloadJson || "{}")) || {}
      return typeof payload.filter === "string" ? payload.filter : ""
    } catch (e) {
      return ""
    }
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- data -------------------------------------------------------------

  function focusedScreen() {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function monitorList() {
    var out = []
    var mons = Hyprland.monitors ? (Hyprland.monitors.values || []) : []
    for (var i = 0; i < mons.length; i++) {
      var ipc = mons[i].lastIpcObject || {}
      out.push({
        id: mons[i].id,
        name: String(mons[i].name || ""),
        x: Number(ipc.x !== undefined ? ipc.x : mons[i].x) || 0
      })
    }
    root.multiMonitor = out.length > 1
    return out
  }

  // Desktop entry for a window class. Exact ids beat StartupWMClass, which
  // beats looser icon/name matches (foot must not resolve to footclient).
  function desktopEntry(className) {
    var needle = String(className || "").toLowerCase()
    if (!needle) return null
    var tail = needle.split(".").pop()
    var values = DesktopEntries.applications ? (DesktopEntries.applications.values || []) : []
    var best = null
    var bestRank = 99
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (!e) continue
      var id = String(e.id || "").toLowerCase()
      var idTail = id.split(".").pop()
      var rank = 99
      if (id === needle) rank = 0
      else if (String(e.startupClass || "").toLowerCase() === needle) rank = 1
      else if (idTail === needle || idTail === tail) rank = 2
      else if (String(e.icon || "").toLowerCase() === needle || String(e.icon || "").toLowerCase() === tail) rank = 3
      else if (String(e.name || "").toLowerCase() === needle) rank = 4
      if (rank < bestRank) {
        best = e
        bestRank = rank
      }
    }
    return best
  }

  function prettyClass(className) {
    var raw = String(className || "")
    var last = raw.split(".").pop().replace(/[-_]+/g, " ").trim()
    if (!last) return "App"
    return last.charAt(0).toUpperCase() + last.slice(1)
  }

  function decorate(row) {
    var entry = root.desktopEntry(row.className)
    row.appName = entry ? (root.appLibrary ? root.appLibrary.entryName(entry) : String(entry.name || "")) : root.prettyClass(row.className)
    var iconName = entry && entry.icon ? String(entry.icon) : row.className
    row.icon = String(root.appLibrary ? root.appLibrary.iconSource(iconName) : Quickshell.iconPath(iconName, true))
    var where = row.scratchpad ? "Scratchpad" : ("WS " + (row.workspaceName || row.workspaceId))
    if (root.multiMonitor && !row.scratchpad && row.monitorName) where += "  ·  " + row.monitorName
    row.badge = where
    row.badgeShort = row.scratchpad ? "Scratch" : ("WS " + (row.workspaceName || row.workspaceId))
    return row
  }

  function rebuild(resetSelection) {
    var keep = ""
    if (!resetSelection && root.selectedIndex >= 0 && root.selectedIndex < windowModel.count)
      keep = String(windowModel.get(root.selectedIndex).address || "")

    var all = Windows.collectWindows(Hyprland.toplevels, root.monitorList())
    var shown = []
    for (var i = 0; i < all.length; i++) {
      var row = root.decorate(all[i])
      if (Windows.matchesFilter(row, root.filterText)) shown.push(row)
    }

    windowModel.clear()
    for (var j = 0; j < shown.length; j++) windowModel.append(shown[j])
    root.rows = shown

    var next = resetSelection ? Windows.initialIndex(shown) : 0
    if (keep) {
      for (var k = 0; k < shown.length; k++) {
        if (shown[k].address === keep) next = k
      }
    }
    root.selectedIndex = shown.length === 0 ? 0 : Math.min(next, shown.length - 1)
    pointerGate.reset()
    root.rebuildStrip(all)
    Qt.callLater(root.scrollToSelection)
  }

  function rebuildStrip(allWindows) {
    var mons = []
    var monValues = Hyprland.monitors ? (Hyprland.monitors.values || []) : []
    var positions = root.monitorList()
    for (var i = 0; i < monValues.length; i++) {
      var m = monValues[i]
      var x = 0
      for (var p = 0; p < positions.length; p++) if (positions[p].name === m.name) x = positions[p].x
      mons.push({ name: String(m.name || ""), x: x, activeWorkspaceId: m.activeWorkspace ? m.activeWorkspace.id : -1 })
    }
    var existing = []
    var wsValues = Hyprland.workspaces ? (Hyprland.workspaces.values || []) : []
    for (var j = 0; j < wsValues.length; j++) {
      var ws = wsValues[j]
      existing.push({ id: ws.id, monitorName: ws.monitor ? String(ws.monitor.name || "") : "" })
    }
    var groups = Windows.workspaceStrip(root.workspaceRules, existing, mons, allWindows)
    // Icon URLs for the apps on each workspace (max 4 shown).
    for (var g = 0; g < groups.length; g++) {
      for (var s = 0; s < groups[g].slots.length; s++) {
        var slot = groups[g].slots[s]
        var icons = []
        for (var a = 0; a < slot.apps.length && icons.length < 4; a++) {
          var entry = root.desktopEntry(slot.apps[a])
          var iconName = entry && entry.icon ? String(entry.icon) : slot.apps[a]
          icons.push({
            source: String(root.appLibrary ? root.appLibrary.iconSource(iconName) : Quickshell.iconPath(iconName, true)),
            name: entry ? String(entry.name || "") : root.prettyClass(slot.apps[a])
          })
        }
        slot.icons = icons
      }
    }
    root.workspaceGroups = groups
  }

  // Keep the selected card on screen when the row is wider than the area.
  function scrollToSelection() {
    if (!root.layout.scrollable || windowModel.count === 0) {
      cardArea.contentX = 0
      return
    }
    var step = root.layout.cardW + root.gap
    var left = root.edgePad + root.selectedIndex * step
    var right = left + root.layout.cardW
    var pad = root.edgePad
    var maxX = Math.max(0, cardArea.contentWidth - cardArea.width)
    if (left - pad < cardArea.contentX) cardArea.contentX = Math.max(0, left - pad)
    else if (right + pad > cardArea.contentX + cardArea.width)
      cardArea.contentX = Math.min(maxX, right + pad - cardArea.width)
  }

  function setFilter(text) {
    root.filterText = text
    root.rebuild(false)
    if (text) root.selectedIndex = 0
  }

  // ---- actions ----------------------------------------------------------

  function normalizeAddress(address) {
    var a = String(address || "").trim()
    if (!a) return ""
    if (a.indexOf("0x") !== 0) a = "0x" + a
    return a
  }

  function findToplevel(address) {
    var values = Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
    for (var i = 0; i < values.length; i++) {
      if (root.normalizeAddress(values[i].address) === root.normalizeAddress(address)) return values[i]
    }
    return null
  }

  function captureSource(address) {
    var t = root.findToplevel(address)
    return t && t.wayland ? t.wayland : null
  }

  function activate(index) {
    if (index < 0 || index >= windowModel.count) return
    focusTimer.address = root.normalizeAddress(windowModel.get(index).address)
    root.dismiss()
    focusTimer.restart()
  }

  function closeWindow(index) {
    if (index < 0 || index >= windowModel.count) return
    var a = root.normalizeAddress(windowModel.get(index).address)
    if (!a) return
    Quickshell.execDetached(["hyprctl", "eval",
      'hl.dispatch(hl.dsp.window.close({ window = "address:' + a + '" }))'])
  }

  function move(direction) {
    root.userMoved = true
    pointerGate.reset()
    root.selectedIndex = Windows.moveIndex(root.selectedIndex, direction, windowModel.count, windowModel.count)
    root.scrollToSelection()
  }

  // Send a window to a workspace without following it. Filmstrip stays open
  // and refreshes, so the card's tag and the strip show the result.
  function moveToWorkspace(address, workspaceId) {
    var a = root.normalizeAddress(address)
    if (!a || !(workspaceId > 0)) return
    root.userMoved = true
    Quickshell.execDetached(["hyprctl", "eval",
      'hl.dispatch(hl.dsp.window.move({ workspace = "' + workspaceId + '", follow = false, window = "address:' + a + '" }))'])
    moveRefresh.restart()
  }

  function switchToWorkspace(workspaceId) {
    root.dismiss()
    Quickshell.execDetached(["hyprctl", "eval",
      'hl.dispatch(hl.dsp.focus({ workspace = "' + workspaceId + '" }))'])
  }

  ListModel { id: windowModel }

  // App icon, or the first letter of the app name when the theme has none.
  component AppIcon: Item {
    id: appIconRoot
    property string source: ""
    property string name: ""

    Image {
      id: img
      anchors.fill: parent
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      source: appIconRoot.source
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
    }

    Rectangle {
      anchors.fill: parent
      visible: !appIconRoot.source || img.status === Image.Error || img.status === Image.Null
      radius: width / 2
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25)

      Text {
        anchors.centerIn: parent
        text: (appIconRoot.name || "?").charAt(0).toUpperCase()
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Math.max(8, Math.round(appIconRoot.height * 0.55))
        font.bold: true
      }
    }
  }

  // refreshToplevels() is async: positions and focus history of windows that
  // just opened arrive a moment after open(), so rebuild once more.
  Timer {
    id: settleTimer
    interval: 250
    onTriggered: if (root.opened) root.rebuild(!root.userMoved && !root.filterText)
  }

  // After a move, refresh the IPC snapshot, then rebuild once it has landed.
  Timer {
    id: moveRefresh
    interval: 120
    onTriggered: {
      if (Hyprland.refreshToplevels) Hyprland.refreshToplevels()
      if (Hyprland.refreshWorkspaces) Hyprland.refreshWorkspaces()
      settleTimer.restart()
    }
  }

  // Which workspace belongs to which screen, including ones that don't exist
  // yet (from the workspace rules in ~/.config/hypr/overview.lua).
  Process {
    id: rulesQuery
    command: ["hyprctl", "workspacerules", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.workspaceRules = JSON.parse(text) || []
        } catch (e) {
          root.workspaceRules = []
        }
        if (root.opened) root.rebuild(false)
      }
    }
  }

  // Hover only changes the selection after the pointer really moves, so the
  // card that happens to sit under a still mouse doesn't steal it on open.
  PointerMoveGate {
    id: pointerGate
    referenceItem: keyCatcher
  }

  // Focus after the overlay has released keyboard focus, so the target
  // window actually receives it.
  Timer {
    id: focusTimer
    interval: 16
    property string address: ""
    onTriggered: {
      if (!address) return
      Quickshell.execDetached(["hyprctl", "eval",
        'hl.dispatch(hl.dsp.focus({ window = "address:' + address + '" }))'])
      address = ""
    }
  }

  // Closed windows disappear from the grid while it is open.
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() {
      if (root.opened) root.rebuild(false)
    }
  }

  // ---- UI ---------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "filmstrip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Blurred, dimmed wallpaper behind everything.
    Image {
      anchors.fill: parent
      source: "file://" + root.wallpaperPath
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      layer.enabled: true
      layer.effect: MultiEffect {
        blurEnabled: true
        blur: 0.8
        blurMax: 56
        saturation: 0.25
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.72)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: overlay
      anchors.fill: parent

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var alt = (event.modifiers & Qt.AltModifier) !== 0
        if (alt && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          if (root.selectedIndex < windowModel.count)
            root.moveToWorkspace(windowModel.get(root.selectedIndex).address, event.key - Qt.Key_0)
        } else if (event.key === Qt.Key_Escape) {
          if (root.filterText) root.setFilter("")
          else root.dismiss()
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate(root.selectedIndex)
        } else if (event.key === Qt.Key_Delete || (ctrl && event.key === Qt.Key_W)) {
          root.closeWindow(root.selectedIndex)
        } else if (event.key === Qt.Key_Left) {
          root.move("left")
        } else if (event.key === Qt.Key_Right) {
          root.move("right")
        } else if (event.key === Qt.Key_Tab) {
          root.move("right")
        } else if (event.key === Qt.Key_Backtab) {
          root.move("left")
        } else if (event.key === Qt.Key_Home) {
          root.selectedIndex = 0
          root.scrollToSelection()
        } else if (event.key === Qt.Key_End) {
          root.selectedIndex = Math.max(0, windowModel.count - 1)
          root.scrollToSelection()
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && !ctrl) {
          root.setFilter(root.filterText + event.text)
        } else {
          return
        }
        event.accepted = true
      }
    }

    // Search pill.
    Rectangle {
      id: search
      anchors.top: parent.top
      anchors.topMargin: Style.space(40)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width - Style.space(80), Style.space(560))
      height: Style.space(48)
      radius: height / 2
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.85)
      border.width: Style.space(2)
      border.color: root.filterText ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

      Text {
        anchors.fill: parent
        anchors.leftMargin: Style.space(22)
        anchors.rightMargin: Style.space(22)
        verticalAlignment: Text.AlignVCenter
        text: root.filterText || "Type to search windows…"
        color: root.filterText ? root.foreground : root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideLeft
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(22)
        anchors.verticalCenter: parent.verticalCenter
        text: windowModel.count + (windowModel.count === 1 ? " window" : " windows")
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // One row of cards. It scrolls sideways (following the selection, or with
    // the mouse wheel) only when the cards no longer fit at their minimum size.
    Flickable {
      id: cardArea
      anchors.top: search.bottom
      anchors.bottom: strip.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(48)
      anchors.rightMargin: Style.space(48)
      anchors.topMargin: Style.space(24)
      anchors.bottomMargin: Style.space(24)
      contentWidth: Math.max(width, root.layout.contentWidth + root.edgePad * 2)
      contentHeight: height
      flickableDirection: Flickable.HorizontalFlick
      // Dragging is for moving windows, not for flicking the row.
      interactive: false
      clip: true

      Behavior on contentX { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) {
          var d = event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x
          if (d !== 0) root.move(d < 0 ? "right" : "left")
        }
      }

    Repeater {
      model: windowModel

      delegate: Item {
        id: card
        required property int index
        required property string address
        required property string appName
        required property string title
        required property string icon
        required property string badge
        required property string badgeShort
        required property real aspect
        required property bool urgent

        readonly property bool selected: index === root.selectedIndex
        readonly property bool dragged: root.dragAddress === address
        // Centered when everything fits; otherwise starts at the edge padding and scrolls.
        readonly property real rowStart: root.layout.scrollable ? root.edgePad : (cardArea.width - root.layout.contentWidth) / 2
        // Narrow cards (many windows) show just the icon and app name.
        readonly property bool compact: width < Style.space(260)

        x: rowStart + index * (root.layout.cardW + root.gap)
        y: (cardArea.height - root.layout.cardH) / 2
        width: root.layout.cardW
        height: root.layout.cardH
        scale: selected ? root.selectedScale : 1.0
        opacity: dragged ? 0.35 : 1.0
        z: selected ? 2 : 1

        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Rectangle {
          id: frame
          anchors.fill: parent
          radius: root.cardRadius
          color: Qt.rgba(root.background.r, root.background.g, root.background.b, card.selected ? 0.95 : 0.8)
          border.width: card.selected ? Style.space(3) : 1
          border.color: card.selected ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
        }

        // Live preview, letterboxed to the window's own aspect ratio.
        Item {
          id: previewBox
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(10)
          height: parent.height - root.captionHeight - Style.space(10)
          clip: true

          readonly property real fitW: Math.min(width, height * card.aspect)
          readonly property real fitH: fitW / card.aspect

          Rectangle {
            id: previewMask
            anchors.centerIn: parent
            width: previewBox.fitW
            height: previewBox.fitH
            radius: Math.max(0, root.cardRadius - Style.space(6))
            visible: false
            layer.enabled: true
          }

          ScreencopyView {
            anchors.centerIn: parent
            width: previewBox.fitW
            height: previewBox.fitH
            captureSource: root.opened ? root.captureSource(card.address) : null
            live: root.opened
            paintCursor: false
            layer.enabled: true
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: previewMask
              maskThresholdMin: 0.5
              maskSpreadAtMin: 1
            }
          }
        }

        // Caption: icon, app name, window title.
        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          height: root.captionHeight
          spacing: Style.space(12)

          AppIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(34)
            height: width
            source: card.icon
            name: card.appName
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(34) - (badge.visible ? badge.width + parent.spacing : 0) - parent.spacing
            spacing: 2

            Text {
              width: parent.width
              text: card.appName
              textFormat: Text.PlainText
              color: card.selected ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: !card.compact
              text: card.title
              textFormat: Text.PlainText
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Where the window lives.
          Rectangle {
            id: badge
            visible: !card.compact
            anchors.verticalCenter: parent.verticalCenter
            width: badgeText.implicitWidth + Style.space(16)
            height: badgeText.implicitHeight + Style.space(8)
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

            Text {
              id: badgeText
              anchors.centerIn: parent
              text: card.width < Style.space(400) ? card.badgeShort : card.badge
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Rectangle {
          visible: card.urgent
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(18)
          width: Style.space(10)
          height: width
          radius: width / 2
          color: Color.urgent
        }

        MouseArea {
          id: cardMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton
          drag.target: dragProxy
          drag.threshold: Style.space(8)
          property bool wasDragged: false

          onPressed: function(mouse) {
            wasDragged = false
            // Center the floating copy under the pointer before a drag starts.
            var p = card.mapToItem(overlay, mouse.x, mouse.y)
            dragProxy.x = p.x - dragProxy.width / 2
            dragProxy.y = p.y - dragProxy.height / 2
            dragProxy.appName = card.appName
            dragProxy.icon = card.icon
            dragProxy.address = card.address
          }
          onPositionChanged: function(mouse) {
            if (drag.active) {
              if (!wasDragged) {
                wasDragged = true
                root.dragAddress = card.address
              }
              return
            }
            if (pointerGate.moved(card, mouse)) {
              root.userMoved = true
              root.selectedIndex = card.index
            }
          }
          onReleased: {
            if (wasDragged) dragProxy.Drag.drop()
            root.dragAddress = ""
          }
          onClicked: function(mouse) {
            if (wasDragged) return
            if (mouse.button === Qt.MiddleButton) root.closeWindow(card.index)
            else root.activate(card.index)
          }
        }
      }
    }

    }

    Text {
      visible: windowModel.count === 0
      anchors.centerIn: cardArea
      text: root.filterText ? "No windows match \"" + root.filterText + "\"" : "No open windows"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    // Workspaces grouped by screen: drop a card here to move that window.
    Row {
      id: strip
      anchors.bottom: hints.top
      anchors.bottomMargin: Style.space(20)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(36)

      Repeater {
        model: root.workspaceGroups

        delegate: Column {
          id: group
          required property var modelData
          spacing: Style.space(8)

          Text {
            text: group.modelData.monitor
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(10)

            Repeater {
              model: group.modelData.slots

              delegate: Rectangle {
                id: slot
                required property var modelData
                readonly property bool hovered: drop.containsDrag || slotMouse.containsMouse

                width: Style.space(104)
                height: Style.space(64)
                radius: Style.space(12)
                color: drop.containsDrag
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
                  : Qt.rgba(root.background.r, root.background.g, root.background.b, slot.hovered ? 0.95 : 0.8)
                border.width: drop.containsDrag || slot.modelData.active ? Style.space(2) : 1
                border.color: drop.containsDrag || slot.modelData.active
                  ? root.accent
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
                scale: drop.containsDrag ? 1.08 : 1.0

                Behavior on scale { NumberAnimation { duration: 100 } }

                Text {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.leftMargin: Style.space(10)
                  anchors.topMargin: Style.space(6)
                  text: slot.modelData.id
                  color: slot.modelData.active ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Row {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.rightMargin: Style.space(8)
                  anchors.bottomMargin: Style.space(8)
                  spacing: Style.space(3)

                  Repeater {
                    model: slot.modelData.icons || []
                    delegate: AppIcon {
                      required property var modelData
                      width: Style.space(18)
                      height: width
                      source: modelData.source
                      name: modelData.name
                    }
                  }
                }

                Text {
                  visible: slot.modelData.apps.length > 4
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.rightMargin: Style.space(10)
                  anchors.topMargin: Style.space(8)
                  text: "+" + (slot.modelData.apps.length - 4)
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                DropArea {
                  id: drop
                  anchors.fill: parent
                  keys: ["filmstrip-window"]
                  onDropped: function(dropEvent) {
                    root.moveToWorkspace(dragProxy.address, slot.modelData.id)
                    dropEvent.accept()
                  }
                }

                MouseArea {
                  id: slotMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.switchToWorkspace(slot.modelData.id)
                }
              }
            }
          }
        }
      }
    }

    // Floating copy of the card being dragged.
    Rectangle {
      id: dragProxy
      property string address: ""
      property string appName: ""
      property string icon: ""

      visible: root.dragAddress !== ""
      width: Style.space(200)
      height: Style.space(56)
      radius: height / 2
      z: 100
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.95)
      border.width: Style.space(2)
      border.color: root.accent

      Drag.active: root.dragAddress !== ""
      Drag.keys: ["filmstrip-window"]
      Drag.hotSpot.x: width / 2
      Drag.hotSpot.y: height / 2

      Row {
        anchors.centerIn: parent
        spacing: Style.space(10)

        AppIcon {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(28)
          height: width
          source: dragProxy.icon
          name: dragProxy.appName
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: dragProxy.appName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
    }

    Text {
      id: hints
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(24)
      anchors.horizontalCenter: parent.horizontalCenter
      text: "←→ move  ·  Enter switch  ·  drag onto a workspace or Alt+1–9 to move it there  ·  Del close  ·  type to search  ·  Esc"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    }
  }
}
