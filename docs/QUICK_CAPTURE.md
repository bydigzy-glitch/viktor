# Quick capture: notes, links, reminders, events

Personal fork of Coucou that turns the notch into a design-work assistant. This file is the
**run guide**, the **test checklist**, and the **full roadmap**.

---

## 1. Run it on your Mac

Requirements: macOS 15+, Xcode 16+ (free, App Store).

```bash
git clone <your fork URL> coucou
cd coucou/NotchBuddy
open NotchBuddy.xcodeproj
```

In Xcode: pick the **NotchBuddy** scheme (top bar) → **My Mac** → press **Run** (⌘R).

The Mochi island appears at the notch (or top-centre on a Mac without a notch).

Optional, only if you add/remove Swift files later:

```bash
brew install xcodegen
cd NotchBuddy && xcodegen   # regenerates NotchBuddy.xcodeproj from project.yml
```

### Permissions macOS will ask for

| When | Prompt | Why |
|---|---|---|
| First global shortcut use | **Accessibility** (System Settings → Privacy & Security → Accessibility → enable Coucou) | Global shortcuts (⌃⌥Space) only work with this on |
| First reminder you capture | **Reminders** | Adds it to Apple Reminders |
| First event you capture | **Calendars** | Adds it to Apple Calendar, shows today's agenda |

Debug builds are ad-hoc signed, so macOS may ask again after a rebuild. If a shortcut stops
working after rebuilding, remove Coucou from the Accessibility list and add it again.

### Keep it running all the time

Settings (menu bar icon → Settings…) → **Startup → Launch at Mac startup**.
For a build you don't need Xcode for: Xcode → Product → Archive → Distribute App → Copy App →
drag it into /Applications.

---

## 2. What the quick capture does

Press **⌃⌥Space** from any app (change it in Settings → Quick capture), or click the pencil tab
in the island, or menu bar → Quick Capture. Type one line, press **Return**. **Esc** closes.

| You type | It becomes | Stored in |
|---|---|---|
| `call Sam tomorrow 3pm` | Reminder "Call Sam", tomorrow 15:00 | Apple Reminders (+ inbox) |
| `remind me to send invoice friday` | Reminder "Send invoice", Friday (all-day) | Apple Reminders |
| `shoot with Mia fri 10am to 12pm` | Event, Friday 10:00–12:00 | Apple Calendar |
| `lunch with Jo tomorrow 1pm` | Event (keyword "lunch"), 1 h | Apple Calendar |
| `https://pinterest.com/pin/…` | Link (page title fetched) | This Mac only |
| `read https://… tonight` | Reminder with the link attached | Apple Reminders |
| `rust + cream palette for the drop` | Note | This Mac only |

- The chips above the field light up with what it detected. Click a chip to force the type;
  click it again to go back to auto.
- Prefixes force the type too: `n:` note, `l:` link, `r:` reminder, `e:` event.
- Detection is instant and offline (Apple's NSDataDetector). No AI, no network.
- Link titles are fetched from the page you pasted (first 64 KB, 6 s timeout). That's the
  only network call quick capture makes.

**Inbox** (tray tab, or the "Inbox" link under the field): everything you captured, newest
first, filters per type, today's calendar at the top. Hover a row for actions:
open link / copy note / open Reminders or Calendar / remove. Ticking a reminder completes it
in Apple Reminders too. Removing an event or reminder from the inbox **does not** delete it from
Calendar/Reminders (on purpose).

**Mochi nudges**: when a timed reminder you captured is due, the island pops out with it and
Mochi looks surprised (plus the normal Reminders notification). It never interrupts an alert,
a chat or something you're typing.

**If Reminders/Calendar access is off**, the item is still saved in the inbox (marked
"Only here") and the field tells you how to turn access on. Nothing you type is lost.

Data file: `~/Library/Application Support/NotchBuddy/captures.json`
(Settings → Quick capture → Show file). If it's ever unreadable, it's copied aside as
`captures.corrupt-<time>.json` instead of being overwritten.

---

## 3. Test checklist (do this after the first build)

- [ ] App builds and runs; Mochi greets as before; existing tabs still work
- [ ] ⌃⌥Space from Safari/Illustrator opens the field with the cursor already in it
- [ ] Each example in the table above picks the right chip and preview
- [ ] `3pm` typed after 3pm today → preview says Tomorrow
- [ ] Reminder lands in Reminders with the right time and an alert
- [ ] Event lands in Calendar with the right start/end
- [ ] Deny Calendar access once → item still in inbox, warning shown
- [ ] Link row shows the page title a second later
- [ ] Tick a reminder in the inbox → completed in Reminders
- [ ] Capture `r: test in 2 minutes`… wait → Mochi pops out with the reminder
- [ ] Quit and relaunch → inbox still there
- [ ] Esc closes the field; alerts from Claude Code still interrupt normally

Anything wrong: copy the Xcode error / describe what happened and hand it back to Claude.

---

## 4. Roadmap

Built in this branch = **Phase 1**. Each later phase is its own branch.

### Phase 1: Quick capture (done, needs a first build + test on a Mac)
- Capture field, type detection, Reminders/Calendar via EventKit, local notes/links, inbox,
  today's agenda, reminder nudges, capture shortcut, settings section.
- Files: `CaptureModels.swift`, `CaptureParser.swift`, `CaptureStore.swift`,
  `CalendarBridge.swift`, `CaptureViews.swift`, plus small hooks in `IslandTypes`,
  `IslandViewContent`, `IslandRootView`, `IslandWindowController`, `AppState`, `AppDelegate`,
  `SettingsView`.

### Phase 2: Polish the capture
- Edit an item in place (click the title) and snooze a reminder (+1 h / tomorrow).
- Search in the inbox; pin notes.
- Drag an image or file onto the island → saved as a note with the file attached
  (reuses the existing drop handling).
- Clipboard shortcut: capture whatever is on the clipboard with one key.
- Pick which Reminders list / calendar to use (Settings).
- Mochi "writing" pose while you type (new BotState, drawn in BotEngine like the others).

### Phase 3: Notion sync
- Coucou already stores a Notion key (Settings) and polls pages. Add "Send to Notion" per
  kind: notes → a *Notes* database, links → a *Moodboard* database (URL, title, tags).
- One-way first (Mac → Notion), with a "Synced" badge in the inbox; failures keep the item
  local and retry later. Never delete in Notion from the Mac.

### Phase 4: Voice (hold to talk)
- Hold a key (e.g. Right ⌥) → Mochi "listening" state with a live level meter → release →
  on-device speech-to-text (Apple Speech framework, works offline) → text goes into the same
  capture parser. "remind me to call Sam at 3" works by voice with zero extra logic.
- Permissions: Microphone + Speech Recognition.

### Phase 5: "What am I looking at?"
- Shortcut grabs the window under the cursor (ScreenCaptureKit, Screen Recording permission)
  and sends it with your question to Claude via the existing `ClaudeService`.
- Presets: "What style is this?" (style, era, palette hex codes, likely fonts),
  "Save to moodboard" (auto-tags into Phase 3's Notion database).
- Only captures on key press, never in the background.

### Phase 6: Agent does the design work
- Hand a task ("make a poster in this style in Illustrator") to a computer-use agent
  (Claude computer use, or Astra if it gets an API). The island shows live steps, a pause /
  take-back key, and approve cards before saving or exporting (Coucou's approval UI already
  does this for Claude Code).
- Scripted Illustrator chores (export 3x, outline text…) via AppleScript/ExtendScript,
  which are faster and more reliable than an agent for fixed jobs.

### Phase 7: Fitroom link
- "Put this on a tee" → Fitroom mockup in the island; "Is this print-ready?" → Fitroom
  print-prep checks.

### Before sharing it with anyone else
The name "Coucou", Mochi, the icon and the sounds belong to Louis Raillé (see
`LICENSE-ASSETS.md`). Fine for personal use; replace them before distributing.
