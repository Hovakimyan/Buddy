# Buddy: own character with full behaviour, question answering, first-run steps — design

Date: 2026-10-20. Builds on `2026-10-19-buddy-design.md` and on the branch that brought the earlier character back (commit 9b77094).

## 1. Why

The maintainer tried the running app and found it thin: the character barely moves, only three sounds play, questions
with several answers can only be answered in the terminal, and a new user is not told what to do after installing.
They also decided (2026-10-20) that **everything in Buddy must be Buddy's own**: its own character, its own or freely
licensed sounds, its own code, and no mention of any other product in the app.

They want:
1. **A lively character of our own**: a simple rounded **square with eyes and glossy reflections**, with a full set of
   states, expressions and reactions (section 3). Later it may become a green construction safety helmet for the project team,
   so swapping the character must be easy.
2. **Sounds from a free library** that allows shipping them in an app (section 4).
3. **Answer Claude's multiple-choice questions** (`AskUserQuestion`: one to four questions, single or multi select) from
   the Mac island and the iPhone, and accept or send back a plan (`ExitPlanMode`) from the Mac (section 6).
4. **Exact first-run steps**, so a colleague who installs the app knows what to do and sees when it works (section 8).

Success:
- Every state, expression and reaction in section 3 can be seen on the island; the demo (section 7) shows them all.
- A developer can add another character (the helmet) by following `docs/replacing-the-character.md`, touching only the
  new character's folder and one registration line, and swap sounds by replacing files.
- A real `AskUserQuestion` (Claude Code 2.1.85+) is answered from the Mac card or the iPhone and Claude Code continues
  with those answers, no terminal input.
- A first-time user goes from opening the app to "Buddy sees your session" by following the window, without docs.
- The app bundle, its source and the repo docs contain no third-party character, sound or icon whose licence does not
  allow distribution, and no mention of another product (section 9).

## 2. Scope

In: the character layer and the square character (3); the sound layer and a free sound set (4); the island with all
its states, motion, overview, session pills and cards (5); questions and plans (6); demo mode (7); first-run steps and
"hooks outdated" (8); removing the previous character, sounds and every outside mention, and rewriting the few pieces
of code that came from elsewhere (9).

Also in, as **phase B** (maintainer, 2026-10-20: "add everything"), specified in section 13: outfits, a character
that walks out onto the desktop, moods from Mac load, dancing to music, voice, chat, jump to terminal, and the other
extras listed there. Phase A (sections 3 to 9) ships first and works on its own; phase B builds on it. Each phase gets
its own plan.

Anti-goals:
- An answer or allow that no human picked: the relay prints nothing unless a person chose (existing rule).
- A character that silently draws nothing for a state: a missing look must fail to compile or fail a test.
- Any asset in the app whose licence does not allow redistribution in a commercial internal app.

## 3. Character layer

### 3.1 Vocabulary (owned by the app, not by a character)

`CharacterState` and when the island sets it:

| State | Trigger |
|---|---|
| idle | SessionStart; nothing running; 5 s after finished |
| working | PreToolUse / PostToolUse / PostToolUseFailure |
| thinking | UserPromptSubmit, until the first tool event |
| searching | PreToolUse of Grep, Glob, WebSearch, WebFetch |
| approval | a permission card or plan card is pending |
| question | a question card is pending; a Notification whose message ends in "?" |
| error | StopFailure |
| finished | Stop |
| rateLimited | a Notification containing "rate limit" (case-insensitive) |
| sleeping | island visible and no session event for 120 s |
| dizzy | three clicks on the character within 1.7 s; lasts about 3 s, then a happy expression |

- The island shows the focused session's state; a pending card anywhere takes focus.
- `CharacterEmote` (one-shot, on top of the state): love, surprised, proud, wink, yawn, happy, annoyed, listening.
- Reactions the island sends: hover began/ended; long hover (about 2 s → love, then a 6 s cooldown, re-armed after the
  mouse moves 40 pt); click (a "boop": the character flinches, annoyed); greet; a look target (mouse position
  relative to the character, so the eyes follow the mouse).
- Greeting at launch: the character drops in, lands with a squash, looks around, blinks; about 4 s; repeats when the
  Mac was away for 3 minutes or more.
- Reduce Motion: no rolls, shakes, hops, bounces or particles; colour, eyes and badge still change.
- Durations and triggers above are the island's; how each looks is the character's.

### 3.2 Contract a character implements

- A SwiftUI view that receives the state, the last emote and when it started, reactions, a look vector, a size (it
  is drawn at island size and at pill size, about 12 pt) and Reduce Motion. It reports nothing back.
- A description: display name, an accent colour per `CharacterState` (the island uses it for glow, card washes and
  pills), and the folder its sounds come from (section 4).
- Drawing switches over `CharacterState` and `CharacterEmote` without `default`, so adding a case fails to compile for
  every character until it gets a look.
- A registry lists characters; Settings shows a picker only when there are two or more.
- Nothing in the island may assume a round body, a mouth or hands (the helmet must fit).

### 3.3 The square (first character)

Working name "Block" (my call; the maintainer may rename). A rounded square (continuous corners) in the state's
colour, with a soft vertical gradient, a glossy highlight (a curved reflection band near the top left and a small
specular dot), and a subtle shadow. Two eyes, each a white-ish rounded shape with a dark pupil and a tiny catch-light.
Pupils follow the look vector. Ideas for each state (the builder refines them):

| State | Look |
|---|---|
| idle | calm round eyes, slow breathing scale, blinks every 2-5 s, sometimes a double blink |
| working | focused eyes, eyes darting; three dots badge |
| thinking | eyes up and to the side; dots badge; slight tilt |
| searching | eyes sweep left and right |
| approval | wide eyes, "!" badge; hop, then a gentle bounce while waiting |
| question | head tilt, one eye slightly bigger, "?" badge |
| error | flat eyes, a quick side shake, red tint |
| finished | happy eyes (arcs), a spin with squash and a few sparkles |
| rateLimited | tired half-closed eyes, a sweat drop |
| sleeping | closed eyes, slow breathing, "z" bubbles |
| dizzy | spiral eyes, a double spin |

Emotes: love (heart eyes or hearts floating up, blush), surprised (big eyes, jump), proud (stars, puffed up), wink,
yawn (stretch tall, closed eyes), happy (arc eyes, blush), annoyed (narrow eyes, small shake), listening (eyes toward
the mouse, slight lean). Colours: one accent per state, chosen to read on the black island and to stay apart for
colour-blind users (builder picks; the blue/amber/green/red family is fine).

## 4. Sound layer

- `SoundCue` names: peek, open, close, hover, boop, annoyed, dizzy, greet, work, think, search, approval, question,
  approve, send, finish, error, rate, love, pop, proud, wink, yawn, sleep, tick, switch. The file name is the cue name
  (`<cue>.wav`, `.caf` or `.m4a`).
- When each plays: work = SessionStart; think = UserPromptSubmit; search = entering searching; approval = permission
  or plan card; question = question card; approve = allow or answer sent from the Mac; send = answer sent from the
  phone arrives; finish = Stop and error = StopFailure, both skipped when the session's terminal app is frontmost;
  rate = rate limit; peek = hidden → compact; open / close = expand / collapse; hover, love, boop, annoyed, dizzy,
  greet = those reactions; tick = mute toggled; switch = focusing another session pill; pop = sounds reloaded; sleep =
  entering sleeping; proud, wink, yawn = those emotes.
- Bundled set: from a **CC0** (public domain) library so it can ship with no attribution and no restrictions. First
  choice: Kenney's audio packs (kenney.nl: "Interface Sounds", "UI Audio", "Digital Audio", "Impact Sounds"; CC0).
  Second: freesound.org filtered to CC0. Each chosen file, its source pack and its licence are listed in
  `Apps/BuddyMac/Resources/sounds/SOURCES.md`; a test checks every bundled file is listed there with "CC0". Files are
  trimmed and level-matched (short: under 1.5 s; same perceived loudness). The maintainer listens and can swap any.
- User override folder `~/Library/Application Support/Buddy/Sounds`: a file named like a cue replaces the bundled one.
  Settings: "Open sounds folder", "Reload sounds", how many custom files are in use, and a one-line hint.
- Mute toggle in the island header, in Settings and on ⌃⌥M; volume slider in Settings (default about 40%). Both kept
  across launches. A pool of 3 players per cue so a sound can overlap itself.

## 5. Island

- Sizes: hidden; compact (peek) = the notch plus about 160 pt; expanded about 640 pt wide, height per view (question
  card up to 560 pt). Macs without a notch keep the existing top bar.
- Behaviour: hover on hidden → compact; click → expanded; expanded → compact after 15 s without interaction; compact →
  hidden after 60 s; held open while a card is pending; Escape collapses. Ordinary events reveal compact; approval,
  question and plan cards expand. A thin countdown line shows before an automatic close.
- Motion: opening on a spring (slight overshoot), closing on an ease-in-out of about a third of a second; the shape
  animates width, height and corners; content cross-fades; the character glows in its state colour. Reduce Motion:
  fades only.
- Expanded overview: header (mute, settings, close; close hidden while a card is pending); the focused session (project,
  steps so far, its last three tool summaries scrolling in); up to 4 other session pills (small character, name, badge
  "!", check or x; click focuses). ⌃⌥] / ⌃⌥[ cycle focus, ⌃⌥A jumps to the pending card.
- Cards: approval (unchanged rules: Allow / Deny / Always, arming delay, "cannot allow what you cannot read", queue
  "1/N"), plan and question (section 6), error ("This session stopped with an error.", details, OK), finished ("Claude
  is done", last line, OK), dizzy ("Whoa, too many boops!" for 3 s). When answered elsewhere: "Answered in <where>.";
  on timeout: "Still waiting in the terminal." Copy is Buddy's own; the builder may polish it.

## 6. Questions and plans

### 6.1 Hooks
- The installer adds a PreToolUse group: matcher `AskUserQuestion`, command `"<buddy-hook>" --ask`, timeout 130 s.
  Other groups stay as today (5 s, PermissionRequest 120 s).
- `buddy-hook --ask` forwards the event marked as an ask and waits up to 125 s; without `--ask` a PreToolUse never
  waits, so the `*` group firing for the same call does not block. `--ask` on any other tool or event: as without it.
- While the `--ask` hook waits, Claude Code's own question prompt is not shown in the terminal (the hook runs before
  the tool). So the wait must only happen when someone can answer in Buddy (my call):
  - the engine releases the hook at once (prints nothing, the terminal prompt appears) when no surface can show the
    card: the Mac screen is locked, asleep or off **and** the phone link is unavailable;
  - the card's "Answer in terminal" releases it at once, and so does the island being closed by the user with
    Escape while the card shows;
  - Settings has "Answer Claude's questions in Buddy" (default on); off means the `--ask` hook always returns at once.
  - Otherwise the wait is accepted, up to the timeout. The terminal cannot answer while the hook waits; Ctrl+C there
    interrupts Claude and the card clears when the hook's connection closes.
- The engine keeps a question open 120 s (under the relay's wait, same reasoning as approvals). The socket reply limit
  grows from 256 bytes to a bounded size that fits answers (my call: 64 KiB).

### 6.2 Parsing and answers
- Valid: 1 to 4 questions; each with non-empty text, a header of at most 12 characters, 2 to 4 options with
  non-empty labels (descriptions optional), a `multiSelect` bool. Anything else: no card, the hook prints nothing.
- Answers: an object keyed by each question's full text; single select → the chosen label (or Mac free text);
  multi select → the chosen labels joined with ", " in option order (the documented format: hooks docs, "Tools that
  require user interaction"; arrays are only tolerated since a 2.1.136 fix). The builder checks it in a real session
  before pinning it in tests.
- Output on answer: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":
  {"questions":<original questions>,"answers":<answers>}}}`. On "Answer in terminal", timeout, error, app gone, the
  hook's connection closing, or the release rules in 6.1: print nothing.
- Accepted only for the pending question id, before expiry, once, and only if every label is one of that question's
  options (free text only from the Mac). Phone answers are untrusted input.

### 6.3 Mac question card
Cyan wash, "Claude is asking", "i/N" when there are several questions, an "Answer in terminal" link, the header label,
the question. Options as buttons in a row when none has a description, as a list with descriptions otherwise; keys
1-4 pick. Single select moves to the next question (sends after the last); multi select toggles, with Next / Send
enabled once one is picked; "Other..." opens a text field ("Type your answer"), Esc cancels it. The arming delay
applies to option buttons (my call). Long text scrolls inside the card.

### 6.4 iPhone
- New CloudKit record types: `Question` (requestId, sessionId, status, createdAt, expiresAt; encrypted: the questions
  JSON) and `Answer` (requestId, encrypted answers, answeredAt). Published, subscribed and cleaned up like `Approval` and
  `Decision`. Notification: "Claude is asking" (opens the app on the question; no answer buttons).
- Screen: one question at a time, radio rows or checkboxes, descriptions under labels, "Send answer", footnote "If you
  don't answer in about 2 minutes, Claude asks in the terminal." No free text on the phone.
- Sending requires Face ID / passcode, like Allow (maintainer, 2026-10-20).
- Older phone builds ignore record types and session states they do not know.

### 6.5 Plan card (Mac only)
`ExitPlanMode` stops being terminal-only. Its PermissionRequest shows a plan card: "Claude has a plan", the plan text
(scrollable), buttons "Change plan", "Go (auto-accept edits)" (primary), "Go (ask each time)". They allow with
`updatedPermissions:[{"type":"setMode","mode":"acceptEdits"|"default","destination":"session"}]` (both valid mode names
per the hooks docs, "Permission update entries"; `auto` is avoided because an admin may have it off); "Change plan" denies with
`interrupt: true` and a message telling Claude the user will type changes in the terminal. Arming delay applies. Not
mirrored to the phone (my call); the phone row shows "waiting".

## 7. Demo mode

Menu "Demo" and a button in the first-run window play a scripted session inside the app (no hooks, nothing printed):
tools, thinking, searching, a permission card, a single-select and a multi-select question, a plan card, a rate-limit
notice, finished, an error, sleeping; clicking the character shows the reactions. Answers in the demo do nothing. It
doubles as the visual check that every state and emote draws.

## 8. First-run steps

A window (replacing the Settings welcome card) opens on first launch and from the menu ("Setup steps..."). Each step
shows done / to do:

1. **Move Buddy to Applications** (existing alert; done when already there).
2. **Connect Buddy to Claude Code.** "Buddy adds small hooks to `~/.claude/settings.json` so Claude Code can tell
   Buddy what it is doing. A backup is made first." Button "Review and install" → the existing diff → Confirm.
3. **Open sessions pick it up.** Claude Code watches `settings.json` and reloads hooks in running sessions (docs:
   settings, "When edits take effect"; hooks, "Disable or remove hooks"), so no restart is normally needed. Copy:
   "Claude sessions that are already open pick up Buddy within a few seconds. If one doesn't show up in step 4, quit
   it (`/exit`) and run `claude --continue` to pick up where you were." No action; shown done once step 4 sees an
   event.
4. **Check it works.** "Type anything in a Claude session." Spinner, then "Buddy sees your session in <project>" with
   the character greeting, as soon as the first hook event arrives. Button "Try the demo".
5. **Optional: iPhone.** "Install Buddy on your iPhone from TestFlight, signed in to the same Apple Account, and allow
   notifications." Only in builds with CloudKit on.
6. **Open at login** toggle.

When the hooks are installed but outdated (no AskUserQuestion group, or a PermissionRequest timeout under 120 s), the
window reopens at step 2 ("Update Buddy's hooks so you can answer Claude's questions from the notch"), then step 3.
The menu shows a dot until done.

## 9. Making everything Buddy's own

- Delete the previous character (its folder under `Apps/BuddyMac/`) and the seven sound files, once the square and the CC0 set
  are in.
- Rewrite from Apple's documentation, not from the earlier port, the pieces `THIRD-PARTY-NOTICES.md` lists as derived:
  island placement and screen choice, the island panel set-up, the sound player pool, the settings backup naming and
  parsing helpers, the hook-command walk. Then `THIRD-PARTY-NOTICES.md` lists only the CC0 sounds (or goes, if the
  sounds' `SOURCES.md` suffices).
- No mention of another product in app strings, code comments, file names, tests, scripts or repo docs (the old spec's
  notes included). A test greps the source tree and the built app for the old product and character names and fails
  if any appear.
- The release scripts' asset checks change from "testing-only notice present" to "every sound listed as CC0".
- Git history: squashed at the end of phase A (section 11).

## 10. Constraints

- macOS 15+, iOS 18+, Swift 6, existing project layout. Pure logic (state derivation, question parsing and validation,
  answer JSON, hook outputs, installer groups, relay `--ask`) lives in `BuddyKit` with `swift test` coverage.
- Tests never touch the real `~/.claude/settings.json` or `~/Library/Application Support/Buddy`.
- Nothing is pushed; the Team ID is never committed.
- Exact JSON for answer, plan and silence outputs is pinned by tests, as allow and deny are today.
- Existing approval safety rules stay.

## 11. Maintainer decisions (2026-10-20)

- Extras: all in, as phase B (section 13).
- Face ID before sending an answer from the phone: yes.
- Git history: squash it into a fresh start so no commit holds the previous character or sounds, after a backup
  bundle is made, as the **last** step of phase A once the deletions in section 9 are committed. Irreversible: the
  builder stops and asks for a go-ahead right before running it.
- Rename the repo folder to `buddy`: the maintainer does it outside the plan, after the squash
  (it moves the working directory of running tools). Until then the built-app name check covers resources and strings
  only and says so; after it, the check also covers embedded paths.
- Character name: "Block" is a working name; the maintainer may rename.

## 12. Left to the builder

File layout of the character and sound layers; how the relay marks an ask on the wire; how the character view is
driven (timeline view or display link); exact colours, sizes and animation curves not pinned above; which CC0 sounds
to pick; task order.

## 13. Phase B: extras

Built after phase A, on its character contract (new cases are added there, every character gets a look for them).
Scope per item is my call unless marked; each item is independent and can be dropped from the phase B plan alone.

1. **Jump to terminal.** `buddy-hook` adds its parent terminal's identity to each forwarded event (the
   `TERM_PROGRAM` and `__CFBundleIdentifier` environment values; nothing else from the environment). "Open terminal"
   on the error, finished and question cards, clicking the focused session, and ⌃⌥T bring that app to the front
   (`NSRunningApplication`; no AppleScript, no Accessibility). Unknown or not running: the first running known
   terminal (Terminal, iTerm2, Ghostty, kitty, WezTerm, Warp, Alacritty), else Terminal. App level only, not the tab.
   After the jump the island collapses. No session focused: annoyed emote and error sound.
2. **Outfits.** A wardrobe view in the expanded island (⌃⌥G, or right-click the character): a grid of outfits;
   hovering previews on the character, clicking picks (pop sound, proud emote), Esc goes back; kept across launches.
   Outfits are drawn by the character (part of its contract: an `Outfit` enum, exhaustive). For Block: none, hard hat
   (green, the project team), beanie, party hat, crown, sunglasses, round glasses, bow, scarf, witch hat, Santa hat, bunny
   ears, plus "Auto" by season (New Year party hat, December Santa, October witch hat, around Easter bunny ears,
   summer sunglasses, else none). Default: Auto.
3. **Character on the desktop.** Drag the character out of the island, or ⌃⌥D, and it flies to a spot on the desktop
   (default bottom right of the main screen, clamped to the visible area) in a small always-on-top panel on all
   Spaces, click-through except over its body. It keeps reacting to session states and the mouse; drag moves it;
   double-click or dropping it on the notch flies it home. On a pending card it jumps, flies to the notch to show the
   card, and returns once handled. Sleeps after 120 s without activity when the mouse is more than 150 pt away
   (lower frame rate while asleep, paused when the screen sleeps or locks). Position and "on desktop" kept across
   launches. It does not walk around (my call: matches what users expect from a desk pet without stealing focus).
4. **Feels your Mac.** Toggle "Block feels your Mac" (default on). Sampled every 3 s, only while the character is
   visible, all local: busy (CPU ≥ 80 % on two readings: sweats, nervous hops), hot (thermal state fair / serious /
   critical: flushed, heat waves), memory pressure (warning / critical: puffed up), tired (battery under 20 % on
   battery: heavy eyelids, yawns), very low (under 10 %: dozes). Plugging in while tired: happy, pop sound. Shown only
   in calm states (idle, working, thinking, searching, finished). Hovering the character shows one line under the
   island, e.g. "CPU 94% · node, Chrome".
5. **Dances to music.** When Apple Music or Spotify reports playing (their distributed "player info" notifications;
   my call: no AppleScript, so no Automation prompt) and the character is in a calm state, it bobs, sways and squashes
   at a fixed 112 BPM, with happy eyes; fades in 0.3 s, out 0.5 s. Toggle in Settings (default on). No music controls.
6. **Chat.** A chat view in the expanded island (⌃⌥Space opens it with the field focused): a text field, streamed
   replies in bubbles with plain markdown, a "new chat" button. Provider: Anthropic's API with the user's own key in
   the Keychain, model picker from the live model list (my call: one provider; others can be added behind the same
   interface). Attach a file by dropping it on the field. It is a general chat with Claude, not with a running Claude
   Code session. No key: the view explains how to add one in Settings.
7. **Voice.** Push to talk (my call: no always-on wake word): hold a hotkey (default right Option, configurable,
   can be turned off) to dictate; the island shows the listening state (character attentive, eyes pulse with the
   mic level, a live caption under the island); releasing sends the text to the chat (6), or, while a question card is
   open, picks the option whose label matches what was said (confirmation tap required). Optional: read chat replies
   aloud with a macOS voice (default off). Speech is recognised on the Mac (Apple's on-device recognition); audio never
   leaves the Mac. Needs microphone and speech-recognition permission, asked on first use with a plain explanation.

Still out (not in the maintainer's list): integrations (GitHub, Stripe and others), weekly recap, plan usage gauges,
notetaker, screen capture, other coding agents than Claude Code, self-updater, widgets and Live Activities.

