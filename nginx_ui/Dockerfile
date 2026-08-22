FROM uozi/nginx-ui:2.5.10
LABEL io.hass.type="addon"

# The base image is Debian (it is built on nginx:latest), so this is apt, not
# apk. jq reads /data/options.json; keepalived is the optional virtual IP and
# does nothing at all unless `ha.enabled` is set.
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq keepalived \
    && rm -rf /var/lib/apt/lists/*

COPY rootfs /

RUN chmod a+x /etc/s6-overlay/s6-rc.d/init-addon/init-addon.sh \
              /etc/s6-overlay/s6-rc.d/keepalived/run \
              /usr/local/bin/generate-keepalived-conf.sh

# No ENTRYPOINT of our own: the base image's is s6-overlay's /init, and the
# services this add-on adds are registered under /etc/s6-overlay/s6-rc.d like
# the image's own.
