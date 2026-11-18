## Minimal bindings for the GTK 3, GDK and xfce4-panel calls the applet uses.

import ./gio

{.passL: "-l:libgtk-3.so.0 -l:libgdk-3.so.0 -l:libxfce4panel-2.0.so.4".}

type
  GType* = csize_t
  GtkWidget* = ptr object
  GdkScreen* = ptr object
  GdkDisplay* = ptr object
  XfcePanelPlugin* = ptr object
  GCallback* = pointer
  GSourceFunc* = proc (data: pointer): gboolean {.cdecl.}

const
  GTK_ORIENTATION_HORIZONTAL* = cint(0)
  GTK_STYLE_PROVIDER_PRIORITY_APPLICATION* = cuint(600)

{.push importc, cdecl.}
proc g_object_new*(gtype: GType, firstProperty: cstring): pointer {.varargs.}
proc g_object_set_data*(obj: pointer, key: cstring, data: pointer)
proc g_object_set*(obj: pointer, firstProperty: cstring) {.varargs.}
proc g_object_get*(obj: pointer, firstProperty: cstring) {.varargs.}
proc gtk_settings_get_default*(): pointer
proc g_object_get_data*(obj: pointer, key: cstring): pointer
proc g_signal_connect_data*(instance: pointer, signal: cstring,
    handler: GCallback, data, destroyData: pointer, flags: cint): culong
proc g_type_check_instance_is_a*(instance: pointer, gtype: GType): gboolean
proc g_timeout_add*(interval: cuint, function: GSourceFunc,
    data: pointer): cuint
proc g_idle_add*(function: GSourceFunc, data: pointer): cuint
proc g_source_remove*(tag: cuint): gboolean

proc gtk_box_new*(orientation, spacing: cint): GtkWidget
proc gtk_container_add*(container, widget: GtkWidget)
proc gtk_container_remove*(container, widget: GtkWidget)
proc gtk_widget_destroy*(widget: GtkWidget)
proc gtk_widget_set_name*(widget: GtkWidget, name: cstring)
proc gtk_widget_show*(widget: GtkWidget)
proc gtk_widget_show_all*(widget: GtkWidget)
proc gtk_widget_insert_action_group*(widget: GtkWidget, name: cstring,
    group: GActionGroup)
proc gtk_label_new*(text: cstring): GtkWidget
proc gtk_label_set_markup*(label: GtkWidget, markup: cstring)
proc gtk_bin_get_child*(bin: GtkWidget): GtkWidget
proc gtk_box_pack_start*(box, child: GtkWidget, expand, fill: gboolean,
    padding: cuint)
proc gtk_menu_bar_new*(): GtkWidget
proc gtk_menu_new*(): GtkWidget
proc gtk_menu_item_new_with_label*(label: cstring): GtkWidget
proc gtk_menu_item_set_label*(item: GtkWidget, label: cstring)
proc gtk_menu_item_set_submenu*(item, submenu: GtkWidget)
proc gtk_menu_shell_append*(shell, child: GtkWidget)
proc gtk_separator_menu_item_new*(): GtkWidget
proc g_markup_escape_text*(text: cstring, length: int): cstring
proc gtk_widget_set_tooltip_text*(widget: GtkWidget, text: cstring)
proc gtk_widget_get_style_context*(widget: GtkWidget): pointer
proc gtk_style_context_add_class*(context: pointer, className: cstring)
proc g_signal_handler_disconnect*(instance: pointer, handlerId: culong)
proc gtk_menu_bar_new_from_model*(model: GMenuModel): GtkWidget
proc gtk_menu_item_new_with_mnemonic*(label: cstring): GtkWidget
proc gtk_menu_item_set_use_underline*(item: GtkWidget, setting: gboolean)
proc gtk_check_menu_item_new_with_mnemonic*(label: cstring): GtkWidget
proc gtk_check_menu_item_set_active*(item: GtkWidget, active: gboolean)
proc gtk_check_menu_item_set_draw_as_radio*(item: GtkWidget,
    drawAsRadio: gboolean)
proc gtk_widget_set_sensitive*(widget: GtkWidget, sensitive: gboolean)
proc gtk_widget_set_visible*(widget: GtkWidget, visible: gboolean)
proc gtk_widget_set_no_show_all*(widget: GtkWidget, noShowAll: gboolean)
proc gtk_accel_label_get_type*(): GType
proc gtk_accel_label_set_accel*(label: GtkWidget, key: cuint, mods: cuint)
proc gtk_get_current_event_time*(): uint32
proc gdk_keyval_from_name*(name: cstring): cuint
proc gdk_keyval_to_lower*(keyval: cuint): cuint
proc gdk_unicode_to_keyval*(wc: uint32): cuint

proc gtk_css_provider_new*(): pointer
proc gtk_css_provider_load_from_data*(provider: pointer, data: cstring,
    length: int, error: ptr ptr GError): gboolean
proc gtk_style_context_add_provider_for_screen*(screen: GdkScreen,
    provider: pointer, priority: cuint)

proc gdk_screen_get_default*(): GdkScreen
proc gdk_display_get_default*(): GdkDisplay
proc gdk_wayland_display_get_type*(): GType
proc gdk_wayland_display_get_wl_display*(display: GdkDisplay): pointer

proc xfce_panel_plugin_get_type*(): GType
proc xfce_panel_plugin_set_expand*(plugin: XfcePanelPlugin, expand: gboolean)
{.pop.}

proc g_signal_connect*(instance: pointer, signal: cstring, handler: GCallback,
    data: pointer = nil) =
  discard g_signal_connect_data(instance, signal, handler, data, nil, 0)

proc g_signal_connect_after*(instance: pointer, signal: cstring,
    handler: GCallback, data: pointer = nil) =
  discard g_signal_connect_data(instance, signal, handler, data, nil, 1)

proc onWayland*(display: GdkDisplay): bool =
  g_type_check_instance_is_a(display, gdk_wayland_display_get_type()) != 0
