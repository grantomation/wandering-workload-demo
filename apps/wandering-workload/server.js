const express = require('express');
const path = require('path');
const { Pool } = require('pg');

const app = express();
const port = process.env.PORT || 8080;

// Pin colors, cycled by creation order. The SERIAL id is a stable, never-reused
// counter, so PALETTE[(id - 1) % 8] keeps each stop's color fixed across deletes.
const PALETTE = [
  '#e5484d', '#f2820c', '#2fa45a', '#0aa2b0',
  '#3b6ef0', '#8b5cf6', '#d6409f', '#b45309',
];

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

// DB_HOST is a single hostname (e.g. 'wandering-backend-svc') resolved by:
//   VMware:    /etc/hosts (managed by wandering-env-detect.service)
//   OpenShift: K8s Service + CoreDNS
//   Combined:  127.0.0.1 (loopback, both tiers on one VM)
const DB_HOST = process.env.DB_HOST || '127.0.0.1';

// The infrastructure route currently exposing this app is captured straight from the
// browser's own request when a pin is dropped: the OpenShift router (and a VMware DNS
// name) put the real route host in Host / X-Forwarded-Host, so the app just reads its
// own incoming request — no platform detection, no cluster access, no env wiring.
// Each pin freezes the route that was live when it was created; the journey is the
// history of those routes.
//
// PUBLIC_DOMAIN is the stable vanity/redirector domain the faux LB dashboard uses
// (e.g. your-domain.example.com). Reaching the app via that domain, by raw
// IP, or via localhost is NOT a real infra route, so those are stored as NULL — only
// genuine per-infrastructure routes get recorded. INFRA_URL is an optional manual
// override (mostly for local dev).
const PUBLIC_DOMAIN = (process.env.PUBLIC_DOMAIN || 'your-domain.example.com').toLowerCase();

const firstHeader = (value) =>
  (Array.isArray(value) ? value[0] : value || '').split(',')[0].trim();

function infraUrlFromRequest(req) {
  const override = process.env.INFRA_URL?.trim();
  if (override) return override;

  const host = (firstHeader(req.headers['x-forwarded-host']) ||
    firstHeader(req.headers.host)).toLowerCase();
  if (!host) return null;

  const hostname = host.split(':')[0];
  // Reject non-routes: the stable LB/vanity domain, localhost, and bare IPs.
  if (hostname === PUBLIC_DOMAIN || hostname === 'localhost') return null;
  if (/^[0-9.]+$/.test(hostname) || hostname.includes(':') || hostname.startsWith('[')) return null;

  const proto = firstHeader(req.headers['x-forwarded-proto']) ||
    (req.socket && req.socket.encrypted ? 'https' : 'http');
  return `${proto}://${host}`;
}

const poolConfig = {
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'todo',
  password: process.env.DB_PASSWORD || 'todo',
  database: process.env.DB_NAME || 'todo',
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
};

// Set once a connection succeeds, then reused for every query.
let pool;

// Retry until the backend answers, forever. The backend may still be booting,
// or — right after a migration — its Service may not exist yet. We never give
// up: the server keeps listening and /health reports DB status until it connects.
async function connectToDatabase(delayMs = 2000) {
  for (let attempt = 1; ; attempt += 1) {
    const candidate = new Pool({ ...poolConfig, host: DB_HOST, connectionTimeoutMillis: 2000 });
    try {
      await candidate.query('SELECT 1');
      pool = candidate;
      console.log(`Connected to PostgreSQL at ${DB_HOST}`);
      return;
    } catch (error) {
      await candidate.end().catch(() => {});
      console.log(`Waiting for PostgreSQL at ${DB_HOST} (attempt ${attempt})`);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.get('/health', async (_req, res) => {
  if (!pool) {
    return res.status(503).json({ status: 'starting', database: 'connecting' });
  }
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', database: 'connected' });
  } catch (error) {
    res.status(503).json({ status: 'error', database: 'disconnected', message: error.message });
  }
});

app.get('/db', async (_req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, name, x, y, color, url, created_at FROM stops ORDER BY id ASC'
    );
    res.json({ status: 'ok', count: result.rowCount, rows: result.rows });
  } catch (error) {
    res.status(503).json({ status: 'error', message: error.message });
  }
});

app.get('/api/stops', async (_req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, name, x, y, color, url, created_at FROM stops ORDER BY id ASC'
    );
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/stops', async (req, res) => {
  const name = req.body.name?.trim();
  if (!name) {
    return res.status(400).json({ error: 'Name is required' });
  }

  const x = Number(req.body.x);
  const y = Number(req.body.y);
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return res.status(400).json({ error: 'x and y must be numbers' });
  }

  // Match the prototype's placement bounds so pins/labels never clip the edges.
  const clampedX = clamp(x, 2, 98);
  const clampedY = clamp(y, 4, 95);

  try {
    // Reserve the id up front so we can derive a stable color before inserting.
    const seq = await pool.query(
      "SELECT nextval(pg_get_serial_sequence('stops', 'id')) AS id"
    );
    const id = Number(seq.rows[0].id);
    const color = PALETTE[(id - 1) % PALETTE.length];

    const result = await pool.query(
      'INSERT INTO stops (id, name, x, y, color, url) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, name, x, y, color, url, created_at',
      [id, name, clampedX, clampedY, color, infraUrlFromRequest(req)]
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.delete('/api/stops/:id', async (req, res) => {
  const id = Number(req.params.id);

  try {
    const result = await pool.query('DELETE FROM stops WHERE id = $1', [id]);

    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Stop not found' });
    }

    res.status(204).send();
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

function start() {
  // Listen immediately so the port is always open; /health reports DB status.
  // Connect in the background and retry forever, so the app tolerates the DB or
  // its Service not being ready yet (e.g. right after a migration) and self-heals
  // without ever exiting — startup order stops being a correctness requirement.
  app.listen(port, '0.0.0.0', () => {
    console.log(`Wandering Workload listening on port ${port}`);
  });
  connectToDatabase();
}

start();
