#pragma once
#include <stdbool.h>
#include <stddef.h>
#define ESP_OK 0
#define HTTP_METHOD_POST 1
typedef struct mock_client *esp_http_client_handle_t;
typedef struct { const char *url; int method; int timeout_ms; int buffer_size_tx; int (*crt_bundle_attach)(void *); bool disable_auto_redirect; } esp_http_client_config_t;
esp_http_client_handle_t esp_http_client_init(const esp_http_client_config_t *);
int esp_http_client_set_header(esp_http_client_handle_t, const char *, const char *);
int esp_http_client_open(esp_http_client_handle_t, int);
int esp_http_client_write(esp_http_client_handle_t, const char *, int);
long long esp_http_client_fetch_headers(esp_http_client_handle_t);
int esp_http_client_get_status_code(esp_http_client_handle_t);
int esp_http_client_read(esp_http_client_handle_t, char *, int);
bool esp_http_client_is_complete_data_received(esp_http_client_handle_t);
int esp_http_client_close(esp_http_client_handle_t);
int esp_http_client_cleanup(esp_http_client_handle_t);
