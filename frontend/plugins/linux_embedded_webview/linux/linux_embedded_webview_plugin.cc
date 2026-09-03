#include "include/linux_embedded_webview/linux_embedded_webview_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <cstring>
#include <string>

#define LINUX_EMBEDDED_WEBVIEW_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), linux_embedded_webview_plugin_get_type(), \
                              LinuxEmbeddedWebviewPlugin))

struct _LinuxEmbeddedWebviewPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* channel;
  GtkWidget* overlay;
  GtkWidget* webview;
  gchar* on_ready_script;
};

G_DEFINE_TYPE(LinuxEmbeddedWebviewPlugin, linux_embedded_webview_plugin,
              g_object_get_type())

static GtkWidget* ensure_overlay(GtkWidget* view) {
  GtkWidget* parent = gtk_widget_get_parent(view);
  if (parent != nullptr && GTK_IS_OVERLAY(parent)) {
    return parent;
  }
  GtkWidget* overlay = gtk_overlay_new();
  gtk_widget_set_hexpand(overlay, TRUE);
  gtk_widget_set_vexpand(overlay, TRUE);
  if (parent != nullptr) {
    g_object_ref(view);
    gtk_container_remove(GTK_CONTAINER(parent), view);
    gtk_container_add(GTK_CONTAINER(parent), overlay);
    gtk_container_add(GTK_CONTAINER(overlay), view);
    g_object_unref(view);
  }
  gtk_widget_show(overlay);
  gtk_widget_show(view);
  return overlay;
}

static void apply_user_agent(WebKitSettings* settings) {
  const gchar* current = webkit_settings_get_user_agent(settings);
  if (current != nullptr && strstr(current, "Chrome/") != nullptr) {
    return;
  }
  g_autofree gchar* ua =
      g_strdup_printf("%s Chrome/122.0.0.0", current != nullptr ? current : "");
  webkit_settings_set_user_agent(settings, ua);
}

static void on_load_changed(WebKitWebView* web_view, WebKitLoadEvent event,
                            gpointer user_data) {
  auto* self = LINUX_EMBEDDED_WEBVIEW_PLUGIN(user_data);
  if (event != WEBKIT_LOAD_FINISHED || self->on_ready_script == nullptr) {
    return;
  }
  webkit_web_view_evaluate_javascript(web_view, self->on_ready_script, -1,
                                      nullptr, nullptr, nullptr, nullptr,
                                      nullptr);
}

static void ensure_webview(LinuxEmbeddedWebviewPlugin* self) {
  if (self->webview != nullptr) {
    return;
  }
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr) {
    return;
  }
  self->overlay = ensure_overlay(GTK_WIDGET(view));
  GtkWidget* webview = webkit_web_view_new();
  WebKitSettings* settings = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(webview));
  webkit_settings_set_javascript_can_open_windows_automatically(settings, TRUE);
  webkit_settings_set_media_playback_requires_user_gesture(settings, FALSE);
  webkit_settings_set_auto_load_images(settings, TRUE);
  apply_user_agent(settings);
  gtk_widget_set_halign(webview, GTK_ALIGN_START);
  gtk_widget_set_valign(webview, GTK_ALIGN_START);
  gtk_widget_set_hexpand(webview, FALSE);
  gtk_widget_set_vexpand(webview, FALSE);
  gtk_overlay_add_overlay(GTK_OVERLAY(self->overlay), webview);
  g_signal_connect(webview, "load-changed", G_CALLBACK(on_load_changed), self);
  self->webview = webview;
}

static void set_bounds(LinuxEmbeddedWebviewPlugin* self, int x, int y, int w,
                       int h, gboolean visible) {
  ensure_webview(self);
  if (self->webview == nullptr) {
    return;
  }
  if (!visible || w < 8 || h < 8) {
    gtk_widget_hide(self->webview);
    return;
  }
  gtk_widget_set_margin_start(self->webview, x);
  gtk_widget_set_margin_top(self->webview, y);
  gtk_widget_set_margin_end(self->webview, 0);
  gtk_widget_set_margin_bottom(self->webview, 0);
  gtk_widget_set_size_request(self->webview, w, h);
  gtk_widget_set_visible(self->webview, TRUE);
  gtk_widget_show(self->webview);
  gtk_widget_queue_resize(self->webview);
}

static void linux_embedded_webview_plugin_handle_method_call(
    LinuxEmbeddedWebviewPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "load") == 0) {
    ensure_webview(self);
    const gchar* url = fl_value_get_string(fl_value_lookup_string(args, "url"));
    if (self->webview != nullptr && url != nullptr) {
      webkit_web_view_load_uri(WEBKIT_WEB_VIEW(self->webview), url);
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "setBounds") == 0) {
    const int x = static_cast<int>(fl_value_get_int(fl_value_lookup_string(args, "x")));
    const int y = static_cast<int>(fl_value_get_int(fl_value_lookup_string(args, "y")));
    const int w = static_cast<int>(fl_value_get_int(fl_value_lookup_string(args, "w")));
    const int h = static_cast<int>(fl_value_get_int(fl_value_lookup_string(args, "h")));
    const gboolean visible =
        fl_value_get_bool(fl_value_lookup_string(args, "visible"));
    set_bounds(self, x, y, w, h, visible);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "eval") == 0) {
    const gchar* js = fl_value_get_string(fl_value_lookup_string(args, "js"));
    if (self->webview != nullptr && js != nullptr) {
      webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(self->webview), js, -1,
                                          nullptr, nullptr, nullptr, nullptr,
                                          nullptr);
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "setOnReadyScript") == 0) {
    const gchar* js = fl_value_get_string(fl_value_lookup_string(args, "js"));
    g_free(self->on_ready_script);
    self->on_ready_script = js != nullptr ? g_strdup(js) : nullptr;
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "hide") == 0) {
    if (self->webview != nullptr) {
      gtk_widget_hide(self->webview);
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "disposeView") == 0) {
    if (self->webview != nullptr) {
      gtk_widget_destroy(self->webview);
      self->webview = nullptr;
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  fl_method_call_respond_not_implemented(method_call, nullptr);
}

static void linux_embedded_webview_plugin_dispose(GObject* object) {
  auto* self = LINUX_EMBEDDED_WEBVIEW_PLUGIN(object);
  if (self->webview != nullptr) {
    gtk_widget_destroy(self->webview);
    self->webview = nullptr;
  }
  g_clear_pointer(&self->on_ready_script, g_free);
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(linux_embedded_webview_plugin_parent_class)->dispose(object);
}

static void linux_embedded_webview_plugin_class_init(
    LinuxEmbeddedWebviewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = linux_embedded_webview_plugin_dispose;
}

static void linux_embedded_webview_plugin_init(LinuxEmbeddedWebviewPlugin* self) {
  self->overlay = nullptr;
  self->webview = nullptr;
  self->on_ready_script = nullptr;
}

static void method_call_cb(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                           gpointer user_data) {
  linux_embedded_webview_plugin_handle_method_call(
      LINUX_EMBEDDED_WEBVIEW_PLUGIN(user_data), method_call);
}

void linux_embedded_webview_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  LinuxEmbeddedWebviewPlugin* plugin = LINUX_EMBEDDED_WEBVIEW_PLUGIN(
      g_object_new(linux_embedded_webview_plugin_get_type(), nullptr));
  plugin->registrar = registrar;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "linux_embedded_webview",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
