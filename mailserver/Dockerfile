FROM ghcr.io/docker-mailserver/docker-mailserver:latest
LABEL io.hass.type="addon"
COPY run.sh /run.sh
RUN chmod a+x /run.sh
ENTRYPOINT ["/run.sh"]
