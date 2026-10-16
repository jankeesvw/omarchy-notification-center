# Notification Center

An [Omarchy](https://omarchy.org) bar widget that keeps the notifications you
were sent. A bell on the right of the bar, a dot on it when something has come
in, and a panel of everything you were told, still there tomorrow.

Omarchy shows a notification once. This answers the question that comes ten
minutes later, in the middle of something else: *what did that say?*

<img src="preview.png" alt="The notification center open on the right of the screen, a column of cards under Today and Yesterday" width="720">

## Install

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-notification-center.git --enable
```

Needs `jq` and `inotifywait`, both of which Omarchy already has. Leave the bell
at the far right of the bar: the panel is pinned to the right edge of the
screen, so a bell in the middle is a bell whose panel opens somewhere else.

## What it does

Omarchy's notification service already writes every notification to disk, and
then keeps only the last ten. This copies each one out of there as it lands,
icon and all, and keeps it for 30 days.

- One card per notification, newest first, under the day it arrived on.
- **A picture** when there was one. Cameras and screenshot tools hand their
  file to the notification's action rather than setting an image on it, so the
  path is read out of there and a scaled copy is kept.
- **Clicking a card** opens that picture, or focuses the app that sent the
  notification. A Slack card opens the conversation it was about, thread and
  all: Slack logs the ids of every notification it raises, and the one logged
  the moment this one arrived is the one it came from. Slack keeps that log for
  a couple of weeks; past that, or with the snap or Flatpak, the card focuses
  Slack.
  It never runs the command the notification arrived with: that command is
  chosen by whoever sent the notification, so a stored one would be an
  attacker's command waiting for a click. Only an absolute path to an image is
  kept, and it is opened by argument rather than through a shell.
- **The × on a card**, or a right-click, removes one. **Clear** draws a line
  under everything you have seen: the panel empties, and what was in it ages
  out through the ordinary retention limits instead of being deleted on the
  spot. Nothing is destroyed by a click, so nothing has to be confirmed.
- **The bell in the header** is Do Not Disturb, the same switch as the bar's.
  Right-clicking the bell in the bar does it without opening anything.
- **The phone beside the bell** mutes notifications mirrored from your phone,
  and only those. KDE Connect, GSConnect and Valent send every notification
  from the phone under their own name, so that name is how one is recognised;
  the desktop's own notifications keep coming and Do Not Disturb is left as it
  was. A muted one is still kept here, so nothing is lost, only not shown.
  The phone is there when a bridge is running on the session bus or one of
  its notifications has been kept, and stays while muted so it can always be
  turned back; `p` does the same with the panel open. Details under
  [Muting the phone](#muting-the-phone).
- **The magnifier**, or `/`, searches everything kept. Escape leaves the
  search, Escape again closes the panel.
- **No grouping**, on purpose. Ten identical messages are ten cards, not one card with a ×10 on it. A stack hides when each one arrived, and the newest one on top hides whether an older one was urgent. If an app sends the same thing ten times, that is worth seeing as it is.

## Settings

| Setting | Default | |
| --- | --- | --- |
| Mark what you have not read | Dot | `Dot`, `Highlight`, `Count` or `None` on the bell. `Highlight` colours the bell itself instead of adding anything to it. |
| Keep notifications for | 30 days | Older than this is deleted, icon and all. |
| Keep at most | 1000 | A ceiling regardless of age. |
| Clicking a notification | Auto | Opens the picture or the Slack conversation, or focuses the app. Or neither. |
| Show the message text | on | Off leaves the sender and subject only. |
| Show pictures | on | Off stops keeping copies as well. |
| Phone notifications come from | KDE Connect, GSConnect, Valent | App names, comma separated, that the phone button mutes. Case, spaces and dots are ignored. Empty means the default. |
| Panel width | 420 | In the shell's spacing units. |
| List height | 0 | 0 runs the list to the bottom of the screen. |

## Muting the phone

Omarchy's notification service gives a plugin no say over which toasts it
shows, so the mute works one step later. The service writes each toast to disk
as it appears; the archive is already watching that directory, and when a
phone notification lands while the phone is muted, it is archived and then
taken straight back off the screen through the service's own
`omarchy-shell notifications dismiss`. In practice the toast is gone within a
few tens of milliseconds, but it can show for a frame. Things worth knowing:

- Omarchy makes no sound for notifications, so there is nothing to silence on
  this side. A bridge set up to play its own sound keeps playing it; turn that
  off in the bridge.
- Closing the toast does not dismiss anything on the phone: KDE Connect only
  does that when asked through its own D-Bus method, and GSConnect and Valent
  are never told.
- The toast is found by its title. A desktop toast on screen at the same
  moment whose title contains the phone one's would be closed with it; it is
  still in the archive.
- While Do Not Disturb is on nothing reaches the screen anyway, so the mute
  does nothing then.
- To stop phone notifications reaching the desktop at all, turn notification
  sync off in the bridge instead; then they are not kept here either.

Recognising the bridges needs nothing but the name on each notification and,
to offer the switch before the first one, the list of names already owned on
your session bus. No device, account or address is read, and nothing leaves the
machine. The setting is remembered in
`~/.local/state/omarchy-notification-center/phone.json`.

Bind it to a key the way you would Do Not Disturb:

```bash
omarchy-shell jankeesvw.notification-center.phone toggle   # or: set on|off, state
```

## Where things are kept

`~/.local/state/omarchy-notification-center/`, one line of JSON per
notification plus a copy of every icon and picture. The directory is `0700`
and the archive `0600`, and only files that are actually images are copied
into it.

Worth knowing for one reason: **that is every notification you have been sent**,
chat messages and two-factor codes included. It never leaves the machine, but
it is not something to sync or back up carelessly. `Keep notifications for` is
the setting that limits the damage, and one day is a perfectly reasonable
answer to it.

Removing the plugin leaves the archive alone, on purpose:

```bash
omarchy plugin remove jankeesvw.notification-center
rm -rf ~/.local/state/omarchy-notification-center
```

## The command line

`bin/notification-center` is the storage side, and how you search further back
than the panel loads:

```
list [LIMIT]       the archive as JSON, newest first
remove KEY         drop one, or clear for all of them
seed [N]           fill it with test traffic
backfill           give older entries the picture their action points at
```

`watch`, `sync`, `seen`, `unread` and `prune` are in there too; everything
prints JSON.

```bash
# everything Slack sent you last week, as text
notification-center list 2000 | jq -r '.[] | select(.app == "Slack") | "\(.summary): \(.body)"'
```

The panel opens over IPC, which is how you bind it to a key:

```bash
omarchy-shell jankeesvw.notification-center toggle
```

## Tests

The Slack matching and the phone detection have unit tests. Run them from the
plugin directory with `node --test`.

## Licence

MIT.
