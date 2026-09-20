# redquit

Click the red close button on an app's **last** window and the app quits — the way it works on Windows.

macOS keeps most apps running after their last window is closed: the Dock dot stays, the app keeps
its memory, and Cmd+Tab fills up with windowless apps. `redquit` is a tiny background utility that
fixes this for the one gesture that clearly means "I'm done": a click on the red button.

- single Swift file, no dependencies, no Xcode project
- no Dock icon, no menu bar icon, runs as a LaunchAgent
- needs only the **Accessibility** permission
- macOS 12+, Apple Silicon and Intel

## Why does macOS keep apps running at all?

Why doesn't macOS quit an app when the user clicks "close"? Why does the app stay in memory and in
the Dock even after it has been closed?

In short: it is a legacy of the 1984 Mac that has never been changed. I'm not aware of an official
explanation from Apple; what follows is a reconstruction.

**Launch cost.** In 1984 apps were loaded from a floppy disk, later from a slow hard drive, and a
launch took anywhere from seconds to tens of seconds. Keeping the app resident meant the next
document opened instantly. NeXTSTEP, the ancestor of macOS, worked the same way, and that is also
where the Dock with its running-app indicator came from. With SSDs this argument has all but lost
its force, yet the behaviour remained.

**About memory.** Yes, an app sitting there without windows costs less than it seems. App Nap
brings its CPU usage close to zero, and unused pages are compressed and, under memory pressure,
swapped out. But it is not zero either: Electron apps hold on to hundreds of megabytes, some apps
keep background timers and network activity going, and there is a noticeable delay when an app
comes back from compressed memory or swap. So the cost is real, but small.

The main annoyance, however, is not memory but cognitive load: Cmd+Tab and the Dock fill up with
apps that have no windows. `redquit` is meant to solve exactly that.

## What it does — and deliberately doesn't

| Situation | Result |
|---|---|
| Red button on the only window | app quits (politely — unsaved-changes prompts still appear) |
| Red button while other windows exist (incl. minimized, Settings, a compose window) | just closes the window |
| Other windows are on another Space or in fullscreen | just closes the window |
| "Save changes?" → **Cancel** | nothing happens, the click is forgotten |
| "Save changes?" → Save / Don't Save | app quits once the window is really gone |
| Option-click (close all windows) | app quits |
| Cmd+W, File → Close, closing a tab | untouched — only a real click on the red button counts |
| Menu bar / background apps (`LSUIElement`, accessory) | never touched |
| Apps that own a menu bar item (Docker, 1Password, …) | never quit — they are meant to live without windows |
| Finder | never quit |
| Apps in your exclude list | never quit |

## Install

```sh
git clone https://github.com/hamet/redquit.git
cd redquit
./install.sh
```

`install.sh` builds the binary, signs it ad hoc, copies it to `/usr/local/bin/redquit` and loads the
LaunchAgent `com.user.redquit` (starts at login, restarts if it dies).

Then grant the permission: **System Settings → Privacy & Security → Accessibility → add
`/usr/local/bin/redquit`**. No restart needed; it starts working as soon as the switch is on.

Requires the Xcode Command Line Tools (`xcode-select --install`) for `swiftc`.

### Build only

```sh
./build.sh      # produces ./redquit, installs nothing
./redquit       # run in the foreground, log goes to the terminal
```

When started from a terminal, the Accessibility grant must be given to the terminal app — it has
its own TCC context, separate from the LaunchAgent.

### Uninstall

```sh
./uninstall.sh
```

## Configuration

**Exclude list** — `~/.config/redquit/exclude`, one bundle id per line, `#` starts a comment.
The file is re-read on every click, so no restart is needed.

```sh
mkdir -p ~/.config/redquit
cat >> ~/.config/redquit/exclude <<'END'
# apps that should stay alive without windows
com.apple.mail
com.apple.Music
END
```

Find a bundle id with `osascript -e 'id of app "Mail"'`.

**Timings** — constants in the `Config` section at the top of `redquit.swift`; re-run `./install.sh`
after changing them.

| Constant | Default | Meaning |
|---|---|---|
| `pollInterval` | 0.05 s | how often we check whether the clicked window is gone |
| `settleDelay` | 0.15 s | pause after the window disappears, so a follow-up window can appear |
| `confirmDelay` | 0.15 s | "no windows left" must hold twice; set to `0` for the fastest quit |
| `vetoGrace` | 2 s | window still there with no sheet/alert → the close was cancelled |
| `pollHardCap` | 300 s | upper limit while a save sheet / save panel is open |

## Log

`/tmp/redquit.log` (set in the plist as `StandardErrorPath`). Every decision is one line with its reason:

```
redquit: Preview: last window closed → quit
redquit: Safari: 1 window(s) left ["GitHub"], keep
redquit: Notes: window #4121 1200x800 on space [7], keep
redquit: Docker Desktop: owns a menu bar item, keep
redquit: TextEdit: window did not close (cancelled / vetoed), ignore
```

```sh
tail -f /tmp/redquit.log
```

If an app quits when it shouldn't, or stays when it should quit, this line tells why.

## How it works

1. A global `NSEvent` monitor receives left mouse down / up. Mouse monitors need no TCC grant, so
   there is no event tap and no Input Monitoring permission.
2. On mouse down the Accessibility element under the cursor is resolved. If it is a window's
   `AXCloseButton`, the window and pid are remembered; mouse up must land on the same button.
3. The decision is made **after** the close, not before. `redquit` waits until that exact window
   disappears from the app's `AXWindows`. While a sheet or a modal alert is up it keeps waiting; if
   the window stays with nothing pending, the click is dropped.
4. Then it counts what is left: all AX windows (minimized ones included), plus windows on other
   Spaces. Zero, confirmed twice → `NSRunningApplication.terminate()`, the same polite quit as Cmd+Q.
   An AX error (unresponsive app) is never treated as "no windows".

### Private API note

`AXWindows` only lists windows of the current Space. To see windows on other Spaces and in
fullscreen, `redquit` calls three SkyLight functions (`SLSMainConnectionID`, `SLSGetActiveSpace`,
`SLSCopySpacesForWindows`). They are resolved with `dlsym` at runtime, so nothing is linked against
a private framework; if Apple removes them, a warning is logged and only that check is skipped.

## Limitations

- Apps that draw their own traffic lights instead of the system ones expose no `AXCloseButton` and
  are not recognised.
- If a Settings or compose window is the *only* window left and you close it with the red button,
  the app quits — it was the last window. Use the exclude list for apps where that is unwanted.
- A floating panel (Fonts, Colors, an inspector) counts as a window, so the app stays while one is open.
- The menu bar item check is a heuristic; an app with both a Dock icon and a status item never quits.
- After rebuilding, the ad-hoc signature may invalidate the Accessibility grant — remove the entry
  and add it again.

## Similar tools

Swift Quit, RedQuits and Last Window Quits solve the
same problem. `redquit` differs in scope rather than features: it reacts only to a real click on
the close button instead of any window disappearing, which avoids a whole class of false quits
(start screens, tabs, helper windows), and it is one readable source file you can audit in ten minutes.

## License

MIT — see [LICENSE](LICENSE).
