#!/bin/sh
# Substitute ${ICECAST_BACKEND_AUTH_URL} in the config template, then start Icecast.
# Docker Compose default: http://backend:8080
# Railway override:       http://backend.railway.internal:8080
envsubst '${ICECAST_BACKEND_AUTH_URL}' \
  < /etc/icecast2/icecast.xml.tmpl \
  > /tmp/icecast.xml
exec icecast2 -c /tmp/icecast.xml
