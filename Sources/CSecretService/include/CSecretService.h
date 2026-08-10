#ifndef OPENUSAGE_SECRET_SERVICE_H
#define OPENUSAGE_SECRET_SERVICE_H

#include <gio/gio.h>

typedef struct {
    guint8 *bytes;
    gsize length;
    gchar *error;
} OpenUsageSecretResult;

static inline gchar *openusage_sha256_hex(const guint8 *bytes, gsize length) {
    return g_compute_checksum_for_data(G_CHECKSUM_SHA256, bytes, length);
}

static inline void openusage_secret_result_clear(OpenUsageSecretResult *result) {
    if (result == NULL) {
        return;
    }
    if (result->bytes != NULL) {
        g_clear_pointer(&result->bytes, g_free);
    }
    if (result->error != NULL) {
        g_clear_pointer(&result->error, g_free);
    }
    result->length = 0;
}

static inline gboolean openusage_secret_fail(
    OpenUsageSecretResult *result,
    GError *error,
    const gchar *fallback
) {
    if (result != NULL) {
        result->error = g_strdup(error != NULL ? error->message : fallback);
    }
    g_clear_error(&error);
    return FALSE;
}

static inline GVariant *openusage_secret_call(
    GDBusConnection *connection,
    const gchar *path,
    const gchar *interface_name,
    const gchar *method,
    GVariant *parameters,
    const GVariantType *reply_type,
    GError **error
) {
    return g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.secrets",
        path,
        interface_name,
        method,
        parameters,
        reply_type,
        G_DBUS_CALL_FLAGS_NONE,
        5000,
        NULL,
        error
    );
}

static inline gboolean openusage_secret_service_lookup(
    const gchar *identity_key,
    OpenUsageSecretResult *result
) {
    GError *error = NULL;
    GDBusConnection *connection = NULL;
    GVariant *search_reply = NULL;
    GVariant *unlocked = NULL;
    GVariant *locked = NULL;
    GVariant *session_reply = NULL;
    GVariant *session_output = NULL;
    GVariant *secrets_reply = NULL;
    GVariant *secrets = NULL;
    gchar *session_path = NULL;
    const gchar **item_paths = NULL;
    gsize item_count = 0;
    gboolean success = FALSE;

    if (result == NULL || identity_key == NULL) {
        return FALSE;
    }
    result->bytes = NULL;
    result->length = 0;
    result->error = NULL;

    connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (connection == NULL) {
        return openusage_secret_fail(result, error, "Session bus unavailable");
    }

    GVariantBuilder attributes;
    g_variant_builder_init(&attributes, G_VARIANT_TYPE("a{ss}"));
    g_variant_builder_add(&attributes, "{ss}", "service", "gemini");
    g_variant_builder_add(&attributes, "{ss}", identity_key, "antigravity");
    search_reply = openusage_secret_call(
        connection,
        "/org/freedesktop/secrets",
        "org.freedesktop.Secret.Service",
        "SearchItems",
        g_variant_new("(a{ss})", &attributes),
        G_VARIANT_TYPE("(aoao)"),
        &error
    );
    if (search_reply == NULL) {
        openusage_secret_fail(result, error, "Secret search failed");
        goto cleanup;
    }
    g_variant_get(search_reply, "(@ao@ao)", &unlocked, &locked);
    item_paths = g_variant_get_objv(unlocked, &item_count);
    if (item_count == 0) {
        success = TRUE;
        goto cleanup;
    }

    session_reply = openusage_secret_call(
        connection,
        "/org/freedesktop/secrets",
        "org.freedesktop.Secret.Service",
        "OpenSession",
        g_variant_new("(sv)", "plain", g_variant_new_string("")),
        G_VARIANT_TYPE("(vo)"),
        &error
    );
    if (session_reply == NULL) {
        openusage_secret_fail(result, error, "Secret session failed");
        goto cleanup;
    }
    const gchar *borrowed_session_path = NULL;
    g_variant_get(session_reply, "(@v&o)", &session_output, &borrowed_session_path);
    session_path = g_strdup(borrowed_session_path);

    secrets_reply = openusage_secret_call(
        connection,
        "/org/freedesktop/secrets",
        "org.freedesktop.Secret.Service",
        "GetSecrets",
        g_variant_new(
            "(@aoo)",
            g_variant_new_objv(item_paths, item_count),
            session_path
        ),
        G_VARIANT_TYPE("(a{o(oayays)})"),
        &error
    );
    if (secrets_reply == NULL) {
        openusage_secret_fail(result, error, "Secret retrieval failed");
        goto cleanup;
    }

    g_variant_get(secrets_reply, "(@a{o(oayays)})", &secrets);
    GVariantIter iterator;
    const gchar *item_path = NULL;
    GVariant *secret = NULL;
    g_variant_iter_init(&iterator, secrets);
    if (g_variant_iter_next(&iterator, "{&o@(oayays)}", &item_path, &secret)) {
        const gchar *returned_session = NULL;
        const gchar *content_type = NULL;
        GVariant *parameters = NULL;
        GVariant *value = NULL;
        g_variant_get(
            secret,
            "(&o@ay@ay&s)",
            &returned_session,
            &parameters,
            &value,
            &content_type
        );
        const guint8 *bytes = g_variant_get_fixed_array(
            value,
            &result->length,
            sizeof(guint8)
        );
        result->bytes = g_memdup2(bytes, result->length);
        g_variant_unref(parameters);
        g_variant_unref(value);
        g_variant_unref(secret);
    }
    success = TRUE;

cleanup:
    if (connection != NULL && session_path != NULL) {
        GVariant *close_reply = openusage_secret_call(
            connection,
            session_path,
            "org.freedesktop.Secret.Session",
            "Close",
            NULL,
            G_VARIANT_TYPE("()"),
            NULL
        );
        if (close_reply != NULL) {
            g_variant_unref(close_reply);
        }
    }
    g_free(item_paths);
    g_free(session_path);
    g_clear_pointer(&secrets, g_variant_unref);
    g_clear_pointer(&secrets_reply, g_variant_unref);
    g_clear_pointer(&session_output, g_variant_unref);
    g_clear_pointer(&session_reply, g_variant_unref);
    g_clear_pointer(&locked, g_variant_unref);
    g_clear_pointer(&unlocked, g_variant_unref);
    g_clear_pointer(&search_reply, g_variant_unref);
    g_clear_object(&connection);
    g_clear_error(&error);
    return success;
}

#endif
