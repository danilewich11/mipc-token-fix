#!/bin/bash
# refresh_mipc.sh
# Periodically fetches a fresh tokenized stream URL from a MIPC camera and
# registers it in go2rtc (and optionally mirrors it into a Home Assistant input_text).
#
# Configuration comes from refresh_mipc.env (next to this script) or from the
# environment. Override the file location with MIPC_ENV_FILE.

ENV_FILE="${MIPC_ENV_FILE:-$(dirname "$0")/refresh_mipc.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

CAMERA_IP="${CAMERA_IP:-}"
CAMERA_USER="${CAMERA_USER:-admin}"
CAMERA_PASSWORD="${CAMERA_PASSWORD:-}"
GO2RTC_URL="${GO2RTC_URL:-http://localhost:1984}"
STREAM_NAME="${STREAM_NAME:-mipc_camera}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-270}"   # seconds between refreshes
RETRY_INTERVAL="${RETRY_INTERVAL:-30}"        # seconds before retry if the camera doesn't answer

# Optional: mirror the current URL into a Home Assistant input_text entity
HA_URL="${HA_URL:-http://localhost:8123}"
HA_TOKEN="${HA_TOKEN:-}"
HA_ENTITY="${HA_ENTITY:-input_text.mipc_stream_url}"

if [ -z "$CAMERA_IP" ] || [ -z "$CAMERA_PASSWORD" ]; then
  echo "$(date): CAMERA_IP and CAMERA_PASSWORD must be set (see refresh_mipc.env.example)" >&2
  exit 1
fi

# mipc_camera_client reads the password from the environment
export CAMERA_PASSWORD

log() { echo "$(date): $*"; }

while true; do
  STREAM_URL=$(mipc_camera_client --host "$CAMERA_IP" --user "$CAMERA_USER" stream 2>/dev/null)

  if [ -z "$STREAM_URL" ]; then
    log "camera did not answer, retrying in ${RETRY_INTERVAL}s"
    sleep "$RETRY_INTERVAL"
    continue
  fi

  # 1. (Re)define the stream in go2rtc
  curl -s -X PUT -G \
    --data-urlencode "src=ffmpeg:${STREAM_URL}#video=copy#audio=copy" \
    "${GO2RTC_URL}/api/streams?name=${STREAM_NAME}" > /dev/null

  # 2. Keep the connection to the camera open permanently, so viewers attach
  #    to a live stream instead of re-using a stale/one-time URL.
  curl -s -X PUT -G \
    --data-urlencode "src=${STREAM_NAME}" \
    --data-urlencode "query=video&audio" \
    "${GO2RTC_URL}/api/preload" > /dev/null

  # 3. Optional: publish the URL to Home Assistant
  if [ -n "$HA_TOKEN" ]; then
    curl -s -X POST \
      -H "Authorization: Bearer ${HA_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"entity_id\": \"${HA_ENTITY}\", \"value\": \"${STREAM_URL}\"}" \
      "${HA_URL}/api/services/input_text/set_value" > /dev/null
  fi

  log "stream URL refreshed"
  sleep "$REFRESH_INTERVAL"
done
