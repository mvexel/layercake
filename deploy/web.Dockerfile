# Caddy with this stack's Caddyfile baked in, so a Caddyfile change changes the
# image and a redeploy recreates the container (a bind-mounted file would not).
FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
