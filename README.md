# EDM Reporting Dashboard

[![Bootstrap](https://img.shields.io/badge/Bootstrap-5.3-7952B3?logo=bootstrap&logoColor=white)](https://getbootstrap.com)
[![Chart.js](https://img.shields.io/badge/Chart.js-4.4-FF6384?logo=chartdotjs&logoColor=white)](https://www.chartjs.org)
[![PowerShell](https://img.shields.io/badge/PowerShell-5197F7?logo=powershell&logoColor=white)](https://learn.microsoft.com/en-us/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A static dashboard that automatically pulls data from **Jamf Pro** and **Microsoft Intune** via scheduled CI/CD pipelines and presents it as a live, shareable web page. Supports both **GitHub Actions + GitHub Pages** and **GitLab CI + GitLab Pages**.

## Dashboards

| Page | Description |
|---|---|
| **OS Compliance** | Compliance rate, OS version distribution, and a list of devices below the minimum required version. macOS compliance is evaluated dynamically via the [SOFA feed](https://sofafeed.macadmins.io) using a configurable N-rule. Windows compliance is evaluated against a minimum build number. |
| **Enrollment** | Total enrolled devices, enrollments in the last 24 hours and 30 days, and a bar chart of enrollments per year. Covers both Mac (Jamf) and Windows (Intune). |
| **Hardware** | Manufacturer breakdown, top device models, and a year-of-manufacture distribution chart. Covers both Mac (Jamf) and Windows (Intune). |
| **Security** | Side-by-side security compliance checks for Mac (Jamf) and Windows (Intune). Mac checks include FileVault, SIP, Recent Check-In, Microsoft Defender, Bootstrap Token, Device Attestation, Secure Boot, Firewall, and Platform SSO. Windows checks include BitLocker, Intune Compliance, Recent Sync, and Entra ID Registration. |
| **Applications** | Search across all detected applications from both platforms. Browse by name, view version distribution, and see what share of the installed fleet is on each version — side-by-side for Mac and Windows. |

## How It Works

1. A **scheduled pipeline** runs hourly (`0 * * * *` on `main`).
2. Ten parallel fetch jobs call the Jamf Pro and Intune APIs and write JSON files to `data/`.
3. A deploy job copies the dashboard and JSON data into the Pages output directory.
4. The dashboard JavaScript reads the JSON files at page load — no server required.

```
fetch-jamf ──────────────────────┐
fetch-jamf-enrollment ───────────┤
fetch-jamf-hardware ─────────────┤
fetch-jamf-security ─────────────┼──► deploy (GitHub Pages / GitLab Pages)
fetch-jamf-apps ─────────────────┤
fetch-intune ────────────────────┤
fetch-intune-enrollment ─────────┤
fetch-intune-hardware ───────────┤
fetch-intune-security ───────────┤
fetch-intune-apps ───────────────┘
```

> Each fetch job uses `continue-on-error` / `allow_failure: true` — if one platform is not configured, the rest still deploy.

## Repository Structure

```
.github/
  workflows/
    mdm-dashboard.yml               # GitHub Actions pipeline
.gitlab-ci.yml                      # GitLab CI pipeline
LICENSE
scripts/
  jamf/
    get-os-compliance.sh            # macOS inventory, SOFA N-rule compliance
    get-enrollment-stats.sh         # Enrollment dates, 24h / 30d / yearly stats
    get-hardware-stats.sh           # Model, arch, manufacture year breakdown
    get-security-compliance.sh      # FileVault, SIP, check-in, Defender, Bootstrap Token,
                                    #   Device Attestation, Secure Boot, Firewall, Platform SSO
    get-app-inventory.sh            # Full application inventory with version distributions
  intune/
    get-os-compliance.ps1           # Windows inventory, build compliance
    get-enrollment-stats.ps1        # Windows enrollment stats
    get-hardware-report.ps1         # Manufacturer, model, storage, device age breakdown
    get-security-compliance.ps1     # BitLocker, Intune compliance, recent sync, Entra ID
    get-app-inventory.ps1           # Full application inventory with version distributions
dashboard/
  index.html                        # OS Compliance page
  enrollment.html                   # Enrollment page
  hardware.html                     # Hardware page
  security.html                     # Security page
  applications.html                 # Applications page
  css/style.css                     # Shared styles (Bootstrap overrides, customisable brand tokens)
  fonts/                            # Place custom font files here (see Customisation)
  img/                              # Place company-logo.png here (see Customisation)
  js/dashboard.js                   # Shared helpers + OS Compliance logic
  js/enrollment.js                  # Enrollment logic
  js/hardware.js                    # Hardware logic
  js/security.js                    # Security logic
  js/applications.js                # Applications search, browse, and version distribution logic
```

## Setup

Choose the platform you are hosting on. Steps 1 and 2 (Jamf and Intune credentials) are the same for both.

### 1. Jamf Pro — API Client

1. In Jamf Pro go to **Settings → API Roles and Clients**.
2. Create an **API Role** with the permission: `Read Computers`.
3. Create an **API Client**, assign the role, and copy the **Client ID** and **Client Secret**.

> Only configure the Jamf steps if you manage Macs with Jamf Pro. The dashboard works with Intune-only or Jamf-only environments.

### 2. Microsoft Intune — App Registration

1. In Entra ID go to **App registrations → New registration**.
2. Add the API permission: `DeviceManagementManagedDevices.Read.All` (Application).
3. Grant admin consent.
4. Create a **Client Secret** and copy the value.

> Only configure the Intune steps if you manage Windows devices with Intune.

---

### GitHub Setup

#### 3a. Add Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Description |
|---|---|
| `JAMF_URL` | e.g. `https://yourco.jamfcloud.com` |
| `JAMF_CLIENT_ID` | Jamf Pro API client ID |
| `JAMF_CLIENT_SECRET` | Jamf Pro API client secret |
| `INTUNE_TENANT_ID` | Azure AD / Entra tenant ID |
| `INTUNE_CLIENT_ID` | App registration client ID |
| `INTUNE_CLIENT_SECRET` | App registration client secret |

See the [Optional variables](#optional-variables) table for additional secrets you can set.

#### 4a. Enable GitHub Pages

Go to **Settings → Pages → Source** and select **GitHub Actions**.

#### 5a. Enable the Schedule

The workflow runs on push to `main` and on the hourly cron schedule automatically. If you just forked the repo, trigger the first run manually: **Actions → MDM Dashboard → Run workflow**.

#### 6a. View the Dashboard

After the first workflow run completes go to **Settings → Pages** to find your URL (format: `https://<org>.github.io/<repo>`).

> **Access control:** GitHub Pages on public repos is public by default. To restrict access, set the repo to **Private** — Pages on private repos requires GitHub Pro, Team, or Enterprise. Alternatively use a [custom domain with Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-apps/) in front of the Pages URL.

---

### GitLab Setup

#### 3b. Add CI/CD Variables

Go to **Settings → CI/CD → Variables** and add:

| Variable | Description | Mask? |
|---|---|---|
| `JAMF_URL` | e.g. `https://yourco.jamfcloud.com` | No |
| `JAMF_CLIENT_ID` | Jamf Pro API client ID | No |
| `JAMF_CLIENT_SECRET` | Jamf Pro API client secret | **Yes** |
| `INTUNE_TENANT_ID` | Azure AD / Entra tenant ID | No |
| `INTUNE_CLIENT_ID` | App registration client ID | No |
| `INTUNE_CLIENT_SECRET` | App registration client secret | **Yes** |

See the [Optional variables](#optional-variables) table for additional variables you can set.

#### 4b. Pipeline Schedule

Go to **CI/CD → Schedules → New Schedule**:

- **Description:** Hourly MDM Sync
- **Interval:** `0 * * * *`
- **Target branch:** `main`

#### 5b. View the Dashboard

After the first pipeline completes go to **Deploy → Pages** to find your URL.

> **Access control:** Go to **Settings → General → Visibility** and set Pages to **Only Project Members**. To grant read-only access to colleagues, go to **Settings → Members → Invite a group** at the **Guest** role.

---

### Optional Variables

These can be set as GitHub Secrets or GitLab CI/CD Variables. All are optional — sensible defaults apply if omitted.

| Variable | Description | Default |
|---|---|---|
| `JAMF_N_RULE` | Previous macOS minor releases counted as compliant | `2` |
| `JAMF_BUSINESS_UNITS` | JSON array of business unit smart groups for the Enrollment page. Format: `[{"name":"Group A","id":123}]`. Omit to hide the section. | *(hidden)* |
| `JAMF_SG_FV_ENCRYPTED` | Smart group ID — FileVault encrypted | `0` |
| `JAMF_SG_FV_NOT_ENCRYPTED` | Smart group ID — FileVault not encrypted | `0` |
| `JAMF_SG_CHECKIN_COMPLIANT` | Smart group ID — recent check-in compliant | `0` |
| `JAMF_SG_CHECKIN_NONCOMPLIANT` | Smart group ID — recent check-in non-compliant | `0` |
| `JAMF_SG_DEFENDER_COMPLIANT` | Smart group ID — Microsoft Defender compliant | `0` |
| `JAMF_SG_DEFENDER_NONCOMPLIANT` | Smart group ID — Microsoft Defender non-compliant | `0` |
| `JAMF_SG_PLATFORM_SSO_REGISTERED` | Smart group ID — Platform SSO registered | `0` |
| `JAMF_SG_ENTRA_NOT_REGISTERED` | Smart group ID — Entra ID not registered | `0` |
| `JAMF_SG_ENTRA_OLD_COMPLIANCE` | Smart group ID — Entra ID old compliance record | `0` |
| `INTUNE_N_RULE` | Previous Windows feature releases counted as compliant | `2` |
| `INTUNE_MIN_WINDOWS_BUILD` | Fallback minimum Windows build if [endoflife.date](https://endoflife.date/windows) is unreachable | `10.0.22621` |

---

## Customisation

### Logo

Each page has a comment in the header showing exactly how to add your logo:

```html
<!-- Logo: add img/company-logo.png to your repo and replace the span below with:
     <img src="img/company-logo.png" alt="Your Company" height="28" class="flex-shrink-0"> -->
```

Place your logo file at `dashboard/img/company-logo.png` (PNG recommended, ~28px tall), then apply the swap in all five HTML files.

### Custom Font

Place your font file(s) in `dashboard/fonts/`. Then uncomment and fill in the `@font-face` template at the top of `dashboard/css/style.css`, and add your font name at the start of the `font-family` list in the `body` rule.

### Brand Colours

All colours are CSS custom properties in `dashboard/css/style.css` under `:root`. At minimum, update `--red` (primary accent) and `--espresso` / `--espresso-dark` (header gradient) to match your brand.

---

## macOS Compliance — N-Rule

Rather than a hardcoded minimum version, macOS compliance is evaluated dynamically using the [SOFA macOS data feed](https://sofafeed.macadmins.io/v1/macos_data_feed.json):

- A device is **compliant** if it is running the latest release, one of the `N` most recent security releases, or any release published within the last 30 days.
- `N` is controlled by the `JAMF_N_RULE` CI/CD variable (default `2`).
- Model compatibility is respected — a Mac that only supports macOS 13 is evaluated against the macOS 13 release line, not macOS 15.
