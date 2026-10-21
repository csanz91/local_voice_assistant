#!/bin/sh
set -eu
sdk=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
nanopb="$sdk/../../managed_components/livekit__nanopb/src"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
${CC:-cc} -std=c11 -D_DARWIN_C_SOURCE -DPB_ENABLE_MALLOC=1 -DCONFIG_LK_MAX_DATA_STREAM_WRITERS=2 -DCONFIG_LK_MAX_DATA_STREAM_READERS=2 \
  -fsanitize=address,undefined -g -I"$sdk/test_app/host/stubs" -I"$sdk/include" -I"$sdk/core" -I"$sdk/protocol" -I"$nanopb/../include" \
  "$sdk/test_app/host/compatibility.c" "$sdk/core/data_stream_writer.c" "$sdk/core/data_stream_reader.c" \
  "$sdk/protocol/protocol_attributes.c" "$sdk/protocol/livekit_models.pb.c" "$sdk/protocol/livekit_rtc.pb.c" \
  "$sdk/protocol/livekit_metrics.pb.c" "$sdk/protocol/timestamp.pb.c" \
  "$nanopb/pb_common.c" "$nanopb/pb_encode.c" "$nanopb/pb_decode.c" -o "$tmp/compatibility"
"$tmp/compatibility"
