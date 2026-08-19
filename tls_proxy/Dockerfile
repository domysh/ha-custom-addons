FROM nginx:1.31.3-alpine
LABEL io.hass.type="addon"

RUN apk add --no-cache bash jq keepalived

COPY generate-nginx-conf.sh /generate-nginx-conf.sh
COPY generate-keepalived-conf.sh /generate-keepalived-conf.sh
COPY run.sh /run.sh
RUN chmod a+x /generate-nginx-conf.sh /generate-keepalived-conf.sh /run.sh

ENTRYPOINT ["/run.sh"]
