# Prometheus Metrics Configuration
#
# Controls whether DriftHound serves Prometheus metrics at /metrics.
#
# METRICS_ENABLED=true  - GET /metrics returns drift state in the Prometheus text format
# METRICS_ENABLED=false - /metrics returns 404 (default)
#
# Authentication uses an existing API token (Authorization: Bearer <token>).
# A token with "read" access is enough. PUBLIC_MODE does not open this endpoint.

Rails.application.config.metrics_enabled = ENV.fetch("METRICS_ENABLED", "false") == "true"
