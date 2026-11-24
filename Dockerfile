# cups-label-crop: CUPS + AirPrint + a crop queue that turns A4/Letter
# shipping sheets (Vinted, InPost, Evri, ...) into 4x6 labels.
# SPDX-License-Identifier: GPL-3.0-or-later
FROM debian:trixie-slim

# Set to true to bundle Debian's printer-driver-all (~300 extra packages).
ARG INSTALL_ALL_DRIVERS=false
ARG VERSION=dev

LABEL org.opencontainers.image.title="cups-label-crop" \
      org.opencontainers.image.description="CUPS print server with AirPrint and a crop queue that turns A4/Letter shipping label sheets into 4x6 labels" \
      org.opencontainers.image.source="https://github.com/Dyingmisery/cups-label-crop" \
      org.opencontainers.image.url="https://github.com/Dyingmisery/cups-label-crop" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    CUPSADMIN=admin \
    CUPSPASSWORD=admin \
    TARGET_PRINTER=Label_Printer \
    CROP_QUEUE_NAME=Label_Crop \
    CROP_QUEUE_DISPLAY_NAME="Label Crop" \
    LABEL_WIDTH_IN=4 \
    LABEL_HEIGHT_IN=6 \
    PADDING_PT=3 \
    ROTATE_MODE=auto \
    DEFAULT_SHEET=A4 \
    ENABLE_AVAHI=true \
    TZ=Etc/UTC

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        cups cups-client cups-filters cups-ipp-utils \
        avahi-daemon avahi-utils libnss-mdns dbus \
        ghostscript poppler-utils qpdf \
        python3 python3-pikepdf \
        printer-driver-ptouch printer-driver-dymo \
        libcupsimage2t64 \
        tini tzdata ca-certificates; \
    if [ "$INSTALL_ALL_DRIVERS" = "true" ]; then \
        apt-get install -y --no-install-recommends printer-driver-all; \
    fi; \
    rm -rf /var/lib/apt/lists/*; \
    # Advertise image/urf so iOS lists the queues as AirPrint printers, if the
    # distro packages do not already ship URF support.
    if ! grep -rqs '^image/urf' /usr/share/cups/mime/; then \
        echo 'image/urf urf string(0,UNIRAST<00>)' > /usr/share/cups/mime/cups-label-crop-urf.types; \
        echo 'image/urf application/pdf 100 -' > /usr/share/cups/mime/cups-label-crop-urf.convs; \
    fi; \
    # Avahi in a container: no chroot, no rlimits
    sed -i -e 's/^#\?enable-dbus=.*/enable-dbus=yes/' \
           -e 's/^rlimit-/#rlimit-/' /etc/avahi/avahi-daemon.conf; \
    mkdir -p /usr/share/cups-label-crop /etc/cups-label-crop /config; \
    cp -a /etc/cups /usr/share/cups-label-crop/etc-cups.default

COPY src/label-crop /usr/lib/cups/filter/label-crop
COPY src/labelcrop /usr/lib/cups/backend/labelcrop
COPY src/label-crop.ppd /usr/share/cups-label-crop/label-crop.ppd
COPY rootfs/ /
COPY tests/fixtures/*.pdf /usr/share/cups-label-crop/test/

RUN set -eux; \
    chown root:root /usr/lib/cups/filter/label-crop /usr/lib/cups/backend/labelcrop; \
    chmod 0755 /usr/lib/cups/filter/label-crop /usr/lib/cups/backend/labelcrop /usr/local/bin/entrypoint.sh; \
    ln -sf /usr/lib/cups/filter/label-crop /usr/local/bin/label-crop; \
    python3 -c "import pikepdf; print('pikepdf', pikepdf.__version__)"; \
    cupsd -t -c /usr/share/cups-label-crop/cupsd.conf

VOLUME ["/config"]
EXPOSE 631/tcp 5353/udp

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD lpstat -r >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
