#pragma once
#include <stdbool.h>
#include "cJSON.h"
#define SEBASTIAN_PROVISIONING_SCHEMA "sebastian.config.v1"
// NVS implementation in provisioning.c; called only after complete validation.
bool sebastian_provisioning_store_config(cJSON *root);
