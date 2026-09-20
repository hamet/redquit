// redquit — click the red close button on an app's LAST window and the app quits.
//
// Single file, no dependencies.
//   build:  swiftc -O redquit.swift -o redquit
//   needs:  System Settings → Privacy & Security → Accessibility
//   log:    stderr (LaunchAgent routes it to /tmp/redquit.log)
//
// How it works
//   1. A global NSEvent monitor sees left mouse down/up (mouse monitors need no TCC grant).
//   2. On mouse down the AX element under the cursor is resolved; if it is a window's
//      AXCloseButton, the window + pid are remembered. Mouse up must land on the same button.
//   3. We wait until that window actually disappears. While a sheet / modal alert is up we keep
//      waiting; if the window stays with nothing pending for 2 s, the close was cancelled and the
//      click is forgotten. Then we count what is left — twice, 0.15 s apart.
//      Nothing left → polite NSRunningApplication.terminate().
//      Counted as "left": every AX window incl. minimized ones, panels, settings.
//      Never quit: non-regular (LSUIElement/accessory) apps, apps that turn accessory after the
//      close, apps owning a menu bar item, Finder, the exclude list.
//   4. AX only lists windows of the current Space, so windows on other Spaces / fullscreen
//      are checked through SkyLight (private, resolved with dlsym; if the symbols are
//      missing the check is skipped and a warning is logged).
//
// Only red-button clicks are handled. Cmd+W behaves as before.
//
// Excludes: bundle ids, one per line, in ~/.config/redquit/exclude ('#' = comment).
// The file is re-read on every click, no restart needed. Finder is always excluded.

import AppKit
import ApplicationServices

// MARK: - Config

let builtinExcludes: Set<String> = ["com.apple.finder"]
let excludePath = NSString(string: "~/.config/redquit/exclude").expandingTildeInPath

let pollInterval: TimeInterval = 0.05   // how often we look whether the clicked window is gone
let vetoGrace: TimeInterval = 2         // window still there and no sheet/modal for this long = close was vetoed/cancelled
let pollHardCap: TimeInterval = 300     // absolute limit while a save sheet / save panel is open
let settleDelay: TimeInterval = 0.15    // after the window is gone, let the app open a follow-up window
let confirmDelay: TimeInterval = 0.15   // "no windows" must hold twice before we quit (start screens, window swaps)

func log(_ s: String) { fputs("redquit: \(s)\n", stderr) }

func excludedBundleIDs() -> Set<String> {
    var set = builtinExcludes
    if let text = try? String(contentsOfFile: excludePath, encoding: .utf8) {
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty && !id.hasPrefix("#") { set.insert(id) }
        }
    }
    return set
}

// MARK: - AX helpers

let systemWide = AXUIElementCreateSystemWide()

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let value = v, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Frame in global top-left coordinates (same space as CGEvent locations).
func axFrame(_ el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
          let pv = p, let sv = s,
          CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

/// nil = AX error (app busy / not answering) — caller must NOT treat it as "no windows".
func axWindows(_ pid: pid_t) -> [AXUIElement]? {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) {
    case .success: return (v as? [AXUIElement]) ?? []
    case .noValue: return []
    default:       return nil
    }
}

func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? Bool
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
    return (v as? [AXUIElement]) ?? []
}

/// The close is pending on the user: a sheet on the clicked window ("Save changes?", save panel,
/// "Close all tabs?") or an app-modal alert.
func closeIsPending(_ window: AXUIElement, among wins: [AXUIElement]) -> Bool {
    if axChildren(window).contains(where: { axString($0, kAXRoleAttribute) == kAXSheetRole }) { return true }
    return wins.contains { !CFEqual($0, window) && axBool($0, kAXModalAttribute) == true }
}

/// App owns a status item → it is meant to live in the menu bar without windows.
func hasMenuBarExtra(_ pid: pid_t) -> Bool {
    guard let extras = axElement(AXUIElementCreateApplication(pid), kAXExtrasMenuBarAttribute) else { return false }
    return !axChildren(extras).isEmpty
}

struct CloseHit {
    let pid: pid_t
    let window: AXUIElement
    let buttonFrame: CGRect
}

/// Is there a window close button under this point?
func closeButton(at pt: CGPoint) -> CloseHit? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(pt.x), Float(pt.y), &hit) == .success,
          let el = hit else { return nil }

    var button: AXUIElement?
    if axString(el, kAXSubroleAttribute) == kAXCloseButtonSubrole {
        button = el
    } else {
        // Hit-testing sometimes returns a toolbar/titlebar element lying over the traffic lights.
        let win = axString(el, kAXRoleAttribute) == kAXWindowRole ? el : axElement(el, kAXWindowAttribute)
        if let win = win { button = axElement(win, kAXCloseButtonAttribute) }
    }
    guard let b = button,
          let frame = axFrame(b), frame.insetBy(dx: -1, dy: -1).contains(pt),
          let window = axElement(b, kAXWindowAttribute) ?? axElement(b, kAXParentAttribute) else { return nil }

    var pid: pid_t = 0
    guard AXUIElementGetPid(b, &pid) == .success, pid > 0 else { return nil }
    return CloseHit(pid: pid, window: window, buttonFrame: frame)
}

// MARK: - Other Spaces (SkyLight via dlsym)

struct SkyLight {
    typealias MainConnFn   = @convention(c) () -> Int32
    typealias ActiveSpcFn  = @convention(c) (Int32) -> UInt64
    typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> UnsafeRawPointer?

    let mainConnection: MainConnFn
    let activeSpace: ActiveSpcFn
    let copySpaces: CopySpacesFn

    static func load() -> SkyLight? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let a = dlsym(h, "SLSMainConnectionID"),
              let b = dlsym(h, "SLSGetActiveSpace"),
              let c = dlsym(h, "SLSCopySpacesForWindows") else { return nil }
        return SkyLight(mainConnection: unsafeBitCast(a, to: MainConnFn.self),
                        activeSpace: unsafeBitCast(b, to: ActiveSpcFn.self),
                        copySpaces: unsafeBitCast(c, to: CopySpacesFn.self))
    }

    func spaces(of windowID: Int, _ cid: Int32) -> [UInt64] {
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let raw = copySpaces(cid, 0x7 /* all spaces */, ids) else { return [] }
        let arr = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as NSArray
        return arr.compactMap { ($0 as? NSNumber)?.uint64Value }
    }
}

let skyLight = SkyLight.load()

/// A real window of `pid` that lives on a Space other than the active one
/// (incl. fullscreen and windows minimized there). The active Space is AX's job.
func windowOnOtherSpace(_ pid: pid_t) -> String? {
    guard let sl = skyLight,
          let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let cid = sl.mainConnection()
    let active = sl.activeSpace(cid)

    for w in list {
        guard w[kCGWindowOwnerPID as String] as? pid_t == pid,
              w[kCGWindowLayer as String] as? Int == 0,
              (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let wid = w[kCGWindowNumber as String] as? Int,
              let bd = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
              r.width >= 50, r.height >= 50 else { continue }
        let spaces = sl.spaces(of: wid, cid)
        if !spaces.isEmpty && !spaces.contains(active) {
            return "window #\(wid) \(Int(r.width))x\(Int(r.height)) on space \(spaces)"
        }
    }
    return nil
}

// MARK: - Watcher

final class Watcher {
    private var pending: CloseHit?
    private var generation = 0

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            self?.handle(e)
        }
    }

    private func location(_ e: NSEvent) -> CGPoint {
        if let p = e.cgEvent?.location { return p }
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            pending = nil
            guard AXIsProcessTrusted() else { return }
            pending = closeButton(at: location(e))

        case .leftMouseUp:
            guard let hit = pending else { return }
            pending = nil
            // Dragged off the button before releasing = no close.
            guard hit.buttonFrame.insetBy(dx: -2, dy: -2).contains(location(e)) else { return }
            guard let app = NSRunningApplication(processIdentifier: hit.pid),
                  app.activationPolicy == .regular,
                  hit.pid != ProcessInfo.processInfo.processIdentifier else { return }
            if let id = app.bundleIdentifier, excludedBundleIDs().contains(id) { return }

            generation += 1
            let now = Date()
            poll(hit, gen: generation, started: now, lastPending: now)

        default:
            break
        }
    }

    /// Wait until the clicked window is really gone.
    /// - window gone                         → evaluate
    /// - window there + sheet / modal alert  → keep waiting (user is deciding / saving)
    /// - window there, nothing pending       → after `vetoGrace` the close is considered cancelled;
    ///   a later Cmd+W on that window will NOT be attributed to this click.
    private func poll(_ hit: CloseHit, gen: Int, started: Date, lastPending: Date) {
        guard gen == generation else { return }     // a newer close click took over
        guard let app = NSRunningApplication(processIdentifier: hit.pid), !app.isTerminated else { return }
        let name = app.localizedName ?? "pid \(hit.pid)"
        let now = Date()
        var pendingSeen = lastPending

        if let wins = axWindows(hit.pid) {
            if !wins.contains(where: { CFEqual($0, hit.window) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                    self?.evaluate(hit.pid, confirmed: false)
                }
                return
            }
            if closeIsPending(hit.window, among: wins) { pendingSeen = now }
        }
        let seen = pendingSeen
        if now.timeIntervalSince(seen) > vetoGrace {
            log("\(name): window did not close (cancelled / vetoed), ignore")
            return
        }
        if now.timeIntervalSince(started) > pollHardCap {
            log("\(name): still pending after \(Int(pollHardCap))s, giving up")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.poll(hit, gen: gen, started: started, lastPending: seen)
        }
    }

    private func evaluate(_ pid: pid_t, confirmed: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let name = app.localizedName ?? "pid \(pid)"

        // Apps that show a Dock icon only while a window is open drop to .accessory right after the close.
        guard app.activationPolicy == .regular else { log("\(name): became a background/menu bar app, keep"); return }

        guard let wins = axWindows(pid) else { log("\(name): AX error, not touching it"); return }
        if !wins.isEmpty {
            let titles = wins.map { axString($0, kAXTitleAttribute) ?? "" }
            log("\(name): \(wins.count) window(s) left \(titles), keep")
            return
        }
        if let other = windowOnOtherSpace(pid) {
            log("\(name): \(other), keep")
            return
        }
        if hasMenuBarExtra(pid) { log("\(name): owns a menu bar item, keep"); return }

        guard confirmed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + confirmDelay) { [weak self] in
                self?.evaluate(pid, confirmed: true)
            }
            return
        }
        log("\(name): last window closed → quit")
        app.terminate()
    }
}

// MARK: - main

AXUIElementSetMessagingTimeout(systemWide, 0.5)   // never hang on an unresponsive app

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    log("waiting for Accessibility permission (works as soon as it is granted)")
}
if skyLight == nil {
    log("warning: SkyLight symbols not found — windows on other Spaces will NOT be seen")
}

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)
let watcher = Watcher()
watcher.start()
log("started")
nsApp.run()
