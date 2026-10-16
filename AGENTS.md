# AGENTS.md

This file gives guidance to coding agents working with code in this repository.

Intray is a GTK 4 and Granite 7 app for elementary OS. It records every desktop
notification in an inbox so you can triage them after Do Not Disturb.
`README.md` describes the user-visible behaviour; update it in the same commit as
any behaviour change.

## Commands

```sh
make                              # sets up build/ with prefix ~/.local on first run, then compiles
make run                          # compiles and runs ./build/intray (./build/intray --background starts it hidden)
make install                      # installs the binary, desktop file and icon
```

The Makefile wraps Meson; `meson compile -C build` and `meson install -C build`
work directly too.

The project has no tests and no linter. Check a change by compiling it and running
the app. To produce a notification to capture, run `notify-send "summary" "body"`.

## Architecture

All code is in `src/main.vala`. `main()` creates the `Gtk.Application`, and the
`Window` class does the rest: capture, storage, rows and the dock badge.

### Capture through a D-Bus monitor

`start_monitor()` opens a second session-bus connection and calls
`BecomeMonitor`. The monitor receives `Notify` calls to
`org.freedesktop.Notifications` and the server's replies to them.

- The filter callback runs on a GDBus worker thread. It hands work to the main
  loop with `Idle.add` and never touches widgets or the store itself.
- The filter returns `null` for captured messages. If it returned them, GDBus
  would answer them, and the bus disconnects a monitor that sends a message.
- Each `Notify` call is identified by `sender/serial`. The `pending` table maps
  that call to the inbox entry key. The method reply carries the server id,
  which `set_server_id()` stores. An error reply makes `reject()` drop the
  entry, because the server never showed that notification.
- A later `Notify` whose `replaces_id` matches a stored `server_id` for the same
  app replaces the earlier entry. This is how progress notifications merge.
- `add()` skips notifications with the `transient` hint and on-screen displays
  with `x-canonical-private-synchronous`.

### Storage

- The inbox is a `KeyFile` at `~/.local/share/intray/inbox.ini`. Each group is
  one entry, keyed by `get_real_time()` in microseconds. File order is oldest
  first. `reload_rows()` prepends each row, so the newest row shows on top.
- Settings, such as the dock count and the window size, are in a separate
  `KeyFile` at `~/.config/intray/settings.ini`.
- Every change saves the whole file with `save_to()`. An inbox file that fails to
  load is renamed to `inbox.ini.corrupt`, so the next save does not overwrite it.
- **Clear all** keeps the removed data in `cleared` until the toast closes.
  **Undo** prepends that data to the current store, so entries that arrived
  after the clear stay in the inbox.

### Rows and opening

- `add_row()` builds one row and attaches `stamp`, `info` and `uri` to it with
  `set_data`, along with `app` and `key` for sorting. `open_row()` and the
  60-second timer read them back.
- The app to launch comes from the `desktop-entry` hint. Without the hint,
  `find_app()` matches the app name exactly, ignoring case, against an installed
  app's desktop id, the last segment of the id, or the app name.
- A URI takes precedence over the app: `gala-feedback` (screenshots) opens the
  Screenshots folder, and an `x-url` hint opens only when its scheme is http or
  https.
- A sort function groups rows by app, ordered by each app's newest entry in the
  `latest` table, which `refresh()` rebuilds. The header function adds a header
  with **Dismiss all** above the first row of each group. Headers are children of
  the list too, so code that walks the list's children must skip them.
- **Dismiss all** copies the app's entries into the same `cleared` buffer that
  **Clear all** uses, so **Undo** restores them.
- **Dismiss** plays two nested revealers: the inner one fades the content, the outer
  one collapses the row. The CSS in the `Window` constructor moves the theme's row
  padding inside the revealers, so the collapse does not snap at the end.

### Lifecycle and dock

- The app uses `HANDLES_COMMAND_LINE`. `startup` creates the window, and
  `hide_on_close` keeps it alive, so capture continues while the window is
  hidden. `command_line` presents the window unless `--background` is passed.
- `refresh()` emits the Unity `LauncherEntry` `Update` signal, which the dock
  reads to draw the count badge.
- The Do Not Disturb switch binds to the `io.elementary.notifications` GSettings
  key. The switch appears only if the schema and key exist.

## Conventions

- Notification content comes from any client on the bus, so treat it as untrusted.
  Keep the body label plain text, check the `Notify` signature before reading the
  body, and allow only web links in `x-url`.
- Comments explain why the code is the way it is, in one line where possible.
  Keep that density.
- `meson.build` defines `GETTEXT_PACKAGE` so that `dgettext("gala", …)` finds
  gala's translated "Screenshots" folder name. The desktop file uses an absolute
  `bindir`, because the dock may not have `~/.local/bin` on its `PATH`.
