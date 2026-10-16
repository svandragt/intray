# Intray

Intray keeps a list of every desktop notification, so you can turn
on Do Not Disturb and triage the notifications later. It targets elementary OS.

Each entry shows the app, how long ago it arrived, the summary and the body.
Hover over the time to see the date. Select an entry to launch the app that sent
it, or select **Done** to remove the entry. A screenshot entry opens the
Screenshots folder instead, and an entry whose app sent a web link in an `x-url`
hint opens the link. **Clear all** empties the inbox and shows an **Undo** button for a few seconds. The
**Do Not Disturb** switch in the header bar turns the elementary OS setting on
and off. Intray skips transient notifications, which apps mark as not worth
keeping, and on-screen displays such as the volume level, and remembers the size of its window.

If an app sends no desktop entry, Intray finds the app to launch and the icon in an
installed app whose desktop id or name exactly matches the app name, ignoring case.
When an app updates a notification, such as a download progress, Intray replaces
the earlier entry with the new one.

The inbox is saved to `~/.local/share/intray/inbox.ini`, so entries
survive a restart. Notifications are only captured while the app is running.

## Keep it running

Closing the window does not quit Intray, so it keeps capturing notifications.
Launch Intray again, or select its dock icon, to show the window. To quit, open
the menu at the end of the header bar and select **Quit**, or press Ctrl+Q.

To capture notifications from the moment you log in, run `intray --background`
at login. It starts Intray without showing the window.

## Dock count

Intray shows the number of inbox entries as a badge on its dock icon. To hide the
badge, open the menu at the end of the header bar and clear **Show Count in Dock**.
Intray remembers the choice.

## Build and run

Install `valac`, `meson`, GTK 4 and Granite 7 development files, then run:

```sh
meson setup build
meson compile -C build
./build/intray
```

To add Intray to your app launcher and dock, install it with its icon and desktop
file. For a per-user install, run `meson setup build --prefix ~/.local` first:

```sh
meson install -C build
```
