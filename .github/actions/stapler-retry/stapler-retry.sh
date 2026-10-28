#!/usr/bin/env bash
# Usage: stapler-retry.sh <staple|validate> <bundle>
#
# Both stapler verbs query Apple's CloudKit ticketing service, and stapler(1) exits
# EX_NOHOST (68) when that service drops the connection or answers unexpectedly.
# Retry only that status, up to 6x with linear backoff (7.5 min); any other status
# (no ticket, bad signature, wrong bundle), or a sixth EX_NOHOST, is terminal.
set -euo pipefail

verb="$1"
bundle="$2"
attempt=1
while :; do
  status=0
  xcrun stapler "$verb" "$bundle" || status=$?
  if [ "$status" -eq 0 ]; then
    exit 0
  fi
  if [ "$status" -ne 68 ] || [ "$attempt" -ge 6 ]; then
    echo "::error::stapler $verb failed for $bundle (exit $status, attempt $attempt/6)"
    exit "$status"
  fi
  echo "::warning::stapler $verb could not reach the ticketing service for $bundle (attempt $attempt/6); retrying in $((attempt * 30))s"
  sleep "$((attempt * 30))"
  attempt=$((attempt + 1))
done
