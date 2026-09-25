// Pure window-list and grid logic for Filmstrip. No QML imports, so it can be
// unit-tested with node (see tests/windows.test.js).

var SKIP_CLASSES = {
  "xwaylandvideobridge": true,
  "xdg-desktop-portal-gtk": true
}

function ipcOf(toplevel) {
  return (toplevel && toplevel.lastIpcObject) || {}
}

function classOf(toplevel) {
  var ipc = ipcOf(toplevel)
  var cls = String(ipc["class"] || ipc.initialClass || "")
  if (cls) return cls
  try {
    return toplevel && toplevel.wayland ? String(toplevel.wayland.appId || "") : ""
  } catch (e) {
    return ""
  }
}

function workspaceOf(toplevel) {
  var ipc = ipcOf(toplevel)
  var ws = toplevel ? toplevel.workspace : null
  var ipcWs = ipc.workspace || {}
  var id = 0
  if (ws && typeof ws.id === "number") id = ws.id
  else if (typeof ipcWs.id === "number") id = ipcWs.id
  var name = ""
  if (ws && ws.name) name = String(ws.name)
  else if (ipcWs.name) name = String(ipcWs.name)
  return { id: id, name: name }
}

function isScratchpad(ws) {
  if (!ws) return false
  if (typeof ws.id === "number" && ws.id < 0) return true
  var name = String(ws.name || "").toLowerCase()
  return name.indexOf("special") === 0
}

function aspectOf(ipc) {
  var size = (ipc && ipc.size) || []
  var w = Number(size[0])
  var h = Number(size[1])
  if (!isFinite(w) || !isFinite(h) || w <= 0 || h <= 0) return 1.6
  return Math.max(0.5, Math.min(3, w / h))
}

// Screen a window is on. The workspace object is kept current by Hyprland
// events; the IPC snapshot can lag behind for windows that just opened.
function monitorOf(toplevel, monitors) {
  var ws = toplevel ? toplevel.workspace : null
  var name = ws && ws.monitor && ws.monitor.name ? String(ws.monitor.name) : ""
  var ipcId = ipcOf(toplevel).monitor
  for (var i = 0; i < (monitors || []).length; i++) {
    var m = monitors[i]
    if ((name && m.name === name) || (!name && typeof ipcId === "number" && m.id === ipcId))
      return m
  }
  return { id: -1, name: name, x: 0 }
}

// monitors: [{ id, name, x }] so windows sort left to right by screen.
function collectWindows(toplevels, monitors) {
  var out = []
  // Accepts a plain array or Quickshell's ObjectModel (which exposes .values).
  var values = Array.isArray(toplevels) ? toplevels : ((toplevels && toplevels.values) || [])
  for (var i = 0; i < values.length; i++) {
    var t = values[i]
    if (!t) continue
    var ipc = ipcOf(t)
    if (ipc.mapped === false) continue
    var ws = workspaceOf(t)
    var scratch = isScratchpad(ws)
    if (ipc.hidden === true && !scratch) continue
    var cls = classOf(t)
    if (SKIP_CLASSES[cls.toLowerCase()]) continue
    var title = String(t.title || ipc.title || "")
    if (!cls && !title) continue
    var at = ipc.at || [0, 0]
    var mon = monitorOf(t, monitors)
    out.push({
      address: String(t.address || ipc.address || ""),
      className: cls,
      title: title,
      workspaceId: ws.id,
      workspaceName: ws.name,
      scratchpad: scratch,
      monitorName: mon.name,
      monitorX: mon.x,
      x: Number(at[0]) || 0,
      y: Number(at[1]) || 0,
      aspect: aspectOf(ipc),
      focusHistory: typeof ipc.focusHistoryID === "number" ? ipc.focusHistoryID : 999,
      urgent: t.urgent === true
    })
  }
  out.sort(compareWindows)
  return out
}

// Spatial order: screen left to right, then workspace, then position on screen.
// Scratchpad windows go last.
function compareWindows(a, b) {
  if (a.scratchpad !== b.scratchpad) return a.scratchpad ? 1 : -1
  if (a.monitorX !== b.monitorX) return a.monitorX - b.monitorX
  if (a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId
  if (a.x !== b.x) return a.x - b.x
  if (a.y !== b.y) return a.y - b.y
  return a.address < b.address ? -1 : (a.address > b.address ? 1 : 0)
}

// Index of the window to preselect: the previously focused one (focus history
// 1), like Alt+Tab. Falls back to the focused window, then the first.
function initialIndex(rows) {
  var best = -1
  var bestHist = 1e9
  for (var i = 0; i < rows.length; i++) {
    var h = rows[i].focusHistory
    if (h >= 1 && h < bestHist) {
      best = i
      bestHist = h
    }
  }
  if (best >= 0) return best
  for (var j = 0; j < rows.length; j++) {
    if (rows[j].focusHistory === 0) return j
  }
  return 0
}

function matchesFilter(row, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return true
  var blob = [
    row.appName || "", row.title, row.className,
    "ws" + row.workspaceId, row.workspaceName,
    row.scratchpad ? "scratchpad special" : ""
  ].join(" ").toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++) {
    if (blob.indexOf(words[i]) === -1) return false
  }
  return true
}

// Pick the column count that makes cards as large as possible when n cards
// of the given aspect ratio are packed into a width x height area.
// captionH is the fixed text strip under each preview.
function gridLayout(n, width, height, gap, aspect, captionH, maxCardW) {
  var ar = aspect > 0 ? aspect : 1.6
  var cap = captionH || 0
  var best = { columns: 1, rows: 1, cardW: 0, cardH: 0 }
  if (n <= 0 || width <= 0 || height <= 0) return best
  for (var cols = 1; cols <= n; cols++) {
    var rows = Math.ceil(n / cols)
    var cellW = (width - gap * (cols - 1)) / cols
    var cellH = (height - gap * (rows - 1)) / rows
    if (cellW <= 0 || cellH <= cap) continue
    var w = cellW
    var previewH = w / ar
    if (previewH + cap > cellH) {
      previewH = cellH - cap
      w = previewH * ar
    }
    if (maxCardW && w > maxCardW) {
      w = maxCardW
      previewH = w / ar
    }
    if (w > best.cardW) {
      best = { columns: cols, rows: rows, cardW: Math.floor(w), cardH: Math.floor(previewH + cap) }
    }
  }
  return best
}

// Single-row layout: all n cards side by side. Up to fitCount cards always
// fit on screen (they shrink as needed); past that, cards keep the size of
// fitCount cards and the row scrolls (scrollable: true). Card height is capped
// by the area and card width by maxCardW.
function rowLayout(n, width, height, gap, aspect, captionH, fitCount, maxCardW) {
  var ar = aspect > 0 ? aspect : 1.6
  var cap = captionH || 0
  var out = { cardW: 0, cardH: 0, contentWidth: 0, scrollable: false }
  if (n <= 0 || width <= 0 || height <= cap) return out
  var fit = Math.max(1, Math.min(n, fitCount || n))
  var w = (width - gap * (fit - 1)) / fit
  var tallest = (height - cap) * ar
  if (w > tallest) w = tallest
  if (maxCardW && w > maxCardW) w = maxCardW
  w = Math.floor(w)
  out.cardW = w
  out.cardH = Math.floor(w / ar + cap)
  out.contentWidth = n * w + gap * (n - 1)
  out.scrollable = out.contentWidth > width + 0.5
  return out
}

// Workspaces to offer as drop targets, grouped by screen (left to right).
// rules:      [{ workspaceString, monitor }] from `hyprctl workspacerules -j`
// workspaces: [{ id, monitorName }] that exist right now
// monitors:   [{ name, x, activeWorkspaceId }]
// windows:    rows from collectWindows (for per-workspace app lists)
// Named and special workspaces are left out; the target is a workspace number.
// When every workspace of a screen already holds a window, that screen gets
// one extra empty slot (extra: true) with the lowest unused workspace number,
// so there is always somewhere to drop a window.
function workspaceStrip(rules, workspaces, monitors, windows) {
  var byMonitor = {}
  var seen = {}
  function add(id, monitorName) {
    if (!(id > 0) || seen[id] || !monitorName) return
    seen[id] = true
    if (!byMonitor[monitorName]) byMonitor[monitorName] = []
    byMonitor[monitorName].push(id)
  }
  for (var i = 0; i < (rules || []).length; i++) {
    var r = rules[i]
    var id = Number(r.workspaceString)
    if (String(id) === String(r.workspaceString).trim()) add(id, String(r.monitor || ""))
  }
  for (var j = 0; j < (workspaces || []).length; j++) add(Number(workspaces[j].id), workspaces[j].monitorName)

  function nextFree() {
    var id = 1
    while (seen[id]) id++
    seen[id] = true
    return id
  }

  var groups = []
  var mons = (monitors || []).slice().sort(function(a, b) { return a.x - b.x })
  for (var k = 0; k < mons.length; k++) {
    var m = mons[k]
    var ids = (byMonitor[m.name] || []).sort(function(a, b) { return a - b })
    var slots = []
    for (var s = 0; s < ids.length; s++) {
      var apps = []
      for (var w = 0; w < (windows || []).length; w++) {
        if (windows[w].workspaceId === ids[s]) apps.push(windows[w].className)
      }
      slots.push({ id: ids[s], apps: apps, active: ids[s] === m.activeWorkspaceId, extra: false, monitor: m.name })
    }
    var full = slots.length > 0
    for (var f = 0; f < slots.length; f++) {
      if (slots[f].apps.length === 0) full = false
    }
    if (full) slots.push({ id: nextFree(), apps: [], active: false, extra: true, monitor: m.name })
    groups.push({ monitor: m.name, slots: slots })
  }
  return groups
}

// Arrow-key movement in a grid of `count` items laid out in `columns`.
// Left/right wrap across rows; up/down keep the column and clamp to the
// last item in a short final row.
function moveIndex(index, direction, columns, count) {
  if (count <= 0) return 0
  var cols = Math.max(1, columns)
  if (direction === "left") return (index - 1 + count) % count
  if (direction === "right") return (index + 1) % count
  var rows = Math.ceil(count / cols)
  var row = Math.floor(index / cols)
  var col = index % cols
  if (direction === "up") row = (row - 1 + rows) % rows
  else if (direction === "down") row = (row + 1) % rows
  else return index
  return Math.min(row * cols + col, count - 1)
}

if (typeof module !== "undefined") {
  module.exports = {
    collectWindows: collectWindows,
    compareWindows: compareWindows,
    initialIndex: initialIndex,
    matchesFilter: matchesFilter,
    gridLayout: gridLayout,
    moveIndex: moveIndex,
    rowLayout: rowLayout,
    workspaceStrip: workspaceStrip,
    isScratchpad: isScratchpad,
    aspectOf: aspectOf
  }
}
