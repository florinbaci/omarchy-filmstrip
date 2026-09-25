// Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const W = require("../Windows.js")

const MONITORS = [{ id: 0, name: "HDMI-A-1", x: 0 }, { id: 1, name: "DP-2", x: 1536 }]

function toplevel(address, cls, ws, mon, at, extra) {
  return Object.assign({
    address: address,
    title: cls + " window",
    lastIpcObject: Object.assign({
      class: cls, workspace: { id: ws, name: String(ws) }, monitor: mon,
      at: at, size: [1600, 900], mapped: true, hidden: false, focusHistoryID: 5
    }, extra || {})
  })
}

test("sorts by screen left to right, then workspace, then position", () => {
  const rows = W.collectWindows([
    toplevel("c", "right-ws5", 5, 1, [0, 0]),
    toplevel("b", "left-ws2", 2, 0, [0, 0]),
    toplevel("a2", "left-ws1-b", 1, 0, [800, 0]),
    toplevel("a1", "left-ws1-a", 1, 0, [0, 0])
  ], MONITORS)
  assert.deepEqual(rows.map(r => r.address), ["a1", "a2", "b", "c"])
  assert.equal(rows[3].monitorName, "DP-2")
})

test("scratchpad windows go last and hidden normal windows are skipped", () => {
  const rows = W.collectWindows([
    toplevel("s", "scratch", -98, 0, [0, 0], { workspace: { id: -98, name: "special:scratchpad" }, hidden: true }),
    toplevel("h", "hidden", 1, 0, [0, 0], { hidden: true }),
    toplevel("n", "normal", 3, 0, [0, 0])
  ], MONITORS)
  assert.deepEqual(rows.map(r => r.address), ["n", "s"])
  assert.equal(rows[1].scratchpad, true)
})

test("skips unmapped windows and portal helpers", () => {
  const rows = W.collectWindows([
    toplevel("u", "app", 1, 0, [0, 0], { mapped: false }),
    toplevel("p", "xdg-desktop-portal-gtk", 1, 0, [0, 0]),
    toplevel("ok", "app", 1, 0, [0, 0])
  ], MONITORS)
  assert.deepEqual(rows.map(r => r.address), ["ok"])
})

test("initialIndex picks the previously focused window", () => {
  const rows = [{ focusHistory: 0 }, { focusHistory: 3 }, { focusHistory: 1 }]
  assert.equal(W.initialIndex(rows), 2)
  assert.equal(W.initialIndex([{ focusHistory: 0 }]), 0)
  assert.equal(W.initialIndex([]), 0)
})

test("filter matches every word across app, title and workspace", () => {
  const row = { appName: "Brave", title: "GitHub - PR", className: "brave-browser", workspaceId: 2, workspaceName: "2" }
  assert.equal(W.matchesFilter(row, ""), true)
  assert.equal(W.matchesFilter(row, "brave git"), true)
  assert.equal(W.matchesFilter(row, "ws2"), true)
  assert.equal(W.matchesFilter(row, "brave slack"), false)
})

test("gridLayout fits every card inside the area", () => {
  for (let n = 1; n <= 24; n++) {
    const g = W.gridLayout(n, 1400, 800, 20, 16 / 9, 48)
    assert.ok(g.columns * g.rows >= n, `n=${n} needs enough cells`)
    assert.ok(g.columns * g.cardW + (g.columns - 1) * 20 <= 1400 + 0.5, `n=${n} width fits`)
    assert.ok(g.rows * g.cardH + (g.rows - 1) * 20 <= 800 + 0.5, `n=${n} height fits`)
    assert.ok(g.cardW > 0)
  }
})

test("gridLayout uses a sensible shape for common counts on a wide area", () => {
  assert.equal(W.gridLayout(1, 1400, 800, 20, 16 / 9, 48).columns, 1)
  assert.equal(W.gridLayout(4, 1400, 800, 20, 16 / 9, 48).columns, 2)
  assert.equal(W.gridLayout(6, 1400, 800, 20, 16 / 9, 48).columns, 3)
})

test("gridLayout respects the max card width", () => {
  const g = W.gridLayout(1, 3000, 2000, 20, 16 / 9, 48, 600)
  assert.equal(g.cardW, 600)
})

test("moveIndex wraps left/right and keeps column on up/down", () => {
  // 7 items, 3 columns:  0 1 2 / 3 4 5 / 6
  assert.equal(W.moveIndex(0, "left", 3, 7), 6)
  assert.equal(W.moveIndex(6, "right", 3, 7), 0)
  assert.equal(W.moveIndex(1, "down", 3, 7), 4)
  assert.equal(W.moveIndex(4, "down", 3, 7), 6) // short last row clamps
  assert.equal(W.moveIndex(6, "down", 3, 7), 0) // wraps to top
  assert.equal(W.moveIndex(0, "up", 3, 7), 6)
  assert.equal(W.moveIndex(2, "up", 3, 7), 6) // clamps into short row
  assert.equal(W.moveIndex(0, "down", 3, 0), 0)
})

test("screen comes from the live workspace object when the IPC snapshot lags", () => {
  const fresh = toplevel("new", "app", 7, 0, [0, 0], { monitor: undefined })
  fresh.workspace = { id: 7, name: "7", monitor: { name: "DP-2" } }
  const rows = W.collectWindows([fresh, toplevel("old", "app", 1, 0, [0, 0])], MONITORS)
  assert.deepEqual(rows.map(r => r.address), ["old", "new"])
  assert.equal(rows[1].monitorName, "DP-2")
  assert.equal(rows[1].monitorX, 1536)
})

test("rowLayout fits up to fitCount cards on screen without scrolling", () => {
  for (let n = 1; n <= 10; n++) {
    const g = W.rowLayout(n, 1400, 500, 20, 16 / 9, 48, 10, 520)
    assert.equal(g.scrollable, false, `n=${n}`)
    assert.ok(g.contentWidth <= 1400, `n=${n} fits`)
    assert.ok(g.cardH <= 500)
  }
  assert.equal(W.rowLayout(1, 1400, 500, 20, 16 / 9, 48, 10, 520).cardW, 520) // capped
})

test("rowLayout keeps the 10-card size and scrolls from the 11th card", () => {
  const ten = W.rowLayout(10, 1400, 500, 20, 16 / 9, 48, 10, 520)
  const twelve = W.rowLayout(12, 1400, 500, 20, 16 / 9, 48, 10, 520)
  assert.equal(twelve.cardW, ten.cardW)
  assert.equal(twelve.scrollable, true)
  assert.equal(twelve.contentWidth, 12 * ten.cardW + 11 * 20)
})

test("rowLayout limits card height to the area", () => {
  const g = W.rowLayout(1, 3000, 300, 20, 16 / 9, 48, 10, 2000)
  assert.ok(g.cardH <= 300)
})

test("workspaceStrip groups ruled and existing workspaces by screen", () => {
  const rules = [
    { workspaceString: "5", monitor: "DP-2" }, { workspaceString: "1", monitor: "HDMI-A-1" },
    { workspaceString: "2", monitor: "HDMI-A-1" }, { workspaceString: "name:web", monitor: "DP-2" }
  ]
  const existing = [{ id: 9, monitorName: "HDMI-A-1" }, { id: -98, monitorName: "DP-2" }, { id: 5, monitorName: "DP-2" }]
  const monitors = [{ name: "DP-2", x: 1536, activeWorkspaceId: 5 }, { name: "HDMI-A-1", x: 0, activeWorkspaceId: 1 }]
  const windows = [{ workspaceId: 5, className: "foot" }, { workspaceId: 5, className: "brave" }, { workspaceId: 1, className: "code" }]
  const strip = W.workspaceStrip(rules, existing, monitors, windows)
  assert.deepEqual(strip.map(g => g.monitor), ["HDMI-A-1", "DP-2"])
  assert.deepEqual(strip[0].slots.map(s => s.id), [1, 2, 9])
  // DP-2's only workspace has windows, so it also gets an extra empty slot
  // with the lowest unused number.
  assert.deepEqual(strip[1].slots.map(s => s.id), [5, 3])
  assert.equal(strip[1].slots[1].extra, true)
  assert.deepEqual(strip[1].slots[0].apps, ["foot", "brave"])
  assert.equal(strip[0].slots[0].active, true)
  assert.equal(strip[0].slots[1].active, false)
})

test("workspaceStrip adds one empty slot to a screen whose workspaces are all in use", () => {
  const rules = [1, 2, 3, 4].map(n => ({ workspaceString: String(n), monitor: "HDMI-A-1" }))
    .concat([5, 6, 7, 8].map(n => ({ workspaceString: String(n), monitor: "DP-2" })))
  const monitors = [{ name: "HDMI-A-1", x: 0, activeWorkspaceId: 1 }, { name: "DP-2", x: 1536, activeWorkspaceId: 5 }]
  const full = [1, 2, 3, 4].map(n => ({ workspaceId: n, className: "app" + n }))
  let strip = W.workspaceStrip(rules, [], monitors, full)
  assert.deepEqual(strip[0].slots.map(s => s.id), [1, 2, 3, 4, 9]) // 5-8 belong to DP-2
  assert.equal(strip[0].slots[4].extra, true)
  assert.equal(strip[0].slots[4].monitor, "HDMI-A-1")
  assert.equal(strip[1].slots.length, 4) // DP-2 still has empty workspaces
  assert.ok(strip[1].slots.every(s => !s.extra))

  // Both screens full: each gets its own, different extra slot.
  const both = full.concat([5, 6, 7, 8].map(n => ({ workspaceId: n, className: "b" + n })))
  strip = W.workspaceStrip(rules, [], monitors, both)
  assert.equal(strip[0].slots[4].id, 9)
  assert.equal(strip[1].slots[4].id, 10)

  // An existing workspace 9 on HDMI-A-1 that is full too: the next free is 10.
  const nine = full.concat([{ workspaceId: 9, className: "c" }])
  strip = W.workspaceStrip(rules, [{ id: 9, monitorName: "HDMI-A-1" }], monitors, nine)
  assert.deepEqual(strip[0].slots.map(s => s.id), [1, 2, 3, 4, 9, 10])
})
