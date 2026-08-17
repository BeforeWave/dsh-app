#!/bin/bash

# DS Harness desktop extension environment.
# User values can override these defaults.

export DSH_DESKTOP_HOST="${DSH_DESKTOP_HOST:-127.0.0.1}"
export DSH_DESKTOP_PORT="${DSH_DESKTOP_PORT:-3080}"
export DSH_DESKTOP_SERVICE_LABEL="${DSH_DESKTOP_SERVICE_LABEL:-com.beforewave.ds-harness.web}"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
