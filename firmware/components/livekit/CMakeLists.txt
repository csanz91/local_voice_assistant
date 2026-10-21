idf_component_register(
    # Explicit sources ensure newly added compatibility code rebuilds existing trees.
    SRCS
        ./core/data_stream_reader.c
        ./core/data_stream_writer.c
        ./core/engine.c
        ./core/livekit.c
        ./core/peer.c
        ./core/protocol.c
        ./core/rpc_manager.c
        ./core/signaling.c
        ./core/system.c
        ./core/url.c
        ./core/utils.c
        ./protocol/livekit_metrics.pb.c
        ./protocol/livekit_models.pb.c
        ./protocol/livekit_rtc.pb.c
        ./protocol/protocol_attributes.c
        ./protocol/timestamp.pb.c
    PRIV_INCLUDE_DIRS ./core ./protocol
    INCLUDE_DIRS ./include
    REQUIRES
        av_render
        esp_capture
        media_lib_sal
    PRIV_REQUIRES
        esp_netif
        esp_peer
        esp_websocket_client
        json
        khash
        mbedtls
        nanopb
)

idf_component_get_property(LIVEKIT_SDK_VERSION ${COMPONENT_NAME} COMPONENT_VERSION)
target_compile_definitions(${COMPONENT_LIB} PUBLIC "LIVEKIT_SDK_VERSION=\"${LIVEKIT_SDK_VERSION}\"")

target_compile_options(${COMPONENT_LIB} PRIVATE "-Wconversion")