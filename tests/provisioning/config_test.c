// Exercise the actual direct-USB provisioning entry point with an NVS-write spy.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "profiles.h"
#include "session_http.h"
#include "provisioning_config.h"

static unsigned writes;
bool sebastian_cfg_get_bool(const char *key, bool fallback) { (void)key; return fallback; }
bool sebastian_provisioning_store_config(cJSON *root) {
    writes++;
    const cJSON *profiles = cJSON_GetObjectItem(root, "profiles");
    if (profiles) {
        char *s = cJSON_PrintUnformatted(profiles);
        assert(s && strlen(s) < SEBASTIAN_PROFILES_JSON_CAPACITY);
        cJSON_free(s);
    }
    return true;
}
static void apply_profiles(size_t compact_bytes, bool accepted) {
    // The small name remains valid; an ignored annotation creates exact bounds.
    const char *prefix="[{\"name\":\"desk\",\"annotation\":\"";
    const char *suffix="\"}]";
    assert(compact_bytes > strlen(prefix)+strlen(suffix));
    char profiles[2048];
    strcpy(profiles,prefix);
    size_t count=compact_bytes-strlen(prefix)-strlen(suffix);
    memset(profiles+strlen(prefix),'x',count);
    strcpy(profiles+strlen(prefix)+count,suffix);
    char payload[4096];
    snprintf(payload,sizeof(payload),"{\"schema\":\"sebastian.config.v1\",\"wifi\":{\"ssid\":\"must-not-change-if-rejected\"},\"profiles\":%s}",profiles);
    char err[32]="";
    unsigned before=writes;
    assert(sebastian_provisioning_apply(payload,err,sizeof(err))==accepted);
    assert(writes==before+(accepted?1:0));
    if(!accepted) assert(!strcmp(err,"profiles_size"));
}
int main(void) {
    apply_profiles(SEBASTIAN_PROFILES_JSON_CAPACITY-1,true);
    apply_profiles(SEBASTIAN_PROFILES_JSON_CAPACITY,false);
    apply_profiles(SEBASTIAN_PROFILES_JSON_CAPACITY+1,false);
    char err[32];
    unsigned before=writes;
    assert(!sebastian_provisioning_apply("{\"schema\":\"sebastian.config.v1\",\"profiles\":{}}",err,sizeof(err)));
    assert(writes==before);
    assert(sebastian_provisioning_apply("{\"schema\":\"sebastian.config.v1\",\"profiles\":[]}",err,sizeof(err)));
    assert(sebastian_provisioning_apply("{\"schema\":\"sebastian.config.v1\",\"activeProfile\":\"desk\"}",err,sizeof(err)));
    // Escaped Unicode is decoded to UTF-8 before the storage size is checked.
    char payload[4096]="{\"schema\":\"sebastian.config.v1\",\"profiles\":[{\"name\":\"desk\",\"annotation\":\"";
    for(int i=0;i<510;i++) strcat(payload,"\\u00e9");
    strcat(payload,"\"}]}");
    before=writes;
    assert(!sebastian_provisioning_apply(payload,err,sizeof(err)) && writes==before);
    char jwt_config[1200];
    char jwt[1026]; memset(jwt,'a',1025); jwt[1025]=0;
    snprintf(jwt_config,sizeof(jwt_config),"{\"schema\":\"sebastian.config.v1\",\"device\":{\"secret\":\"%s\"}}",jwt);
    before=writes;
    assert(!sebastian_provisioning_apply(jwt_config,err,sizeof(err)) && writes==before);
    jwt[1024]=0;
    snprintf(jwt_config,sizeof(jwt_config),"{\"schema\":\"sebastian.config.v1\",\"device\":{\"secret\":\"%s\"}}",jwt);
    assert(sebastian_provisioning_apply(jwt_config,err,sizeof(err)) && writes==before+1);
    puts("provisioning: direct USB rejects oversized/non-array profiles before any NVS write;1023-byte boundary and omitted/empty profiles accepted");
}
