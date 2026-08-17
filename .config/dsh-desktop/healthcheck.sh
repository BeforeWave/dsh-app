#!/bin/bash

curl -fsS \
  --max-time 1 \
  "http://${DSH_DESKTOP_HOST:-127.0.0.1}:${DSH_DESKTOP_PORT:-3080}/" \
  >/dev/null 2>&1
