/*
 * globalmenu-hide: GTK 3 module that hides applications' in-window menubars
 * while the global menu panel plugin is running.
 *
 * The plugin owns the session bus name org.nimglobalmenu.Panel. This module,
 * loaded into every GTK 3 application through GTK_MODULES, exports
 * org.nimglobalmenu.HideManager at /org/nimglobalmenu/HideManager on the
 * app's own session bus connection, the same connection appmenu-gtk-module
 * exports the menu on, so the plugin reaches it at the unique bus name it
 * already has for the menu. The plugin calls Register once it shows the
 * app's menu (and Unregister if that menu turns out empty):
 *   - while an app is registered, every GtkMenuBar that gets mapped is hidden;
 *   - when unregistered (or plugin disappears), the bars hidden here are shown
 *     again, so an application is never left without a menu.
 * It is loaded after appmenu-gtk-module, which exports the menus over D-Bus.
 *
 * Build: gcc -shared -fPIC -o libglobalmenu-hide.so globalmenu-hide.c \
 *          $(pkg-config --cflags --libs gtk+-3.0 gio-2.0)
 */

#include <gtk/gtk.h>
#include <gio/gio.h>

#define PANEL_NAME "org.nimglobalmenu.Panel"
#define MANAGER_PATH "/org/nimglobalmenu/HideManager"
#define MANAGER_IFACE "org.nimglobalmenu.HideManager"
/* Menubars of the plugin itself carry this widget name and are never hidden. */
#define KEEP_NAME "globalmenu-keep"

static GHashTable *hidden = NULL;   /* GtkWidget* we hid -> unused */
static gboolean registered = FALSE; /* Is this app registered? */

static void
bar_destroyed (gpointer data, GObject *where_the_object_was)
{
  g_hash_table_remove (hidden, where_the_object_was);
}

static gboolean
is_ours (GtkWidget *bar)
{
  return g_strcmp0 (gtk_widget_get_name (bar), KEEP_NAME) == 0;
}

static void
hide_bar (GtkWidget *bar)
{
  if (is_ours (bar) || !gtk_widget_get_visible (bar))
    return;
  g_hash_table_add (hidden, bar);
  g_object_weak_ref (G_OBJECT (bar), bar_destroyed, NULL);
  gtk_widget_hide (bar);
}

static void
show_hidden_bars (void)
{
  GHashTableIter iter;
  gpointer key;
  GList *bars = NULL;

  g_hash_table_iter_init (&iter, hidden);
  while (g_hash_table_iter_next (&iter, &key, NULL))
    bars = g_list_prepend (bars, key);

  for (GList *l = bars; l; l = l->next)
    {
      g_object_weak_unref (G_OBJECT (l->data), bar_destroyed, NULL);
      gtk_widget_show (GTK_WIDGET (l->data));
    }
  g_list_free (bars);
  g_hash_table_remove_all (hidden);
}

static gboolean
hide_in_idle (gpointer data)
{
  GtkWidget *bar = GTK_WIDGET (data);

  if (registered)
    hide_bar (bar);
  g_object_unref (bar);
  return G_SOURCE_REMOVE;
}

/* Runs for every "map" emission on any widget. */
static gboolean
map_hook (GSignalInvocationHint *hint, guint n_values,
          const GValue *values, gpointer data)
{
  GObject *object = g_value_get_object (&values[0]);

  /* Hiding inside the emission would unmap the widget while it is being
   * mapped; do it from the main loop instead. */
  if (registered && GTK_IS_MENU_BAR (object))
    g_idle_add (hide_in_idle, g_object_ref (object));
  return TRUE;
}

static void
hide_mapped_bars (void)
{
  GList *toplevels = gtk_window_list_toplevels ();

  for (GList *l = toplevels; l; l = l->next)
    {
      GList *bars = NULL;
      GList *stack = g_list_prepend (NULL, l->data);

      /* Walk the widget tree for menubars. */
      while (stack)
        {
          GtkWidget *w = stack->data;
          stack = g_list_delete_link (stack, stack);
          if (GTK_IS_MENU_BAR (w))
            bars = g_list_prepend (bars, w);
          else if (GTK_IS_CONTAINER (w))
            {
              GList *children = gtk_container_get_children (GTK_CONTAINER (w));
              stack = g_list_concat (children, stack);
            }
        }
      for (GList *b = bars; b; b = b->next)
        hide_bar (b->data);
      g_list_free (bars);
    }
  g_list_free (toplevels);
}

static void
set_registered (gboolean value)
{
  if (registered == value)
    return;
  registered = value;
  if (registered)
    hide_mapped_bars ();
  else
    show_hidden_bars ();
}

/* --- D-Bus interface for the plugin to register apps --- */

static const gchar manager_introspection_xml[] =
  "<node>"
  "  <interface name='" MANAGER_IFACE "'>"
  "    <method name='Register'>"
  "      <arg type='s' name='app_id' direction='in'/>"
  "    </method>"
  "    <method name='Unregister'>"
  "      <arg type='s' name='app_id' direction='in'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *introspection_data = NULL;

static void
handle_method_call (GDBusConnection *connection,
                    const gchar *sender,
                    const gchar *object_path,
                    const gchar *interface_name,
                    const gchar *method_name,
                    GVariant *parameters,
                    GDBusMethodInvocation *invocation,
                    gpointer user_data)
{
  if (g_strcmp0 (method_name, "Register") == 0)
    {
      const gchar *app_id;
      g_variant_get (parameters, "(&s)", &app_id);
      g_print ("globalmenu-hide: Register app_id=%s\n", app_id);
      set_registered (TRUE);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else if (g_strcmp0 (method_name, "Unregister") == 0)
    {
      const gchar *app_id;
      g_variant_get (parameters, "(&s)", &app_id);
      g_print ("globalmenu-hide: Unregister app_id=%s\n", app_id);
      set_registered (FALSE);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
}

static const GDBusInterfaceVTable interface_vtable =
{
  handle_method_call,
  NULL,  /* get_property */
  NULL   /* set_property */
};

static void
on_bus_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
  GError *error = NULL;
  guint registration_id;
  GDBusConnection *connection = g_bus_get_finish (result, &error);

  if (connection == NULL)
    {
      g_warning ("globalmenu-hide: no session bus: %s", error->message);
      g_error_free (error);
      return;
    }

  introspection_data = g_dbus_node_info_new_for_xml (manager_introspection_xml, &error);
  if (error != NULL)
    {
      g_warning ("globalmenu-hide: failed to parse introspection: %s", error->message);
      g_error_free (error);
      return;
    }

  registration_id = g_dbus_connection_register_object (connection,
                                                        MANAGER_PATH,
                                                        introspection_data->interfaces[0],
                                                        &interface_vtable,
                                                        NULL,  /* user_data */
                                                        NULL,  /* user_data_free_func */
                                                        &error);
  if (error != NULL)
    {
      g_warning ("globalmenu-hide: failed to register object: %s", error->message);
      g_error_free (error);
    }
  (void) registration_id;
  /* The connection is the process-wide shared one; keep it. */
}

static void
on_panel_vanished (GDBusConnection *connection,
                   const gchar *name,
                   gpointer user_data)
{
  /* Panel (or the plugin) gone: show the bars that were hidden here. */
  set_registered (FALSE);
}

/* The panel hosts the plugin: its menubars must stay, so do nothing there. */
static gboolean
in_panel_process (void)
{
  gchar *exe = g_file_read_link ("/proc/self/exe", NULL);
  gchar *base = exe ? g_path_get_basename (exe) : NULL;
  gboolean panel = g_strcmp0 (base, "xfce4-panel") == 0;

  g_free (base);
  g_free (exe);
  return panel;
}

void
gtk_module_init (gint *argc, gchar ***argv)
{
  if (in_panel_process ())
    return;

  hidden = g_hash_table_new (g_direct_hash, g_direct_equal);

  /* Make sure the "map" signal exists before looking it up. */
  g_type_class_ref (GTK_TYPE_MENU_BAR);
  g_signal_add_emission_hook (g_signal_lookup ("map", GTK_TYPE_WIDGET), 0,
                              map_hook, NULL, NULL);

  /* Show the bars again whenever the panel's name goes away. */
  g_bus_watch_name (G_BUS_TYPE_SESSION, PANEL_NAME,
                    G_BUS_NAME_WATCHER_FLAGS_NONE,
                    NULL, on_panel_vanished, NULL, NULL);

  /* Export the HideManager on the shared session connection. */
  g_bus_get (G_BUS_TYPE_SESSION, NULL, on_bus_ready, NULL);
}