# Install Buddy

Buddy shows what your Claude Code terminal sessions are doing and lets you Allow or Deny their permission requests from
the top of your Mac screen, or from your iPhone. This page is for preview testers. You do not need Xcode.

**Preview availability.** Builds and TestFlight invitations are supplied by the maintainer. A public signed download is not available yet.

**Status (read this once).** The first signed and notarized dmg, the TestFlight build, the real iPhone link, the first-run
setup window, the Move to Applications prompt on a real download and Open at login on a real Mac have not yet been run on
a real Apple account or device; this page describes what the app is built to do. If a step does not match what you see,
tell the person who sent you Buddy. The Mac app works on its own; the iPhone is optional.

You need: a Mac on macOS 15 or later, and Claude Code (`claude` works in your terminal). For the iPhone: iOS 18 or later.

## Mac

1. **Download** `Buddy-<version>.dmg` and `Buddy-<version>.dmg.sha256` from `<link from the person who shared Buddy>`.
   Put both in your Downloads folder.
2. **Check the download.** Open Terminal and run (use the real file name):

   ```sh
   cd ~/Downloads
   shasum -a 256 -c Buddy-<version>.dmg.sha256
   ```

   It must print `Buddy-<version>.dmg: OK`. If it says FAILED, delete both files and download again.
3. **Install.** Double-click the dmg. Drag **BuddyMac** onto **Applications** in the window that opens. Eject the dmg
   (the eject button next to "Buddy" in the Finder sidebar).
4. **Open it for the first time.** Open Finder > Applications, double-click **BuddyMac**. It has no Dock icon: look for the
   paw-print icon in the menu bar at the top right.
   - **Notarized build** (the normal one): it opens. macOS may first ask "are you sure you want to open it?"; click **Open**.
   - **Unsigned test build** (the sender will say so): macOS blocks it the first time. Open **System Settings > Privacy &
     Security**, scroll to the Security section, click **Open Anyway** next to BuddyMac, and confirm (macOS may ask for your
     password). Or, in Terminal, run once and open it again:

     ```sh
     xattr -dr com.apple.quarantine /Applications/BuddyMac.app
     ```

   If you opened Buddy from Downloads or from the dmg instead, it asks **Move Buddy to Applications?** Click **Move to
   Applications**: it copies itself, quits and opens again from there. **Not Now** keeps it running where it is, and it asks
   again the next time you open it from there.
5. **Set up Buddy window.** The first time, a window opens by itself with Buddy's setup steps. Each step gets a green check
   mark when it is done; the one to do next is highlighted. Nothing is installed yet. If it does not show up, or you closed
   it: paw-print menu bar icon > **Setup steps…** (it has a dot while a step is left).
6. **Connect Buddy to Claude Code.** Hooks are how Claude Code tells Buddy what it is doing. Click **Review and install**.
   Buddy shows the exact changes it will make to `~/.claude/settings.json`. Read them, then click **Confirm** (or **Cancel**
   to change nothing). The step gets its check mark. Buddy keeps a backup next to the file
   (`settings.json.buddy-backup-<time>`), leaves your other settings alone, and copies its small `buddy-hook` helper to
   `~/Library/Application Support/Buddy/bin/`. (Settings > **Install hooks…** does the same.)
7. **Open sessions pick it up, then check it works.** Claude sessions that are already open pick up Buddy within a few
   seconds. Type anything in a Claude session: the step "Check it works" changes to "Buddy sees your session in
   <project>." and Buddy's character greets you. If a session doesn't show up, quit it (`/exit`) and run `claude --continue` to pick up
   where you were. To see what Buddy can do without a real session, click **Try the demo**.
8. **Try it.** Ask Claude to do something that needs permission, for example "create a file called hello.txt here". A card
   opens at the top of the screen (at the notch if you have one) with the tool and the command:
   - **Allow** lets this one request run. **Always** does the same: it allows only this request, and the next one asks again.
   - **Deny** blocks it.
   - The first answer wins, and the terminal prompt goes away. You can also answer in the terminal; the card then clears.
   - Allow is greyed for a moment after the card appears, and for commands that are very long or contain unusual
     characters. The card then says "Allow in terminal": answer there. Deny always works.
   - Next to the notch Buddy's character, Block (a small glossy square with two eyes), shows how your sessions are
     doing: its colour, eyes and badge change while Claude works, when a request waits for you ("!"), when Claude asks
     you something ("?"), when a session finished and after an error. Short sounds go with these moments (Settings >
     **Mute sounds** or the **Volume** slider turns them down).
9. **When Buddy is not running**, or anything else is down (iCloud, the phone), Claude Code asks you in the terminal as it
   always did. Buddy never blocks Claude Code and never allows anything without you. A request that nobody answers for
   about 10 minutes also goes back to the terminal.
10. **Open at login (signed build).** In the setup window (its last step) or Settings, turn on **Open Buddy at login**. If it says it is waiting for approval, click
    **Open Login Items Settings…** and allow Buddy under System Settings > General > Login Items. With the unsigned test
    build this is untried: macOS may ask for approval or may not keep it, so do not rely on it there; open Buddy yourself
    after a restart.

### Update Buddy

Download and check the new dmg (steps 1 and 2). Then either quit Buddy (paw-print menu bar icon > **Quit Buddy**) and drag the new
**BuddyMac** over the old one in Applications (**Replace**), or double-click **BuddyMac** inside the new dmg: Buddy offers to
move to Applications, tells you it replaces the copy there and quits the older Buddy first (an approval waiting in it goes
back to the terminal). An unsigned test build needs the Open Anyway step again. After an update Buddy refreshes its own
`buddy-hook` copy at launch; you do not install the hooks again, unless the new version needs more of them: then the setup
window opens by itself at "Update Buddy's hooks so you can answer Claude's questions from the notch". Click **Review and
install** and **Confirm** as in step 6, then check it works again (step 7).

### Uninstall

1. Menu bar icon > **Open Settings** > **Uninstall hooks…** > **Confirm**. Only Buddy's entries are removed.
2. Turn off **Open Buddy at login**, then paw-print menu bar icon > **Quit Buddy**.
3. Drag **BuddyMac** from Applications to the Trash.
4. Optional: remove the leftover helper folder: `rm -rf ~/Library/Application\ Support/Buddy`

## iPhone (optional)

The phone link needs the notarized Mac build; the unsigned test build has no iCloud, so its menu says "Phone link off".

1. **Accept the App Store Connect invitation, then the TestFlight invite.** The maintainer adds you in App Store Connect.
   First you get an email inviting you to the maintainer’s App Store Connect team (an internal tester is a team member): accept
   it with your Apple Account. Only then does the TestFlight invite ("... invited you to test Buddy") arrive, at the same
   address.
2. On the iPhone, install **TestFlight** from the App Store if you do not have it. Open the email on the iPhone and tap
   **View in TestFlight** (or open TestFlight), then tap **Accept** and **Install**. The app is called **Buddy**.
3. Open **Buddy** and tap **Allow** when it asks to send notifications.
4. **Same Apple Account.** The iPhone and the Mac must be signed in to the same Apple Account with iCloud on (Settings >
   your name > iCloud on the iPhone; System Settings > your name on the Mac). There is no pairing code.
5. On the Mac, the Buddy menu must say **Phone link on**. If you signed in to iCloud after opening Buddy, quit and reopen it.
6. In Buddy on the iPhone, **pull down on the list to refresh**. Your Mac's Claude Code sessions appear under "Sessions".
7. **Try it.** Trigger a permission request on the Mac and leave the card alone. The iPhone shows "Claude Code needs
   approval" (the notification never contains the command).
   - **Deny**: on the lock screen, long-press the notification and tap **Deny**. It works without unlocking.
   - **Allow**: tap Allow on the notification, or open the request in the app. Allow becomes active after a moment, then
     Face ID (or your passcode) is asked, and only then it is sent. Cancel Face ID and nothing is sent.
   - **Questions** (Claude asks you to pick an answer) arrive as "Claude is asking": answer in the app, or long-press the
     notification for a single question with up to four options.
8. **Messages to Claude.** Open a session in the app to see the latest prompt and reply, and write what Claude should do
   next. When the session runs in iTerm2, Terminal or tmux, Buddy types it into the terminal as your own prompt (only
   while no key was pressed on the Mac for a few seconds); the first time, macOS asks whether Buddy may control iTerm2 or
   Terminal: click **OK**. In other terminals the message reaches Claude when it next stops (Claude Code shows it as
   "Stop hook feedback"). In those terminals Claude waits up to 10 minutes after finishing for a message; using the Mac
   (keyboard, mouse or trackpad) ends the wait.

## If something is wrong

| What you see | Why, and what to do |
| --- | --- |
| Menu says `Phone link off: this build is not signed with the iCloud entitlement` | You have the unsigned test build. Ask for the notarized one. The Mac features work without the phone link. |
| `Phone link off: not signed in to iCloud` | Sign in to iCloud on the Mac (System Settings > your name), then quit and reopen Buddy. It checks only at launch. |
| `Phone link off: iCloud is restricted on this Mac` | A device profile or Screen Time restriction blocks iCloud. Ask IT. |
| `Phone link off: iCloud is temporarily unavailable`, `check timed out` or `check failed` | Network or iCloud problem. Quit and reopen Buddy to try again. |
| Menu says `Not listening: ...` | Another Buddy is already running, or the socket is unusable. Quit every Buddy and open one. |
| No card appears on the Mac | Settings must say "Hooks installed" (see step 6). Start a NEW `claude` session after installing. Buddy must be running (icon in the menu bar). Claude Code only asks for things it has not already allowed. Plan approvals are always answered in the terminal. |
| No notification on the iPhone | iPhone Settings > Notifications > Buddy must be on, and Focus modes can hide it. The Mac must be running with "Phone link on". The first alert can take up to a minute: open the app and pull to refresh. |
| iPhone list is empty | Same Apple Account and iCloud on both, Buddy running on the Mac, a `claude` session started after the hooks were installed. Pull down to refresh. |
| Allow is greyed out | It waits a moment after a request appears. It stays off for very long commands or unusual characters ("Allow in terminal" on the Mac, "Allow on your Mac" on the iPhone): answer in the terminal. It is also off once the request has expired (about 10 minutes) or was answered elsewhere. Deny works. |
| "BuddyMac cannot be opened" or "is damaged" | Unsigned test build: do the Open Anyway step (step 4). Otherwise delete it, download again and check the checksum. |
| A message shows "Sent" but nothing appears in the terminal | macOS > System Settings > Privacy & Security > Automation: allow Buddy to control iTerm2 or Terminal. If a key was pressed on the Mac in the last few seconds, it is delivered when Claude next stops instead. |
| Many sessions appear and disappear on the iPhone | Two Macs on one Apple Account is not supported. Use one Mac. |

Maintainers: see [`releasing.md`](releasing.md). Building from source: the [README](../README.md).
