# =============================================================================
# Microsoft Intune — Enrollment Stats Fetcher
# =============================================================================
# Queries Microsoft Graph API for all Windows managed devices, computes
# enrollment statistics, and writes data/intune-enrollment-stats.json for
# the dashboard.
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
$OutputFile   = 'data/intune-enrollment-stats.json'

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
       "&`$select=deviceName,serialNumber,enrolledDateTime,lastSyncDateTime" +
       "&`$top=999"

do {
    $Response = Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers
    foreach ($device in $Response.value) { $AllDevices.Add($device) }
    $Url = if ($Response.PSObject.Properties['@odata.nextLink']) { $Response.'@odata.nextLink' } else { $null }
} while ($Url)

$TotalDevices = $AllDevices.Count
Write-Host "Retrieved $TotalDevices Windows devices from Intune."

# ─── Compute Enrollment Stats ─────────────────────────────────────────────────
$GeneratedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$Now         = [DateTimeOffset]::UtcNow
$Cutoff24h   = $Now.AddHours(-24)
$Cutoff30d   = $Now.AddDays(-30)

$Enrolled24h = 0
$Enrolled30d = 0
$ByYear      = [ordered]@{}

foreach ($Device in $AllDevices) {
    $EnrolledRaw = $Device.enrolledDateTime
    if (-not $EnrolledRaw) { continue }

    $EnrolledAt = [DateTimeOffset]::Parse($EnrolledRaw)
    $Year       = $EnrolledAt.Year.ToString()

    if ($EnrolledAt -ge $Cutoff24h) { $Enrolled24h++ }
    if ($EnrolledAt -ge $Cutoff30d) { $Enrolled30d++ }

    if (-not $ByYear.Contains($Year)) { $ByYear[$Year] = 0 }
    $ByYear[$Year]++
}

# Sort by year ascending
$EnrollmentsByYear = $ByYear.GetEnumerator() | Sort-Object Key | ForEach-Object {
    [PSCustomObject]@{ year = $_.Key; count = $_.Value }
}

# ─── Write JSON Output ────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile) | Out-Null

$Output = [PSCustomObject]@{
    generated_at       = $GeneratedAt
    summary            = [PSCustomObject]@{
        total_enrolled    = $TotalDevices
        enrolled_last_24h = $Enrolled24h
        enrolled_last_30d = $Enrolled30d
    }
    enrollments_by_year = @($EnrollmentsByYear)
}

$Output | ConvertTo-Json -Depth 10 |
    Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "Output written to $OutputFile"
Write-Host "Summary: $TotalDevices total | $Enrolled24h last 24h | $Enrolled30d last 30d"
