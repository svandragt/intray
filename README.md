# Intray

Intray keeps a list of every desktop notification, so you can turn
on Do Not Disturb and triage the notifications later. It targets elementary OS.

Each entry shows the app, the time, the summary and the body. Select **Open** to
launch the app that sent it, or **Done** to remove the entry. **Clear all**
empties the inbox. The **Do Not Disturb** switch in the header bar turns the
elementary OS setting on and off.

The inbox is saved to `~/.local/share/intray/inbox.ini`, so entries
survive a restart. Notifications are only captured while the app is running.
Start it when you log in to capture all of them.

## Dock count

Intray shows the number of inbox entries as a badge on its dock icon. To hide the
badge, open the menu at the end of the header bar and clear **Show Count in Dock**.
Intray remembers the choice.

## Build and run

Install `valac`, `meson`, GTK 4 and libadwaita development files, then run:

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
