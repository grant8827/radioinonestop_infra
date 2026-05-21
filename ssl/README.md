# Radio In One Stop — SSL

Place your TLS certificate and key here **before** running `docker compose up`.

| File       | Contents                                 |
|------------|------------------------------------------|
| `cert.pem` | Full-chain PEM certificate               |
| `key.pem`  | Private key (RSA or ECDSA)               |

## Quick start — self-signed (dev/staging)

```bash
bash scripts/gen-cert.sh localhost   # or your domain name
```

## Production — Let's Encrypt (Certbot)

1. Temporarily expose port 80 without SSL and run Certbot:

```bash
certbot certonly --standalone -d yourdomain.com
```

2. Copy the certs here:

```bash
cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem ssl/cert.pem
cp /etc/letsencrypt/live/yourdomain.com/privkey.pem   ssl/key.pem
```

3. Set `HLS_BASE_URL` in `.env` (or export it):

```
HLS_BASE_URL=https://yourdomain.com
```

4. Start the stack:

```bash
docker compose up --build -d
```

## Renewal

Add a cron job or systemd timer to run `certbot renew` and then
`docker compose restart nginx` to reload the new cert.
