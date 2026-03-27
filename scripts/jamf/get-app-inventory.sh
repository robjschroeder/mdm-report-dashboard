#!/usr/bin/env bash
# =============================================================================
# Jamf Pro — Application Inventory Fetcher
# =============================================================================
# Pulls all managed Mac computer records (GENERAL + APPLICATION sections),
# aggregates application version distributions, and writes
# data/jamf-app-inventory.json for the dashboard.
#
# Output JSON shape (data/jamf-app-inventory.json):
# {
#   "generated_at": "...",
#   "platform": "macOS",
#   "total_devices": 450,
#   "application_count": 1842,
#   "applications": [
#     {
#       "name": "Google Chrome",
#       "device_count": 380,
#       "versions": [
#         { "version": "122.0.6261.128", "count": 250 },
#         { "version": "122.0.6261.94",  "count": 88  }
#       ]
#     }
#   ]
# }
#
# Applications sorted by device_count descending.
# Versions within each app sorted by count descending.
#
# Required CI/CD variables:
#   JAMF_URL           e.g. https://yourcompany.jamfcloud.com
#   JAMF_CLIENT_ID     OAuth client ID from Jamf Pro
#   JAMF_CLIENT_SECRET OAuth client secret from Jamf Pro  (masked)
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
JAMF_URL="${JAMF_URL%/}"
OUTPUT_FILE="data/jamf-app-inventory.json"
PAGE_SIZE=200
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ─── Obtain OAuth Bearer Token ────────────────────────────────────────────────
echo "Authenticating with Jamf Pro at ${JAMF_URL} ..."

TOKEN_RESPONSE=$(curl -sf \
  --request POST \
  --url "${JAMF_URL}/api/v1/oauth/token" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${JAMF_CLIENT_ID}" \
  --data-urlencode "client_secret=${JAMF_CLIENT_SECRET}")

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')

if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "ERROR: Could not obtain Jamf access token. Response:"
  echo "${TOKEN_RESPONSE}"
  exit 1
fi

echo "Authentication successful."

# ─── Fetch All Computer Records with Application Inventory (paginated) ────────
echo "Fetching computer application inventory..."

PAGES_DIR=$(mktemp -d)
ALL_COMPUTERS_FILE=$(mktemp)
PAGE=0

while true; do
  HTTP_STATUS=$(curl -s -o "${PAGES_DIR}/page_${PAGE}.json" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/api/v1/computers-inventory?page-size=${PAGE_SIZE}&page=${PAGE}&section=GENERAL&section=APPLICATIONS" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json")

  if [[ "${HTTP_STATUS}" -lt 200 || "${HTTP_STATUS}" -ge 300 ]]; then
    echo "ERROR: Jamf inventory API returned HTTP ${HTTP_STATUS}. Response body:"
    cat "${PAGES_DIR}/page_${PAGE}.json"
    exit 1
  fi

  COUNT=$(jq '.results | length' "${PAGES_DIR}/page_${PAGE}.json")
  echo "  Page ${PAGE}: ${COUNT} devices"

  if [[ "${COUNT}" -eq 0 || "${COUNT}" -lt "${PAGE_SIZE}" ]]; then
    break
  fi

  PAGE=$((PAGE + 1))
done

# Merge pages into a single flat array
find "${PAGES_DIR}" -name 'page_*.json' | sort -t_ -k2 -n | \
  xargs jq -s '[.[].results[]]' > "${ALL_COMPUTERS_FILE}"
rm -rf "${PAGES_DIR}"

# Filter to managed devices only
MANAGED_FILE=$(mktemp)
jq '[.[] | select(.general.remoteManagement.managed == true)]' \
  "${ALL_COMPUTERS_FILE}" > "${MANAGED_FILE}"
mv "${MANAGED_FILE}" "${ALL_COMPUTERS_FILE}"

TOTAL_DEVICES=$(jq 'length' "${ALL_COMPUTERS_FILE}")
echo "Processing ${TOTAL_DEVICES} managed devices..."

# ─── Aggregate Application Inventory ─────────────────────────────────────────
echo "Building application inventory (this may take a moment)..."

mkdir -p "$(dirname "${OUTPUT_FILE}")"

jq \
  --argjson total "${TOTAL_DEVICES}" \
  --arg now "${NOW}" \
  '
  # Flatten to {id, name, version} triples for every installed app.
  # Use top-level .id (Jamf computer record ID) — always present regardless
  # of which sections are requested; .general.serialNumber can be null.
  [
    .[] |
    .id as $id |
    (.applications // [])[] |
    {
      id:      $id,
      name:    (.name | sub("\\.app$"; "") | ltrimstr(" ") | rtrimstr(" ")),
      version: ((.version // "") | if . == "" then "Unknown" else . end)
    }
  ]

  # Group by app name
  | group_by(.name)

  # Build one object per app
  | map(
      . as $records |
      {
        name:         $records[0].name,
        device_count: ($records | map(.id) | unique | length),
        versions: (
          $records
          | group_by(.version)
          | map({
              version: .[0].version,
              count:   (map(.id) | unique | length)
            })
          | sort_by(-.count)
        )
      }
    )

  # Most widely deployed apps first
  | sort_by(-.device_count)

  # Wrap in metadata envelope
  | {
      generated_at:      $now,
      platform:          "macOS",
      total_devices:     $total,
      application_count: length,
      applications:      .
    }
  ' "${ALL_COMPUTERS_FILE}" > "${OUTPUT_FILE}"

# ─── Summary ──────────────────────────────────────────────────────────────────
APP_COUNT=$(jq '.application_count' "${OUTPUT_FILE}")
echo "Done. Found ${APP_COUNT} unique applications across ${TOTAL_DEVICES} managed devices."
echo "Output written to ${OUTPUT_FILE}"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "${ALL_COMPUTERS_FILE}"
