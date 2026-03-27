#!/usr/bin/env bash
# =============================================================================
# Jamf Pro — Mac Hardware Stats Fetcher
# =============================================================================
# Pulls all managed Mac computer records from Jamf Pro, computes hardware
# statistics, and writes data/jamf-hardware-stats.json for the dashboard.
#
# Sections fetched per device:
#   GENERAL          — device name, serial number, managed flag
#   HARDWARE         — model identifier, model name, year, processor CPU type
#
# Output JSON shape (data/jamf-hardware-stats.json):
# {
#   "generated_at": "...",
#   "summary": {
#     "total_devices": 450,
#     "apple_silicon": 280,
#     "intel": 170,
#     "incompatible_with_latest_os": 65
#   },
#   "architecture_breakdown": [
#     { "architecture": "Apple Silicon", "count": 280 },
#     { "architecture": "Intel", "count": 170 }
#   ],
#   "models_by_year": [
#     { "year": "2021", "count": 55 }, ...
#   ],
#   "top_models": [
#     { "model": "MacBook Pro 14-inch (2023)", "count": 120 }, ...
#   ],
#   "incompatible_devices": [
#     { "name": "...", "serial": "...", "model": "...", "architecture": "Intel", "year": "2017" },
#     ...
#   ]
# }
#
# Prerequisites in Jamf Pro (Settings → API Roles and Clients):
#   1. Create an API Role with permission: "Read Computers"
#   2. Create an API Client, assign that role, copy the Client ID / Secret
#
# Required CI/CD variables:
#   JAMF_URL           e.g. https://yourcompany.jamfcloud.com
#   JAMF_CLIENT_ID     OAuth client ID from Jamf Pro
#   JAMF_CLIENT_SECRET OAuth client secret from Jamf Pro  (masked)
#
# Optional CI/CD variables:
#   JAMF_LATEST_MACOS  Latest macOS major version that determines compatibility
#                      (default: auto-detected from SOFA feed)
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
JAMF_URL="${JAMF_URL%/}"
OUTPUT_FILE="data/jamf-hardware-stats.json"
PAGE_SIZE=200
SOFA_URL="https://sofa.macadmins.io/v2/macos_data_feed.json"
SOFA_FILE=$(mktemp)

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

# ─── Fetch SOFA Feed (model compatibility data) ────────────────────────────────
echo "Fetching SOFA macOS data feed..."

SOFA_HTTP=$(curl -s -o "${SOFA_FILE}" -w "%{http_code}" \
  --compressed --max-time 30 \
  --header "User-Agent: SOFA-GitLab-CI/1.0" \
  "${SOFA_URL}")

if [[ "${SOFA_HTTP}" -lt 200 || "${SOFA_HTTP}" -ge 300 ]]; then
  echo "WARNING: SOFA feed returned HTTP ${SOFA_HTTP} — incompatibility data will be skipped."
  echo '{}' > "${SOFA_FILE}"
else
  echo "SOFA feed fetched (HTTP ${SOFA_HTTP})."
fi

# ─── Fetch All Computer Records (paginated) ───────────────────────────────────
echo "Fetching computer inventory..."

PAGES_DIR=$(mktemp -d)
ALL_COMPUTERS_FILE=$(mktemp)
PAGE=0

while true; do
  HTTP_STATUS=$(curl -s -o "${PAGES_DIR}/page_${PAGE}.json" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/api/v1/computers-inventory?page-size=${PAGE_SIZE}&page=${PAGE}&section=GENERAL&section=HARDWARE&section=STORAGE" \
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

# ─── Invalidate Token ─────────────────────────────────────────────────────────
curl -sf \
  --request POST \
  --url "${JAMF_URL}/api/v1/auth/invalidate-token" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --output /dev/null || true

# ─── Compute & Write JSON Output ─────────────────────────────────────────────
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "${OUTPUT_FILE}")"

jq \
  --slurpfile sofa "${SOFA_FILE}" \
  --arg generated_at "${GENERATED_AT}" '
  # ── Architecture classification ──────────────────────────────────────────
  # Jamf Pro reports the CPU type as a string in hardware.processorType or
  # hardware.processorArchitecture. Apple Silicon chips contain "arm" or "Apple".
  def arch_of:
    (.hardware.processorType // .hardware.processorArchitecture // "") | ascii_downcase |
    if test("arm|apple") then "Apple Silicon"
    else "Intel"
    end;

  # ── Model year extraction ─────────────────────────────────────────────────
  # Jamf stores the model name as e.g. "MacBook Pro (14-inch, 2023)".
  # Extract the last 4-digit year found in the model name; fall back to "Unknown".
  def year_of:
    (.hardware.model // "") |
    [ scan("[0-9]{4}") ] | last // "Unknown";

  # ── Model display name ────────────────────────────────────────────────────
  def model_of:
    .hardware.model // .hardware.modelIdentifier // "Unknown";

  # ── SOFA compatible model identifiers for the latest OS ──────────────────
  # $sofa[0] is the full SOFA feed. We pick the first (i.e. latest) OS entry
  # and collect all SupportedModels identifiers into a set.
  (
    if ($sofa[0] | type) == "object" and ($sofa[0] | has("OSVersions")) then
      [ ($sofa[0].OSVersions[0].SupportedModels // [])[] | .Identifiers | keys[] ] | unique
    else
      []
    end
  ) as $supported_ids |

  # Latest OS version name for the badge
  (
    if ($sofa[0] | type) == "object" and ($sofa[0] | has("OSVersions")) then
      "macOS \($sofa[0].OSVersions[0].OSVersion)"
    else
      "the latest macOS"
    end
  ) as $latest_os_name |

  # ── Battery stats (portable Macs only — batteryCapacityPercent present) ─────
  ( [.[] | select(.hardware.batteryCapacityPercent != null)] ) as $portable_macs |
  ( $portable_macs | length ) as $battery_count |
  (
    $portable_macs |
    group_by(.hardware.batteryHealth // "Unknown") |
    map({ status: (.[0].hardware.batteryHealth // "Unknown"), count: length }) |
    sort_by(-.count)
  ) as $battery_health_breakdown |
  ( $portable_macs | map(select(.hardware.batteryCapacityPercent < 80)) | length ) as $low_battery_count |

  # ── Storage / SMART stats (from storage section) ──────────────────────────
  (
    [.[] | select(.storage.disks != null and (.storage.disks | length) > 0)] |
    group_by(.storage.disks[0].smartStatus // "UNKNOWN") |
    map({ status: (.[0].storage.disks[0].smartStatus // "UNKNOWN"), count: length }) |
    sort_by(-.count)
  ) as $smart_breakdown |
  (
    [.[] | select(
      .storage.bootDriveAvailableSpaceMegabytes != null and
      .storage.bootDriveAvailableSpaceMegabytes < 10240
    )] | length
  ) as $almost_full_count |

  # ── Per-device classification ─────────────────────────────────────────────
  # Build the full classified array in one pass so all subsequent aggregations
  # operate on the complete dataset (not one device at a time).
  [.[] | {
      name:         (.general.name // "Unknown"),
      serial:       (.general.serialNumber // ""),
      model:        model_of,
      model_id:     (.hardware.modelIdentifier // ""),
      architecture: arch_of,
      year:         year_of
  }] |

  # ── Summary counts ────────────────────────────────────────────────────────
  (map(select(.architecture == "Apple Silicon")) | length) as $as_count |
  (map(select(.architecture == "Intel"))          | length) as $intel_count |

  # A device is incompatible if its modelIdentifier is NOT in SOFA supported IDs
  # (only applicable when SOFA data is present)
  (
    if ($supported_ids | length) > 0 then
      map(select(
        .model_id != "" and
        (.model_id | test("^VirtualMac") | not) and
        ((.model_id | IN($supported_ids[])) | not)
      )) | length
    else 0
    end
  ) as $incompat_count |

  # ── Architecture breakdown (ordered: Apple Silicon first) ─────────────────
  (
    group_by(.architecture) |
    map({ architecture: .[0].architecture, count: length }) |
    sort_by(if .architecture == "Apple Silicon" then 0 else 1 end)
  ) as $arch_breakdown |

  # ── Models by year (sorted ascending) ─────────────────────────────────────
  (
    group_by(.year) |
    map({ year: .[0].year, count: length }) |
    sort_by(.year)
  ) as $by_year |

  # ── Top models (descending by count) ──────────────────────────────────────
  (
    group_by(.model) |
    map({ model: .[0].model, count: length }) |
    sort_by(-.count)
  ) as $top_models |

  # ── Incompatible device list (first 200) ──────────────────────────────────
  (
    if ($supported_ids | length) > 0 then
      map(select(
        .model_id != "" and
        (.model_id | test("^VirtualMac") | not) and
        ((.model_id | IN($supported_ids[])) | not)
      )) |
      sort_by(.year) |
      .[:200] |
      map({ name, serial, model, architecture, year })
    else []
    end
  ) as $incompat_devices |

  # ── Final output ──────────────────────────────────────────────────────────
  {
    generated_at: $generated_at,
    latest_os:    $latest_os_name,
    summary: {
      total_devices:               (length),
      apple_silicon:               $as_count,
      intel:                       $intel_count,
      incompatible_with_latest_os: $incompat_count
    },
    architecture_breakdown: $arch_breakdown,
    models_by_year:         $by_year,
    top_models:             $top_models,
    incompatible_devices:   $incompat_devices,
    battery: {
      device_count:           $battery_count,
      low_capacity_count:     $low_battery_count,
      low_capacity_threshold: 80,
      health_breakdown:       $battery_health_breakdown
    },
    storage: {
      almost_full_count:        $almost_full_count,
      almost_full_threshold_gb: 10,
      smart_breakdown:          $smart_breakdown
    }
  }
' "${ALL_COMPUTERS_FILE}" > "${OUTPUT_FILE}"

rm -f "${ALL_COMPUTERS_FILE}" "${SOFA_FILE}"

INCOMPAT=$(jq '.summary.incompatible_with_latest_os' "${OUTPUT_FILE}")
AS_COUNT=$(jq '.summary.apple_silicon'               "${OUTPUT_FILE}")
INTEL_COUNT=$(jq '.summary.intel'                    "${OUTPUT_FILE}")

LOW_BATTERY=$(jq '.battery.low_capacity_count' "${OUTPUT_FILE}")
ALMOST_FULL=$(jq '.storage.almost_full_count'  "${OUTPUT_FILE}")

echo "Output written to ${OUTPUT_FILE}"
echo "Summary: ${TOTAL} total | ${AS_COUNT} Apple Silicon | ${INTEL_COUNT} Intel | ${INCOMPAT} incompatible with latest macOS"
echo "Battery: ${LOW_BATTERY} devices under 80% capacity | Storage: ${ALMOST_FULL} devices with <10 GB free"
