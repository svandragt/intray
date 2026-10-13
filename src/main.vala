const string SCHEMA = "io.elementary.notifications";
const string NOTIFY_SIGNATURE = "(susssasa{sv}i)";
const string APP_ID = "com.github.svandragt.Intray";

// The source line of an entry. The window refreshes its relative time.
class Stamp : Object {
    public Gtk.Label label = new Gtk.Label (null) { xalign = 0 };
    string app;
    DateTime time;

    public Stamp (string app, DateTime time) {
        this.app = app;
        this.time = time;
        label.tooltip_text = time.format ("%d %b %Y %H:%M");
        update ();
    }

    public void update () {
        label.label = "%s · %s".printf (app, Granite.DateTime.get_relative_datetime (time));
    }
}

class Window : Gtk.ApplicationWindow {
    KeyFile store = new KeyFile ();
    string path = Path.build_filename (Environment.get_user_data_dir (), "intray", "inbox.ini");
    Gtk.ListBox list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, show_separators = true };
    Gtk.Stack stack = new Gtk.Stack ();
    Gtk.Button clear = new Gtk.Button.with_label ("Clear all");
    string cleared = "";  // inbox data removed by Clear all, kept for Undo until the toast is dismissed
    DBusConnection monitor;
    KeyFile settings = new KeyFile ();
    string settings_path = Path.build_filename (Environment.get_user_config_dir (), "intray", "settings.ini");
    bool show_count = true;
    List<AppInfo> apps;  // installed apps, reloaded with the rows so Open can match apps by name
    HashTable<string, string> pending = new HashTable<string, string> (str_hash, str_equal);  // Notify call -> entry key

    public Window (Gtk.Application app) {
        Object (application: app, default_width: 480, default_height: 640, hide_on_close: true, title: "Intray");

        try {
            settings.load_from_file (settings_path, KeyFileFlags.NONE);
            show_count = settings.get_boolean ("dock", "show-count");
        } catch (Error e) {
            if (!(e is FileError.NOENT || e is KeyFileError.GROUP_NOT_FOUND || e is KeyFileError.KEY_NOT_FOUND)) {
                warning ("Cannot load %s: %s", settings_path, e.message);
            }
        }
        try {
            default_width = settings.get_integer ("window", "width");
            default_height = settings.get_integer ("window", "height");
            if (settings.get_boolean ("window", "maximized")) {
                maximize ();
            }
        } catch (Error e) {  // not saved yet
        }
        // Quitting while the window is open skips close-request, so save then too.
        close_request.connect (() => {
            save_window ();
            return false;
        });
        app.shutdown.connect (save_window);
        var dock = new SimpleAction.stateful ("show-count", null, new Variant.boolean (show_count));
        dock.change_state.connect ((action, state) => {
            show_count = state.get_boolean ();
            action.set_state (state);
            settings.set_boolean ("dock", "show-count", show_count);
            save_to (settings, settings_path);
            refresh ();
        });
        add_action (dock);

        // Granite deprecated its rich-list constant in 7.7 in favour of Granite.ListItem, which cannot hold buttons.
        list.add_css_class ("rich-list");
        var header = new Gtk.HeaderBar ();
        header.add_css_class (Granite.STYLE_CLASS_FLAT);
        var menu = new Menu ();
        menu.append ("Show Count in Dock", "win.show-count");
        menu.append ("Quit", "app.quit");
        header.pack_end (new Gtk.MenuButton () { icon_name = "open-menu-symbolic", menu_model = menu });
        header.pack_start (clear);
        var toast = new Granite.Toast ("Inbox cleared") { valign = Gtk.Align.END };  // the top would cover the newest entry
        toast.set_default_action ("Undo");
        clear.clicked.connect (() => {
            cleared += store.to_data ();
            store = new KeyFile ();
            save_to (store, path);
            reload_rows ();
            toast.send_notification ();
        });
        // Prepending the cleared groups keeps the file oldest first and keeps notifications that arrived since.
        toast.default_action.connect (() => {
            try {
                store.load_from_data (cleared + store.to_data (), -1, KeyFileFlags.NONE);
                cleared = "";
                save_to (store, path);
                reload_rows ();
            } catch (Error e) {
                warning ("Cannot restore the inbox: %s", e.message);
            }
        });
        toast.dismissed.connect (() => cleared = "");

        var schema = SettingsSchemaSource.get_default ()?.lookup (SCHEMA, true);
        if (schema != null && schema.has_key ("do-not-disturb")) {
            var toggle = new Gtk.Switch () { valign = Gtk.Align.CENTER };
            new Settings (SCHEMA).bind ("do-not-disturb", toggle, "active", SettingsBindFlags.DEFAULT);
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            // The mnemonic gives Alt+D and labels the switch for screen readers; GTK 4 labels ignore clicks.
            var label = new Gtk.Label.with_mnemonic ("_Do Not Disturb") { mnemonic_widget = toggle };
            var click = new Gtk.GestureClick ();
            click.released.connect (() => toggle.active = !toggle.active);
            label.add_controller (click);
            box.append (label);
            box.append (toggle);
            header.pack_end (box);
        }

        stack.add_named (new Gtk.ScrolledWindow () { child = list }, "list");
        stack.add_named (new Granite.Placeholder ("Inbox zero") { icon = new ThemedIcon ("emblem-ok-symbolic") }, "empty");
        titlebar = header;
        var overlay = new Gtk.Overlay () { child = stack };
        overlay.add_overlay (toast);
        child = overlay;

        try {
            store.load_from_file (path, KeyFileFlags.NONE);
        } catch (Error e) {
            if (!(e is FileError.NOENT)) {
                warning ("Cannot load %s: %s", path, e.message);
                // Move the unreadable file aside so the next save does not overwrite it.
                FileUtils.rename (path, path + ".corrupt");
            }
        }
        reload_rows ();
        start_monitor ();
        list.row_activated.connect ((row) => row.get_data<Gtk.Button> ("open").clicked ());
        Timeout.add_seconds (60, () => {
            for (var row = list.get_first_child (); row != null; row = row.get_next_sibling ()) {
                row.get_data<Stamp> ("stamp").update ();
            }
            return Source.CONTINUE;
        });
    }

    void save_window () {
        if (visible) {  // a window that was never shown reports a false size and state
            int width, height;
            get_default_size (out width, out height);
            settings.set_integer ("window", "width", width);
            settings.set_integer ("window", "height", height);
            settings.set_boolean ("window", "maximized", maximized);
            save_to (settings, settings_path);
        }
    }

    void start_monitor () {
        try {
            monitor = new DBusConnection.for_address_sync (BusType.SESSION.get_address_sync (),
                DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION);
            // The filter runs on a worker thread. It drops captured calls and replies so GDBus never answers them
            // (a monitor that sends is disconnected), and passes the rest so BecomeMonitor still works.
            monitor.add_filter ((conn, msg, incoming) => {
                var type = msg.get_message_type ();
                if (!incoming || (type != DBusMessageType.METHOD_CALL && type != DBusMessageType.METHOD_RETURN && type != DBusMessageType.ERROR)) {
                    return msg;
                }
                // The BecomeMonitor reply is addressed to this connection, captured replies to other clients.
                if (type != DBusMessageType.METHOD_CALL && msg.get_destination () == conn.get_unique_name ()) {
                    return msg;
                }
                var body = msg.get_body ();
                // Any client can send a malformed Notify, so check the signature before reading it.
                if (type == DBusMessageType.METHOD_CALL && body != null && body.get_type_string () == NOTIFY_SIGNATURE) {
                    var call = "%s/%u".printf (msg.get_sender (), msg.get_serial ());
                    Idle.add (() => {
                        add (body, call);
                        return Source.REMOVE;
                    });
                } else if (type == DBusMessageType.METHOD_RETURN && body != null && body.get_type_string () == "(u)") {
                    var call = "%s/%u".printf (msg.get_destination (), msg.get_reply_serial ());
                    var id = body.get_child_value (0).get_uint32 ();
                    Idle.add (() => {
                        set_server_id (call, id);
                        return Source.REMOVE;
                    });
                } else if (type == DBusMessageType.ERROR) {
                    var call = "%s/%u".printf (msg.get_destination (), msg.get_reply_serial ());
                    Idle.add (() => {
                        reject (call);
                        return Source.REMOVE;
                    });
                }
                return null;
            });
            // The server's reply carries the id that a later Notify can pass as replaces_id.
            string[] rules = {
                "type='method_call',interface='org.freedesktop.Notifications',member='Notify'",
                "type='method_return',sender='org.freedesktop.Notifications'",
                "type='error',sender='org.freedesktop.Notifications'"
            };
            monitor.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring",
                "BecomeMonitor", new Variant ("(^asu)", rules, 0), null, DBusCallFlags.NONE, -1);
        } catch (Error e) {
            warning ("Cannot monitor notifications: %s", e.message);
        }
    }

    // Senders disagree on the type of the transient hint, so accept a boolean, a byte or an int.
    bool is_transient (Variant hints) {
        var value = hints.lookup_value ("transient", null);
        switch (value?.get_type_string ()) {
            case "b": return value.get_boolean ();
            case "y": return value.get_byte () != 0;
            case "i": return value.get_int32 () != 0;
            default: return false;
        }
    }

    void add (Variant notify, string call) {
        var hints = notify.get_child_value (6);
        if (is_transient (hints)) {
            return;
        }
        var key = get_real_time ().to_string ();  // monotonic time restarts at boot and would reuse saved keys
        var app = notify.get_child_value (0).get_string ();
        var replaces = notify.get_child_value (1).get_uint32 ();
        var hint = hints.lookup_value ("desktop-entry", VariantType.STRING);
        // Server ids restart when the server does, so the newest entry of the same app wins.
        string? old = null;
        foreach (var group in store.get_groups ()) {
            if (replaces != 0 && field (group, "app") == app && field (group, "server_id") == replaces.to_string ()) {
                old = group;
            }
        }
        store.set_string (key, "app", app);
        store.set_string (key, "icon", notify.get_child_value (2).get_string ());
        store.set_string (key, "summary", notify.get_child_value (3).get_string ());
        store.set_string (key, "body", notify.get_child_value (4).get_string ());
        store.set_string (key, "desktop_entry", hint != null ? hint.get_string () : "");
        store.set_int64 (key, "time", get_real_time () / 1000000);
        if (old != null) {
            remove_group (old);
            store.set_int64 (key, "server_id", replaces);  // until the server's reply confirms it
        }
        if (pending.size () >= 100) {
            pending.remove_all ();  // replies that never arrive must not pile up; a lost one only skips a merge
        }
        pending[call] = key;
        save_to (store, path);
        if (old != null) {
            reload_rows ();
        } else {
            apps = AppInfo.get_all ();
            add_row (key);
            refresh ();
        }
    }

    void set_server_id (string call, uint32 id) {
        var key = pending[call];
        if (key != null) {
            pending.remove (call);
            if (store.has_group (key)) {  // Done or a newer replacement may have removed it already
                store.set_int64 (key, "server_id", id);
                save_to (store, path);
            }
        }
    }

    // An error reply means the server never showed the notification, so the inbox drops it too.
    void reject (string call) {
        var key = pending[call];
        if (key != null) {
            pending.remove (call);
            if (store.has_group (key)) {
                remove_group (key);
                save_to (store, path);
                reload_rows ();
            }
        }
    }

    string field (string key, string name) {
        try {
            return store.get_string (key, name);
        } catch (Error e) {
            return "";
        }
    }

    void add_row (string key) {
        var entry = field (key, "desktop_entry");
        var info = entry != "" ? new DesktopAppInfo (entry + ".desktop") : null;
        info = info ?? find_app (field (key, "app"));
        // gala keeps the screenshot path private, so its "Show in Files" button cannot be replayed; open the folder instead.
        var folder = field (key, "app") == "gala-feedback" ? screenshots_folder () : null;
        int64 time = 0;
        try {
            time = store.get_int64 (key, "time");
        } catch (Error e) {
            warning ("Bad time in %s: %s", key, e.message);
        }

        var stamp = new Stamp (field (key, "app"), new DateTime.from_unix_local (time));
        var source = stamp.label;
        source.add_css_class (Granite.CssClass.DIM);
        source.add_css_class (Granite.CssClass.SMALL);
        // Granite's h3 and h4 classes are not bold, and in a list h4 adds a margin, so set the weight directly.
        var bold = new Pango.AttrList ();
        bold.insert (Pango.attr_weight_new (Pango.Weight.BOLD));
        var summary = new Gtk.Label (field (key, "summary")) { xalign = 0, wrap = true, attributes = bold };
        // Plain text, so any markup in the body shows as typed and nothing is interpreted.
        var body = new Gtk.Label (field (key, "body")) { xalign = 0, wrap = true };
        var open = new Gtk.Button.with_label (folder != null ? "Show in Files" : "Open") { sensitive = info != null || folder != null };
        var done = new Gtk.Button.with_label ("Done");
        var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { halign = Gtk.Align.END };
        buttons.append (open);
        buttons.append (done);

        // The themed icon tries the sender's icon, then the app's desktop icon, then a generic one.
        var icon_name = field (key, "icon");
        var desktop_icon = info?.get_string ("Icon");
        Icon icon = icon_name.has_prefix ("/")
            ? (Icon) new FileIcon (File.new_for_path (icon_name))
            : new ThemedIcon.from_names ({ icon_name, desktop_icon ?? "", "dialog-information" });
        var image = new Gtk.Image.from_gicon (icon) { pixel_size = 32, valign = Gtk.Align.START };

        var text = new Gtk.Box (Gtk.Orientation.VERTICAL, 3) { hexpand = true };
        text.append (source);
        text.append (summary);
        text.append (body);
        text.append (buttons);
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        box.append (image);
        box.append (text);
        // Two revealers: the inner one fades the content, the outer one then collapses the space.
        var fade = new Gtk.Revealer () {
            child = box, reveal_child = true, transition_type = Gtk.RevealerTransitionType.CROSSFADE, transition_duration = 180
        };
        var collapse = new Gtk.Revealer () {
            child = fade, reveal_child = true, transition_type = Gtk.RevealerTransitionType.SLIDE_UP, transition_duration = 200
        };
        var row = new Gtk.ListBoxRow () { child = collapse, activatable = info != null || folder != null };
        row.set_data ("stamp", stamp);
        row.set_data ("open", open);
        list.prepend (row);

        open.clicked.connect (() => {
            try {
                if (folder != null) {
                    AppInfo.launch_default_for_uri (folder.get_uri (), null);
                } else {
                    info.launch (null, null);
                }
            } catch (Error e) {
                warning ("Cannot open %s: %s", entry, e.message);
            }
        });
        done.clicked.connect (() => {
            remove_group (key);
            save_to (store, path);
            row.sensitive = false;
            fade.notify["child-revealed"].connect (() => collapse.reveal_child = false);
            collapse.notify["child-revealed"].connect (() => {
                list.remove (row);
                refresh ();
            });
            fade.reveal_child = false;
        });
    }

    // Exact match only: the app name against an installed app's desktop id (or its last segment) or name.
    // Same folder gala saves to: its translated "Screenshots" inside Pictures, or Pictures itself.
    File screenshots_folder () {
        var pictures = File.new_for_path (Environment.get_user_special_dir (UserDirectory.PICTURES) ?? Environment.get_home_dir ());
        var screenshots = pictures.get_child (dgettext ("gala", "Screenshots"));
        return screenshots.query_exists () ? screenshots : pictures;
    }

    DesktopAppInfo? find_app (string name) {
        var wanted = name.down ();
        foreach (var app in apps) {
            var id = app.get_id ().down ();
            id = id.has_suffix (".desktop") ? id.substring (0, id.length - 8) : id;
            if (wanted in new string[] { id, id.substring (id.last_index_of (".") + 1), app.get_name ().down () }) {
                return app as DesktopAppInfo;
            }
        }
        return null;
    }

    void remove_group (string key) {
        try {
            store.remove_group (key);
        } catch (Error e) {
            warning ("Cannot remove %s: %s", key, e.message);
        }
    }

    void reload_rows () {
        apps = AppInfo.get_all ();
        list.remove_all ();
        foreach (var key in store.get_groups ()) {
            add_row (key);  // file order is oldest first, and each row is prepended
        }
        refresh ();
    }

    void refresh () {
        var count = store.get_groups ().length;
        stack.visible_child_name = count > 0 ? "list" : "empty";
        clear.sensitive = count > 0;

        // The dock (Pantheon, Unity, Plank) reads this signal to draw a count badge on the launcher.
        var props = new VariantBuilder (new VariantType ("a{sv}"));
        props.add ("{sv}", "count", new Variant.int64 (count));
        props.add ("{sv}", "count-visible", new Variant.boolean (show_count && count > 0));
        try {
            application.get_dbus_connection ()?.emit_signal (null, "/com/canonical/unity/launcherentry/intray",
                "com.canonical.Unity.LauncherEntry", "Update", new Variant ("(sa{sv})", "application://%s.desktop".printf (APP_ID), props));
        } catch (Error e) {
            warning ("Cannot update the dock badge: %s", e.message);
        }
    }
}

void save_to (KeyFile file, string path) {
    try {
        DirUtils.create_with_parents (Path.get_dirname (path), 0700);
        file.save_to_file (path);
    } catch (Error e) {
        warning ("Cannot save %s: %s", path, e.message);
    }
}

void follow_color_scheme () {
    var dark = Granite.Settings.get_default ().prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
    Gtk.Settings.get_default ().gtk_application_prefer_dark_theme = dark;
}

// valac passes string[] as char **, which C does not convert to the const char * const * that GTK takes.
[CCode (cname = "gtk_application_set_accels_for_action")]
extern void set_accels (Gtk.Application app, string action, [CCode (array_length = false, array_null_terminated = true, type = "const gchar * const *")] string[] accels);

int main (string[] args) {
    var app = new Gtk.Application (APP_ID, ApplicationFlags.HANDLES_COMMAND_LINE);
    app.add_main_option ("background", 0, OptionFlags.NONE, OptionArg.NONE, "Start without showing the window", null);
    app.startup.connect (() => {
        Granite.init ();
        follow_color_scheme ();
        Granite.Settings.get_default ().notify["prefers-color-scheme"].connect (follow_color_scheme);
        var quit = new SimpleAction ("quit", null);
        quit.activate.connect (app.quit);
        app.add_action (quit);
        set_accels (app, "app.quit", { "<Control>q" });
        set_accels (app, "window.close", { "<Control>w" });
        new Window (app);  // captures notifications even while hidden
    });
    app.command_line.connect ((command_line) => {
        if (!command_line.get_options_dict ().contains ("background")) {
            app.active_window.present ();
        }
        return 0;
    });
    return app.run (args);
}
