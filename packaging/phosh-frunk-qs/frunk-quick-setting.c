/*
 * FP5: "Frunk" quick setting for Phosh 0.59 (out-of-tree plugin).
 *
 * Tap -> `systemctl start --no-ask-password tesla-frunk.service` as the session
 * user (polkit rule 60-fp5-tesla-frunk.rules allows exactly that unit/verb).
 * The root side (tesla-frunk-root.sh) re-checks a live BLE link + the Tesla
 * phone-key notification before it sends anything.
 *
 * The tile is insensitive unless BlueZ shows a connected device carrying the
 * Tesla VCSEC GATT service (same rule as tesla-frunk-root.sh). Works on the
 * lock screen like other custom quick settings.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <gio/gio.h>
#include <gtk/gtk.h>
#include <stdlib.h>

#include "quick-setting.h"
#include "status-icon.h"

#define EXTENSION_POINT "phosh-quick-setting-widget"
#define PLUGIN_NAME     "frunk-quick-setting"
#define VCSEC_UUID      "00000211-b2d1-43f0-9b88-960cebf8b91e"
#define ICON_DIR        "/usr/share/fp5-frunk-qs/icons"
#define ICON_NAME       "tesla-frunk-symbolic"

#define PHOSH_TYPE_FRUNK_QUICK_SETTING (phosh_frunk_quick_setting_get_type ())
G_DECLARE_FINAL_TYPE (PhoshFrunkQuickSetting, phosh_frunk_quick_setting, PHOSH,
                      FRUNK_QUICK_SETTING, PhoshQuickSetting)

struct _PhoshFrunkQuickSetting {
  PhoshQuickSetting   parent;

  PhoshStatusIcon    *info;
  GDBusObjectManager *bluez;
  GDBusConnection    *session;
  GCancellable       *cancel;
  gboolean            car_up;
  gboolean            busy;
  guint               reset_id;
};

G_DEFINE_TYPE (PhoshFrunkQuickSetting, phosh_frunk_quick_setting, PHOSH_TYPE_QUICK_SETTING)

static void
update_state (PhoshFrunkQuickSetting *self)
{
  phosh_quick_setting_set_active (PHOSH_QUICK_SETTING (self), self->car_up);
  gtk_widget_set_sensitive (GTK_WIDGET (self), self->car_up && !self->busy);
  if (self->reset_id == 0)
    phosh_status_icon_set_info (self->info, self->car_up ? "Frunk" : "Frunk (no car)");
}

static gboolean
on_reset_label (gpointer data)
{
  PhoshFrunkQuickSetting *self = data;

  self->reset_id = 0;
  update_state (self);
  return G_SOURCE_REMOVE;
}

static void
show_result (PhoshFrunkQuickSetting *self, const char *msg)
{
  phosh_status_icon_set_info (self->info, msg);
  g_clear_handle_id (&self->reset_id, g_source_remove);
  self->reset_id = g_timeout_add_seconds (5, on_reset_label, self);
  /* Toast-like feedback: async Notify to the session's notification daemon
   * (phosh itself; async, so no self-deadlock). notify-send is not installed. */
  if (self->session == NULL)
    return;
  g_dbus_connection_call (self->session,
                          "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                          "org.freedesktop.Notifications", "Notify",
                          g_variant_new ("(susssasa{sv}i)", "Frunk", (guint32) 0, ICON_NAME,
                                         "Frunk", msg, NULL, NULL, (gint32) 4000),
                          NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

static gboolean
device_is_car_up (GDBusObject *obj)
{
  g_autoptr (GDBusInterface) iface = g_dbus_object_get_interface (obj, "org.bluez.Device1");
  g_autoptr (GVariant) connected = NULL;
  g_autoptr (GVariant) uuids = NULL;

  if (iface == NULL)
    return FALSE;
  connected = g_dbus_proxy_get_cached_property (G_DBUS_PROXY (iface), "Connected");
  if (connected == NULL || !g_variant_get_boolean (connected))
    return FALSE;
  uuids = g_dbus_proxy_get_cached_property (G_DBUS_PROXY (iface), "UUIDs");
  if (uuids == NULL)
    return FALSE;
  g_autofree const char **list = g_variant_get_strv (uuids, NULL);  /* container only */
  for (int i = 0; list && list[i]; i++) {
    if (g_ascii_strcasecmp (list[i], VCSEC_UUID) == 0)
      return TRUE;
  }
  return FALSE;
}

static void
recompute (PhoshFrunkQuickSetting *self)
{
  gboolean up = FALSE;

  if (self->bluez) {
    GList *objs = g_dbus_object_manager_get_objects (self->bluez);
    for (GList *l = objs; l && !up; l = l->next)
      up = device_is_car_up (G_DBUS_OBJECT (l->data));
    g_list_free_full (objs, g_object_unref);
  }
  self->car_up = up;
  update_state (self);
}

static void
on_bluez_ready (GObject *source, GAsyncResult *res, gpointer data)
{
  g_autoptr (GError) err = NULL;
  GDBusObjectManager *om = g_dbus_object_manager_client_new_for_bus_finish (res, &err);
  PhoshFrunkQuickSetting *self;

  if (om == NULL) {
    if (!g_error_matches (err, G_IO_ERROR, G_IO_ERROR_CANCELLED))
      g_warning ("frunk-quick-setting: BlueZ object manager: %s", err->message);
    return;
  }
  self = PHOSH_FRUNK_QUICK_SETTING (data);
  self->bluez = om;
  g_signal_connect_object (om, "object-added", G_CALLBACK (recompute), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (om, "object-removed", G_CALLBACK (recompute), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (om, "interface-added", G_CALLBACK (recompute), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (om, "interface-removed", G_CALLBACK (recompute), self, G_CONNECT_SWAPPED);
  g_signal_connect_object (om, "interface-proxy-properties-changed", G_CALLBACK (recompute), self,
                           G_CONNECT_SWAPPED);
  recompute (self);
}

static void
on_status_read (GObject *source, GAsyncResult *res, gpointer data)
{
  PhoshFrunkQuickSetting *self = data;
  g_autoptr (GError) err = NULL;
  g_autofree char *out = NULL;
  int code;

  if (!g_subprocess_communicate_utf8_finish (G_SUBPROCESS (source), res, &out, NULL, &err)) {
    if (g_error_matches (err, G_IO_ERROR, G_IO_ERROR_CANCELLED))
      return;
  }
  code = out ? atoi (g_strstrip (out)) : -1;
  self->busy = FALSE;
  update_state (self);
  switch (code) {
  case 3:  show_result (self, "Car not connected"); break;
  case 4:  show_result (self, "Waydroid not running"); break;
  default: show_result (self, "Could not send"); break;
  }
}

static void
on_start_done (GObject *source, GAsyncResult *res, gpointer data)
{
  PhoshFrunkQuickSetting *self = data;
  g_autoptr (GError) err = NULL;

  if (!g_subprocess_wait_finish (G_SUBPROCESS (source), res, &err)) {
    if (g_error_matches (err, G_IO_ERROR, G_IO_ERROR_CANCELLED))
      return;
  }
  if (err == NULL && g_subprocess_get_successful (G_SUBPROCESS (source))) {
    self->busy = FALSE;
    update_state (self);
    show_result (self, "Frunk command sent");
    return;
  }
  /* Why did it fail? 3 = not connected, 4 = no Waydroid (see tesla-frunk-root.sh) */
  g_autoptr (GSubprocess) st = g_subprocess_new (G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                                 G_SUBPROCESS_FLAGS_STDERR_SILENCE, NULL,
                                                 "systemctl", "show", "-p", "ExecMainStatus",
                                                 "--value", "tesla-frunk.service", NULL);
  if (st == NULL) {
    self->busy = FALSE;
    update_state (self);
    show_result (self, "Could not send");
    return;
  }
  g_subprocess_communicate_utf8_async (st, NULL, self->cancel, on_status_read, self);
}

static void
on_clicked (PhoshFrunkQuickSetting *self)
{
  g_autoptr (GError) err = NULL;
  g_autoptr (GSubprocess) p = NULL;

  if (self->busy || !self->car_up)
    return;

  p = g_subprocess_new (G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, &err,
                        "systemctl", "start", "--no-ask-password", "tesla-frunk.service", NULL);
  if (p == NULL) {
    show_result (self, "Could not send");
    return;
  }
  self->busy = TRUE;
  update_state (self);
  phosh_status_icon_set_info (self->info, "Frunk…");
  g_subprocess_wait_async (p, self->cancel, on_start_done, self);
}

static void
phosh_frunk_quick_setting_dispose (GObject *object)
{
  PhoshFrunkQuickSetting *self = PHOSH_FRUNK_QUICK_SETTING (object);

  g_cancellable_cancel (self->cancel);
  g_clear_object (&self->cancel);
  g_clear_handle_id (&self->reset_id, g_source_remove);
  g_clear_object (&self->bluez);
  g_clear_object (&self->session);

  G_OBJECT_CLASS (phosh_frunk_quick_setting_parent_class)->dispose (object);
}

static void
phosh_frunk_quick_setting_class_init (PhoshFrunkQuickSettingClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = phosh_frunk_quick_setting_dispose;
}

static void
phosh_frunk_quick_setting_init (PhoshFrunkQuickSetting *self)
{
  GtkIconTheme *theme = gtk_icon_theme_get_default ();

  gtk_icon_theme_append_search_path (theme, ICON_DIR);

  self->cancel = g_cancellable_new ();
  self->session = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, NULL);
  self->info = PHOSH_STATUS_ICON (phosh_status_icon_new ());
  phosh_status_icon_set_pixel_size (self->info, 16);
  phosh_status_icon_set_icon_name (self->info, ICON_NAME);
  gtk_widget_show (GTK_WIDGET (self->info));
  phosh_quick_setting_set_status_icon (PHOSH_QUICK_SETTING (self), self->info);

  g_signal_connect (self, "clicked", G_CALLBACK (on_clicked), NULL);

  update_state (self);
  g_dbus_object_manager_client_new_for_bus (G_BUS_TYPE_SYSTEM,
                                            G_DBUS_OBJECT_MANAGER_CLIENT_FLAGS_NONE,
                                            "org.bluez", "/", NULL, NULL, NULL,
                                            self->cancel, on_bluez_ready, self);
}

/* GIO module glue */
char **g_io_phosh_plugin_frunk_quick_setting_query (void);
void g_io_module_load (GIOModule *module);
void g_io_module_unload (GIOModule *module);

void
g_io_module_load (GIOModule *module)
{
  g_type_module_use (G_TYPE_MODULE (module));
  g_io_extension_point_implement (EXTENSION_POINT, PHOSH_TYPE_FRUNK_QUICK_SETTING, PLUGIN_NAME, 10);
}

void
g_io_module_unload (GIOModule *module)
{
}

char **
g_io_phosh_plugin_frunk_quick_setting_query (void)
{
  char *eps[] = { EXTENSION_POINT, NULL };

  return g_strdupv (eps);
}
