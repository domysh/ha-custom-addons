#!/usr/bin/env sh
set -e

CF_TOKEN=$(python3 -c "import json;print(json.load(open('/data/options.json'))['cf_api_token'])")

mkdir -p /run/secrets
printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /run/secrets/cloudflare.ini
chmod 600 /run/secrets/cloudflare.ini

CERTBOT_COMMON="--dns-cloudflare --dns-cloudflare-credentials /run/secrets/cloudflare.ini --dns-cloudflare-propagation-seconds 30 --config-dir /share/certs --work-dir /var/lib/letsencrypt --logs-dir /var/log/letsencrypt"

# Issue a certificate for each domain listed in the add-on options,
# but only if it doesn't already exist (avoids hitting Let's Encrypt rate limits on every restart).
python3 -c "import json;print('\n'.join(json.load(open('/data/options.json'))['domains']))" | while read -r DOMAIN; do
  [ -z "$DOMAIN" ] && continue
  if [ ! -d "/share/certs/live/${DOMAIN}" ]; then
    echo "Issuing new certificate for ${DOMAIN}..."
    certbot certonly $CERTBOT_COMMON \
      --non-interactive --agree-tos --register-unsafely-without-email \
      --key-type ecdsa --elliptic-curve secp256r1 \
      -d "${DOMAIN}"
  fi
done

# certbot renew tracks every previously-issued certificate on its own via /share/certs/renewal/,
# so no per-domain loop is needed here.
trap exit TERM
while :; do
  certbot renew $CERTBOT_COMMON --quiet
  sleep 12h &
  wait $!
done
