/*
 * globalmenu-gtk-module: GTK3 module that forces gtk-shell-shows-menubar=TRUE
 * to make appmenu-gtk-module hide the in-window menubar.
 *
 * This works alongside appmenu-gtk-module which does the actual menu extraction.
 *
 * Build: gcc -shared -fPIC -o libglobalmenu-gtk-module.so globalmenu-gtk-module.c \
 *   $(pkg-config --cflags --libs gtk+-3.0 gio-2.0)
 */

#include <gtk/gtk.h>
#include <gio/gio.h>
#include <string.h>

/* --- GtkModule API ------------------------------------------------------- */

void
gtk_module_init (gint *argc, gchar ***argv)
{
  g_print ("globalmenu-gtk-module: loading, forcing gtk-shell-shows-menubar=TRUE\n");

  /* Force gtk-shell-shows-menubar to TRUE so appmenu-gtk-module hides the in-window menubar */
  GtkSettings *settings = gtk_settings_get_default ();
  if (settings)
    {
      GParamSpec *pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (settings),
                                                         "gtk-shell-shows-menubar");
      if (pspec && pspec->value_type == G_TYPE_BOOLEAN)
        {
          g_object_set (settings, "gtk-shell-shows-menubar", TRUE, NULL);
          g_print ("globalmenu-gtk-module: set gtk-shell-shows-menubar=TRUE\n");
        }
      else
        {
          g_warning ("globalmenu-gtk-module: gtk-shell-shows-menubar property not found\n");
        }
    }
  else
    {
      g_warning ("globalmenu-gtk-module: no default settings\n");
    }
}

void
gtk_module_exit (void)
{
  g_print ("globalmenu-gtk-module: unloading\n");
}