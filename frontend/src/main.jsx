import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { api } from './api.js';
import './styles.css';

const ROLE_DEFINITIONS = [
  {
    id: 'isi',
    label: 'ISI',
    flag: 'ISI',
    serviceKey: 'isi',
    description: 'COPILOT / ISI simulator',
  },
  {
    id: 'sniff',
    label: 'Sniffer',
    flag: 'WSBR0',
    serviceKey: 'sniffer',
    description: 'br0 packet capture',
  },
  {
    id: 'fms',
    label: 'FMS',
    flag: 'FMS',
    serviceKey: 'fms',
    description: 'CAN replay service',
  },
];

const CORE_SERVICE_KEYS = ['dashboard', 'portal', 'ttyd', 'servsync', 'hotspot', 'dnsmasq'];

const NERD_QUOTES = [
  'There are only 10 types of people: those who understand binary and those who do not.',
  'It works on my machine. That machine is now production.',
  'I would tell you a UDP joke, but you might not get it.',
  'Cache me if you can.',
  'There is no cloud. It is just someone else’s Pi.',
  'Debugging: being the detective in a crime movie where you are also the murderer.',
  'Never trust an atom. They make up everything.',
  'sudo make me a sandwich.',
  'A packet walked into a router and asked for directions.',
  'Semicolons are tiny traffic cops for JavaScript.',
  'The bug is not hiding. It is documenting your assumptions.',
  'Real engineers count from zero.',
  'My code does not have bugs. It develops random features.',
  'DNS is always innocent until proven cached.',
  'Pi today, Kubernetes tomorrow, chaos forever.',
];

function flagEnabled(flags, key) {
  if (!key) return true;

  const value = flags?.[key];
  return value === '1' || value === 1 || value === true || value === 'true' || value === 'yes';
}

function serviceClass(value) {
  if (value === 'active' || value === 'enabled') return 'ok';
  if (value === 'inactive' || value === 'disabled') return 'warn';
  if (value === 'activating' || value === 'deactivating') return 'neutral';
  return 'neutral';
}

function formatUptime(seconds) {
  const value = Number(seconds || 0);

  if (!Number.isFinite(value) || value <= 0) {
    return '-';
  }

  const days = Math.floor(value / 86400);
  const hours = Math.floor((value % 86400) / 3600);
  const minutes = Math.floor((value % 3600) / 60);

  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function StatusPill({ value }) {
  return <span className={`pill ${serviceClass(value)}`}>{value || 'unknown'}</span>;
}

function BrandLogo() {
  const [failed, setFailed] = useState(false);

  if (!failed) {
    return (
      <img
        className="brand-logo-img"
        src="/logo.png"
        alt="InitBox"
        onError={() => setFailed(true)}
      />
    );
  }

  return <div className="logo-mark">IB</div>;
}

function Login({ onLogin }) {
  const [username, setUsername] = useState('initbox');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setError('');
    setBusy(true);

    try {
      await api('/api/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      });
      onLogin();
    } catch (err) {
      setError(err.message || 'Login failed');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-page">
      <section className="login-card">
        <div className="brand big">
          <BrandLogo />
          <div>
            <h1>InitBox</h1>
            <p>Field dashboard login</p>
          </div>
        </div>

        <form onSubmit={submit}>
          <label>
            Username
            <input value={username} onChange={(event) => setUsername(event.target.value)} />
          </label>

          <label>
            Password
            <input
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              autoFocus
            />
          </label>

          <button type="submit" disabled={busy}>
            {busy ? 'Signing in...' : 'Sign in'}
          </button>

          {error && <div className="error">{error}</div>}
        </form>
      </section>
    </main>
  );
}

function RoleToggle({ role, enabled, busy, onToggle }) {
  return (
    <button
      type="button"
      className={`role-toggle compact ${enabled ? 'on' : ''}`}
      disabled={busy}
      onClick={() => onToggle(role.id, !enabled)}
      aria-pressed={enabled}
    >
      <span>
        <strong>{role.label}</strong>
        <small>{role.description}</small>
      </span>
      <span className="switch" aria-hidden="true">
        <span />
      </span>
    </button>
  );
}

function ServiceRow({ name, service, selected, onSelect }) {
  return (
    <button
      type="button"
      className={`service-row ${selected ? 'selected' : ''}`}
      onClick={() => onSelect(service.unit)}
    >
      <span className="service-name">{name}</span>
      <span className="service-unit">{service.unit}</span>
      <span className="pill-group">
        <StatusPill value={service.active} />
        <StatusPill value={service.enabled} />
      </span>
    </button>
  );
}

function Metric({ label, value }) {
  return (
    <div>
      <span>{label}</span>
      <strong>{value ?? '-'}</strong>
    </div>
  );
}

function SystemPanel({ stats, hostname }) {
  if (stats.error) {
    return <div className="error">{stats.error}</div>;
  }

  return (
    <div className="system-row">
      <div className="metric-grid dense">
        <Metric label="CPU" value={`${stats.cpu_pct ?? '-'}%`} />
        <Metric label="Memory" value={`${stats.mem_used_pct ?? '-'}%`} />
        <Metric label="Disk" value={`${stats.disk_used_pct ?? '-'}%`} />
        <Metric label="Temp" value={`${stats.temp_c ?? '-'}°C`} />
      </div>

      <div className="info-grid">
        <Metric label="Hostname" value={stats.hostname || hostname || '-'} />
        <Metric label="IP address" value={stats.ip || '-'} />
        <Metric label="OS" value={stats.os || '-'} />
        <Metric label="Model" value={stats.model || '-'} />
        <Metric label="Serial" value={stats.serial || '-'} />
        <Metric label="Time" value={stats.time || '-'} />
        <Metric label="Uptime" value={formatUptime(stats.uptime_s)} />
      </div>
    </div>
  );
}

function TerminalPanel({ ttydUrl }) {
  const [message, setMessage] = useState('');

  function openFloatingTerminal() {
    const width = 1000;
    const height = 700;
    const left = Math.max(0, Math.round((window.screen.width - width) / 2));
    const top = Math.max(0, Math.round((window.screen.height - height) / 2));

    const terminalWindow = window.open(
      ttydUrl,
      'initbox-terminal',
      [
        `width=${width}`,
        `height=${height}`,
        `left=${left}`,
        `top=${top}`,
        'resizable=yes',
        'scrollbars=yes',
        'menubar=no',
        'toolbar=no',
        'location=yes',
        'status=no',
      ].join(','),
    );

    if (terminalWindow) {
      terminalWindow.focus();
      setMessage('Terminal opened in a floating browser window.');
    } else {
      setMessage('Popup was blocked. Use “Open full window” or allow popups for this dashboard.');
    }
  }

  return (
    <section className="card terminal-card compact-terminal-card">
      <h2>Terminal</h2>
      <p>The terminal is served on port 7681.</p>

      <div className="button-row terminal-buttons">
        <button type="button" onClick={openFloatingTerminal}>
          Floating terminal
        </button>
        <a className="button secondary" href={ttydUrl} target="_blank" rel="noreferrer">
          Full window
        </a>
      </div>

      <code className="terminal-url">{ttydUrl}</code>

      {message && <div className="terminal-message">{message}</div>}
    </section>
  );
}

function PowerPanel({ onMessage }) {
  const [busy, setBusy] = useState('');

  async function runAction(action) {
    const label = action === 'reboot' ? 'reboot' : 'shutdown';
    const confirmed = window.confirm(`Confirm ${label}? This will affect the Raspberry Pi immediately.`);

    if (!confirmed) {
      return;
    }

    setBusy(action);

    try {
      const response = await api('/api/system-action', {
        method: 'POST',
        body: JSON.stringify({ action }),
      });

      onMessage(response.message || `${label} command submitted`);
    } catch (err) {
      onMessage(err.message || `${label} failed`);
    } finally {
      setBusy('');
    }
  }

  return (
    <section className="card power-card">
      <h2>Power</h2>

      <div className="button-row power-buttons">
        <button type="button" className="secondary" disabled={!!busy} onClick={() => runAction('reboot')}>
          {busy === 'reboot' ? 'Submitting...' : 'Reboot'}
        </button>
        <button type="button" className="danger" disabled={!!busy} onClick={() => runAction('shutdown')}>
          {busy === 'shutdown' ? 'Submitting...' : 'Shutdown'}
        </button>
      </div>
    </section>
  );
}

function FilesPanel({ onMessage }) {
  const [area, setArea] = useState('trace');
  const [items, setItems] = useState([]);
  const [busy, setBusy] = useState('');
  const [archive, setArchive] = useState(null);
  const [uploadFile, setUploadFile] = useState(null);
  const fileInputRef = useRef(null);

  async function loadFiles(nextArea = area) {
    setBusy('files');

    try {
      const response = await api(`/api/files?area=${encodeURIComponent(nextArea)}`);
      setItems(response.items || []);
      setArea(nextArea);
    } catch (err) {
      onMessage(err.message || 'Failed to load files');
    } finally {
      setBusy('');
    }
  }

  async function uploadCanTrc() {
    if (!uploadFile) {
      onMessage('Select CAN.trc before uploading');
      return;
    }

    if (uploadFile.name.toLowerCase() !== 'can.trc') {
      onMessage('Only a file named CAN.trc can be uploaded');
      return;
    }

    setBusy('upload');

    try {
      const formData = new FormData();
      formData.append('file', uploadFile);

      const response = await api('/api/files/upload-can-trc', {
        method: 'POST',
        body: formData,
      });

      setUploadFile(null);

      if (fileInputRef.current) {
        fileInputRef.current.value = '';
      }

      onMessage(response.message || 'CAN.trc uploaded to /usr/local/bin/CAN.trc');
      await loadFiles('bin');
    } catch (err) {
      onMessage(err.message || 'Failed to upload CAN.trc');
    } finally {
      setBusy('');
    }
  }

  async function prepareAndDownloadZip() {
    setBusy('zip');

    try {
      const response = await api('/api/archive/prepare', {
        method: 'POST',
        body: JSON.stringify({ areas: ['trace'] }),
      });

      setArchive(response.archive || null);
      onMessage(response.message || 'Trace ZIP prepared. Download starting...');

      window.location.href = '/api/archive/download';
    } catch (err) {
      onMessage(err.message || 'Failed to prepare and download trace ZIP');
    } finally {
      setBusy('');
    }
  }

  useEffect(() => {
    loadFiles('trace');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <section className="card files-card">
      <div className="card-title-row">
        <div>
          <h2>Files and ZIP</h2>
          <p>Trace captures from /usr/tracefiles only.</p>
        </div>
        <div className="button-row">
          <button type="button" className="secondary" disabled={!!busy} onClick={() => loadFiles(area)}>
            Refresh
          </button>
          <button type="button" disabled={!!busy} onClick={prepareAndDownloadZip}>
            {busy === 'zip' ? 'Preparing...' : 'Prepare & Download ZIP'}
          </button>
        </div>
      </div>

      <div className="upload-row">
        <input
          ref={fileInputRef}
          type="file"
          accept=".trc"
          disabled={!!busy}
          onChange={(event) => setUploadFile(event.target.files?.[0] || null)}
        />
        <button type="button" disabled={!!busy || !uploadFile} onClick={uploadCanTrc}>
          {busy === 'upload' ? 'Uploading...' : 'Upload CAN.trc'}
        </button>
        <span className="upload-target">Target: /usr/local/bin/CAN.trc</span>
      </div>

      <div className="tab-row">
        <button type="button" className={area === 'trace' ? 'selected' : ''} onClick={() => loadFiles('trace')}>
          Trace
        </button>
        <button type="button" className={area === 'bin' ? 'selected' : ''} onClick={() => loadFiles('bin')}>
          Bin
        </button>
      </div>

      <div className="file-list">
        {busy === 'files' && <p className="muted">Loading files...</p>}
        {!busy && items.length === 0 && <p className="muted">No files found.</p>}

        {items.map((item) => (
          <div className="file-row" key={`${item.type}-${item.name}`}>
            <span>{item.name}</span>
            <small>{item.type}</small>
            <small>{item.size} bytes</small>
          </div>
        ))}
      </div>

      {archive && (
        <div className="terminal-message">
          ZIP ready: {archive.name} ({archive.size} bytes)
        </div>
      )}
    </section>
  );
}

function CopyrightTicker() {
  const [quoteIndex, setQuoteIndex] = useState(0);
  const year = new Date().getFullYear();

  useEffect(() => {
    const timer = window.setInterval(() => {
      setQuoteIndex((current) => (current + 1) % NERD_QUOTES.length);
    }, 9000);

    return () => window.clearInterval(timer);
  }, []);

  return (
    <footer className="copyright-ticker">
      <div className="ticker-window">
        <div className="ticker-track" key={quoteIndex}>
          <span className="ticker-copy">© {year} Authored by Parminder</span>
          <span className="ticker-separator">•</span>
          <span>{NERD_QUOTES[quoteIndex]}</span>
        </div>
      </div>
    </footer>
  );
}

function App() {
  const [session, setSession] = useState(null);
  const [status, setStatus] = useState(null);
  const [logs, setLogs] = useState('');
  const [selectedUnit, setSelectedUnit] = useState('initbox-dashboard.service');
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const [roleBusy, setRoleBusy] = useState('');

  async function load() {
    try {
      const sess = await api('/api/session');
      setSession(sess);

      if (sess.authenticated) {
        const nextStatus = await api('/api/status');
        setStatus(nextStatus);
      }
    } catch (err) {
      setError(err.message || 'Failed to load dashboard status');
    }
  }

  useEffect(() => {
    load();

    const timer = window.setInterval(load, 10000);

    return () => window.clearInterval(timer);
  }, []);

  async function setRole(role, enabled) {
    if (!status) {
      return;
    }

    const previousStatus = status;
    const roles = new Set(status.roles || []);

    if (enabled) {
      roles.add(role);
    } else {
      roles.delete(role);
    }

    const nextRoles = [...roles];

    setRoleBusy(role);
    setStatus({ ...status, roles: nextRoles });

    try {
      const response = await api('/api/roles', {
        method: 'POST',
        body: JSON.stringify({ roles: nextRoles }),
      });

      setStatus((current) => ({
        ...current,
        roles: response.roles || nextRoles,
      }));

      await load();
    } catch (err) {
      setStatus(previousStatus);
      setError(err.message || 'Failed to update role');
    } finally {
      setRoleBusy('');
    }
  }

  async function showLogs(unit) {
    setSelectedUnit(unit);
    setLogs('Loading logs...');

    try {
      const data = await api(`/api/logs?unit=${encodeURIComponent(unit)}&lines=120`);
      setLogs(data.output || 'No logs');
    } catch (err) {
      setLogs(err.message || 'Failed to load logs');
    }
  }

  async function logout() {
    await api('/api/logout', { method: 'POST' });
    setSession({ authenticated: false });
    setStatus(null);
  }

  const moduleFlags = status?.moduleFlags || {};
  const roles = status?.roles || [];
  const services = status?.services || {};
  const stats = status?.stats || {};

  const visibleRoles = useMemo(
    () => ROLE_DEFINITIONS.filter((role) => flagEnabled(moduleFlags, role.flag)),
    [moduleFlags],
  );

  const visibleServiceEntries = useMemo(() => {
    const allowed = new Set(CORE_SERVICE_KEYS);

    for (const role of visibleRoles) {
      if (role.serviceKey) {
        allowed.add(role.serviceKey);
      }
    }

    return Object.entries(services).filter(([name]) => allowed.has(name));
  }, [services, visibleRoles]);

  const terminalUrl = useMemo(() => {
    const proto = window.location.protocol;
    const host = window.location.hostname;
    return `${proto}//${host}:7681/`;
  }, []);

  if (!session) {
    return <div className="loading">Loading dashboard...</div>;
  }

  if (!session.authenticated) {
    return <Login onLogin={load} />;
  }

  return (
    <>
      <header className="topbar">
        <div className="brand">
          <BrandLogo />
          <div>
            <h1>InitBox Dashboard</h1>
          </div>
        </div>

        <button type="button" onClick={logout}>
          Logout
        </button>
      </header>

      <main className="dashboard">
        {error && (
          <div className="error wide">
            {error}
            <button type="button" className="clear-error" onClick={() => setError('')}>
              Clear
            </button>
          </div>
        )}

        {message && (
          <div className="terminal-message wide">
            {message}
            <button type="button" className="clear-error" onClick={() => setMessage('')}>
              Clear
            </button>
          </div>
        )}

        <section className="summary-grid compact-summary">
          <div className="card compact-card roles-card">
            <h2>Roles</h2>

            {visibleRoles.length === 0 && <p className="muted">No optional modules installed.</p>}

            <div className="role-list compact-role-list">
              {visibleRoles.map((role) => (
                <RoleToggle
                  key={role.id}
                  role={role}
                  enabled={roles.includes(role.id)}
                  busy={roleBusy === role.id}
                  onToggle={setRole}
                />
              ))}
            </div>
          </div>

          <div className="card compact-card system-card">
            <CopyrightTicker />
            <h2>System</h2>
            <SystemPanel stats={stats} hostname={status?.hostname} />
          </div>
        </section>

        <section className="card ops-card">
          <div className="card-title-row">
            <div>
              <h2>Services and Logs</h2>
              <p>Installed services only. Click a service to view logs.</p>
            </div>
            <button type="button" className="secondary" onClick={() => showLogs(selectedUnit)}>
              Refresh logs
            </button>
          </div>

          <div className="ops-grid">
            <div className="services-list">
              {visibleServiceEntries.length === 0 && <p className="muted">Service status is loading...</p>}

              {visibleServiceEntries.map(([name, service]) => (
                <ServiceRow
                  key={name}
                  name={name}
                  service={service}
                  selected={service.unit === selectedUnit}
                  onSelect={showLogs}
                />
              ))}
            </div>

            <div className="logs-panel">
              <div className="logs-title">{selectedUnit}</div>
              <pre>{logs || 'Select a service to show logs.'}</pre>
            </div>
          </div>
        </section>

        <section className="utility-grid">
          <div className="power-terminal-stack">
            <PowerPanel onMessage={setMessage} />
            <TerminalPanel ttydUrl={terminalUrl} />
          </div>

          <FilesPanel onMessage={setMessage} />
        </section>

      </main>
    </>
  );
}

createRoot(document.getElementById('root')).render(<App />);
