# =============================================================================
# Microsoft Intune — Windows OS Compliance Data Fetcher
# =============================================================================
# Queries Microsoft Graph API for all Windows managed devices, computes OS
# compliance against dynamically fetched Windows lifecycle data from
# endoflife.date, and writes a JSON summary to data/intune-os-compliance.json.
#
# Compliance rule: a device is compliant if its OS build matches any currently
# maintained Windows release (isMaintained == true) according to endoflife.date.
# IoT variants are excluded. If endoflife.date is unreachable the script falls
# back to INTUNE_MIN_WINDOWS_BUILD (or 10.0.22621 if not set).
#
# Prerequisites in Entra ID (Azure AD):
#   1. Register an app in Entra ID (App registrations)
#   2. Add API permission: DeviceManagementManagedDevices.Read.All (Application)
#   3. Grant admin consent
#   4. Create a client secret and copy the value
#
# Required CI/CD variables:
#   INTUNE_TENANT_ID      Azure AD / Entra tenant ID
#   INTUNE_CLIENT_ID      App registration (client) ID
#   INTUNE_CLIENT_SECRET  App registration client secret  (masked)
#
# Optional CI/CD variables:
#   INTUNE_MIN_WINDOWS_BUILD  Fallback minimum build if endoflife.date is
#                             unreachable (default: 10.0.22621)
# =============================================================================
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Configuration ────────────────────────────────────────────────────────────
$TenantId     = $env:INTUNE_TENANT_ID
$ClientId     = $env:INTUNE_CLIENT_ID
$ClientSecret = $env:INTUNE_CLIENT_SECRET
$FallbackBuild = if ($env:INTUNE_MIN_WINDOWS_BUILD) { $env:INTUNE_MIN_WINDOWS_BUILD } else { '10.0.22621' }
# N-rule: number of previous feature releases to count as compliant (in addition to latest).
# N=2 (default) -> latest + 2 prior = 3 total feature releases. Same convention as JAMF_N_RULE.
$NRule        = if ($env:INTUNE_N_RULE) { [int]$env:INTUNE_N_RULE } else { 2 }
$OutputFile   = 'data/intune-os-compliance.json'

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

# ─── Fetch Windows Lifecycle Data from endoflife.date ────────────────────────
# Compliance = device build matches any currently maintained Windows release.
# IoT variants are excluded; E/W editions sharing the same build deduplicate
# naturally so all maintained enterprise builds are represented.
Write-Host "Fetching Windows release lifecycle data from endoflife.date..."

$CompliantBuilds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$EolSource   = 'endoflife.date'
$NRuleActual = $NRule
$LtscCount   = 0

try {
    $EolResponse = Invoke-RestMethod -Uri 'https://endoflife.date/api/v1/products/windows' `
        -Method Get -TimeoutSec 30

    $MaintainedReleases = $EolResponse.result.releases | Where-Object {
        $_.isMaintained -eq $true -and
        $_.name         -notmatch 'iot' -and
        $_.latest.name  -match    '^\d+\.\d+\.\d+'
    }

    # Separate LTS/LTSC from feature releases.
    # LTS builds are always compliant — they are intentionally long-term.
    # Feature releases are subject to the N-rule: latest + N prior = N+1 total.
    $LtscSet     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $FeatureSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $FeatureList = [System.Collections.Generic.List[string]]::new()

    foreach ($r in $MaintainedReleases) {
        $parts = $r.latest.name -split '\.'
        if ($parts.Count -ge 3) {
            $build = "$($parts[0]).$($parts[1]).$($parts[2])"
            if ($r.isLts) {
                $null = $LtscSet.Add($build)
            } else {
                if ($FeatureSet.Add($build)) {
                    $FeatureList.Add($build)
                }
            }
        }
    }

    # Sort feature builds newest -> oldest and take the top N+1
    $TopFeature = $FeatureList | Sort-Object {
        $p = $_ -split '\.'
        [long]$p[0] * 1000000000L + [long]$p[1] * 1000000L + [long]$p[2]
    } -Descending | Select-Object -First ($NRule + 1)

    foreach ($b in $TopFeature) { $null = $CompliantBuilds.Add($b) }
    foreach ($b in $LtscSet)    { $null = $CompliantBuilds.Add($b) }

    $LtscCount = $LtscSet.Count
    Write-Host "N-rule: $NRule -> $($NRule + 1) feature release(s) + $LtscCount LTSC build(s) = $($CompliantBuilds.Count) compliant build(s)"
} catch {
    Write-Warning "Could not reach endoflife.date: $_"
    Write-Warning "Falling back to INTUNE_MIN_WINDOWS_BUILD ($FallbackBuild)."
    $null = $CompliantBuilds.Add($FallbackBuild)
    $EolSource   = 'fallback'
    $NRuleActual = 0
}

# ─── Fetch All Windows Managed Devices (paginated) ───────────────────────────
Write-Host "Fetching Windows managed devices from Intune..."

$AllDevices = [System.Collections.Generic.List[object]]::new()
$Url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
       "?`$filter=operatingSystem eq 'Windows'" +
       "&`$select=deviceName,serialNumber,osVersion,lastSyncDateTime" +
       "&`$top=999"

do {
    $Response = Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers
    foreach ($device in $Response.value) { $AllDevices.Add($device) }
    $Url = if ($Response.PSObject.Properties['@odata.nextLink']) { $Response.'@odata.nextLink' } else { $null }
} while ($Url)

$TotalDevices = $AllDevices.Count
Write-Host "Retrieved $TotalDevices Windows devices from Intune."

# ─── Compute Compliance & Build Summary ───────────────────────────────────────
$GeneratedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$CompliantCount    = 0
$NonCompliantCount = 0
$OsGroups          = [ordered]@{}

foreach ($Device in $AllDevices) {
    # Normalise: strip patch/build suffix to keep major.minor.build (first 3 parts)
    $RawVersion = $Device.osVersion
    if (-not $RawVersion) { $RawVersion = '0.0.0' }

    $Parts        = $RawVersion -split '\.'
    $BuildVersion = "$($Parts[0]).$($Parts[1]).$($Parts[2])"
    $IsCompliant  = $CompliantBuilds.Contains($BuildVersion)

    if ($IsCompliant) { $CompliantCount++ } else { $NonCompliantCount++ }

    if (-not $OsGroups.Contains($BuildVersion)) {
        $OsGroups[$BuildVersion] = @{ count = 0; compliant = $IsCompliant }
    }
    $OsGroups[$BuildVersion].count++
}

$CompliancePct = if ($TotalDevices -gt 0) {
    [Math]::Round(($CompliantCount / $TotalDevices) * 100)
} else { 0 }

# Sort distribution newest → oldest
$OsDistribution = $OsGroups.GetEnumerator() | Sort-Object -Property {
    $Parts = $_.Key -split '\.'
    [long]$Parts[0] * 1000000000L + [long]$Parts[1] * 1000000L + [long]$Parts[2]
} -Descending | ForEach-Object {
    [PSCustomObject]@{
        version   = $_.Key
        count     = $_.Value.count
        compliant = $_.Value.compliant
    }
}

# First 100 non-compliant devices for the dashboard table
$NonCompliantDevices = $AllDevices |
    Where-Object {
        $Prt = ($_.osVersion ?? '0.0.0') -split '\.'
        $Bld = "$($Prt[0]).$($Prt[1]).$($Prt[2])"
        -not $CompliantBuilds.Contains($Bld)
    } |
    Sort-Object osVersion |
    Select-Object -First 100 |
    ForEach-Object {
        [PSCustomObject]@{
            name       = $_.deviceName       ?? 'Unknown'
            serial     = $_.serialNumber     ?? ''
            os_version = $_.osVersion        ?? 'Unknown'
            last_seen  = $_.lastSyncDateTime ?? $null
        }
    }

# ─── Write JSON Output ────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile) | Out-Null

$Output = [PSCustomObject]@{
    generated_at     = $GeneratedAt
    eol_source       = $EolSource
    n_rule           = $NRuleActual
    compliance_rule  = if ($EolSource -eq 'endoflife.date') {
        "N=$NRuleActual (latest + $NRuleActual prior feature release(s) + maintained LTSC)"
    } else {
        "fallback minimum build"
    }
    compliant_builds = @(
        $CompliantBuilds | Sort-Object {
            $p = $_ -split '\.'
            [long]$p[0] * 1000000000L + [long]$p[1] * 1000000L + [long]$p[2]
        } -Descending
    )
    # min_version kept for backward compatibility: oldest compliant build
    min_version      = (
        $CompliantBuilds | Sort-Object {
            $p = $_ -split '\.'
            [long]$p[0] * 1000000000L + [long]$p[1] * 1000000L + [long]$p[2]
        } | Select-Object -First 1
    )
    summary      = [PSCustomObject]@{
        total_devices          = $TotalDevices
        compliant              = $CompliantCount
        non_compliant          = $NonCompliantCount
        compliance_percentage  = $CompliancePct
    }
    os_distribution       = @($OsDistribution)
    non_compliant_devices = @($NonCompliantDevices)
}

$Output | ConvertTo-Json -Depth 10 |
    Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "Output written to $OutputFile"
Write-Host "Summary: $TotalDevices total | $CompliantCount compliant | $NonCompliantCount non-compliant"
