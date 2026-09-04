(() => {
  'use strict';

  const ROLE_DEFINITIONS = [
    { id: 'isi', label: 'ISI', flag: 'ISI', serviceKey: 'isi', description: 'COPILOT / ISI simulator' },
    { id: 'sniff', label: 'Sniffer', flag: 'WSBR0', serviceKey: 'sniffer', description: 'br0 packet capture' },
    { id: 'fms', label: 'FMS', flag: 'FMS', serviceKey: 'fms', description: 'CAN replay service' },
  ];

  const SERVICE_ORDER = ['dashboard', 'portal', 'ttyd', 'servsync', 'isi', 'sniffer', 'fms', 'hotspot', 'dnsmasq'];
  const SERVICE_LABELS = {
    dashboard: 'Dashboard',
    portal: 'Portal',
    ttyd: 'Ttyd',
    servsync: 'Servsync',
    isi: 'ISI',
    sniffer: 'Sniffer',
    fms: 'FMS',
    hotspot: 'Hotspot',
    dnsmasq: 'Dnsmasq',
    bridge: 'Bridge',
    rtc: 'RTC',
  };

  const POLL_MS = 15000;
  const LOG_LINES = 80;

  const state = {
    session: null,
    status: null,
    error: '',
    message: '',
    selectedUnit: '',
    logs: 'Click a service to view logs.',
    roleBusy: '',
    statusBusy: false,
    logBusy: false,
    fileArea: 'trace',
    files: [],
    fileBusy: false,
    pollTimer: 0,
  };

  const root = document.getElementById('root');

  function escapeHtml(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function formatUptime(seconds) {
    const value = Number(seconds || 0);
    if (!Number.isFinite(value) || value <= 0) return '-';
    const days = Math.floor(value / 86400);
    const hours = Math.floor((value % 86400) / 3600);
    const minutes = Math.floor((value % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  }

  function statusClass(value) {
    if (value === 'active' || value === 'enabled') return 'ok';
    if (value === 'inactive' || value === 'disabled') return 'off';
    return 'neutral';
  }

  function flagEnabled(flags, key) {
    const value = flags?.[key];
    return value === '1' || value === 1 || value === true || value === 'true' || value === 'yes';
  }

  function terminalUrl() {
    return `${window.location.protocol}//${window.location.hostname}:7681/`;
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    const hasBody = Object.prototype.hasOwnProperty.call(options, 'body');
    const isForm = hasBody && options.body instanceof FormData;
    if (hasBody && !isForm && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json');
    }

    const response = await fetch(path, {
      ...options,
      headers,
      credentials: 'same-origin',
      cache: 'no-store',
    });

    const contentType = response.headers.get('Content-Type') || '';
    const payload = contentType.includes('application/json') ? await response.json() : await response.text();

    if (!response.ok) {
      const message = payload && typeof payload === 'object' ? payload.error || payload.message : payload;
      throw new Error(message || `HTTP ${response.status}`);
    }

    return payload;
  }

  function clearTimers() {
    if (state.pollTimer) {
      window.clearInterval(state.pollTimer);
      state.pollTimer = 0;
    }
  }

  function renderLogin() {
    clearTimers();
    root.innerHTML = `
      <main class="login-page">
        <section class="login-card">
          <div class="login-brand">
            <img src="/logo.png" alt="InitBox" onerror="this.style.display='none'" />
            <div>
              <h1>InitBox</h1>
              <p>Field dashboard login</p>
            </div>
          </div>
          <form id="login-form">
            <label>Username<input id="login-user" autocomplete="username" value="initbox" /></label>
            <label>Password<input id="login-pass" type="password" autocomplete="current-password" autofocus /></label>
            <button type="submit">Sign in</button>
            ${state.error ? `<div class="error">${escapeHtml(state.error)}</div>` : ''}
          </form>
        </section>
      </main>`;

    document.getElementById('login-form').addEventListener('submit', async (event) => {
      event.preventDefault();
      state.error = '';
      const username = document.getElementById('login-user').value;
      const password = document.getElementById('login-pass').value;
      try {
        await api('/api/login', { method: 'POST', body: JSON.stringify({ username, password }) });
        await bootstrap();
      } catch (err) {
        state.error = err.message || 'Login failed';
        renderLogin();
      }
    });
  }

  function metric(label, value) {
    return `<div class="tile"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value || '-')}</strong></div>`;
  }

  function pill(value) {
    return `<span class="pill ${statusClass(value)}">${escapeHtml(value || 'unknown')}</span>`;
  }

  function visibleRoles() {
    const flags = state.status?.moduleFlags || {};
    return ROLE_DEFINITIONS.filter((role) => flagEnabled(flags, role.flag));
  }

  function roleButton(role) {
    const active = (state.status?.roles || []).includes(role.id);
    const busy = state.roleBusy === role.id;
    return `
      <button type="button" class="role-toggle ${active ? 'on' : ''}" data-role="${escapeHtml(role.id)}" ${busy ? 'disabled' : ''}>
        <span class="role-text"><strong>${escapeHtml(role.label)}</strong><small>${escapeHtml(role.description)}</small></span>
        <span class="switch"><span></span></span>
      </button>`;
  }

  function serviceRow(name, service) {
    const selected = service.unit === state.selectedUnit;
    return `
      <button type="button" class="service-row ${selected ? 'selected' : ''}" data-unit="${escapeHtml(service.unit)}">
        <span class="service-name">${escapeHtml(SERVICE_LABELS[name] || name)}</span>
        <span class="service-unit">${escapeHtml(service.unit || '-')}</span>
        <span class="pill-group">${pill(service.active)}${pill(service.enabled)}</span>
      </button>`;
  }

  function visibleServiceEntries() {
    const services = state.status?.services || {};
    const roleIds = new Set(visibleRoles().map((role) => role.serviceKey));
    return SERVICE_ORDER
      .filter((key) => services[key] && (['dashboard', 'portal', 'ttyd', 'servsync', 'hotspot', 'dnsmasq'].includes(key) || roleIds.has(key)))
      .map((key) => [key, services[key]]);
  }

  function renderDashboard() {
    const status = state.status || {};
    const stats = status.stats || {};
    const roles = visibleRoles();
    const services = visibleServiceEntries();
    const files = state.files || [];

    root.innerHTML = `
      <header class="topbar">
        <div class="brand"><img src="/logo.png" alt="InitBox" onerror="this.style.display='none'" /><div><h1>InitBox Dashboard</h1><p>${escapeHtml(stats.hostname || status.hostname || 'raspberrypi')}</p></div></div>
        <div class="header-actions"><button id="refresh-status" class="secondary" type="button">Refresh</button><button id="logout" type="button">Logout</button></div>
      </header>

      <main class="dashboard">
        ${state.error ? `<div class="error wide"><span>${escapeHtml(state.error)}</span><button id="clear-error" class="secondary" type="button">Clear</button></div>` : ''}
        ${state.message ? `<div class="notice wide"><span>${escapeHtml(state.message)}</span><button id="clear-message" class="secondary" type="button">Clear</button></div>` : ''}

        <section class="summary-grid">
          <div class="card roles-card">
            <div class="card-head"><h2>Roles</h2><span class="subtle">Installed, OFF until toggled</span></div>
            <div class="role-list">${roles.length ? roles.map(roleButton).join('') : '<p class="muted">No optional modules installed.</p>'}</div>
          </div>

          <div class="card system-card">
            <div class="card-head"><h2>System</h2><span class="subtle">polls every 15 seconds</span></div>
            <div class="metric-grid">
              ${metric('CPU', `${stats.cpu_pct ?? '-'}%`)}
              ${metric('Memory', `${stats.mem_used_pct ?? '-'}%`)}
              ${metric('Disk', `${stats.disk_used_pct ?? '-'}%`)}
              ${metric('Temp', `${stats.temp_c ?? '-'}°C`)}
            </div>
            <div class="info-grid">
              ${metric('Hostname', stats.hostname || status.hostname || '-')}
              ${metric('IP', stats.ip || '-')}
              ${metric('OS', stats.os || '-')}
              ${metric('Model', stats.model || '-')}
              ${metric('Serial', stats.serial || '-')}
              ${metric('Time', stats.time || '-')}
              ${metric('Uptime', formatUptime(stats.uptime_s))}
            </div>
          </div>
        </section>

        <section class="card ops-card">
          <div class="card-title-row"><div><h2>Services and Logs</h2><p>Logs load only when clicked to keep Pi 3 responsive.</p></div><button id="refresh-logs" class="secondary" type="button">Refresh selected logs</button></div>
          <div class="ops-grid">
            <div class="services-list">${services.map(([name, service]) => serviceRow(name, service)).join('')}</div>
            <div class="logs-panel"><div class="logs-title">${escapeHtml(state.selectedUnit || 'No service selected')}</div><pre>${escapeHtml(state.logBusy ? 'Loading logs...' : state.logs)}</pre></div>
          </div>
        </section>

        <section class="utility-grid">
          <div class="card utility-card">
            <h2>Terminal</h2>
            <p>Terminal is not embedded here. Open it separately so ttyd does not keep reconnecting inside the Dashboard.</p>
            <a class="button" href="${escapeHtml(terminalUrl())}" target="_blank" rel="noreferrer">Open Web Terminal</a>
            <code>${escapeHtml(terminalUrl())}</code>
          </div>
          <div class="card utility-card">
            <h2>Power</h2>
            <div class="button-row"><button id="reboot" class="secondary" type="button">Reboot</button><button id="shutdown" class="danger" type="button">Shutdown</button></div>
          </div>
          <div class="card files-card">
            <div class="card-title-row"><div><h2>Files and ZIP</h2><p>Trace files and CAN.trc upload.</p></div><div class="button-row"><button id="files-trace" class="secondary" type="button">Trace</button><button id="files-bin" class="secondary" type="button">Bin</button><button id="zip" type="button">Prepare ZIP</button></div></div>
            <div class="upload-row"><input id="can-file" type="file" accept=".trc" /><button id="upload-can" type="button">Upload CAN.trc</button><span>Target: /usr/local/bin/CAN.trc</span></div>
            <div class="file-list">${state.fileBusy ? '<p class="muted">Loading files...</p>' : files.length ? files.map((item) => `<div class="file-row"><span>${escapeHtml(item.name)}</span><small>${escapeHtml(item.type)}</small><small>${escapeHtml(item.size)} bytes</small></div>`).join('') : '<p class="muted">No files loaded.</p>'}</div>
          </div>
        </section>
      </main>`;

    wireDashboardEvents();
  }

  function wireDashboardEvents() {
    document.getElementById('logout')?.addEventListener('click', logout);
    document.getElementById('refresh-status')?.addEventListener('click', () => loadStatus(true));
    document.getElementById('clear-error')?.addEventListener('click', () => { state.error = ''; renderDashboard(); });
    document.getElementById('clear-message')?.addEventListener('click', () => { state.message = ''; renderDashboard(); });
    document.getElementById('refresh-logs')?.addEventListener('click', () => { if (state.selectedUnit) showLogs(state.selectedUnit); });
    document.getElementById('reboot')?.addEventListener('click', () => systemAction('reboot'));
    document.getElementById('shutdown')?.addEventListener('click', () => systemAction('shutdown'));
    document.getElementById('files-trace')?.addEventListener('click', () => loadFiles('trace'));
    document.getElementById('files-bin')?.addEventListener('click', () => loadFiles('bin'));
    document.getElementById('zip')?.addEventListener('click', prepareZip);
    document.getElementById('upload-can')?.addEventListener('click', uploadCan);

    for (const button of document.querySelectorAll('.role-toggle[data-role]')) {
      button.addEventListener('click', () => {
        const role = button.getAttribute('data-role');
        const enabled = !(state.status?.roles || []).includes(role);
        setRole(role, enabled);
      });
    }

    for (const button of document.querySelectorAll('.service-row[data-unit]')) {
      button.addEventListener('click', () => showLogs(button.getAttribute('data-unit')));
    }
  }

  async function loadStatus(force = false) {
    if (state.statusBusy && !force) return;
    state.statusBusy = true;
    try {
      const nextStatus = await api('/api/status');
      state.status = nextStatus;
      state.error = '';
    } catch (err) {
      state.error = err.message || 'Failed to fetch Dashboard status';
    } finally {
      state.statusBusy = false;
      renderDashboard();
    }
  }

  async function setRole(role, enabled) {
    if (!state.status) return;

    if (enabled && (role === 'isi' || role === 'sniff')) {
      const ok = window.confirm('Enabling ISI or Sniffer starts bridge/field runtime. If your SSH session uses the affected wired path it may drop. Continue?');
      if (!ok) return;
    }

    const roles = new Set(state.status.roles || []);
    if (enabled) roles.add(role); else roles.delete(role);
    state.roleBusy = role;
    renderDashboard();

    try {
      const response = await api('/api/roles', { method: 'POST', body: JSON.stringify({ roles: [...roles] }) });
      state.status.roles = response.roles || [...roles];
      state.message = enabled ? `${role.toUpperCase()} role enabled` : `${role.toUpperCase()} role disabled`;
      await loadStatus(true);
    } catch (err) {
      state.error = err.message || 'Failed to update role';
      renderDashboard();
    } finally {
      state.roleBusy = '';
    }
  }

  async function showLogs(unit) {
    if (!unit) return;
    state.selectedUnit = unit;
    state.logBusy = true;
    renderDashboard();
    try {
      const data = await api(`/api/logs?unit=${encodeURIComponent(unit)}&lines=${LOG_LINES}`);
      state.logs = data.output || 'No logs.';
    } catch (err) {
      state.logs = err.message || 'Failed to load logs';
    } finally {
      state.logBusy = false;
      renderDashboard();
    }
  }

  async function systemAction(action) {
    const label = action === 'reboot' ? 'reboot' : 'shutdown';
    if (!window.confirm(`Confirm ${label}?`)) return;
    try {
      const response = await api('/api/system-action', { method: 'POST', body: JSON.stringify({ action }) });
      state.message = response.message || `${label} submitted`;
      renderDashboard();
    } catch (err) {
      state.error = err.message || `${label} failed`;
      renderDashboard();
    }
  }

  async function loadFiles(area = state.fileArea) {
    state.fileArea = area;
    state.fileBusy = true;
    renderDashboard();
    try {
      const response = await api(`/api/files?area=${encodeURIComponent(area)}`);
      state.files = response.items || [];
    } catch (err) {
      state.error = err.message || 'Failed to load files';
    } finally {
      state.fileBusy = false;
      renderDashboard();
    }
  }

  async function uploadCan() {
    const input = document.getElementById('can-file');
    const file = input?.files?.[0];
    if (!file) {
      state.message = 'Select CAN.trc before uploading';
      renderDashboard();
      return;
    }
    if (file.name.toLowerCase() !== 'can.trc') {
      state.error = 'Only a file named CAN.trc can be uploaded';
      renderDashboard();
      return;
    }
    const form = new FormData();
    form.append('file', file);
    try {
      const response = await api('/api/files/upload-can-trc', { method: 'POST', body: form });
      state.message = response.message || 'CAN.trc uploaded';
      await loadFiles('bin');
    } catch (err) {
      state.error = err.message || 'CAN.trc upload failed';
      renderDashboard();
    }
  }

  async function prepareZip() {
    try {
      const response = await api('/api/archive/prepare', { method: 'POST', body: JSON.stringify({ areas: ['trace'] }) });
      state.message = response.message || 'Trace ZIP prepared. Download starting...';
      renderDashboard();
      window.location.href = '/api/archive/download';
    } catch (err) {
      state.error = err.message || 'Failed to prepare ZIP';
      renderDashboard();
    }
  }

  async function logout() {
    try { await api('/api/logout', { method: 'POST' }); } catch (_) { /* ignore */ }
    state.session = { authenticated: false };
    state.status = null;
    renderLogin();
  }

  async function bootstrap() {
    state.error = '';
    try {
      state.session = await api('/api/session');
      if (!state.session.authenticated) {
        renderLogin();
        return;
      }
      await loadStatus(true);
      clearTimers();
      state.pollTimer = window.setInterval(() => loadStatus(false), POLL_MS);
    } catch (err) {
      state.error = err.message || 'Failed to start Dashboard';
      renderLogin();
    }
  }

  bootstrap();
})();
