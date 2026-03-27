#!/usr/bin/env bash
# =============================================================================
# Jamf Pro — Enrollment Stats Fetcher
# =============================================================================
# Pulls all managed Mac records, computes enrollment stats, and writes
# data/jamf-enrollment-stats.json for the dashboard.
#
# Required CI/CD variables:
#   JAMF_URL              e.g. https://yourcompany.jamfcloud.com
#   JAMF_CLIENT_ID        OAuth client ID from Jamf Pro
#   JAMF_CLIENT_SECRET    OAuth client secret from Jamf Pro  (masked)
#
# Optional CI/CD variables:
#   JAMF_BUSINESS_UNITS   JSON array of business unit smart groups to count.
#                         Format: '[{"name":"GroupA","id":123},{"name":"GroupB","id":456}]'
#                         If unset or empty, the business_units array in the output
#                         will be empty and the card will be hidden on the dashboard.
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
JAMF_URL="${JAMF_URL%/}"
OUTPUT_FILE="data/jamf-enrollment-stats.json"
PAGE_SIZE=200

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

# ─── Fetch All Computer Records (paginated) ───────────────────────────────────
echo "Fetching computer inventory..."
PAGES_DIR=$(mktemp -d)
ALL_COMPUTERS_FILE=$(mktemp)
PAGE=0

while true; do
  HTTP_STATUS=$(curl -s -o "${PAGES_DIR}/page_${PAGE}.json" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/api/v1/computers-inventory?page-size=${PAGE_SIZE}&page=${PAGE}&section=GENERAL" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json")

  if [[ "${HTTP_STATUS}" -lt 200 || "${HTTP_STATUS}" -ge 300 ]]; then
    echo "ERROR: Jamf inventory API returned HTTP ${HTTP_STATUS}. Response body:"
    cat "${PAGES_DIR}/page_${PAGE}.json"
    exit 1
  fi

  COUNT=$(jq '.results | length' "${PAGES_DIR}/page_${PAGE}.json")
  echo "  Page ${PAGE}: ${COUNT} devices"

  if [[ "${COUNT}" -lt "${PAGE_SIZE}" ]]; then
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

TOTAL=$(jq 'length' "${ALL_COMPUTERS_FILE}")
echo "Retrieved ${TOTAL} managed computers from Jamf Pro."

# ─── Helper: fetch smart group member count ───────────────────────────────────
fetch_group_count() {
  local group_id="$1"
  local body http_status
  body=$(mktemp)
  http_status=$(curl -s -o "${body}" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/JSSResource/computergroups/id/${group_id}" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json")
  if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
    jq '.computer_group.computers | length' "${body}"
  else
    echo "WARNING: Smart group ${group_id} returned HTTP ${http_status} — defaulting to 0." >&2
    echo 0
  fi
  rm -f "${body}"
}

# ─── Fetch Business Unit Smart Group Counts ───────────────────────────────────
# Driven by JAMF_BUSINESS_UNITS — a JSON array of {name, id} objects.
# If the variable is not set, no groups are fetched and business_units will be [].

BUSINESS_UNITS_JSON='[]'
if [[ -n "${JAMF_BUSINESS_UNITS:-}" ]]; then
  echo "Fetching business unit smart group counts..."
  UNIT_COUNT=$(echo "${JAMF_BUSINESS_UNITS}" | jq 'length')
  RESULT_ARRAY='[]'
  for i in $(seq 0 $((UNIT_COUNT - 1))); do
    UNIT_NAME=$(echo "${JAMF_BUSINESS_UNITS}" | jq -r ".[${i}].name")
    UNIT_ID=$(echo "${JAMF_BUSINESS_UNITS}"   | jq -r ".[${i}].id")
    COUNT=$(fetch_group_count "${UNIT_ID}")
    echo "  ${UNIT_NAME} (${UNIT_ID}): ${COUNT}"
    RESULT_ARRAY=$(echo "${RESULT_ARRAY}" | jq ". + [{name: \"${UNIT_NAME}\", count: ${COUNT}}]")
  done
  BUSINESS_UNITS_JSON="${RESULT_ARRAY}"
else
  echo "JAMF_BUSINESS_UNITS not set — skipping business unit counts."
fi

# ─── Invalidate Token ─────────────────────────────────────────────────────────
curl -sf \
  --request POST \
  --url "${JAMF_URL}/api/v1/auth/invalidate-token" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --output /dev/null || true

# ─── Compute Stats & Write Output ─────────────────────────────────────────────
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOW=$(date -u +%s)

jq \
  --argjson now          "${NOW}" \
  --arg     generated_at "${GENERATED_AT}" \
  --argjson business_units "${BUSINESS_UNITS_JSON}" '
  def secs_24h:  86400;
  def secs_30d:  2592000;

  # Parse ISO date to epoch; null/empty → 0
  def to_epoch:
    if . == null or . == "" then 0
    else (gsub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
         // 0
    end;

  # Enrollments per calendar year (from lastEnrolledDate)
  ( [.[] | select(.general.lastEnrolledDate != null and .general.lastEnrolledDate != "")]
    | group_by(.general.lastEnrolledDate[0:4])
    | map({ year: .[0].general.lastEnrolledDate[0:4], count: length })
    | sort_by(.year)
  ) as $by_year |

  # Last 24h and 30d counts
  ( [.[] | select(
      (.general.lastEnrolledDate | to_epoch) >= ($now - secs_24h)
    )] | length
  ) as $last_24h |

  ( [.[] | select(
      (.general.lastEnrolledDate | to_epoch) >= ($now - secs_30d)
    )] | length
  ) as $last_30d |

  {
    generated_at: $generated_at,
    summary: {
      total_enrolled:    (length),
      enrolled_last_24h: $last_24h,
      enrolled_last_30d: $last_30d
    },
    business_units: $business_units,
    enrollments_by_year: $by_year
  }
' "${ALL_COMPUTERS_FILE}" > "${OUTPUT_FILE}"

rm -f "${ALL_COMPUTERS_FILE}"

LAST_24H=$(jq '.summary.enrolled_last_24h' "${OUTPUT_FILE}")
LAST_30D=$(jq '.summary.enrolled_last_30d' "${OUTPUT_FILE}")

echo "Output written to ${OUTPUT_FILE}"
echo "Summary: ${TOTAL} total | ${LAST_24H} enrolled last 24h | ${LAST_30D} enrolled last 30d"
