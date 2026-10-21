// USB provisioning validation kept independent of IDF/NVS for host regression tests.
#include <stdio.h>
#include <string.h>
#include "session_http.h"
#include "session_policy.h"
#include "profiles.h"
#include "provisioning_config.h"

// Parse and validate local USB provisioning. Never restarts on its own.
bool sebastian_provisioning_apply(const char *json, char *err, size_t err_size) {
    cJSON *root = cJSON_Parse(json);
    if (!root) { snprintf(err, err_size, "json_parse"); return false; }
    cJSON *schema = cJSON_GetObjectItem(root, "schema");
    if (!cJSON_IsString(schema) || strcmp(schema->valuestring, SEBASTIAN_PROVISIONING_SCHEMA) != 0) {
        cJSON_Delete(root);
        snprintf(err, err_size, "schema");
        return false;
    }
    const cJSON *lk = cJSON_GetObjectItem(root, "livekit");
    const cJSON *url = cJSON_GetObjectItem(lk, "tokenServerUrl");
    const cJSON *allow = cJSON_GetObjectItem(lk, "allowInsecureHttp");
    const bool insecure = cJSON_IsBool(allow) ? cJSON_IsTrue(allow) : sebastian_cfg_get_bool("insecure_http", false);
    const cJSON *dev = cJSON_GetObjectItem(root, "device");
    const cJSON *secret = cJSON_GetObjectItem(dev, "secret");
    if (!secret) secret = cJSON_GetObjectItem(cJSON_GetObjectItem(root, "adoption"), "deviceSecret");
    bool valid = (!url || (cJSON_IsString(url) && (!url->valuestring[0] || session_url_valid(url->valuestring, false, insecure)))) &&
        (!allow || cJSON_IsBool(allow)) &&
        (!secret || (cJSON_IsString(secret) && (!secret->valuestring[0] || session_secret_valid(secret->valuestring))));
    if (!valid) { cJSON_Delete(root); snprintf(err, err_size, "session_config"); return false; }
    const cJSON *profiles = cJSON_GetObjectItem(root, "profiles");
    if (profiles) {
        char *compact = cJSON_IsArray(profiles) ? cJSON_PrintUnformatted(profiles) : NULL;
        const bool fits = compact && strlen(compact) < SEBASTIAN_PROFILES_JSON_CAPACITY;
        cJSON_free(compact);
        if (!fits) { cJSON_Delete(root); snprintf(err, err_size, "profiles_size"); return false; }
    }
    bool ok = sebastian_provisioning_store_config(root);
    cJSON_Delete(root);
    if (!ok) snprintf(err, err_size, "wifi");
    return ok;
}
