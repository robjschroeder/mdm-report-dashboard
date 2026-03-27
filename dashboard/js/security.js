'use strict';

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

async function safeFetch(url) {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  }
}

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ─── Check Card Renderer ──────────────────────────────────────────────────────
// Renders a compliant/non-compliant breakdown with progress bar into `elId`.

function renderCheck(elId, compliant, nonCompliant) {
  const total = compliant + nonCompliant;
  const pct   = total > 0 ? Math.round((compliant / total) * 100) : 0;

  let barColor, textClass, statusLabel;
  if (pct >= 90) {
    barColor    = '#16a34a';
    textClass   = 'text-success';
    statusLabel = 'Good';
  } else if (pct >= 70) {
    barColor    = '#f59e0b';
    textClass   = 'text-warning';
    statusLabel = 'Needs attention';
  } else {
    barColor    = '#dc2626';
    textClass   = 'text-danger';
    statusLabel = 'Critical';
  }

  document.getElementById(elId).innerHTML = `
    <div class="d-flex justify-content-between align-items-baseline mb-1">
      <span class="fw-bold fs-4 ${textClass}">${pct}%</span>
      <small class="text-muted">${statusLabel}</small>
    </div>
    <div class="progress mb-3" style="height:8px;border-radius:4px;">
      <div class="progress-bar" role="progressbar"
           style="width:${pct}%;background:${barColor};border-radius:4px;"
           aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
    </div>
    <div class="row g-2">
      <div class="col-6">
        <div class="mini-stat border border-success rounded">
          <div class="num text-success">${compliant.toLocaleString()}</div>
          <div class="lbl">Compliant</div>
        </div>
      </div>
      <div class="col-6">
        <div class="mini-stat border border-danger rounded">
          <div class="num text-danger">${nonCompliant.toLocaleString()}</div>
          <div class="lbl">Non-Compliant</div>
        </div>
      </div>
    </div>
  `;

  return pct;
}

// ─── Platform SSO Renderer ────────────────────────────────────────────────────
// Three states:
//   registered      — Platform SSO complete (group 1224)
//   old_compliance  — Entra registered via old device compliance (group 1581)
//   not_registered  — No Entra registration at all (group 948)

function renderPlatformSSO(elId, registered, oldCompliance, notRegistered) {
  const total = registered + oldCompliance + notRegistered;
  const pct   = total > 0 ? Math.round((registered / total) * 100) : 0;

  let barColor, textClass;
  if (pct >= 90) { barColor = '#16a34a'; textClass = 'text-success'; }
  else if (pct >= 70) { barColor = '#f59e0b'; textClass = 'text-warning'; }
  else { barColor = '#dc2626'; textClass = 'text-danger'; }

  // Stacked progress: registered (green) | old compliance (amber) | not registered (red)
  const pctOld = total > 0 ? Math.round((oldCompliance / total) * 100) : 0;
  const pctNone = total > 0 ? Math.round((notRegistered / total) * 100) : 0;

  document.getElementById(elId).innerHTML = `
    <div class="d-flex justify-content-between align-items-baseline mb-1">
      <span class="fw-bold fs-4 ${textClass}">${pct}%</span>
      <small class="text-muted">Platform SSO complete</small>
    </div>
    <div class="progress mb-3" style="height:8px;border-radius:4px;">
      <div class="progress-bar" role="progressbar"
           style="width:${pct}%;background:#16a34a;"
           aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
      <div class="progress-bar" role="progressbar"
           style="width:${pctOld}%;background:#f59e0b;"
           aria-valuenow="${pctOld}" aria-valuemin="0" aria-valuemax="100"></div>
      <div class="progress-bar" role="progressbar"
           style="width:${pctNone}%;background:#dc2626;"
           aria-valuenow="${pctNone}" aria-valuemin="0" aria-valuemax="100"></div>
    </div>
    <div class="row g-2">
      <div class="col-4">
        <div class="mini-stat border border-success rounded">
          <div class="num text-success">${registered.toLocaleString()}</div>
          <div class="lbl">PSSO Complete</div>
        </div>
      </div>
      <div class="col-4">
        <div class="mini-stat border border-warning rounded">
          <div class="num text-warning">${oldCompliance.toLocaleString()}</div>
          <div class="lbl">Old Compliance</div>
        </div>
      </div>
      <div class="col-4">
        <div class="mini-stat border border-danger rounded">
          <div class="num text-danger">${notRegistered.toLocaleString()}</div>
          <div class="lbl">Not Registered</div>
        </div>
      </div>
    </div>
  `;
}

// ─── Init ─────────────────────────────────────────────────────────────────────

async function init() {
  const [data, intuneSecData] = await Promise.all([
    safeFetch('data/jamf-security-compliance.json'),
    safeFetch('data/intune-security-compliance.json'),
  ]);

  const loading = document.getElementById('loading-state');
  const errorEl = document.getElementById('error-state');
  const content = document.getElementById('dashboard-content');

  if (!data) {
    loading.classList.add('d-none');
    errorEl.classList.remove('d-none');
    return;
  }

  const { checks, summary } = data;
  const total = summary.total_devices;

  // ── Last updated ───────────────────────────────────────────────────────────
  if (data.generated_at) {
    document.getElementById('last-updated').textContent =
      `Last updated: ${fmtDate(data.generated_at)}`;
  }

  // ── Jamf Mac card header ───────────────────────────────────────────────────
  document.getElementById('jamf-sec-subtitle').textContent =
    `Updated ${fmtDate(data.generated_at)}  ·  Jamf Pro`;

  const jamfBadge = document.getElementById('jamf-sec-badge');
  jamfBadge.textContent      = `${total.toLocaleString()} devices`;
  jamfBadge.className        = 'badge fs-6 px-3 py-2 text-white';
  jamfBadge.style.background = '#2B1F1E';

  // ── Per-check cards ────────────────────────────────────────────────────────
  renderCheck('check-filevault',          checks.filevault.compliant,          checks.filevault.non_compliant);
  renderCheck('check-sip',               checks.sip.compliant,                checks.sip.non_compliant);
  renderCheck('check-checkin',           checks.checkin.compliant,            checks.checkin.non_compliant);
  renderCheck('check-defender',          checks.defender.compliant,           checks.defender.non_compliant);
  renderCheck('check-bootstrap-escrowed', checks.bootstrap_escrowed.compliant, checks.bootstrap_escrowed.non_compliant);
  renderCheck('check-bootstrap-allowed',  checks.bootstrap_allowed.compliant,  checks.bootstrap_allowed.non_compliant);
  renderCheck('check-attestation',       checks.attestation.compliant,        checks.attestation.non_compliant);
  renderCheck('check-secure-boot',       checks.secure_boot.compliant,        checks.secure_boot.non_compliant);
  renderCheck('check-firewall',          checks.firewall.compliant,           checks.firewall.non_compliant);

  renderPlatformSSO('check-platform-sso',
    checks.platform_sso.registered,
    checks.platform_sso.old_compliance,
    checks.platform_sso.not_registered
  );

  document.getElementById('jamf-sec-unavailable').classList.add('d-none');
  document.getElementById('jamf-sec-data').classList.remove('d-none');

  // ── Intune Windows security ───────────────────────────────────────────────────────
  if (intuneSecData) {
    const winTotal    = intuneSecData.summary.total_devices;
    const { checks: wc } = intuneSecData;

    document.getElementById('intune-sec-subtitle').textContent =
      `Updated ${fmtDate(intuneSecData.generated_at)}  ·  Microsoft Intune`;

    const badge = document.getElementById('intune-sec-badge');
    badge.textContent      = `${winTotal.toLocaleString()} devices`;
    badge.className        = 'badge fs-6 px-3 py-2 text-white';
    badge.style.background = '#0078D4';

    renderCheck('check-bitlocker',         wc.bitlocker.compliant,          wc.bitlocker.non_compliant);
    renderCheck('check-intune-compliance', wc.compliance_state.compliant,   wc.compliance_state.non_compliant);
    renderCheck('check-win-sync',          wc.recent_sync.compliant,        wc.recent_sync.non_compliant);
    renderCheck('check-entra-registered',  wc.entra_registered.compliant,   wc.entra_registered.non_compliant);

    document.getElementById('intune-sec-unavailable').classList.add('d-none');
    document.getElementById('intune-sec-data').classList.remove('d-none');
  } else {
    document.getElementById('intune-sec-subtitle').textContent = 'Data unavailable';
  }
  loading.classList.add('d-none');
  content.classList.remove('d-none');
}

document.addEventListener('DOMContentLoaded', init);
