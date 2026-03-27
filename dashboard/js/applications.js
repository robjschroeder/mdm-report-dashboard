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

// ─── State ────────────────────────────────────────────────────────────────────

let _jamf   = null;  // raw {generated_at, total_devices, applications[]}
let _intune = null;  // raw {generated_at, total_devices, applications[]}

// Index: Map<lowerName, {canonical, mac, win}>
// mac/win: {device_count, versions, total_devices} | null
let _index  = new Map();

// Sorted array used for browse + dropdown: [{canonical, mac, win, total_count}]
let _sorted = [];

// ─── Data Processing ──────────────────────────────────────────────────────────

function buildIndex() {
  _index.clear();
  _sorted = [];

  if (_jamf) {
    for (const app of _jamf.applications) {
      const key = app.name.toLowerCase();
      if (!_index.has(key)) {
        _index.set(key, { canonical: app.name, mac: null, win: null });
      }
      _index.get(key).mac = {
        device_count: app.device_count,
        versions:     app.versions,
        total_devices: _jamf.total_devices,
      };
    }
  }

  if (_intune) {
    for (const app of _intune.applications) {
      const key = app.name.toLowerCase();
      if (!_index.has(key)) {
        // Use Intune's name as canonical when there is no Jamf match
        _index.set(key, { canonical: app.name, mac: null, win: null });
      }
      _index.get(key).win = {
        device_count: app.device_count,
        versions:     app.versions,
        total_devices: _intune.total_devices,
      };
    }
  }

  for (const [, entry] of _index) {
    const macCount = entry.mac?.device_count ?? 0;
    const winCount = entry.win?.device_count ?? 0;
    _sorted.push({ ...entry, total_count: macCount + winCount });
  }

  // Most widely deployed apps first
  _sorted.sort((a, b) => b.total_count - a.total_count);
}

// ─── Version Distribution Table ───────────────────────────────────────────────

const VERSION_LIMIT = 20;

function renderVersionTable(containerId, unavailableId, data, barColor) {
  const container  = document.getElementById(containerId);
  const unavailable = document.getElementById(unavailableId);

  if (!data) {
    unavailable.classList.remove('d-none');
    container.classList.add('d-none');
    return;
  }

  unavailable.classList.add('d-none');
  container.classList.remove('d-none');

  const { device_count, versions, total_devices } = data;
  const coveragePct = total_devices > 0
    ? ((device_count / total_devices) * 100).toFixed(1)
    : '0.0';

  const shown = versions.slice(0, VERSION_LIMIT);

  // Bar widths are relative to the most common version so bars always fill
  // proportionally. The label shows the real share of devices with this app.
  const maxCount = shown.length > 0 ? shown[0].count : 1;

  const rows = shown.map((v) => {
    const barPct = maxCount > 0
      ? ((v.count / maxCount) * 100).toFixed(1)
      : '0.0';
    // % of devices that have this app which are on this specific version
    const labelPct = device_count > 0
      ? ((v.count / device_count) * 100).toFixed(1)
      : '0.0';
    return `
      <tr>
        <td style="width:42%;max-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
          <code class="small user-select-all">${escHtml(v.version)}</code>
        </td>
        <td>
          <div class="d-flex align-items-center gap-2">
            <div class="flex-grow-1 rounded" style="background:#e9ecef;height:6px;min-width:40px;">
              <div class="rounded" style="width:${barPct}%;height:6px;background:${barColor};transition:width .3s;"></div>
            </div>
            <span class="text-muted small text-nowrap" style="min-width:7em;text-align:right;">
              ${v.count.toLocaleString()} <span class="opacity-50">(${labelPct}%)</span>
            </span>
          </div>
        </td>
      </tr>`;
  }).join('');

  const moreNote = versions.length > VERSION_LIMIT
    ? `<p class="text-muted small mt-2 mb-0">Showing top ${VERSION_LIMIT} of ${versions.length} versions</p>`
    : '';

  container.innerHTML = `
    <p class="text-muted small mb-2 text-uppercase fw-semibold" style="letter-spacing:.05em;">
      ${versions.length} version${versions.length !== 1 ? 's' : ''}
      &middot;
      ${device_count.toLocaleString()} of ${total_devices.toLocaleString()} devices (${coveragePct}%)
    </p>
    <table class="table table-sm mb-0">
      <tbody>${rows}</tbody>
    </table>
    ${moreNote}
  `;
}

// ─── Detail View ──────────────────────────────────────────────────────────────

function showApp(appName) {
  const entry = _index.get(appName.toLowerCase());
  if (!entry) return;

  // Switch to detail view
  document.getElementById('browse-view').classList.add('d-none');
  document.getElementById('detail-view').classList.remove('d-none');

  // Sync search input
  document.getElementById('app-search').value = entry.canonical;
  document.getElementById('clear-btn').classList.remove('d-none');
  document.getElementById('search-dropdown').classList.add('d-none');

  document.getElementById('detail-app-name').textContent = entry.canonical;

  // Mac card
  const macBadge = document.getElementById('mac-detail-badge');
  if (entry.mac) {
    macBadge.textContent      = `${entry.mac.device_count.toLocaleString()} devices`;
    macBadge.className        = 'badge fs-6 px-3 py-2 text-white';
    macBadge.style.background = '#2B1F1E';
    document.getElementById('mac-detail-subtitle').textContent =
      `${entry.mac.versions.length} version${entry.mac.versions.length !== 1 ? 's' : ''}  ·  Jamf Pro`;
  } else {
    macBadge.textContent      = 'Not installed';
    macBadge.className        = 'badge fs-6 px-3 py-2 bg-secondary text-white';
    macBadge.style.background = '';
    document.getElementById('mac-detail-subtitle').textContent = 'No macOS data for this application';
  }
  renderVersionTable('mac-versions', 'mac-unavailable', entry.mac, '#2B1F1E');

  // Windows card
  const winBadge = document.getElementById('win-detail-badge');
  if (entry.win) {
    winBadge.textContent      = `${entry.win.device_count.toLocaleString()} devices`;
    winBadge.className        = 'badge fs-6 px-3 py-2 text-white';
    winBadge.style.background = '#0078D4';
    document.getElementById('win-detail-subtitle').textContent =
      `${entry.win.versions.length} version${entry.win.versions.length !== 1 ? 's' : ''}  ·  Microsoft Intune`;
  } else {
    winBadge.textContent      = 'Not installed';
    winBadge.className        = 'badge fs-6 px-3 py-2 bg-secondary text-white';
    winBadge.style.background = '';
    document.getElementById('win-detail-subtitle').textContent = 'No Windows data for this application';
  }
  renderVersionTable('win-versions', 'win-unavailable', entry.win, '#0078D4');
}

// ─── Browse View ──────────────────────────────────────────────────────────────

const BROWSE_LIMIT = 500;

function renderBrowse(filter = '') {
  const q = filter.toLowerCase().trim();
  const rows = q
    ? _sorted.filter((a) => a.canonical.toLowerCase().includes(q))
    : _sorted;

  const tbody  = document.getElementById('apps-tbody');
  const shown  = rows.slice(0, BROWSE_LIMIT);

  tbody.innerHTML = shown.map((a) => {
    const macCell = a.mac
      ? `<strong>${a.mac.device_count.toLocaleString()}</strong>`
      : `<span class="text-muted">&mdash;</span>`;
    const winCell = a.win
      ? `<strong>${a.win.device_count.toLocaleString()}</strong>`
      : `<span class="text-muted">&mdash;</span>`;
    const verCount = Math.max(
      a.mac?.versions?.length ?? 0,
      a.win?.versions?.length ?? 0,
    );

    return `
      <tr data-app="${escHtml(a.canonical)}" style="cursor:pointer;">
        <td class="ps-4">${escHtml(a.canonical)}</td>
        <td class="text-center">${macCell}</td>
        <td class="text-center">${winCell}</td>
        <td class="text-center">
          <span class="badge bg-light text-secondary border">${verCount}</span>
        </td>
      </tr>`;
  }).join('');

  if (rows.length > BROWSE_LIMIT) {
    tbody.innerHTML += `
      <tr>
        <td colspan="4" class="text-center text-muted small py-2">
          Showing top ${BROWSE_LIMIT.toLocaleString()} of ${rows.length.toLocaleString()} results
          &mdash; refine your search to narrow further
        </td>
      </tr>`;
  }

  const countEl = document.getElementById('apps-count');
  if (q) {
    countEl.textContent = rows.length > 0
      ? `${rows.length.toLocaleString()} application${rows.length !== 1 ? 's' : ''} matching "${filter}"`
      : `No applications matching "${filter}"`;
  } else {
    countEl.textContent =
      `${_sorted.length.toLocaleString()} applications across both platforms — click any row to view version distribution`;
  }
}

// ─── Search Dropdown ──────────────────────────────────────────────────────────

const DROPDOWN_LIMIT = 10;

function updateDropdown(query) {
  const dropdown = document.getElementById('search-dropdown');

  if (!query) {
    dropdown.classList.add('d-none');
    return;
  }

  const lower   = query.toLowerCase();
  const matches = _sorted.filter((a) => a.canonical.toLowerCase().includes(lower));

  if (matches.length === 0) {
    dropdown.innerHTML = '<li class="list-group-item text-muted small py-2 px-3">No matching applications</li>';
    dropdown.classList.remove('d-none');
    return;
  }

  dropdown.innerHTML = matches.slice(0, DROPDOWN_LIMIT).map((a) => {
    const platforms = [a.mac ? 'macOS' : '', a.win ? 'Windows' : ''].filter(Boolean).join(' + ');
    return `
      <li class="list-group-item list-group-item-action d-flex align-items-center gap-2 py-2 px-3"
          data-app="${escHtml(a.canonical)}" style="cursor:pointer;">
        <i class="bi bi-box text-muted small flex-shrink-0"></i>
        <span class="flex-grow-1 text-truncate">${escHtml(a.canonical)}</span>
        <span class="text-muted small flex-shrink-0">${escHtml(platforms)}</span>
      </li>`;
  }).join('');

  if (matches.length > DROPDOWN_LIMIT) {
    dropdown.innerHTML += `
      <li class="list-group-item text-muted small text-center py-1 px-3 bg-light">
        ${(matches.length - DROPDOWN_LIMIT).toLocaleString()} more &mdash; keep typing to narrow
      </li>`;
  }

  dropdown.classList.remove('d-none');
}

// ─── Show Browse ──────────────────────────────────────────────────────────────

function showBrowse() {
  document.getElementById('detail-view').classList.add('d-none');
  document.getElementById('browse-view').classList.remove('d-none');
  document.getElementById('app-search').value = '';
  document.getElementById('clear-btn').classList.add('d-none');
  document.getElementById('search-dropdown').classList.add('d-none');
  renderBrowse();
}

// ─── Init ─────────────────────────────────────────────────────────────────────

async function init() {
  const [jamfData, intuneData] = await Promise.all([
    safeFetch('data/jamf-app-inventory.json'),
    safeFetch('data/intune-app-inventory.json'),
  ]);

  const loading = document.getElementById('loading-state');
  const errorEl = document.getElementById('error-state');
  const content = document.getElementById('dashboard-content');

  if (!jamfData && !intuneData) {
    loading.classList.add('d-none');
    errorEl.classList.remove('d-none');
    return;
  }

  _jamf   = jamfData;
  _intune = intuneData;
  buildIndex();

  // Last updated
  const ts = _jamf?.generated_at ?? _intune?.generated_at;
  if (ts) {
    document.getElementById('last-updated').textContent = `Last updated: ${fmtDate(ts)}`;
  }

  renderBrowse();

  // ── Wire up events ──────────────────────────────────────────────────────────
  const searchEl = document.getElementById('app-search');
  const dropdown = document.getElementById('search-dropdown');
  const clearBtn = document.getElementById('clear-btn');
  const backBtn  = document.getElementById('back-btn');
  const tbody    = document.getElementById('apps-tbody');

  let debounceTimer;

  searchEl.addEventListener('input', () => {
    const q = searchEl.value;
    clearBtn.classList.toggle('d-none', q.length === 0);

    // Always switch back to browse view while typing
    document.getElementById('detail-view').classList.add('d-none');
    document.getElementById('browse-view').classList.remove('d-none');
    renderBrowse(q);

    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => updateDropdown(q.trim()), 120);
  });

  searchEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const first = dropdown.querySelector('[data-app]');
      if (first) {
        showApp(first.dataset.app);
      }
    }
    if (e.key === 'Escape') {
      dropdown.classList.add('d-none');
    }
  });

  dropdown.addEventListener('click', (e) => {
    const item = e.target.closest('[data-app]');
    if (item) showApp(item.dataset.app);
  });

  // Close dropdown when clicking outside the search area
  document.addEventListener('click', (e) => {
    if (!searchEl.closest('.position-relative').contains(e.target)) {
      dropdown.classList.add('d-none');
    }
  });

  clearBtn.addEventListener('click', showBrowse);
  backBtn.addEventListener('click', showBrowse);

  tbody.addEventListener('click', (e) => {
    const row = e.target.closest('[data-app]');
    if (row) showApp(row.dataset.app);
  });

  loading.classList.add('d-none');
  content.classList.remove('d-none');
}

document.addEventListener('DOMContentLoaded', init);
