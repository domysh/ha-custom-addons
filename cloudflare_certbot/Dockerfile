FROM certbot/dns-cloudflare:latest
LABEL io.hass.type="addon"
COPY run.sh /run.sh
RUN chmod a+x /run.sh
ENTRYPOINT ["/run.sh"]
