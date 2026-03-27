# =============================================================================
# Microsoft Intune — Windows Security Compliance
# =============================================================================
# Queries Microsoft Graph API for all Windows managed devices and computes
# security compliance metrics:
#   - BitLocker encryption  (isEncrypted)
#   - Intune compliance     (complianceState)
#
# Outputs data/intune-security-compliance.json for the dashboard.
#
# Required CI/CD variables:
#   INTUNE_TENANT_ID      Azure AD / Entra tenant ID
#   INTUNE_CLIENT_ID      App registration (client) ID
#   INTUNE_CLIENT_SECRET  App registration client secret  (masked)
# =============================================================================
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Configuration ────────────────────────────────────────────────────────────
$TenantId     = $env:INTUNE_TENANT_ID
$ClientId     = $env:INTUNE_CLIENT_ID
$ClientSecret = $env:INTUNE_CLIENT_SECRET
$OutputFile   = 'data/intune-security-compliance.json'

# ─── Obtain OAuth Access Token ────────────────────────────────────────────────
Write-Host "Authenticating with Microsoft Graph..."

$TokenUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$TokenBody = @{
    grant_type    = 'client_credentials'
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = 'https://graph.microsoft.com/.default'
}

$TokenResponse = Invoke-RestMethod -Uri $TokenUrl -Method Post `
    -Body $TokenBody -ContentType 'application/x-www-form-urlencoded'

$AccessToken = $TokenResponse.access_token
$Headers     = @{ Authorization = "Bearer $AccessToken" }

Write-Host "Authentication successful."

# ─── Fetch All Windows Managed Devices (paginated) ───────────────────────────
Write-Host "Fetching Windows managed devices from Intune..."

$AllDevices = [System.Collections.Generic.List[object]]::new()
$Url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
       "?`$filter=operatingSystem eq 'Windows'" +
       "&`$select=isEncrypted,complianceState,lastSyncDateTime,azureADRegistered" +
       "&`$top=999"

do {
    $Response = Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers
    foreach ($device in $Response.value) { $AllDevices.Add($device) }
    $Url = if ($Response.PSObject.Properties['@odata.nextLink']) { $Response.'@odata.nextLink' } else { $null }
} while ($Url)

$TotalDevices = $AllDevices.Count
Write-Host "Retrieved $TotalDevices Windows devices from Intune."

# ─── Compute Stats ────────────────────────────────────────────────────────────
$GeneratedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$BitLockerOn    = 0
$BitLockerOff   = 0
$CompCompliant  = 0
$CompOther      = 0   # noncompliant + unknown + notApplicable + inGracePeriod
$SyncCompliant  = 0   # lastSyncDateTime within 30 days
$SyncStale      = 0
$EntraRegistered    = 0
$EntraNotRegistered = 0

$CutoffDate = (Get-Date).ToUniversalTime().AddDays(-30)

foreach ($Device in $AllDevices) {
    # BitLocker
    if ($Device.isEncrypted -eq $true) { $BitLockerOn++ } else { $BitLockerOff++ }

    # Compliance state — 'compliant' is the only fully passing state
    if ($Device.complianceState -eq 'compliant') { $CompCompliant++ } else { $CompOther++ }

    # Recent sync — within 30 days
    $Synced = $false
    if ($Device.lastSyncDateTime) {
        $LastSync = [DateTimeOffset]::Parse($Device.lastSyncDateTime)
        if ($LastSync.UtcDateTime -ge $CutoffDate) { $Synced = $true }
    }
    if ($Synced) { $SyncCompliant++ } else { $SyncStale++ }

    # Entra ID (Azure AD) registration
    if ($Device.azureADRegistered -eq $true) { $EntraRegistered++ } else { $EntraNotRegistered++ }
}

Write-Host "BitLocker: $BitLockerOn encrypted / $BitLockerOff not encrypted"
Write-Host "Compliance: $CompCompliant compliant / $CompOther non-compliant or unknown"
Write-Host "Recent Sync: $SyncCompliant within 30d / $SyncStale stale"
Write-Host "Entra ID: $EntraRegistered registered / $EntraNotRegistered not registered"

# ─── Write JSON Output ────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile) | Out-Null

$Output = [PSCustomObject]@{
    generated_at = $GeneratedAt
    summary      = [PSCustomObject]@{
        total_devices = $TotalDevices
    }
    checks       = [PSCustomObject]@{
        bitlocker = [PSCustomObject]@{
            label         = 'BitLocker Encryption'
            icon          = 'lock-fill'
            compliant     = $BitLockerOn
            non_compliant = $BitLockerOff
        }
        compliance_state = [PSCustomObject]@{
            label         = 'Intune Compliance'
            icon          = 'shield-check'
            compliant     = $CompCompliant
            non_compliant = $CompOther
        }
        recent_sync = [PSCustomObject]@{
            label         = 'Recent Sync (30 days)'
            icon          = 'arrow-repeat'
            compliant     = $SyncCompliant
            non_compliant = $SyncStale
        }
        entra_registered = [PSCustomObject]@{
            label         = 'Entra ID Registered'
            icon          = 'person-badge-fill'
            compliant     = $EntraRegistered
            non_compliant = $EntraNotRegistered
        }
    }
}

$Output | ConvertTo-Json -Depth 10 |
    Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "Output written to $OutputFile"
Write-Host "Summary: $TotalDevices total | BitLocker: $BitLockerOn/$BitLockerOff | Compliance: $CompCompliant/$CompOther | Sync: $SyncCompliant/$SyncStale | Entra: $EntraRegistered/$EntraNotRegistered"
