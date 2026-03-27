# =============================================================================
# Microsoft Intune — Windows Hardware Report
# =============================================================================
# Queries Microsoft Graph API for all Windows managed devices, computes
# hardware statistics (manufacturer breakdown, top models, enrollment by year),
# and writes data/intune-hardware-stats.json for the dashboard.
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
$OutputFile   = 'data/intune-hardware-stats.json'

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Dell 7-char service tags encode manufacture year at index 4.
# Mapping: A=2010 B=2011 ... H=2017 (no I) J=2018 K=2019 L=2020 M=2021 N=2022 P=2023 R=2024 S=2025
function Get-DellYear {
    param([string]$Serial)
    if ($Serial.Length -lt 5) { return $null }
    $map = @{ A=2010;B=2011;C=2012;D=2013;E=2014;F=2015;G=2016;H=2017;
              J=2018;K=2019;L=2020;M=2021;N=2022;P=2023;R=2024;S=2025 }
    $ch = $Serial[4].ToString().ToUpper()
    if ($map.ContainsKey($ch)) { return $map[$ch] } else { return $null }
}

function Get-ManufactureYear {
    param([string]$Manufacturer, [string]$Serial)
    $norm = Normalize-Manufacturer $Manufacturer
    if ($norm -eq 'Dell') {
        $yr = Get-DellYear -Serial $Serial
        if ($null -ne $yr) { return $yr.ToString() }
    }
    return $null
}

# ─── Normalise Manufacturer Name ─────────────────────────────────────────────
function Normalize-Manufacturer {
    param([string]$Raw)
    $s = ($Raw ?? '').Trim()
    switch -Regex ($s) {
        '(?i)^dell'                    { return 'Dell' }
        '(?i)^hp|hewlett'              { return 'HP' }
        '(?i)^lenovo'                  { return 'Lenovo' }
        '(?i)^microsoft'               { return 'Microsoft' }
        '(?i)^samsung'                 { return 'Samsung' }
        '(?i)^panasonic'               { return 'Panasonic' }
        '(?i)^toshiba'                 { return 'Toshiba' }
        '(?i)^acer'                    { return 'Acer' }
        '(?i)^asus'                    { return 'ASUS' }
        '(?i)^apple'                   { return 'Apple' }
        default {
            if ($s -eq '') { return 'Unknown' }
            return $s
        }
    }
}

# ─── Lenovo Machine-Type → Friendly Model Name ───────────────────────────────
# Intune reports Lenovo models as the raw machine-type code (e.g. "20Y4S2BT07").
# The first 4 characters identify the product line; we map those to human names.
# Devices not in this table fall back to "Lenovo <TYPE>" (e.g. "Lenovo 20Y4").
$LenovoMachineTypes = @{
    # ThinkPad X1 Carbon
    '20HR'='ThinkPad X1 Carbon Gen 5';  '20HQ'='ThinkPad X1 Carbon Gen 5'
    '20KG'='ThinkPad X1 Carbon Gen 6';  '20KH'='ThinkPad X1 Carbon Gen 6'
    '20L7'='ThinkPad X1 Carbon Gen 6';  '20L8'='ThinkPad X1 Carbon Gen 6'
    '20QD'='ThinkPad X1 Carbon Gen 7';  '20QE'='ThinkPad X1 Carbon Gen 7'
    '20R1'='ThinkPad X1 Carbon Gen 8';  '20R2'='ThinkPad X1 Carbon Gen 8'
    '20U9'='ThinkPad X1 Carbon Gen 8';  '20UA'='ThinkPad X1 Carbon Gen 8'
    '20XW'='ThinkPad X1 Carbon Gen 9';  '20XX'='ThinkPad X1 Carbon Gen 9'
    '20XS'='ThinkPad X1 Carbon Gen 9';  '20XT'='ThinkPad X1 Carbon Gen 9'
    '21CB'='ThinkPad X1 Carbon Gen 10'; '21CC'='ThinkPad X1 Carbon Gen 10'
    '21HM'='ThinkPad X1 Carbon Gen 11'; '21HN'='ThinkPad X1 Carbon Gen 11'
    '21KC'='ThinkPad X1 Carbon Gen 12'; '21KD'='ThinkPad X1 Carbon Gen 12'
    # ThinkPad X1 Yoga
    '20LD'='ThinkPad X1 Yoga Gen 3';    '20LE'='ThinkPad X1 Yoga Gen 3'
    '20QF'='ThinkPad X1 Yoga Gen 4';    '20QG'='ThinkPad X1 Yoga Gen 4'
    '20SA'='ThinkPad X1 Yoga Gen 5';    '20SB'='ThinkPad X1 Yoga Gen 5'
    '20XY'='ThinkPad X1 Yoga Gen 6';    '20XZ'='ThinkPad X1 Yoga Gen 6'
    '21CD'='ThinkPad X1 Yoga Gen 7';    '21CE'='ThinkPad X1 Yoga Gen 7'
    '21HK'='ThinkPad X1 Yoga Gen 8';    '21HL'='ThinkPad X1 Yoga Gen 8'
    # ThinkPad X1 Extreme
    '20MF'='ThinkPad X1 Extreme Gen 1'; '20MG'='ThinkPad X1 Extreme Gen 1'
    '20QV'='ThinkPad X1 Extreme Gen 2'; '20QW'='ThinkPad X1 Extreme Gen 2'
    '20TK'='ThinkPad X1 Extreme Gen 3'; '20TL'='ThinkPad X1 Extreme Gen 3'
    '21DE'='ThinkPad X1 Extreme Gen 5'; '21DF'='ThinkPad X1 Extreme Gen 5'
    # ThinkPad T series
    '20JM'='ThinkPad T470';     '20JN'='ThinkPad T470'
    '20HD'='ThinkPad T470s';    '20JS'='ThinkPad T470s'
    '20L5'='ThinkPad T480';     '20L6'='ThinkPad T480'
    '20L3'='ThinkPad T480s';    '20L4'='ThinkPad T480s'
    '20Q1'='ThinkPad T490';     '20Q2'='ThinkPad T490'
    '20N2'='ThinkPad T490s';    '20NX'='ThinkPad T490s'
    '20L9'='ThinkPad T580';     '20LA'='ThinkPad T580'
    '20N3'='ThinkPad T590';     '20N4'='ThinkPad T590'
    '20S0'='ThinkPad T14 Gen 1'; '20S1'='ThinkPad T14 Gen 1'
    '20UD'='ThinkPad T14 Gen 1'; '20UE'='ThinkPad T14 Gen 1'
    '20W0'='ThinkPad T14 Gen 2'; '20W1'='ThinkPad T14 Gen 2'
    '20XK'='ThinkPad T14 Gen 2'; '20XL'='ThinkPad T14 Gen 2'
    '21AH'='ThinkPad T14 Gen 3'; '21AK'='ThinkPad T14 Gen 3'
    '21CF'='ThinkPad T14 Gen 4'; '21CG'='ThinkPad T14 Gen 4'
    '21ML'='ThinkPad T14 Gen 5'; '21MM'='ThinkPad T14 Gen 5'
    '20S5'='ThinkPad T15 Gen 1'; '20S6'='ThinkPad T15 Gen 1'
    '20W2'='ThinkPad T15 Gen 2'; '20W3'='ThinkPad T15 Gen 2'
    '21A7'='ThinkPad T15 Gen 3'; '21A8'='ThinkPad T15 Gen 3'
    '21CH'='ThinkPad T16 Gen 1'; '21CS'='ThinkPad T16 Gen 1'
    '21HH'='ThinkPad T16 Gen 2'; '21HJ'='ThinkPad T16 Gen 2'
    # ThinkPad L series
    '20U7'='ThinkPad L14 Gen 1'; '20U8'='ThinkPad L14 Gen 1'
    '20X1'='ThinkPad L14 Gen 2'; '20X2'='ThinkPad L14 Gen 2'
    '21C5'='ThinkPad L14 Gen 3'; '21C6'='ThinkPad L14 Gen 3'
    '21H5'='ThinkPad L14 Gen 4'; '21H6'='ThinkPad L14 Gen 4'
    '20U3'='ThinkPad L15 Gen 1'; '20U4'='ThinkPad L15 Gen 1'
    '20X3'='ThinkPad L15 Gen 2'; '20X4'='ThinkPad L15 Gen 2'
    '21C7'='ThinkPad L15 Gen 3'; '21C8'='ThinkPad L15 Gen 3'
    '21H7'='ThinkPad L15 Gen 4'; '21H8'='ThinkPad L15 Gen 4'
    # ThinkPad E series
    '20RA'='ThinkPad E14 Gen 1'; '20RB'='ThinkPad E14 Gen 1'
    '20TA'='ThinkPad E14 Gen 2'; '20TB'='ThinkPad E14 Gen 2'
    '21E3'='ThinkPad E14 Gen 4'; '21E4'='ThinkPad E14 Gen 4'
    '21JK'='ThinkPad E14 Gen 5'; '21JL'='ThinkPad E14 Gen 5'
    '20RD'='ThinkPad E15 Gen 1'; '20RE'='ThinkPad E15 Gen 1'
    '20T8'='ThinkPad E15 Gen 2'; '20T9'='ThinkPad E15 Gen 2'
    '21E6'='ThinkPad E15 Gen 4'; '21E7'='ThinkPad E15 Gen 4'
    # ThinkPad P series
    '20V9'='ThinkPad P14s Gen 1'; '20VA'='ThinkPad P14s Gen 1'
    '21A0'='ThinkPad P14s Gen 3'; '21AQ'='ThinkPad P14s Gen 3'
    '21D8'='ThinkPad P14s Gen 4'
    '20VB'='ThinkPad P15s Gen 1'; '20VC'='ThinkPad P15s Gen 1'
    '20W6'='ThinkPad P15s Gen 2'; '20W7'='ThinkPad P15s Gen 2'
    # ThinkCentre M series
    '11D3'='ThinkCentre M70q Gen 2'
    '11UB'='ThinkCentre M70q Gen 3'
    '11QN'='ThinkCentre M75q Gen 2'
    '12E9'='ThinkCentre M75q Gen 5'
    '11JA'='ThinkCentre M90s Gen 2'
    '11WD'='ThinkCentre M90q Gen 3'
    '12A1'='ThinkCentre M90q Gen 4'
}

function Get-FriendlyModel {
    param([string]$Manufacturer, [string]$Model)
    $norm = Normalize-Manufacturer $Manufacturer
    if ($norm -ne 'Lenovo') { return $Model }
    $m = $Model.Trim()
    if ($m.Length -lt 4) { return $m }
    # If the model already looks friendly (contains spaces or a brand keyword), keep it as-is.
    if ($m -match '\s' -or $m -match '(?i)^(thinkpad|thinkcentre|thinkstation|ideapad|yoga|legion)') {
        return $m
    }
    # Look up the 4-char machine type; fall back to "Lenovo <TYPE>" to at least group variants.
    $type = $m.Substring(0, 4).ToUpper()
    if ($LenovoMachineTypes.ContainsKey($type)) { return $LenovoMachineTypes[$type] }
    return "Lenovo $type"
}

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
       "&`$select=deviceName,serialNumber,model,manufacturer,enrolledDateTime,osVersion,totalStorageSpaceInBytes,freeStorageSpaceInBytes" +
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

$MfgGroups    = [ordered]@{}
$ModelGroups  = [ordered]@{}
$YearGroups   = [ordered]@{}
$Win11Count   = 0
$Win10Count   = 0
$YearKnown    = 0
$AgeLt2       = 0
$Age2to4      = 0
$AgeGt4       = 0
$AgeUnknown   = 0
$Now          = (Get-Date).ToUniversalTime()
$StorageLt50  = 0   # used < 50%
$Storage50to75 = 0  # used 50–75%
$Storage75to90 = 0  # used 75–90%
$StorageGt90  = 0   # used ≥ 90% (almost full)
$StorageUnknown = 0
$AlmostFullThresholdPct = 80  # flag at ≥ 80% used

foreach ($Device in $AllDevices) {
    # Manufacturer
    $Mfg = Normalize-Manufacturer ($Device.manufacturer ?? '')
    if (-not $MfgGroups.Contains($Mfg)) { $MfgGroups[$Mfg] = 0 }
    $MfgGroups[$Mfg]++

    # Model — resolve to friendly name (Lenovo lookup) or raw value for others
    $Model = Get-FriendlyModel -Manufacturer ($Device.manufacturer ?? '') `
                               -Model        (($Device.model ?? '').Trim())
    if ($Model -eq '') { $Model = 'Unknown' }
    if (-not $ModelGroups.Contains($Model)) { $ModelGroups[$Model] = 0 }
    $ModelGroups[$Model]++

    # OS version — classify Win11 vs Win10
    $Build = 0
    if ($Device.osVersion) {
        $osParts = $Device.osVersion -split '\.'        
        if ($osParts.Count -ge 3) { $Build = [int]$osParts[2] }
    }
    if     ($Build -ge 22000) { $Win11Count++ }
    elseif ($Build -gt  0)    { $Win10Count++ }

    # Year — serial-decoded manufacture year only; exclude unknowns from chart
    $Year = Get-ManufactureYear -Manufacturer ($Device.manufacturer ?? '') `
                                -Serial       ($Device.serialNumber  ?? '')
    if ($null -ne $Year) {
        if (-not $YearGroups.Contains($Year)) { $YearGroups[$Year] = 0 }
        $YearGroups[$Year]++
        $YearKnown++
    }

    # Storage — bucketed by % used; both fields must be non-zero to be meaningful
    $TotalBytes = [long]($Device.totalStorageSpaceInBytes ?? 0)
    $FreeBytes  = [long]($Device.freeStorageSpaceInBytes  ?? 0)
    if ($TotalBytes -gt 0) {
        $UsedPct = [Math]::Round((($TotalBytes - $FreeBytes) / $TotalBytes) * 100)
        if     ($UsedPct -lt 50) { $StorageLt50++   }
        elseif ($UsedPct -lt 75) { $Storage50to75++ }
        elseif ($UsedPct -lt 90) { $Storage75to90++ }
        else                      { $StorageGt90++   }
    } else {
        $StorageUnknown++
    }

    # Device age — bucketed from enrolledDateTime (available for all devices)
    if ($Device.enrolledDateTime) {
        $enrolled = [DateTime]::Parse($Device.enrolledDateTime, $null,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
        $ageYears = ($Now - $enrolled).TotalDays / 365.25
        if     ($ageYears -lt 2) { $AgeLt2++ }
        elseif ($ageYears -lt 4) { $Age2to4++ }
        else                      { $AgeGt4++ }
    } else {
        $AgeUnknown++
    }
}

# Manufacturer breakdown — top 7 + "Other"
$SortedMfg = $MfgGroups.GetEnumerator() | Sort-Object Value -Descending
$TopMfg    = [System.Collections.Generic.List[PSCustomObject]]::new()
$OtherCount = 0
$Rank = 0
foreach ($entry in $SortedMfg) {
    $Rank++
    if ($Rank -le 7) {
        $TopMfg.Add([PSCustomObject]@{ manufacturer = $entry.Key; count = $entry.Value })
    } else {
        $OtherCount += $entry.Value
    }
}
if ($OtherCount -gt 0) {
    $TopMfg.Add([PSCustomObject]@{ manufacturer = 'Other'; count = $OtherCount })
}

# Top models — top 20 by count
$TopModels = $ModelGroups.GetEnumerator() |
    Sort-Object Value -Descending |
    Select-Object -First 20 |
    ForEach-Object { [PSCustomObject]@{ model = $_.Key; count = $_.Value } }

# Models by year — ascending
$ByYear = $YearGroups.GetEnumerator() |
    Sort-Object Key |
    ForEach-Object { [PSCustomObject]@{ year = $_.Key; count = $_.Value } }

# ─── Storage Buckets ────────────────────────────────────────────────────────
$StorageKnown = $StorageLt50 + $Storage50to75 + $Storage75to90 + $StorageGt90
$WinStorageData = [PSCustomObject]@{
    total           = [int]($StorageKnown + $StorageUnknown)
    almost_full_count           = [int]$StorageGt90
    almost_full_threshold_pct   = [int]$AlmostFullThresholdPct
    unknown_count   = [int]$StorageUnknown
    buckets         = @(
        [PSCustomObject]@{ label = '< 50% used';   count = [int]$StorageLt50   }
        [PSCustomObject]@{ label = '50–75% used';  count = [int]$Storage50to75 }
        [PSCustomObject]@{ label = '75–90% used';  count = [int]$Storage75to90 }
        [PSCustomObject]@{ label = '≥ 90% used';   count = [int]$StorageGt90   }
    )
}

# ─── Device Age Buckets ──────────────────────────────────────────────────────
$DeviceAgeData = [PSCustomObject]@{
    total   = [int]($AgeLt2 + $Age2to4 + $AgeGt4 + $AgeUnknown)
    buckets = @(
        [PSCustomObject]@{ label = '< 2 years';  count = [int]$AgeLt2  }
        [PSCustomObject]@{ label = '2–4 years';  count = [int]$Age2to4 }
        [PSCustomObject]@{ label = '> 4 years';  count = [int]$AgeGt4  }
    )
    unknown_count = [int]$AgeUnknown
}

# ─── Write JSON Output ────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile) | Out-Null

$Output = [PSCustomObject]@{
    generated_at              = $GeneratedAt
    summary                   = [PSCustomObject]@{
        total_devices      = $TotalDevices
        windows_11         = $Win11Count
        windows_10         = $Win10Count
        year_known_count   = $YearKnown
    }
    manufacturers_breakdown   = @($TopMfg)
    top_models                = @($TopModels)
    models_by_year            = @($ByYear)
    win_storage               = $WinStorageData
    device_age                = $DeviceAgeData
}

$Output | ConvertTo-Json -Depth 10 |
    Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "Output written to $OutputFile"
Write-Host "Summary: $TotalDevices total | Win11: $Win11Count | Win10: $Win10Count | $($TopMfg.Count) manufacturers"
