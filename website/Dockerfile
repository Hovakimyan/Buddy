# The marketing site (dist/, plain static files) served by Caddy, for Railway (service Root Directory: website).
# Railway sets PORT; TLS is Railway's (and Cloudflare's, if proxied), so Caddy serves plain HTTP. See docs/releasing.md,
# "Website: Railway and Cloudflare".
FROM caddy:2.10.2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY dist /srv
