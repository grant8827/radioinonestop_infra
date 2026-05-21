#!/bin/sh
# Substitute env vars in the config template, then start Icecast.
# Required on Railway:
#   ICECAST_SOURCE_PASSWORD=<random>   (must match backend ICECAST_SOURCE_PASSWORD)
#   ICECAST_ADMIN_PASSWORD=<random>    (admin UI password)
envsubst '${ICECAST_SOURCE_PASSWORD} ${ICECAST_ADMIN_PASSWORD}' \
  < /etc/icecast2/icecast.xml.tmpl \
  > /tmp/icecast.xml
exec icecast2 -c /tmp/icecast.xml
