#!/usr/bin/env bash
# =============================================================================
# Jamf Pro — macOS OS Compliance Data Fetcher
# =============================================================================
# Pulls all Mac computer records from Jamf Pro via the API, computes OS
# compliance against a minimum required version, and writes a JSON summary
# to data/jamf-os-compliance.json for the dashboard.
#
# Prerequisites in Jamf Pro (Settings → API Roles and Clients):
#   1. Create an API Role with permission: "Read Computers"
#   2. Create an API Client, assign that role, and copy the Client ID/Secret
#
# Required CI/CD variables:
#   JAMF_URL           e.g. https://yourcompany.jamfcloud.com
#   JAMF_CLIENT_ID     OAuth client ID from Jamf Pro
#   JAMF_CLIENT_SECRET OAuth client secret from Jamf Pro  (masked)
#
# Optional CI/CD variables:
#   JAMF_N_RULE        Number of previous minor releases counted as compliant
#                      (default: 2 — i.e. latest + 2 prior security releases)
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
JAMF_URL="${JAMF_URL%/}"                          # strip trailing slash
N_RULE="${JAMF_N_RULE:-2}"                        # N previous minor releases = compliant
SOFA_URL="https://sofafeed.macadmins.io/v1/macos_data_feed.json"
SOFA_FILE=$(mktemp)
OUTPUT_FILE="data/jamf-os-compliance.json"
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

# ─── Fetch SOFA macOS Data Feed ──────────────────────────────────────────────
echo "Fetching SOFA macOS data feed..."
SOFA_HTTP=$(curl -s -o "${SOFA_FILE}" -w "%{http_code}" \
  --compressed --max-time 30 \
  --header "User-Agent: SOFA-GitLab-CI/1.0" \
  "${SOFA_URL}")

if [[ "${SOFA_HTTP}" -lt 200 || "${SOFA_HTTP}" -ge 300 ]]; then
  echo "ERROR: SOFA feed returned HTTP ${SOFA_HTTP}"
  exit 1
fi
echo "SOFA feed fetched (HTTP ${SOFA_HTTP})."

# ─── Fetch All Computer Records (paginated) — written to disk to avoid ARG_MAX ─
echo "Fetching computer inventory..."
PAGES_DIR=$(mktemp -d)
ALL_COMPUTERS_FILE=$(mktemp)   # separate from PAGES_DIR to avoid glob collision
PAGE=0

while true; do
  HTTP_STATUS=$(curl -s -o "${PAGES_DIR}/page_${PAGE}.json" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/api/v1/computers-inventory?page-size=${PAGE_SIZE}&page=${PAGE}&section=GENERAL&section=HARDWARE&section=OPERATING_SYSTEM" \
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

# Merge all pages into a single flat JSON array on disk.
# Files are sorted numerically so page_10 comes after page_9, not page_1.
find "${PAGES_DIR}" -name 'page_*.json' | sort -t_ -k2 -n | \
  xargs jq -s '[.[].results[]]' > "${ALL_COMPUTERS_FILE}"
rm -rf "${PAGES_DIR}"

# Filter out unmanaged devices — only managed Macs should count for compliance.
MANAGED_FILE=$(mktemp)
jq '[.[] | select(.general.remoteManagement.managed == true)]' "${ALL_COMPUTERS_FILE}" > "${MANAGED_FILE}"
mv "${MANAGED_FILE}" "${ALL_COMPUTERS_FILE}"

TOTAL=$(jq 'length' "${ALL_COMPUTERS_FILE}")
echo "Retrieved ${TOTAL} managed computers from Jamf Pro."

# ─── Compute Compliance via SOFA N-Rule ──────────────────────────────────────
# Compliance rules per device's latest compatible OS line:
#   1. Running Latest.ProductVersion → compliant
#   2. Running any of SecurityReleases[0..N] → compliant (N-rule)
#   3. Running any SecurityReleases[].ProductVersion released within 30 days → compliant
# Model lookup via SOFA Models map; VirtualMac / unknown → latest OS line.
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOW=$(date -u +%s)

# ─── Invalidate Token ─────────────────────────────────────────────────────────
curl -sf \
  --request POST \
  --url "${JAMF_URL}/api/v1/auth/invalidate-token" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --output /dev/null || true

# ─── Write JSON Output (single-pass jq) ───────────────────────────────────────
jq \
  --slurpfile sofa "${SOFA_FILE}" \
  --argjson   n    "${N_RULE}" \
  --argjson   now  "${NOW}" \
  --arg       generated_at "${GENERATED_AT}" '
  def thirty_days: 2592000;
  def nv: split(".") | map(tonumber? // 0) | . + [0,0,0] | .[0:3]
          | map(. + 100000 | tostring | .[-6:]) | join(".");
  # Strip trailing .0 segments: "26.4.0" → "26.4", "15.3" stays "15.3"
  def norm_ver: gsub("(\\.0)+$"; "");

  # Compliant version set per OS line — normalize SOFA versions too
  ($sofa[0].OSVersions | map({
    key: .OSVersion,
    value: (
      [.Latest.ProductVersion | norm_ver] +
      (.SecurityReleases[0:($n + 1)] | map(.ProductVersion | norm_ver)) +
      (.SecurityReleases | map(
        select(
          (.ReleaseDate | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) >= ($now - thirty_days)
        ) | .ProductVersion | norm_ver
      ))
    ) | unique
  }) | from_entries) as $compliant_per_os |

  # Model → latest compatible OS line name
  ($sofa[0].Models | to_entries | map({
    key: .key,
    value: (.value.SupportedOS[0] // null)
  }) | from_entries) as $model_os |

  # Fallback OS line (newest in feed) and latest product version
  ($sofa[0].OSVersions[0].OSVersion)            as $latest_os_line |
  ($sofa[0].OSVersions[0].Latest.ProductVersion) as $latest_version |

  # Resolve which OS line applies to a device
  def device_os_line:
    (.hardware.modelIdentifier // "") as $m |
    if $m == "" or ($m | test("^VirtualMac"))
    then $latest_os_line
    else ($model_os[$m] // $latest_os_line)
    end;

  # Is the device running a compliant OS version?
  def is_compliant:
    (.operatingSystem.version // "") as $raw |
    if $raw == "" then false
    else ($raw | norm_ver) as $v |
      (device_os_line) as $line |
      ($compliant_per_os[$line] // []) | contains([$v])
    end;

  # OS version distribution
  ( [.[] | select(.operatingSystem.version != null and .operatingSystem.version != "")] |
    group_by(.operatingSystem.version) |
    map({
      version:   .[0].operatingSystem.version,
      count:     length,
      compliant: (.[0] | is_compliant)
    }) |
    sort_by(.version | nv) | reverse
  ) as $os_dist |

  # Summary counts
  (length) as $total |
  ([$os_dist[] | select(.compliant)       | .count] | add // 0) as $compliant_count |
  ([$os_dist[] | select(.compliant | not) | .count] | add // 0
   + ([.[] | select(.operatingSystem.version == null or .operatingSystem.version == "")] | length)
  ) as $non_compliant_count |

  # First 100 non-compliant devices for the table
  ( [.[] | select(is_compliant | not)] |
    sort_by(.operatingSystem.version // "0") |
    .[0:100] |
    map({
      name:       (.general.name           // "Unknown"),
      serial:     (.hardware.serialNumber  // ""),
      os_version: (.operatingSystem.version // "Unknown"),
      last_seen:  (.general.lastContactTime // null)
    })
  ) as $non_compliant_devices |

  {
    generated_at:    $generated_at,
    compliance_rule: ("SOFA N-\($n) rule"),
    latest_version:  $latest_version,
    summary: {
      total_devices:         $total,
      compliant:             $compliant_count,
      non_compliant:         $non_compliant_count,
      compliance_percentage: (if $total > 0 then (($compliant_count / $total) * 100 | round) else 0 end)
    },
    os_distribution:       $os_dist,
    non_compliant_devices: $non_compliant_devices
  }
' "${ALL_COMPUTERS_FILE}" > "${OUTPUT_FILE}"

rm -f "${SOFA_FILE}" "${ALL_COMPUTERS_FILE}"

SUMMARY_TOTAL=$(jq '.summary.total_devices' "${OUTPUT_FILE}")
SUMMARY_OK=$(jq '.summary.compliant'        "${OUTPUT_FILE}")
SUMMARY_BAD=$(jq '.summary.non_compliant'   "${OUTPUT_FILE}")
LATEST=$(jq -r '.latest_version'            "${OUTPUT_FILE}")

echo "Output written to ${OUTPUT_FILE}"
echo "Latest macOS: ${LATEST} · Summary: ${SUMMARY_TOTAL} total | ${SUMMARY_OK} compliant | ${SUMMARY_BAD} non-compliant"
