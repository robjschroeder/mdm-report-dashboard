#!/usr/bin/env bash
# =============================================================================
# Jamf Pro — Security Compliance Fetcher
# =============================================================================
# Pulls security posture data from Jamf Pro smart groups and the inventory
# API, then writes data/jamf-security-compliance.json for the dashboard.
#
# Smart group IDs are supplied via CI/CD variables (see below).
# Each variable should be set to the numeric ID of the corresponding
# smart group in your Jamf Pro instance. If a variable is unset or empty
# the count defaults to 0 and the check is still rendered on the dashboard.
#
# Required CI/CD variables:
#   JAMF_URL                        e.g. https://yourcompany.jamfcloud.com
#   JAMF_CLIENT_ID                  OAuth client ID from Jamf Pro
#   JAMF_CLIENT_SECRET              OAuth client secret from Jamf Pro  (masked)
#
# Smart group CI/CD variables (set each to the numeric group ID):
#   JAMF_SG_FV_ENCRYPTED            FileVault encrypted
#   JAMF_SG_FV_NOT_ENCRYPTED        FileVault not encrypted
#   JAMF_SG_CHECKIN_COMPLIANT       Recent check-in compliant
#   JAMF_SG_CHECKIN_NONCOMPLIANT    Recent check-in non-compliant
#   JAMF_SG_DEFENDER_COMPLIANT      Microsoft Defender compliant
#   JAMF_SG_DEFENDER_NONCOMPLIANT   Microsoft Defender non-compliant
#   JAMF_SG_PLATFORM_SSO_REGISTERED Platform SSO registered
#   JAMF_SG_ENTRA_NOT_REGISTERED    Entra ID not registered
#   JAMF_SG_ENTRA_OLD_COMPLIANCE    Entra ID old compliance record
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
JAMF_URL="${JAMF_URL%/}"
OUTPUT_FILE="data/jamf-security-compliance.json"
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

# ─── Fetch Smart Group Counts ─────────────────────────────────────────────────
# Each group ID is read from a CI/CD variable; defaults to 0 if unset.
echo "Fetching smart group counts..."

FV_ENCRYPTED=$(fetch_group_count "${JAMF_SG_FV_ENCRYPTED:-0}")
FV_NOT_ENCRYPTED=$(fetch_group_count "${JAMF_SG_FV_NOT_ENCRYPTED:-0}")
CHECKIN_COMPLIANT=$(fetch_group_count "${JAMF_SG_CHECKIN_COMPLIANT:-0}")
CHECKIN_NONCOMPLIANT=$(fetch_group_count "${JAMF_SG_CHECKIN_NONCOMPLIANT:-0}")
DEFENDER_COMPLIANT=$(fetch_group_count "${JAMF_SG_DEFENDER_COMPLIANT:-0}")
DEFENDER_NONCOMPLIANT=$(fetch_group_count "${JAMF_SG_DEFENDER_NONCOMPLIANT:-0}")
PLATFORM_SSO_REGISTERED=$(fetch_group_count "${JAMF_SG_PLATFORM_SSO_REGISTERED:-0}")
ENTRA_NOT_REGISTERED=$(fetch_group_count "${JAMF_SG_ENTRA_NOT_REGISTERED:-0}")
ENTRA_OLD_COMPLIANCE=$(fetch_group_count "${JAMF_SG_ENTRA_OLD_COMPLIANCE:-0}")

echo "FileVault: ${FV_ENCRYPTED} encrypted / ${FV_NOT_ENCRYPTED} not encrypted"
echo "Check-In:  ${CHECKIN_COMPLIANT} compliant / ${CHECKIN_NONCOMPLIANT} non-compliant"
echo "Defender:  ${DEFENDER_COMPLIANT} compliant / ${DEFENDER_NONCOMPLIANT} non-compliant"
echo "Platform SSO: ${PLATFORM_SSO_REGISTERED} registered / ${ENTRA_OLD_COMPLIANCE} old compliance / ${ENTRA_NOT_REGISTERED} not registered"

# ─── Fetch Total Device Count + SIP Status via Inventory API ─────────────────
echo "Fetching inventory for total count and SIP status..."

PAGES_DIR=$(mktemp -d)
PAGE=0
TOTAL_COUNT=0

while true; do
  HTTP_STATUS=$(curl -s -o "${PAGES_DIR}/page_${PAGE}.json" -w "%{http_code}" \
    --request GET \
    --url "${JAMF_URL}/api/v1/computers-inventory?page-size=${PAGE_SIZE}&page=${PAGE}&section=GENERAL&section=SECURITY" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json")

  if [[ "${HTTP_STATUS}" -lt 200 || "${HTTP_STATUS}" -ge 300 ]]; then
    echo "ERROR: Jamf inventory API returned HTTP ${HTTP_STATUS}."
    cat "${PAGES_DIR}/page_${PAGE}.json"
    exit 1
  fi

  # Capture total count from first page
  if [[ "${PAGE}" -eq 0 ]]; then
    TOTAL_COUNT=$(jq '.totalCount // 0' "${PAGES_DIR}/page_${PAGE}.json")
    echo "Total devices in Jamf: ${TOTAL_COUNT}"
  fi

  COUNT=$(jq '.results | length' "${PAGES_DIR}/page_${PAGE}.json")
  echo "  Page ${PAGE}: ${COUNT} devices"

  if [[ "${COUNT}" -lt "${PAGE_SIZE}" ]]; then
    break
  fi

  PAGE=$((PAGE + 1))
done

# Merge all pages into a flat array of managed-only records
ALL_COMPUTERS_FILE=$(mktemp)
find "${PAGES_DIR}" -name 'page_*.json' | sort -t_ -k2 -n | \
  xargs jq -s '[.[].results[] | select(.general.remoteManagement.managed == true)]' \
  > "${ALL_COMPUTERS_FILE}"
rm -rf "${PAGES_DIR}"

MANAGED_TOTAL=$(jq 'length' "${ALL_COMPUTERS_FILE}")
echo "Managed computers: ${MANAGED_TOTAL}"

# Compute SIP counts — field is .security.sipStatus = "ENABLED" | "DISABLED"
SIP_ENABLED=$(jq '[.[] | select(.security.sipStatus == "ENABLED")] | length' "${ALL_COMPUTERS_FILE}")
SIP_DISABLED=$(jq -n --argjson total "${MANAGED_TOTAL}" --argjson enabled "${SIP_ENABLED}" '$total - $enabled')
echo "SIP: ${SIP_ENABLED} enabled / ${SIP_DISABLED} disabled/unknown"

# Bootstrap Token Escrowed (ESCROWED = compliant)
BT_ESCROWED=$(jq '[.[] | select(.security.bootstrapTokenEscrowedStatus == "ESCROWED")] | length' "${ALL_COMPUTERS_FILE}")
BT_NOT_ESCROWED=$(jq -n --argjson total "${MANAGED_TOTAL}" --argjson n "${BT_ESCROWED}" '$total - $n')

# Bootstrap Token Allowed (true = compliant)
BT_ALLOWED=$(jq '[.[] | select(.security.bootstrapTokenAllowed == true)] | length' "${ALL_COMPUTERS_FILE}")
BT_NOT_ALLOWED=$(jq -n --argjson total "${MANAGED_TOTAL}" --argjson n "${BT_ALLOWED}" '$total - $n')

# Attestation Status (SUCCESS = compliant)
ATTEST_SUPPORTED=$(jq '[.[] | select(.security.attestationStatus == "SUCCESS")] | length' "${ALL_COMPUTERS_FILE}")
ATTEST_OTHER=$(jq -n --argjson total "${MANAGED_TOTAL}" --argjson n "${ATTEST_SUPPORTED}" '$total - $n')

# Secure Boot Level (FULL_SECURITY = compliant)
SECURE_BOOT_FULL=$(jq '[.[] | select(.security.secureBootLevel == "FULL_SECURITY")] | length' "${ALL_COMPUTERS_FILE}")
SECURE_BOOT_OTHER=$(jq -n --argjson total "${MANAGED_TOTAL}" --argjson n "${SECURE_BOOT_FULL}" '$total - $n')

# Firewall Enabled (true = compliant)
FIREWALL_ON=$(jq '[.[] | select(.security.firewallEnabled == true)] | length' "${ALL_COMPUTERS_FILE}")
FIREWALL_OFF=$(jq -n --argjson total "${MANAGED_TOTAL}" --argjson n "${FIREWALL_ON}" '$total - $n')

echo "Bootstrap: escrowed=${BT_ESCROWED} allowed=${BT_ALLOWED} | Attestation: ${ATTEST_SUPPORTED} | SecureBoot: ${SECURE_BOOT_FULL} | Firewall: ${FIREWALL_ON}"

rm -f "${ALL_COMPUTERS_FILE}"

# ─── Invalidate Token ─────────────────────────────────────────────────────────
curl -sf \
  --request POST \
  --url "${JAMF_URL}/api/v1/auth/invalidate-token" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --output /dev/null || true

# ─── Write Output JSON ────────────────────────────────────────────────────────
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "${OUTPUT_FILE}")"

jq -n \
  --arg  generated_at          "${GENERATED_AT}" \
  --argjson total              "${MANAGED_TOTAL}" \
  --argjson fv_enc             "${FV_ENCRYPTED}" \
  --argjson fv_not             "${FV_NOT_ENCRYPTED}" \
  --argjson sip_on             "${SIP_ENABLED}" \
  --argjson sip_off            "${SIP_DISABLED}" \
  --argjson checkin_ok         "${CHECKIN_COMPLIANT}" \
  --argjson checkin_bad        "${CHECKIN_NONCOMPLIANT}" \
  --argjson defender_ok        "${DEFENDER_COMPLIANT}" \
  --argjson defender_bad       "${DEFENDER_NONCOMPLIANT}" \
  --argjson sso_registered     "${PLATFORM_SSO_REGISTERED}" \
  --argjson sso_old_compliance "${ENTRA_OLD_COMPLIANCE}" \
  --argjson sso_not_registered "${ENTRA_NOT_REGISTERED}" \
  --argjson bt_escrowed        "${BT_ESCROWED}" \
  --argjson bt_not_escrowed    "${BT_NOT_ESCROWED}" \
  --argjson bt_allowed         "${BT_ALLOWED}" \
  --argjson bt_not_allowed     "${BT_NOT_ALLOWED}" \
  --argjson attest_ok          "${ATTEST_SUPPORTED}" \
  --argjson attest_other       "${ATTEST_OTHER}" \
  --argjson secureboot_full    "${SECURE_BOOT_FULL}" \
  --argjson secureboot_other   "${SECURE_BOOT_OTHER}" \
  --argjson firewall_on        "${FIREWALL_ON}" \
  --argjson firewall_off       "${FIREWALL_OFF}" \
'{
  generated_at: $generated_at,
  summary: {
    total_devices: $total
  },
  checks: {
    filevault: {
      label:         "FileVault Encryption",
      icon:          "lock-fill",
      compliant:     $fv_enc,
      non_compliant: $fv_not
    },
    sip: {
      label:         "System Integrity Protection",
      icon:          "shield-lock-fill",
      compliant:     $sip_on,
      non_compliant: $sip_off
    },
    checkin: {
      label:         "Recent Check-In",
      icon:          "arrow-repeat",
      compliant:     $checkin_ok,
      non_compliant: $checkin_bad
    },
    defender: {
      label:         "Microsoft Defender",
      icon:          "shield-check",
      compliant:     $defender_ok,
      non_compliant: $defender_bad
    },
    platform_sso: {
      label:              "Platform SSO",
      icon:               "person-badge-fill",
      registered:         $sso_registered,
      old_compliance:     $sso_old_compliance,
      not_registered:     $sso_not_registered
    },
    bootstrap_escrowed: {
      label:         "Bootstrap Token Escrowed",
      icon:          "key-fill",
      compliant:     $bt_escrowed,
      non_compliant: $bt_not_escrowed
    },
    bootstrap_allowed: {
      label:         "Bootstrap Token Allowed",
      icon:          "key",
      compliant:     $bt_allowed,
      non_compliant: $bt_not_allowed
    },
    attestation: {
      label:         "Device Attestation",
      icon:          "patch-check-fill",
      compliant:     $attest_ok,
      non_compliant: $attest_other
    },
    secure_boot: {
      label:         "Secure Boot (Full Security)",
      icon:          "hdd-fill",
      compliant:     $secureboot_full,
      non_compliant: $secureboot_other
    },
    firewall: {
      label:         "Firewall",
      icon:          "reception-4",
      compliant:     $firewall_on,
      non_compliant: $firewall_off
    }
  }
}' > "${OUTPUT_FILE}"

echo "Output written to ${OUTPUT_FILE}"
echo "Summary: ${MANAGED_TOTAL} total | FV ${FV_ENCRYPTED}/${FV_NOT_ENCRYPTED} | SIP ${SIP_ENABLED}/${SIP_DISABLED} | Check-In ${CHECKIN_COMPLIANT}/${CHECKIN_NONCOMPLIANT} | Defender ${DEFENDER_COMPLIANT}/${DEFENDER_NONCOMPLIANT} | SSO ${PLATFORM_SSO_REGISTERED} | BT escrowed=${BT_ESCROWED} allowed=${BT_ALLOWED} | Attest=${ATTEST_SUPPORTED} | SecureBoot=${SECURE_BOOT_FULL} | Firewall=${FIREWALL_ON}"
