'use strict';

// ─── Version Name Mappings ────────────────────────────────────────────────────

const MACOS_NAMES = {
  15: 'Sequoia',
  14: 'Sonoma',
  13: 'Ventura',
  12: 'Monterey',
  11: 'Big Sur',
  10: 'Catalina or older',
};

// Windows build → marketing name (major.minor.build key, exact match)
const WIN_NAMES = {
  '10.0.28000': 'Windows 11 26H1',
  '10.0.26200': 'Windows 11 25H2',
  '10.0.26100': 'Windows 11 24H2',
  '10.0.22631': 'Windows 11 23H2',
  '10.0.22621': 'Windows 11 22H2',
  '10.0.22000': 'Windows 11 21H2',
  '10.0.19045': 'Windows 10 22H2',
  '10.0.19044': 'Windows 10 21H2',
  '10.0.19043': 'Windows 10 21H1',
  '10.0.19042': 'Windows 10 20H2',
  '10.0.19041': 'Windows 10 2004',
};

// Range-based fallback: Intune reports cumulative-update builds (e.g. 10.0.26200)
// which don't match the RTM key. Map any build in a feature-release range to the
// correct marketing name. Sorted descending so first match wins.
const WIN_RANGES = [
  { min: 28000, name: 'Windows 11 26H1' },
  { min: 26200, name: 'Windows 11 25H2' },
  { min: 26100, name: 'Windows 11 24H2' },
  { min: 22631, name: 'Windows 11 23H2' },
  { min: 22621, name: 'Windows 11 22H2' },
  { min: 22000, name: 'Windows 11 21H2' },
  { min: 19045, name: 'Windows 10 22H2' },
  { min: 19044, name: 'Windows 10 21H2' },
  { min: 19043, name: 'Windows 10 21H1' },
  { min: 19042, name: 'Windows 10 20H2' },
  { min: 19041, name: 'Windows 10 2004' },
];

function macosLabel(version) {
  if (!version) return 'Unknown';
  const major = parseInt(version.split('.')[0], 10);
  const name = MACOS_NAMES[major];
  return name ? `macOS ${name} (${version})` : `macOS ${version}`;
}

function windowsLabel(buildVersion) {
  if (!buildVersion) return 'Unknown';
  const key = buildVersion.split('.').slice(0, 3).join('.');
  if (WIN_NAMES[key]) return WIN_NAMES[key];
  // Fallback: range match on the 3rd component for cumulative-update builds
  const thirdPart = parseInt(buildVersion.split('.')[2], 10);
  if (!isNaN(thirdPart)) {
    const match = WIN_RANGES.find((r) => thirdPart >= r.min);
    if (match) return match.name;
  }
  return buildVersion;
}

// ─── Colour Palettes ──────────────────────────────────────────────────────────

const COMPLIANT_PALETTE = [
  '#16a34a', '#22c55e', '#4ade80', '#86efac', '#bbf7d0',
];
const AT_RISK_PALETTE = [
  '#dc2626', '#ef4444', '#f87171', '#fca5a5', '#fecaca',
];

function assignColors(distribution) {
  let ci = 0;
  let ri = 0;
  return distribution.map((d) => {
    if (d.compliant) {
      return COMPLIANT_PALETTE[ci++ % COMPLIANT_PALETTE.length];
    }
    return AT_RISK_PALETTE[ri++ % AT_RISK_PALETTE.length];
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtDate(iso) {
  if (!iso) return 'N/A';
  try {
    return new Date(iso).toLocaleString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric',
      hour: '2-digit', minute: '2-digit',
    });
  } catch {
    return iso;
  }
}

function badgeClass(pct) {
  if (pct >= 90) return 'bg-success';
  if (pct >= 70) return 'bg-warning text-dark';
  return 'bg-danger';
}

function rateColorClass(pct) {
  if (pct >= 90) return 'text-success';
  if (pct >= 70) return 'text-warning';
  return 'text-danger';
}

async function safeFetch(url) {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  }
}

// ─── Chart Builder ────────────────────────────────────────────────────────────

function buildDonut(canvasId, centerId, distribution, labelFn, pct) {
  const colors = assignColors(distribution);
  const labels = distribution.map((d) => labelFn(d.version));
  const counts = distribution.map((d) => d.count);

  new Chart(document.getElementById(canvasId), {
    type: 'doughnut',
    data: {
      labels,
      datasets: [{
        data: counts,
        backgroundColor: colors,
        borderWidth: 2,
        borderColor: '#ffffff',
        hoverOffset: 5,
      }],
    },
    options: {
      cutout: '68%',
      responsive: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label(ctx) {
              const total = ctx.dataset.data.reduce((a, b) => a + b, 0);
              const share = Math.round((ctx.parsed / total) * 100);
              return `  ${ctx.parsed.toLocaleString()} devices (${share}%)`;
            },
          },
        },
      },
    },
  });

  // Centre overlay text
  const pctColor = pct >= 90 ? '#16a34a' : pct >= 70 ? '#d97706' : '#dc2626';
  const center = document.getElementById(centerId);
  center.innerHTML = `
    <span class="pct" style="color:${pctColor}">${pct}%</span>
    <span class="sub">compliant</span>
  `;
}

// ─── Platform Stats Panel ─────────────────────────────────────────────────────

function renderStats(elId, data) {
  const { total_devices: total, compliant, non_compliant, compliance_percentage: pct } = data.summary;
  const barColor = pct >= 90 ? 'bg-success' : pct >= 70 ? 'bg-warning' : 'bg-danger';

  document.getElementById(elId).innerHTML = `
    <div class="mb-3">
      <div class="d-flex justify-content-between mb-1">
        <small class="text-muted">Overall compliance</small>
        <small class="fw-semibold ${pct >= 90 ? 'text-success' : pct >= 70 ? 'text-warning' : 'text-danger'}">${pct}%</small>
      </div>
      <div class="progress" style="height:7px;">
        <div class="progress-bar ${barColor}" style="width:${pct}%" role="progressbar"
             aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
      </div>
    </div>
    <div class="row g-2">
      <div class="col-4">
        <div class="mini-stat border rounded">
          <div class="num">${total.toLocaleString()}</div>
          <div class="lbl">Total</div>
        </div>
      </div>
      <div class="col-4">
        <div class="mini-stat border border-success rounded">
          <div class="num text-success">${compliant.toLocaleString()}</div>
          <div class="lbl">OK</div>
        </div>
      </div>
      <div class="col-4">
        <div class="mini-stat border border-danger rounded">
          <div class="num text-danger">${non_compliant.toLocaleString()}</div>
          <div class="lbl">At Risk</div>
        </div>
      </div>
    </div>
  `;
}

// ─── Version Legend ───────────────────────────────────────────────────────────

function renderLegend(elId, distribution, labelFn) {
  const colors = assignColors(distribution);
  const html = distribution.map((d, i) => `
    <div class="legend-item">
      <span class="legend-dot" style="background:${colors[i]}"></span>
      <span class="text-truncate" title="${labelFn(d.version)}">${labelFn(d.version)}</span>
      <span class="ms-auto text-muted">${d.count}</span>
    </div>
  `).join('');
  document.getElementById(elId).innerHTML = html;
}

// ─── Non-Compliant Devices Table ──────────────────────────────────────────────

function renderDeviceTable(jamfData, intuneData) {
  const jamfDevices = (jamfData?.non_compliant_devices ?? []).map((d) => ({
    ...d,
    platform: 'macOS (Jamf)',
    minVersion: `macOS ${jamfData.latest_version}`,
  }));

  const intuneDevices = (intuneData?.non_compliant_devices ?? []).map((d) => ({
    ...d,
    platform: 'Windows (Intune)',
    minVersion: 'A current Windows release',
  }));

  const all = [...jamfDevices, ...intuneDevices];
  const tbody = document.getElementById('devices-tbody');

  if (all.length === 0) {
    tbody.innerHTML = `
      <tr>
        <td colspan="5" class="text-center py-4 text-success">
          <i class="bi bi-check-circle-fill me-2"></i>All devices are compliant — great work!
        </td>
      </tr>`;
    return;
  }

  tbody.innerHTML = all.map((d) => `
    <tr>
      <td class="fw-medium">${escHtml(d.name ?? 'Unknown')}</td>
      <td><span class="badge bg-secondary">${escHtml(d.platform)}</span></td>
      <td><span class="badge bg-danger">${escHtml(d.os_version ?? 'Unknown')}</span></td>
      <td><span class="badge bg-success">${escHtml(d.minVersion)}</span></td>
      <td class="text-muted">${fmtDate(d.last_seen)}</td>
    </tr>
  `).join('');
}

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ─── Init ─────────────────────────────────────────────────────────────────────

async function init() {
  const [jamfData, intuneData] = await Promise.all([
    safeFetch('data/jamf-os-compliance.json'),
    safeFetch('data/intune-os-compliance.json'),
  ]);

  const loading = document.getElementById('loading-state');
  const errorEl = document.getElementById('error-state');
  const content = document.getElementById('dashboard-content');

  if (!jamfData && !intuneData) {
    loading.classList.add('d-none');
    errorEl.classList.remove('d-none');
    return;
  }

  // ── Combined totals ────────────────────────────────────────────────────────
  const totalDevices     = (jamfData?.summary.total_devices ?? 0) + (intuneData?.summary.total_devices ?? 0);
  const totalCompliant   = (jamfData?.summary.compliant     ?? 0) + (intuneData?.summary.compliant     ?? 0);
  const totalNonComp     = (jamfData?.summary.non_compliant ?? 0) + (intuneData?.summary.non_compliant ?? 0);
  const overallPct       = totalDevices > 0 ? Math.round((totalCompliant / totalDevices) * 100) : 0;

  document.getElementById('total-devices').textContent      = totalDevices.toLocaleString();
  document.getElementById('total-compliant').textContent    = totalCompliant.toLocaleString();
  document.getElementById('total-non-compliant').textContent = totalNonComp.toLocaleString();

  const rateEl = document.getElementById('compliance-rate');
  rateEl.textContent = `${overallPct}%`;
  rateEl.className = `stat-value mb-0 ${rateColorClass(overallPct)}`;

  const rateIcon = document.getElementById('rate-icon');
  rateIcon.className = `stat-icon ${overallPct >= 90 ? 'bg-success-soft text-success' : overallPct >= 70 ? 'bg-warning-soft text-warning' : 'bg-danger-soft text-danger'}`;

  // ── Last updated ───────────────────────────────────────────────────────────
  const ts = jamfData?.generated_at ?? intuneData?.generated_at;
  if (ts) {
    document.getElementById('last-updated').textContent = `Last updated: ${fmtDate(ts)}`;
  }

  // ── Jamf section ──────────────────────────────────────────────────────────
  if (jamfData) {
    const pct = jamfData.summary.compliance_percentage;
    document.getElementById('jamf-subtitle').textContent =
      `Updated ${fmtDate(jamfData.generated_at)}  ·  ${jamfData.compliance_rule}  ·  Latest: macOS ${jamfData.latest_version}`;

    const badge = document.getElementById('jamf-badge');
    badge.textContent = `${pct}% Compliant`;
    badge.className = `badge fs-6 px-3 py-2 ${badgeClass(pct)}`;

    buildDonut('jamfChart', 'jamf-center', jamfData.os_distribution, macosLabel, pct);
    renderStats('jamf-stats', jamfData);
    renderLegend('jamf-legend', jamfData.os_distribution, macosLabel);
  } else {
    document.getElementById('jamf-subtitle').textContent = 'Data unavailable';
    document.getElementById('jamf-card').classList.add('card-unavailable');
  }

  // ── Intune section ────────────────────────────────────────────────────────
  if (intuneData) {
    const pct = intuneData.summary.compliance_percentage;
    document.getElementById('intune-subtitle').textContent =
      `Updated ${fmtDate(intuneData.generated_at)}  ·  ${intuneData.compliance_rule ?? intuneData.eol_source ?? 'endoflife.date'}  ·  ${(intuneData.compliant_builds ?? []).length} compliant release${(intuneData.compliant_builds ?? []).length !== 1 ? 's' : ''}`;

    const badge = document.getElementById('intune-badge');
    badge.textContent = `${pct}% Compliant`;
    badge.className = `badge fs-6 px-3 py-2 ${badgeClass(pct)}`;

    buildDonut('intuneChart', 'intune-center', intuneData.os_distribution, windowsLabel, pct);
    renderStats('intune-stats', intuneData);
    renderLegend('intune-legend', intuneData.os_distribution, windowsLabel);
  } else {
    document.getElementById('intune-subtitle').textContent = 'Data unavailable';
    document.getElementById('intune-card').classList.add('card-unavailable');
  }

  // ── Devices table ─────────────────────────────────────────────────────────
  renderDeviceTable(jamfData, intuneData);

  // ── Show dashboard ────────────────────────────────────────────────────────
  loading.classList.add('d-none');
  content.classList.remove('d-none');
}

document.addEventListener('DOMContentLoaded', init);
