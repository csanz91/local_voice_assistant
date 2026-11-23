// Runs the production C shim against a deterministic IDF HTTP transport.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "session_http.h"
#include "session_policy.h"

static const char *endpoint = "https://example.test/api/v2/device-voice-session?test=1";
static const char *response;
static size_t response_len;
static int status, open_error, write_result, read_error;
static bool complete, insecure, initialized, closed, cleaned, content_type_set, body_written;
struct mock_client { size_t pos; };
static struct mock_client mock;

bool sebastian_cfg_get_bool(const char *key, bool fallback) { (void)fallback; assert(!strcmp(key,"insecure_http")); return insecure; }
int esp_crt_bundle_attach(void *p) { (void)p; return 0; }
esp_http_client_handle_t esp_http_client_init(const esp_http_client_config_t *cfg) {
    assert(!strcmp(cfg->url, endpoint)); // full path AND query survive untouched
    assert(cfg->method == HTTP_METHOD_POST && cfg->timeout_ms == 5000);
    assert(cfg->crt_bundle_attach == esp_crt_bundle_attach && cfg->disable_auto_redirect);
    assert(cfg->buffer_size_tx >= 1051);
    initialized = true; return &mock;
}
int esp_http_client_set_header(esp_http_client_handle_t c, const char *name, const char *value) {
    (void)c;
    if (!strcmp(name,"Authorization")) assert(!strcmp(value,"Bearer test-device-secret"));
    else { assert(!strcmp(name,"Content-Type")); assert(!strcmp(value,"application/json")); content_type_set=true; }
    return 0;
}
int esp_http_client_open(esp_http_client_handle_t c, int len) { (void)c; assert(len==2 && content_type_set); return open_error; }
int esp_http_client_write(esp_http_client_handle_t c, const char *body, int len) {
    (void)c; assert(len==2 && !memcmp(body,"{}",2)); body_written=write_result==len; return write_result;
}
long long esp_http_client_fetch_headers(esp_http_client_handle_t c) { (void)c; assert(body_written); return (long long)response_len; }
int esp_http_client_get_status_code(esp_http_client_handle_t c) { (void)c; return status; }
int esp_http_client_read(esp_http_client_handle_t c, char *out, int len) {
    if (read_error) return -1;
    size_t n = response_len - c->pos;
    if (n > (size_t)len) n = (size_t)len;
    if (n > 11) n = 11; // fragmented body/chunk boundary independent
    memcpy(out, response+c->pos,n); c->pos+=n; return (int)n;
}
bool esp_http_client_is_complete_data_received(esp_http_client_handle_t c) { return complete && c->pos==response_len; }
int esp_http_client_close(esp_http_client_handle_t c) { (void)c; closed=true; return 0; }
int esp_http_client_cleanup(esp_http_client_handle_t c) { (void)c; cleaned=true; return 0; }

static void reset(const char *body) {
    mock.pos=0; response=body; response_len=strlen(body); status=200;
    open_error=read_error=0; write_result=2; complete=true; insecure=false;
    initialized=closed=cleaned=content_type_set=body_written=false;
    endpoint="https://example.test/api/v2/device-voice-session?test=1";
}
static int run(void) {
    char url[256]="stale", token[1280]="stale", room[128]="stale";
    int rc=sebastian_session_create(endpoint,"aabbcc001122","test-device-secret",url,sizeof(url),token,sizeof(token),room,sizeof(room));
    if (initialized) assert(closed && cleaned);
    if (rc) assert(!url[0] && !token[0] && !room[0]);
    else assert(url[0] && token[0] && room[0]);
    return rc;
}
int main(void) {
    const char *ok="{\"roomName\":\"room-test\",\"serverUrl\":\"wss://livekit.example.test\",\"participantToken\":\"test.jwt.token\"}";
    reset(ok); assert(run()==0);
    int codes[]={301,302,307,308,401,403,409,429,503};
    for (size_t i=0;i<sizeof(codes)/sizeof(*codes);i++) { reset(ok); status=codes[i]; assert(run()==codes[i]); }
    reset(ok); open_error=-1; assert(run()==-2); // includes TLS trust failures: no fallback/retry
    reset(ok); write_result=1; assert(run()==-2); // partial JSON request must not reach response parsing
    reset(ok); read_error=1; assert(run()==-4);
    reset(ok); complete=false; assert(run()==-4);
    reset(""); assert(run()==-4);
    const char *bad[]={"{}", "[]", "not-json", "{\"roomName\":\"room-test\",\"serverUrl\":\"\",\"participantToken\":\"x\"}",
        "{\"roomName\":\"room-test\",\"serverUrl\":\"wss://host\",\"participantToken\":\"\"}", "{\"roomName\":\"room-test\",\"serverUrl\":\"https://host\",\"participantToken\":\"x\"}",
        "{\"roomName\":\"room-test\",\"serverUrl\":\"wss://user:pass@host\",\"participantToken\":\"x\"}", "{\"roomName\":\"room-test\",\"serverUrl\":\"wss://host\",\"participantToken\":\"a b\"}",
        "{\"roomName\":\"room-test\",\"serverUrl\":\"wss://host\",\"participantToken\":5}", "{\"roomName\":\"room-test\",\"serverUrl\":\"wss://host\",\"participantToken\":\"x\"} garbage"};
    for(size_t i=0;i<sizeof(bad)/sizeof(*bad);i++) { reset(bad[i]); assert(run()==-5); }
    reset("{\"roomName\":\"room-test\",\"serverUrl\":\"ws://host:7880\",\"participantToken\":\"x\"}"); assert(run()==-5);
    reset("{\"roomName\":\"room-test\",\"serverUrl\":\"ws://host:7880\",\"participantToken\":\"x\"}"); insecure=true; assert(run()==0);
    reset(ok); endpoint="http://127.0.0.1:8787/api/v2/device-voice-session"; assert(run()==-6 && !initialized);
    reset(ok); insecure=true; endpoint="http://127.0.0.1:8787/api/v2/device-voice-session"; assert(run()==0);
    const char *bad_urls[]={"https:///path","https://user@host/path","https://host/#fragment","https://host/a b","ftp://host/path","https://host\\path","https://?path"};
    for(size_t i=0;i<sizeof(bad_urls)/sizeof(*bad_urls);i++) { reset(ok); endpoint=bad_urls[i]; assert(run()==-6 && !initialized); }
    char oversized[1600]; memset(oversized,' ',sizeof(oversized)); memcpy(oversized,ok,strlen(ok)); oversized[1599]=0;
    reset(oversized); assert(run()==-4); // valid JSON prefix must never hide truncation
    char token_big[1500]; snprintf(token_big,sizeof(token_big),"{\"roomName\":\"room-test\",\"serverUrl\":\"wss://host\",\"participantToken\":\"%01300d\"}",0);
    reset(token_big); assert(run()==-5);
    char exact[1536]; memset(exact,' ',sizeof(exact)); memcpy(exact,ok,strlen(ok)); exact[1535]=0;
    reset(exact); assert(run()==0); // maximum complete body is accepted
    reset("{\"roomName\":\"room-test\",\"serverUrl\":\"wss://host\",\"participantToken\":\"x\\u0000hidden\"}"); assert(run()==-5);
    reset(ok); response_len=10; assert(run()==-5);
    assert(!session_secret_valid("header\r\ninjection"));
    const char *accepted="{\"version\":2,\"request_id\":\"1-2\",\"status\":\"accepted\",\"reason\":\"interrupted\"}";
    assert(sebastian_wake_result((const unsigned char *)accepted,strlen(accepted),"1-2")==1);
    assert(sebastian_wake_result((const unsigned char *)accepted,strlen(accepted),"2-2")==0);
    const char *rejected="{\"version\":2,\"request_id\":\"1-2\",\"status\":\"rejected\",\"reason\":\"policy\"}";
    assert(sebastian_wake_result((const unsigned char *)rejected,strlen(rejected),"1-2")==-1);
    const char *failures[] = {"invalid", "not_ready", "timeout"};
    for (size_t i = 0; i < 3; i++) {
        char outcome[128];
        snprintf(outcome, sizeof(outcome), "{\"version\":2,\"request_id\":\"1-2\",\"status\":\"rejected\",\"reason\":\"%s\"}", failures[i]);
        assert(sebastian_wake_result((const unsigned char *)outcome, strlen(outcome), "1-2") == -2);
    }
    const char *invalid="{\"version\":2,\"request_id\":\"1-2\",\"status\":\"accepted\",\"reason\":\"policy\"}";
    assert(sebastian_wake_result((const unsigned char *)invalid,strlen(invalid),"1-2")==0);
    assert(sebastian_wake_result((const unsigned char *)accepted,strlen(accepted)-1,"1-2")==0);
    puts("session_http: full endpoint, auth, TLS/redirect policy, dev opt-in, status, bounds and malformed/truncated response tests passed");
}
