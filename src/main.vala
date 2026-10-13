const string SCHEMA = "io.elementary.notifications";
const string NOTIFY_SIGNATURE = "(susssasa{sv}i)";

class Window : Adw.ApplicationWindow {
    KeyFile store = new KeyFile ();
    string path = Path.build_filename (Environment.get_user_data_dir (), "intray", "inbox.ini");
    Gtk.ListBox list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, show_separators = true };
    Gtk.Stack stack = new Gtk.Stack ();
    Gtk.Button clear = new Gtk.Button.with_label ("Clear all");
    DBusConnection monitor;

    public Window (Adw.Application app) {
        Object (application: app, default_width: 480, default_height: 640);

        var header = new Adw.HeaderBar ();
        header.pack_start (clear);
        clear.clicked.connect (() => {
            foreach (var key in store.get_groups ()) {
                remove_group (key);
            }
            save ();
            list.remove_all ();
            refresh ();
        });

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
        stack.add_named (new Adw.StatusPage () { title = "Inbox zero", icon_name = "emblem-ok-symbolic" }, "empty");
        var view = new Adw.ToolbarView () { content = stack };
        view.add_top_bar (header);
        content = view;

        try {
            store.load_from_file (path, KeyFileFlags.NONE);
        } catch (Error e) {
            if (!(e is FileError.NOENT)) {
                warning ("Cannot load %s: %s", path, e.message);
                // Move the unreadable file aside so the next save does not overwrite it.
                FileUtils.rename (path, path + ".corrupt");
            }
        }
        foreach (var key in store.get_groups ()) {
            add_row (key);  // file order is oldest first, and each row is prepended
        }
        refresh ();
        start_monitor ();
    }

    void start_monitor () {
        try {
            monitor = new DBusConnection.for_address_sync (BusType.SESSION.get_address_sync (),
                DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION);
            // The filter runs on a worker thread. It drops captured calls so GDBus never replies to them
            // (a monitor that sends is disconnected), and passes the rest so BecomeMonitor still works.
            monitor.add_filter ((conn, msg, incoming) => {
                if (!incoming || msg.get_message_type () != DBusMessageType.METHOD_CALL) {
                    return msg;
                }
                var body = msg.get_body ();
                // Any client can send a malformed Notify, so check the signature before reading it.
                if (body != null && body.get_type_string () == NOTIFY_SIGNATURE) {
                    Idle.add (() => {
                        add (body);
                        return Source.REMOVE;
                    });
                }
                return null;
            });
            string[] rules = { "type='method_call',interface='org.freedesktop.Notifications',member='Notify'" };
            monitor.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring",
                "BecomeMonitor", new Variant ("(^asu)", rules, 0), null, DBusCallFlags.NONE, -1);
        } catch (Error e) {
            warning ("Cannot monitor notifications: %s", e.message);
        }
    }

    void add (Variant notify) {
        var key = get_real_time ().to_string ();  // monotonic time restarts at boot and would reuse saved keys
        var hint = notify.get_child_value (6).lookup_value ("desktop-entry", VariantType.STRING);
        store.set_string (key, "app", notify.get_child_value (0).get_string ());
        store.set_string (key, "icon", notify.get_child_value (2).get_string ());
        store.set_string (key, "summary", notify.get_child_value (3).get_string ());
        store.set_string (key, "body", notify.get_child_value (4).get_string ());
        store.set_string (key, "desktop_entry", hint != null ? hint.get_string () : "");
        store.set_int64 (key, "time", get_real_time () / 1000000);
        save ();
        add_row (key);
        refresh ();
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
        int64 time = 0;
        try {
            time = store.get_int64 (key, "time");
        } catch (Error e) {
            warning ("Bad time in %s: %s", key, e.message);
        }

        var source = new Gtk.Label ("%s · %s".printf (field (key, "app"), new DateTime.from_unix_local (time).format ("%d %b %H:%M"))) { xalign = 0 };
        source.add_css_class ("dim-label");
        source.add_css_class ("caption");
        var summary = new Gtk.Label (field (key, "summary")) { xalign = 0, wrap = true };
        summary.add_css_class ("heading");
        // Plain text, so any markup in the body shows as typed and nothing is interpreted.
        var body = new Gtk.Label (field (key, "body")) { xalign = 0, wrap = true };
        var open = new Gtk.Button.with_label ("Open") { sensitive = info != null };
        var done = new Gtk.Button.with_label ("Done");
        var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { halign = Gtk.Align.END };
        buttons.append (open);
        buttons.append (done);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4) {
            margin_top = 8, margin_bottom = 8, margin_start = 12, margin_end = 12
        };
        box.append (source);
        box.append (summary);
        box.append (body);
        box.append (buttons);
        var row = new Gtk.ListBoxRow () { child = box, activatable = false };
        list.prepend (row);

        open.clicked.connect (() => {
            try {
                info.launch (null, null);
            } catch (Error e) {
                warning ("Cannot open %s: %s", entry, e.message);
            }
        });
        done.clicked.connect (() => {
            remove_group (key);
            save ();
            list.remove (row);
            refresh ();
        });
    }

    void remove_group (string key) {
        try {
            store.remove_group (key);
        } catch (Error e) {
            warning ("Cannot remove %s: %s", key, e.message);
        }
    }

    void save () {
        try {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            store.save_to_file (path);
        } catch (Error e) {
            warning ("Cannot save %s: %s", path, e.message);
        }
    }

    void refresh () {
        var count = store.get_groups ().length;
        title = count > 0 ? "Intray (%d)".printf (count) : "Intray";
        stack.visible_child_name = count > 0 ? "list" : "empty";
        clear.sensitive = count > 0;
    }
}

int main (string[] args) {
    var app = new Adw.Application ("com.github.svandragt.Intray", ApplicationFlags.DEFAULT_FLAGS);
    app.activate.connect (() => (app.active_window ?? new Window (app)).present ());
    return app.run (args);
}
