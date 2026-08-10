#ifndef OPENUSAGE_CDESKTOPPORTAL_H
#define OPENUSAGE_CDESKTOPPORTAL_H

#include <gio/gio.h>
#include <glib.h>
#include <unistd.h>

typedef struct {
    gboolean success;
    gboolean autostart;
    gchar *error_message;
} OpenUsagePortalResult;

typedef struct {
    GMainLoop *loop;
    gboolean received;
    guint32 response;
    gboolean autostart;
} OpenUsagePortalContext;

static inline void openusage_portal_result_clear(OpenUsagePortalResult *result) {
    if (result == NULL) {
        return;
    }
    g_free(result->error_message);
    result->error_message = NULL;
    result->success = FALSE;
    result->autostart = FALSE;
}

static inline void openusage_portal_response(
    GDBusConnection *connection,
    const gchar *sender_name,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *signal_name,
    GVariant *parameters,
    gpointer user_data
) {
    (void)connection;
    (void)sender_name;
    (void)object_path;
    (void)interface_name;
    (void)signal_name;
    OpenUsagePortalContext *context = user_data;
    GVariant *results = NULL;
    g_variant_get(parameters, "(u@a{sv})", &context->response, &results);
    context->received = TRUE;
    context->autostart = FALSE;
    g_variant_lookup(results, "autostart", "b", &context->autostart);
    g_variant_unref(results);
    g_main_loop_quit(context->loop);
}

static inline gboolean openusage_portal_timeout(gpointer user_data) {
    OpenUsagePortalContext *context = user_data;
    g_main_loop_quit(context->loop);
    return G_SOURCE_REMOVE;
}

static inline gchar *openusage_portal_sender_path(GDBusConnection *connection) {
    const gchar *unique_name = g_dbus_connection_get_unique_name(connection);
    if (unique_name == NULL) {
        return NULL;
    }
    gchar *sender = g_strdup(unique_name[0] == ':' ? unique_name + 1 : unique_name);
    for (gchar *cursor = sender; *cursor != '\0'; cursor++) {
        if (*cursor == '.') {
            *cursor = '_';
        }
    }
    return sender;
}

static inline gboolean openusage_portal_set_autostart(
    gboolean enabled,
    guint timeout_milliseconds,
    OpenUsagePortalResult *result
) {
    if (result == NULL) {
        return FALSE;
    }
    openusage_portal_result_clear(result);

    GError *error = NULL;
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (connection == NULL) {
        result->error_message = g_strdup(error != NULL ? error->message : "Portal session bus unavailable");
        g_clear_error(&error);
        return FALSE;
    }

    gchar *sender = openusage_portal_sender_path(connection);
    gchar *token = g_strdup_printf("openusage_%u_%08x", (guint)getpid(), g_random_int());
    gchar *request_path = sender == NULL ? NULL : g_strdup_printf(
        "/org/freedesktop/portal/desktop/request/%s/%s",
        sender,
        token
    );
    GMainContext *main_context = g_main_context_new();
    GMainLoop *main_loop = g_main_loop_new(main_context, FALSE);
    OpenUsagePortalContext context = {
        .loop = main_loop,
        .received = FALSE,
        .response = 2,
        .autostart = FALSE
    };
    guint subscription = 0;
    GSource *timeout_source = NULL;
    GVariant *reply = NULL;
    gboolean success = FALSE;

    if (request_path == NULL) {
        result->error_message = g_strdup("Portal request path unavailable");
        goto cleanup;
    }

    g_main_context_push_thread_default(main_context);
    subscription = g_dbus_connection_signal_subscribe(
        connection,
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        request_path,
        NULL,
        G_DBUS_SIGNAL_FLAGS_NONE,
        openusage_portal_response,
        &context,
        NULL
    );

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    g_variant_builder_add(
        &options,
        "{sv}",
        "reason",
        g_variant_new_string("Track AI subscription usage at login")
    );
    g_variant_builder_add(&options, "{sv}", "autostart", g_variant_new_boolean(enabled));
    reply = g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Background",
        "RequestBackground",
        g_variant_new("(s@a{sv})", "", g_variant_builder_end(&options)),
        G_VARIANT_TYPE("(o)"),
        G_DBUS_CALL_FLAGS_NONE,
        (gint)timeout_milliseconds,
        NULL,
        &error
    );
    if (reply == NULL) {
        result->error_message = g_strdup(error != NULL ? error->message : "Portal request failed");
        goto cleanup_context;
    }
    const gchar *returned_request_path = NULL;
    g_variant_get(reply, "(&o)", &returned_request_path);
    if (g_strcmp0(returned_request_path, request_path) != 0) {
        g_dbus_connection_signal_unsubscribe(connection, subscription);
        subscription = g_dbus_connection_signal_subscribe(
            connection,
            "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.Request",
            "Response",
            returned_request_path,
            NULL,
            G_DBUS_SIGNAL_FLAGS_NONE,
            openusage_portal_response,
            &context,
            NULL
        );
    }

    timeout_source = g_timeout_source_new(timeout_milliseconds);
    g_source_set_callback(timeout_source, openusage_portal_timeout, &context, NULL);
    g_source_attach(timeout_source, main_context);
    g_main_loop_run(main_loop);

    if (!context.received) {
        result->error_message = g_strdup("Portal response timed out");
        goto cleanup_context;
    }
    if (context.response != 0) {
        result->error_message = g_strdup(
            context.response == 1 ? "Portal request was cancelled" : "Portal request was denied"
        );
        goto cleanup_context;
    }
    if (context.autostart != enabled) {
        result->error_message = g_strdup("Portal did not apply the requested autostart state");
        goto cleanup_context;
    }
    result->success = TRUE;
    result->autostart = context.autostart;
    success = TRUE;

cleanup_context:
    if (subscription != 0) {
        g_dbus_connection_signal_unsubscribe(connection, subscription);
    }
    g_main_context_pop_thread_default(main_context);

cleanup:
    if (timeout_source != NULL) {
        g_source_destroy(timeout_source);
        g_source_unref(timeout_source);
    }
    g_clear_pointer(&reply, g_variant_unref);
    g_main_loop_unref(main_loop);
    g_main_context_unref(main_context);
    g_free(request_path);
    g_free(token);
    g_free(sender);
    g_clear_object(&connection);
    g_clear_error(&error);
    return success;
}

#endif
