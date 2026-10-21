FROM espressif/idf:v5.4.4
# Firmware build only. The Zig fork is fetched with a pinned SHA256 by CMake.
RUN echo '. "$IDF_PATH/export.sh" > /dev/null 2>&1 || true' >> /etc/bash.bashrc \
    && echo '. "$IDF_PATH/export.sh" > /dev/null 2>&1 || true' > /etc/profile.d/esp-idf.sh
