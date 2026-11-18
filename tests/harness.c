/*
 * Hosts a panel plugin library in a plain GTK window, the way xfce4-panel
 * loads it, so the plugin can be tried in the isolated test session.
 *   harness LIBRARY.so [SECONDS]
 */
#include <gtk/gtk.h>
#include <gmodule.h>

typedef GtkWidget *(*Construct)(const gchar *, gint, const gchar *,
    const gchar *, gchar **, GdkScreen *);

static gboolean quit(gpointer data) { gtk_main_quit(); return FALSE; }

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  GModule *module = g_module_open(argv[1], G_MODULE_BIND_LOCAL);
  if (!module) { g_printerr("open failed: %s\n", g_module_error()); return 1; }
  Construct construct;
  if (!g_module_symbol(module, "xfce_panel_module_construct",
      (gpointer *)&construct)) return 2;
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(window), 700, 40);
  GtkWidget *plugin = construct("globalmenu-nim", 9999, "Global Menu (Nim)",
      "test", NULL, gdk_screen_get_default());
  gtk_container_add(GTK_CONTAINER(window), plugin);
  gtk_widget_show_all(window);
  g_timeout_add_seconds(argc > 2 ? atoi(argv[2]) : 60, quit, NULL);
  gtk_main();
  return 0;
}
