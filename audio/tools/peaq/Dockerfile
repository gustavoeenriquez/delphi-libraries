# Herramientas de evaluación de codecs: ffmpeg, LAME, numpy y GstPEAQ (PEAQ básico/avanzado).
# docker build -t audio-eval audio/tools/peaq
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg lame sox python3 python3-numpy ca-certificates git \
      build-essential meson ninja-build pkg-config autoconf automake libtool gtk-doc-tools \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base gstreamer1.0-tools \
    && git clone --depth 1 https://github.com/HSU-ANT/gstpeaq /src/gstpeaq \
    && cd /src/gstpeaq \
    && if [ -f meson.build ]; then meson setup build --prefix=/usr && ninja -C build install; \
       else ./autogen.sh --prefix=/usr && make -j1 && make install; fi \
    && apt-get purge -y build-essential meson ninja-build autoconf automake libtool gtk-doc-tools git \
    && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* /src
# wavparse (plugins-good); GstPEAQ se instala en /usr/lib/gstreamer-1.0, fuera de la ruta multiarch
RUN apt-get update && apt-get install -y --no-install-recommends gstreamer1.0-plugins-good \
    && rm -rf /var/lib/apt/lists/*
ENV GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0
WORKDIR /work
