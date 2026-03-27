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

// ─── Mini Stats Row ───────────────────────────────────────────────────────────

function renderMiniStats(elId, data) {
  const { total_enrolled, enrolled_last_24h, enrolled_last_30d } = data.summary;
  document.getElementById(elId).innerHTML = `
    <div class="col-4">
      <div class="mini-stat border rounded text-center p-2">
        <div class="num">${total_enrolled.toLocaleString()}</div>
        <div class="lbl">Total</div>
      </div>
    </div>
    <div class="col-4">
      <div class="mini-stat border border-success rounded text-center p-2">
        <div class="num text-success">${enrolled_last_24h.toLocaleString()}</div>
        <div class="lbl">Last 24h</div>
      </div>
    </div>
    <div class="col-4">
      <div class="mini-stat border border-primary rounded text-center p-2">
        <div class="num text-primary">${enrolled_last_30d.toLocaleString()}</div>
        <div class="lbl">Last 30d</div>
      </div>
    </div>
  `;
}

// ─── Business Unit Cards ─────────────────────────────────────────────────────

function renderBusinessUnits(units) {
  const section = document.getElementById('business-units-section');
  const row     = document.getElementById('business-units-row');
  if (!section || !row || !units || units.length === 0) return;
  const total = units.reduce((s, u) => s + u.count, 0);
  row.innerHTML = units.map((u) => {
    const pct = total > 0 ? Math.round((u.count / total) * 100) : 0;
    return `
      <div class="col-12 col-md-4">
        <div class="card stat-card border-0 bg-light h-100">
          <div class="card-body d-flex align-items-center gap-3">
            <div class="stat-icon bg-primary-soft text-primary">
              <i class="bi bi-building"></i>
            </div>
            <div>
              <p class="stat-label mb-0">${escHtml(u.name)}</p>
              <h2 class="stat-value mb-0">${u.count.toLocaleString()}</h2>
              <small class="text-muted">${pct}% of fleet</small>
            </div>
          </div>
        </div>
      </div>
    `;
  }).join('');
  section.classList.remove('d-none');
}

// ─── Bar Chart ────────────────────────────────────────────────────────────────

function buildBarChart(canvasId, byYear, color) {
  const currentYear = String(new Date().getFullYear());
  const labels = byYear.map((d) => d.year);
  const counts = byYear.map((d) => d.count);
  const colors = labels.map((y) =>
    y === currentYear ? color.current : color.past
  );

  new Chart(document.getElementById(canvasId), {
    type: 'bar',
    data: {
      labels,
      datasets: [{
        label: 'Enrollments',
        data: counts,
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
            title: (ctx) => `Year ${ctx[0].label}`,
            label: (ctx) => `  ${ctx.parsed.y.toLocaleString()} enrollments`,
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

// ─── Placeholder Chart (Intune unavailable) ───────────────────────────────────

function buildPlaceholderChart(canvasId) {
  const years = ['2022', '2023', '2024', '2025', '2026'];
  new Chart(document.getElementById(canvasId), {
    type: 'bar',
    data: {
      labels: years,
      datasets: [{
        label: 'Enrollments',
        data: [0, 0, 0, 0, 0],
        backgroundColor: 'rgba(200,200,200,0.3)',
        borderRadius: 5,
        borderSkipped: false,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: true,
      plugins: { legend: { display: false }, tooltip: { enabled: false } },
      scales: {
        x: { grid: { display: false } },
        y: { beginAtZero: true, max: 10, ticks: { display: false }, grid: { display: false } },
      },
    },
  });
}

// ─── Init ─────────────────────────────────────────────────────────────────────

async function init() {
  const [jamfData, intuneData] = await Promise.all([
    safeFetch('data/jamf-enrollment-stats.json'),
    safeFetch('data/intune-enrollment-stats.json'),
  ]);

  const loading = document.getElementById('loading-state');
  const errorEl = document.getElementById('error-state');
  const content = document.getElementById('dashboard-content');

  if (!jamfData && !intuneData) {
    loading.classList.add('d-none');
    errorEl.classList.remove('d-none');
    return;
  }


  // ── Last updated ───────────────────────────────────────────────────────────
  const ts = jamfData?.generated_at ?? intuneData?.generated_at;
  if (ts) {
    document.getElementById('last-updated').textContent = `Last updated: ${fmtDate(ts)}`;
  }

  // ── Jamf section ──────────────────────────────────────────────────────────
  if (jamfData) {
    document.getElementById('jamf-subtitle').textContent =
      `Updated ${fmtDate(jamfData.generated_at)}  ·  Jamf Pro`;

    const jamfBadge = document.getElementById('jamf-badge');
    jamfBadge.textContent      = `${jamfData.summary.total_enrolled.toLocaleString()} devices`;
    jamfBadge.className        = 'badge fs-6 px-3 py-2 text-white';
    jamfBadge.style.background = '#2B1F1E';

    renderMiniStats('jamf-mini-stats', jamfData);
    renderBusinessUnits(jamfData.business_units ?? []);
    buildBarChart('jamfYearChart', jamfData.enrollments_by_year, {
      current: 'rgba(27, 58, 92, 0.9)',
      past:    'rgba(27, 58, 92, 0.45)',
    });
  } else {
    document.getElementById('jamf-subtitle').textContent = 'Data unavailable';
    buildPlaceholderChart('jamfYearChart');
  }

  // ── Intune section ────────────────────────────────────────────────────────
  if (intuneData) {
    document.getElementById('intune-subtitle').textContent =
      `Updated ${fmtDate(intuneData.generated_at)}  ·  Microsoft Intune`;

    const intuneBadge = document.getElementById('intune-badge');
    intuneBadge.textContent      = `${intuneData.summary.total_enrolled.toLocaleString()} devices`;
    intuneBadge.className        = 'badge fs-6 px-3 py-2 text-white';
    intuneBadge.style.background = '#0078D4';

    document.getElementById('intune-unavailable').classList.add('d-none');
    document.getElementById('intune-data').classList.remove('d-none');

    renderMiniStats('intune-mini-stats', intuneData);
    buildBarChart('intuneYearChart', intuneData.enrollments_by_year, {
      current: 'rgba(0, 120, 212, 0.9)',
      past:    'rgba(0, 120, 212, 0.4)',
    });
  } else {
    document.getElementById('intune-subtitle').textContent = 'Data unavailable';
  }

  // ── Show dashboard ────────────────────────────────────────────────────────
  loading.classList.add('d-none');
  content.classList.remove('d-none');
}

document.addEventListener('DOMContentLoaded', init);
