# =============================================================================
# Microsoft Intune — Application Inventory Fetcher
# =============================================================================
# Queries Microsoft Graph API for all detected Windows applications, groups
# by application name to build a version distribution, and writes
# data/intune-app-inventory.json for the dashboard.
#
# Uses the detectedApps endpoint which returns one record per (app, version)
# pair along with the device count for that version — no per-device expansion
# required.
#
# Output JSON shape (data/intune-app-inventory.json):
# {
#   "generated_at": "...",
#   "platform":     "Windows",
#   "total_devices": 300,
#   "application_count": 2104,
#   "applications": [
#     {
#       "name": "Google Chrome",
#       "device_count": 290,
#       "versions": [
#         { "version": "122.0.6261.128", "count": 210 },
#         { "version": "122.0.6261.94",  "count":  80 }
#       ]
#     }
#   ]
# }
#
# Applications sorted by device_count descending.
# Versions within each app sorted by count descending.
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
$OutputFile   = 'data/intune-app-inventory.json'

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

# ─── Get Total Windows Device Count ──────────────────────────────────────────
# Uses $count with ConsistencyLevel: eventual for an efficient single-call count.
Write-Host "Counting total Windows managed devices..."

$CountHeaders = @{
    Authorization    = "Bearer $AccessToken"
    ConsistencyLevel = 'eventual'
}
$CountUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
            "?`$filter=operatingSystem eq 'Windows'&`$count=true&`$top=1&`$select=id"

$CountResponse = Invoke-RestMethod -Uri $CountUrl -Method Get -Headers $CountHeaders
$TotalDevices  = [int]$CountResponse.'@odata.count'

Write-Host "Total Windows devices: $TotalDevices"

# ─── Fetch All Detected Windows Apps (paginated) ─────────────────────────────
# detectedApps returns one record per (app, version) pair with deviceCount already
# computed by Intune — no per-device expansion needed.
Write-Host "Fetching detected Windows applications from Intune..."

$AllApps = [System.Collections.Generic.List[object]]::new()
$Url = "https://graph.microsoft.com/v1.0/deviceManagement/detectedApps" +
       "?`$select=displayName,version,deviceCount,platform" +
       "&`$top=999"

do {
    $Response = Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers
    foreach ($app in $Response.value) {
        # Filter client-side: keep only Windows platform entries.
        # The detectedApps endpoint does not support $filter on platform.
        $p = ($app.platform ?? '').ToLower()
        if ($p -eq 'windows' -or $p -eq 'windowsmobile' -or $p -eq 'windowsholographic') {
            $AllApps.Add($app)
        }
    }
    $Url = if ($Response.PSObject.Properties['@odata.nextLink']) {
        $Response.'@odata.nextLink'
    } else {
        $null
    }
} while ($Url)

Write-Host "Retrieved $($AllApps.Count) (app, version) records from Intune."

# ─── Aggregate into Per-App Version Distributions ────────────────────────────
Write-Host "Building application inventory..."

# Group by displayName (case-sensitive as returned by Graph API)
$Grouped = $AllApps | Group-Object -Property displayName

$Apps = foreach ($group in $Grouped) {
    # Normalise version strings
    $versions = $group.Group |
        Sort-Object -Property deviceCount -Descending |
        ForEach-Object {
            $ver = if ([string]::IsNullOrWhiteSpace($_.version)) { 'Unknown' } else { $_.version.Trim() }
            [PSCustomObject]@{
                version = $ver
                count   = [int]$_.deviceCount
            }
        }

    # Sum deviceCount across all versions of this app.
    # Intune deduplicates per-version, so this is the best available
    # approximation of "unique devices with this app installed".
    $totalCount = [int]($group.Group | Measure-Object -Property deviceCount -Sum).Sum

    [PSCustomObject]@{
        name         = $group.Name
        device_count = $totalCount
        versions     = @($versions)
    }
}

# Sort most-deployed apps first
$Apps = @($Apps | Sort-Object -Property device_count -Descending)

$AppCount = $Apps.Count
Write-Host "Found $AppCount unique Windows applications."

# ─── Build Output JSON ────────────────────────────────────────────────────────
$Output = [PSCustomObject]@{
    generated_at      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)
    platform          = 'Windows'
    total_devices     = $TotalDevices
    application_count = $AppCount
    applications      = $Apps
}

$null = New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile)
$Output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "Done. Output written to $OutputFile"
