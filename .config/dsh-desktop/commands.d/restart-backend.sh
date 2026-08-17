#!/bin/bash
# @menu Restart Backend
# @shortcut cmd+shift+r
# @order 10

launchctl kickstart -k \
  "gui/$(id -u)/${DSH_DESKTOP_SERVICE_LABEL:-com.beforewave.ds-harness.web}"
