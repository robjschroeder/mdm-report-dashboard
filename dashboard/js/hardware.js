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

// ─── Colour Definitions ───────────────────────────────────────────────────────

const ARCH_COLORS = {
  'Apple Silicon': '#1b3a5c',
  'Intel':         '#94a3b8',
};

function archColor(arch) {
  return ARCH_COLORS[arch] ?? '#64748b';
}

// ─── Architecture Donut Chart ─────────────────────────────────────────────────

function buildArchDonut(canvasId, centerId, breakdown) {
  const total  = breakdown.reduce((s, d) => s + d.count, 0);
  const asStat = breakdown.find((d) => d.architecture === 'Apple Silicon');
  const asPct  = total > 0 ? Math.round(((asStat?.count ?? 0) / total) * 100) : 0;
  const colors = breakdown.map((d) => archColor(d.architecture));

  new Chart(document.getElementById(canvasId), {
    type: 'doughnut',
    data: {
      labels: breakdown.map((d) => d.architecture),
      datasets: [{
        data:            breakdown.map((d) => d.count),
        backgroundColor: colors,
        borderWidth:     2,
        borderColor:     '#ffffff',
        hoverOffset:     5,
      }],
    },
    options: {
      cutout:    '68%',
      responsive: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label(ctx) {
              const share = Math.round((ctx.parsed / total) * 100);
              return `  ${ctx.parsed.toLocaleString()} devices (${share}%)`;
            },
          },
        },
      },
    },
  });

  document.getElementById(centerId).innerHTML = `
    <span class="pct" style="color:#1b3a5c">${asPct}%</span>
    <span class="sub">Apple Silicon</span>
  `;
}

// ─── Architecture Stats Panel ─────────────────────────────────────────────────

function renderArchStats(elId, summary) {
  const { total_devices: total, apple_silicon: as, intel } = summary;
  const asPct = total > 0 ? Math.round((as / total) * 100) : 0;

  document.getElementById(elId).innerHTML = `
    <div class="mb-3">
      <div class="d-flex justify-content-between mb-1">
        <small class="text-muted">Apple Silicon adoption</small>
        <small class="fw-semibold" style="color:#1b3a5c">${asPct}%</small>
      </div>
      <div class="progress" style="height:7px;">
        <div class="progress-bar" style="width:${asPct}%; background:#1b3a5c;"
             role="progressbar" aria-valuenow="${asPct}" aria-valuemin="0" aria-valuemax="100"></div>
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
        <div class="mini-stat border rounded" style="border-color:#1b3a5c !important;">
          <div class="num" style="color:#1b3a5c">${as.toLocaleString()}</div>
          <div class="lbl">AS</div>
        </div>
      </div>
      <div class="col-4">
        <div class="mini-stat border rounded">
          <div class="num text-secondary">${intel.toLocaleString()}</div>
          <div class="lbl">Intel</div>
        </div>
      </div>
    </div>
  `;
}

// ─── Architecture Legend ──────────────────────────────────────────────────────

function renderArchLegend(elId, breakdown) {
  const total = breakdown.reduce((s, d) => s + d.count, 0);
  document.getElementById(elId).innerHTML = breakdown.map((d) => {
    const pct = total > 0 ? Math.round((d.count / total) * 100) : 0;
    return `
      <div class="legend-item">
        <span class="legend-dot" style="background:${archColor(d.architecture)}"></span>
        <span>${escHtml(d.architecture)}</span>
        <span class="ms-auto text-muted">${d.count.toLocaleString()} <small>(${pct}%)</small></span>
      </div>
    `;
  }).join('');
}

// ─── Devices by Year Bar Chart ────────────────────────────────────────────────

function buildYearChart(canvasId, byYear) {
  const currentYear = String(new Date().getFullYear());
  const labels = byYear.map((d) => d.year);
  const counts = byYear.map((d) => d.count);
  const colors = labels.map((y) =>
    y === currentYear ? '#1b3a5c' : 'rgba(27,58,92,0.45)'
  );

  new Chart(document.getElementById(canvasId), {
    type: 'bar',
    data: {
      labels,
      datasets: [{
        label: 'Devices',
        data:   counts,
        backgroundColor: colors,
        borderRadius: 5,
        borderSkipped: false,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: true,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            title: (ctx) => ctx[0].label,
            label: (ctx) => `  ${ctx.parsed.y.toLocaleString()} devices`,
          },
        },
      },
      scales: {
        x: {
          grid: { display: false },
          ticks: { font: { size: 12 } },
        },
        y: {
          beginAtZero: true,
          grid: { color: 'rgba(0,0,0,0.05)' },
          ticks: {
            font: { size: 11 },
            callback: (v) => v.toLocaleString(),
          },
        },
      },
    },
  });
}

// ─── Top Models Horizontal Bar Chart ─────────────────────────────────────────

let _modelsChart = null;
let _macModels   = [];
let _winModels   = [];

function _modelsColors(counts, r, g, b) {
  const max = Math.max(...counts, 1);
  return counts.map((c) => `rgba(${r},${g},${b},${(0.35 + 0.65 * (c / max)).toFixed(2)})`);
}

function buildModelsChart(canvasId, topModels) {
  _macModels = topModels;
  const top    = topModels.slice(0, 10).reverse();
  const labels = top.map((d) => d.model);
  const counts = top.map((d) => d.count);

  _modelsChart = new Chart(document.getElementById(canvasId), {
    type: 'bar',
    data: {
      labels,
      datasets: [{
        label: 'Devices',
        data:   counts,
        backgroundColor: _modelsColors(counts, 27, 58, 92),
        borderRadius: 4,
        borderSkipped: false,
      }],
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: true,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label: (ctx) => `  ${ctx.parsed.x.toLocaleString()} devices`,
          },
        },
      },
      scales: {
        x: {
          beginAtZero: true,
          grid: { color: 'rgba(0,0,0,0.05)' },
          ticks: { font: { size: 11 }, callback: (v) => v.toLocaleString() },
        },
        y: {
          grid: { display: false },
          ticks: { font: { size: 11 } },
        },
      },
    },
  });
}

function _updateModelsChart(topModels, r, g, b) {
  if (!_modelsChart) return;
  const top    = topModels.slice(0, 10).reverse();
  const counts = top.map((d) => d.count);
  _modelsChart.data.labels                          = top.map((d) => d.model);
  _modelsChart.data.datasets[0].data                = counts;
  _modelsChart.data.datasets[0].backgroundColor     = _modelsColors(counts, r, g, b);
  _modelsChart.update();
}

// ─── Incompatible Devices Table ───────────────────────────────────────────────

function renderIncompatibleTable(devices) {
  const tbody = document.getElementById('incompatible-tbody');

  if (!devices || devices.length === 0) {
    tbody.innerHTML = `
      <tr>
        <td colspan="5" class="text-center py-4 text-success">
          <i class="bi bi-check-circle-fill me-2"></i>All devices are compatible with the latest macOS.
        </td>
      </tr>`;
    return;
  }

  tbody.innerHTML = devices.map((d) => `
    <tr>
      <td class="fw-medium">${escHtml(d.name ?? 'Unknown')}</td>
      <td class="text-muted font-monospace small">${escHtml(d.serial ?? '—')}</td>
      <td>${escHtml(d.model ?? 'Unknown')}</td>
      <td><span class="badge bg-secondary">${escHtml(d.architecture ?? 'Unknown')}</span></td>
      <td>${escHtml(d.year ?? '—')}</td>
    </tr>
  `).join('');
}
// ─── Battery Health Card ─────────────────────────────────────────────────────────────────────────────

function renderBatteryHealth(battery) {
  const el = document.getElementById('battery-content');
  if (!el) return;
  if (!battery || battery.device_count === 0) {
    el.innerHTML = '<p class="text-muted small mb-0">No battery data available (desktop Macs have no battery info).</p>';
    return;
  }

  const { device_count: total, low_capacity_count: lowCount, low_capacity_threshold: threshold, health_breakdown: breakdown } = battery;
  const alertCls  = lowCount > 0 ? 'warning' : 'success';
  const alertIcon = lowCount > 0 ? 'exclamation-triangle-fill' : 'check-circle-fill';

  const breakdownHtml = (breakdown || []).map(({ status, count }) => {
    const pct      = total > 0 ? Math.round((count / total) * 100) : 0;
    const isNormal = (status || '').toLowerCase().includes('normal');
    const barColor = isNormal ? 'var(--bs-success)' : 'var(--red, #FF4646)';
    return `
      <div class="mb-2">
        <div class="d-flex justify-content-between mb-1">
          <small>${escHtml(status)}</small>
          <small class="fw-semibold">${count.toLocaleString()} <span class="text-muted">(${pct}%)</span></small>
        </div>
        <div class="progress" style="height:5px;">
          <div class="progress-bar" style="width:${pct}%;background:${barColor};" role="progressbar"
               aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
        </div>
      </div>`;
  }).join('');

  el.innerHTML = `
    <div class="alert alert-${alertCls} d-flex align-items-center gap-2 py-2 mb-3">
      <i class="bi bi-${alertIcon} flex-shrink-0"></i>
      <span><strong>${lowCount.toLocaleString()}</strong> device${lowCount !== 1 ? 's' : ''} under ${threshold}% capacity</span>
    </div>
    <p class="text-muted small mb-2">Health status &mdash; ${total.toLocaleString()} portable Macs</p>
    ${breakdownHtml || '<p class="text-muted small">No health data reported.</p>'}
  `;

  const sub = document.getElementById('battery-subtitle');
  if (sub) sub.textContent = `${total.toLocaleString()} portable Macs`;
}

// ─── Windows Device Age Card ──────────────────────────────────────────────────

function renderWinDeviceAge(deviceAge) {
  const el  = document.getElementById('win-age-content');
  const sub = document.getElementById('win-age-subtitle');
  if (!el) return;

  if (!deviceAge || !deviceAge.buckets || deviceAge.total === 0) {
    el.innerHTML = '<p class="text-muted small mb-0">No device age data available.</p>';
    return;
  }

  const { total, buckets, unknown_count: unknownCount } = deviceAge;
  const known = total - (unknownCount ?? 0);
  if (sub) sub.textContent = `${total.toLocaleString()} devices  ·  By enrollment date`;

  const colors = ['var(--bs-success)', 'var(--bs-warning)', 'var(--red, #FF4646)'];
  const barsHtml = buckets.map((b, i) => {
    const pct    = known > 0 ? Math.round((b.count / known) * 100) : 0;
    const width  = known > 0 ? (b.count / known) * 100 : 0;
    return `
      <div class="mb-3">
        <div class="d-flex justify-content-between mb-1">
          <small class="fw-semibold">${escHtml(b.label)}</small>
          <small class="text-muted">${b.count.toLocaleString()} devices &nbsp;<span class="fw-semibold">${pct}%</span></small>
        </div>
        <div class="progress" style="height:10px;border-radius:5px;">
          <div class="progress-bar" role="progressbar"
               style="width:${width.toFixed(1)}%;background-color:${colors[i]};border-radius:5px;"
               aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
        </div>
      </div>`;
  }).join('');

  const unknownNote = unknownCount > 0
    ? `<p class="text-muted mb-0" style="font-size:0.75rem;">${unknownCount.toLocaleString()} device(s) excluded — no enrollment date recorded.</p>`
    : '';

  el.innerHTML = `${barsHtml}${unknownNote}`;
}

// ─── Windows Storage Health Card ────────────────────────────────────────────

function renderWinStorageHealth(winStorage) {
  const el  = document.getElementById('win-storage-content');
  const sub = document.getElementById('win-storage-subtitle');
  if (!el) return;

  if (!winStorage || winStorage.total === 0) {
    el.innerHTML = '<p class="text-muted small mb-0">No storage data available.</p>';
    return;
  }

  const { total, almost_full_count: almostFull, almost_full_threshold_pct: threshPct,
          buckets, unknown_count: unknownCount } = winStorage;
  const known = total - (unknownCount ?? 0);
  if (sub) sub.textContent = `${total.toLocaleString()} devices  ·  Disk usage from Intune`;

  const alertCls  = almostFull > 0 ? 'warning' : 'success';
  const alertIcon = almostFull > 0 ? 'exclamation-triangle-fill' : 'check-circle-fill';

  const colors = ['var(--bs-success)', '#198754bb', 'var(--bs-warning)', 'var(--red, #FF4646)'];
  const barsHtml = (buckets ?? []).map((b, i) => {
    const pct   = known > 0 ? Math.round((b.count / known) * 100) : 0;
    const width = known > 0 ? (b.count / known) * 100 : 0;
    return `
      <div class="mb-2">
        <div class="d-flex justify-content-between mb-1">
          <small>${escHtml(b.label)}</small>
          <small class="fw-semibold">${b.count.toLocaleString()} <span class="text-muted">(${pct}%)</span></small>
        </div>
        <div class="progress" style="height:5px;">
          <div class="progress-bar" role="progressbar"
               style="width:${width.toFixed(1)}%;background:${colors[i]};" 
               aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
        </div>
      </div>`;
  }).join('');

  const unknownNote = (unknownCount ?? 0) > 0
    ? `<p class="text-muted mb-0 mt-2" style="font-size:0.75rem;">${unknownCount.toLocaleString()} device(s) excluded — no storage data reported.</p>`
    : '';

  el.innerHTML = `
    <div class="alert alert-${alertCls} d-flex align-items-center gap-2 py-2 mb-3">
      <i class="bi bi-${alertIcon} flex-shrink-0"></i>
      <span><strong>${almostFull.toLocaleString()}</strong> device${almostFull !== 1 ? 's' : ''} at &ge;${threshPct}% disk usage</span>
    </div>
    ${barsHtml}${unknownNote}`;
}

// ─── Storage Health Card (macOS) ─────────────────────────────────────────────────────────────────────

function renderStorageHealth(storage) {
  const el = document.getElementById('storage-content');
  if (!el) return;
  if (!storage) {
    el.innerHTML = '<p class="text-muted small mb-0">No storage data available.</p>';
    return;
  }

  const { almost_full_count: almostFull, almost_full_threshold_gb: threshGb, smart_breakdown: smartBreakdown } = storage;
  const totalWithSmart = (smartBreakdown || []).reduce((s, d) => s + d.count, 0);
  const alertCls  = almostFull > 0 ? 'warning' : 'success';
  const alertIcon = almostFull > 0 ? 'exclamation-triangle-fill' : 'check-circle-fill';

  const smartHtml = (smartBreakdown || []).map(({ status, count }) => {
    const pct      = totalWithSmart > 0 ? Math.round((count / totalWithSmart) * 100) : 0;
    const upper    = (status || '').toUpperCase();
    const barColor = upper === 'FAILING'  ? 'var(--red, #FF4646)'
                   : upper === 'VERIFIED' ? 'var(--bs-success)'
                   : 'var(--bs-secondary)';
    return `
      <div class="mb-2">
        <div class="d-flex justify-content-between mb-1">
          <small>${escHtml(status)}</small>
          <small class="fw-semibold">${count.toLocaleString()} <span class="text-muted">(${pct}%)</span></small>
        </div>
        <div class="progress" style="height:5px;">
          <div class="progress-bar" style="width:${pct}%;background:${barColor};" role="progressbar"
               aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"></div>
        </div>
      </div>`;
  }).join('');

  el.innerHTML = `
    <div class="alert alert-${alertCls} d-flex align-items-center gap-2 py-2 mb-3">
      <i class="bi bi-${alertIcon} flex-shrink-0"></i>
      <span><strong>${almostFull.toLocaleString()}</strong> device${almostFull !== 1 ? 's' : ''} with &lt;${threshGb}\u202fGB free</span>
    </div>
    <p class="text-muted small mb-2">SMART status &mdash; ${totalWithSmart.toLocaleString()} disks reported</p>
    ${smartHtml || '<p class="text-muted small">No SMART data reported.</p>'}
  `;
}
// ─── Intune / Windows Colour Palette ───────────────────────────────────────────────────────────────────────────

const MFG_PALETTE = [
  '#0078D4', '#50E6FF', '#773ADC', '#038387', '#C239B3',
  '#E74856', '#FF8C00', '#8E8CD8',
];

function mfgColor(index) {
  return MFG_PALETTE[index % MFG_PALETTE.length];
}

// ─── Manufacturer Donut Chart ─────────────────────────────────────────────────────────────────────────────

function buildMfgDonut(canvasId, centerId, breakdown) {
  const total  = breakdown.reduce((s, d) => s + d.count, 0);
  const top    = breakdown[0];
  const topPct = total > 0 ? Math.round(((top?.count ?? 0) / total) * 100) : 0;
  const colors = breakdown.map((_, i) => mfgColor(i));

  new Chart(document.getElementById(canvasId), {
    type: 'doughnut',
    data: {
      labels: breakdown.map((d) => d.manufacturer),
      datasets: [{
        data:            breakdown.map((d) => d.count),
        backgroundColor: colors,
        borderWidth:     2,
        borderColor:     '#ffffff',
        hoverOffset:     5,
      }],
    },
    options: {
      cutout:    '68%',
      responsive: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label(ctx) {
              const share = Math.round((ctx.parsed / total) * 100);
              return `  ${ctx.parsed.toLocaleString()} devices (${share}%)`;
            },
          },
        },
      },
    },
  });

  document.getElementById(centerId).innerHTML = `
    <span class="pct" style="color:#0078D4">${topPct}%</span>
    <span class="sub">${escHtml(top?.manufacturer ?? '')}</span>
  `;
}

// ─── Manufacturer Stats Panel ───────────────────────────────────────────────────────────────────────────

function renderMfgStats(elId, total, breakdown) {
  const top1Pct = total > 0 ? Math.round(((breakdown[0]?.count ?? 0) / total) * 100) : 0;

  document.getElementById(elId).innerHTML = `
    <div class="mb-3">
      <div class="d-flex justify-content-between mb-1">
        <small class="text-muted">${escHtml(breakdown[0]?.manufacturer ?? '')} share</small>
        <small class="fw-semibold" style="color:#0078D4">${top1Pct}%</small>
      </div>
      <div class="progress" style="height:7px;">
        <div class="progress-bar" style="width:${top1Pct}%;background:#0078D4;"
             role="progressbar" aria-valuenow="${top1Pct}" aria-valuemin="0" aria-valuemax="100"></div>
      </div>
    </div>
    <div class="row g-2">
      <div class="col-6">
        <div class="mini-stat border rounded">
          <div class="num">${total.toLocaleString()}</div>
          <div class="lbl">Total</div>
        </div>
      </div>
      <div class="col-6">
        <div class="mini-stat border rounded" style="border-color:#0078D4 !important;">
          <div class="num" style="color:#0078D4">${(breakdown[0]?.count ?? 0).toLocaleString()}</div>
          <div class="lbl">${escHtml(breakdown[0]?.manufacturer ?? '')}</div>
        </div>
      </div>
    </div>
  `;
}

// ─── Manufacturer Legend ───────────────────────────────────────────────────────────────────────────────

function renderMfgLegend(elId, total, breakdown) {
  document.getElementById(elId).innerHTML = breakdown.map((d, i) => {
    const pct = total > 0 ? Math.round((d.count / total) * 100) : 0;
    return `
      <div class="legend-item">
        <span class="legend-dot" style="background:${mfgColor(i)}"></span>
        <span>${escHtml(d.manufacturer)}</span>
        <span class="ms-auto text-muted">${d.count.toLocaleString()} <small>(${pct}%)</small></span>
      </div>
    `;
  }).join('');
}

// ─── Models Toggle Wiring ───────────────────────────────────────────────────

function wireModelsToggle(winModels) {
  _winModels = winModels;
  const toggle = document.getElementById('models-toggle');
  const macBtn = document.getElementById('btn-mac-models');
  const winBtn = document.getElementById('btn-win-models');
  toggle.classList.remove('d-none');

  macBtn.addEventListener('click', () => {
    _updateModelsChart(_macModels, 27, 58, 92);
    macBtn.style.cssText = 'background:#2B1F1E;color:#fff;border-color:#2B1F1E;';
    macBtn.className     = 'btn btn-sm';
    winBtn.style.cssText = '';
    winBtn.className     = 'btn btn-sm btn-outline-secondary';
  });

  winBtn.addEventListener('click', () => {
    _updateModelsChart(_winModels, 0, 120, 212);
    winBtn.style.cssText = 'background:#0078D4;color:#fff;border-color:#0078D4;';
    winBtn.className     = 'btn btn-sm';
    macBtn.style.cssText = '';
    macBtn.className     = 'btn btn-sm btn-outline-secondary';
  });
}

// ─── Init ─────────────────────────────────────────────────────────────────────

async function init() {
  const [jamfData, intuneData] = await Promise.all([
    safeFetch('data/jamf-hardware-stats.json'),
    safeFetch('data/intune-hardware-stats.json'),
  ]);

  const loading = document.getElementById('loading-state');
  const errorEl = document.getElementById('error-state');
  const content = document.getElementById('dashboard-content');

  if (!jamfData && !intuneData) {
    loading.classList.add('d-none');
    errorEl.classList.remove('d-none');
    return;
  }

  const { total_devices, apple_silicon, intel, incompatible_with_latest_os } = jamfData.summary;
  const asPct = total_devices > 0 ? Math.round((apple_silicon / total_devices) * 100) : 0;

  // ── Mac mini-tiles inside the card ─────────────────────────────────────────
  document.getElementById('hw-mac-total').textContent        = total_devices.toLocaleString();
  document.getElementById('hw-mac-as').textContent           = apple_silicon.toLocaleString();
  document.getElementById('hw-mac-intel').textContent        = intel.toLocaleString();
  document.getElementById('hw-mac-incompatible').textContent = incompatible_with_latest_os.toLocaleString();

  // ── Last updated ───────────────────────────────────────────────────────────
  if (jamfData.generated_at) {
    document.getElementById('last-updated').textContent =
      `Last updated: ${fmtDate(jamfData.generated_at)}`;
  }

  // ── Jamf card header ───────────────────────────────────────────────────────
  document.getElementById('jamf-subtitle').textContent =
    `Updated ${fmtDate(jamfData.generated_at)}  ·  Jamf Pro`;

  const badge = document.getElementById('jamf-badge');
  badge.textContent     = `${asPct}% Apple Silicon`;
  badge.className       = 'badge fs-6 px-3 py-2 text-white';
  badge.style.background = '#1b3a5c';

  // ── Architecture donut + stats + legend ────────────────────────────────────
  buildArchDonut('archChart', 'arch-center', jamfData.architecture_breakdown);
  renderArchStats('jamf-arch-stats', jamfData.summary);
  renderArchLegend('jamf-arch-legend', jamfData.architecture_breakdown);

  // ── Charts ─────────────────────────────────────────────────────────────────
  buildYearChart('yearChart', jamfData.models_by_year);
  buildModelsChart('modelsChart', jamfData.top_models);

  // ── Incompatible devices table ─────────────────────────────────────────────
  renderIncompatibleTable(jamfData.incompatible_devices);

  // ── Battery & Storage health ───────────────────────────────────────────────
  renderBatteryHealth(jamfData.battery);
  renderStorageHealth(jamfData.storage);

  // ── Intune / Windows card ──────────────────────────────────────────────────
  if (intuneData) {
    const { total_devices: winTotal, windows_11: win11 = 0, windows_10: win10 = 0 } = intuneData.summary;
    const breakdown = intuneData.manufacturers_breakdown ?? [];
    const topMfg    = breakdown[0];
    // ── Windows mini-tiles inside the card ───────────────────────────────────
    document.getElementById('hw-win-total').textContent   = winTotal.toLocaleString();
    document.getElementById('hw-win-11').textContent      = win11.toLocaleString();
    document.getElementById('hw-win-10').textContent      = win10.toLocaleString();
    document.getElementById('hw-win-top-mfg').textContent = topMfg?.manufacturer ?? '—';

    document.getElementById('intune-subtitle').textContent =
      `Updated ${fmtDate(intuneData.generated_at)}  ·  Microsoft Intune`;

    const intuneBadge = document.getElementById('intune-badge');
    intuneBadge.textContent      = `${winTotal.toLocaleString()} devices`;
    intuneBadge.className        = 'badge fs-6 px-3 py-2 text-white';
    intuneBadge.style.background = '#0078D4';

    document.getElementById('intune-unavailable').classList.add('d-none');
    document.getElementById('intune-data').classList.remove('d-none');

    buildMfgDonut('intuneMfgChart', 'intune-center', breakdown);
    renderMfgStats('intune-mfg-stats', winTotal, breakdown);
    renderMfgLegend('intune-mfg-legend', winTotal, breakdown);

    wireModelsToggle(intuneData.top_models ?? []);
    renderWinDeviceAge(intuneData.device_age ?? null);
    renderWinStorageHealth(intuneData.win_storage ?? null);
  } else {
    document.getElementById('intune-subtitle').textContent = 'Data unavailable';
  }

  // ── Show content ───────────────────────────────────────────────────────────
  loading.classList.add('d-none');
  content.classList.remove('d-none');
}

document.addEventListener('DOMContentLoaded', init);
