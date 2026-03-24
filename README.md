<div align="center">

```
███████╗██╗      █████╗ ██████╗ ███████╗
██╔════╝██║     ██╔══██╗██╔══██╗██╔════╝
█████╗  ██║     ███████║██████╔╝█████╗  
██╔══╝  ██║     ██╔══██║██╔══██╗██╔══╝  
██║     ███████╗██║  ██║██║  ██║███████╗
╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝
              MASTER PANEL BY SHADOW_LAY
```

**Panel de control central del sistema distribuido Flare**  
*Administra nodos, lanza tareas y gestiona métodos desde una interfaz web*

![Node.js](https://img.shields.io/badge/Node.js-20+-339933?style=flat-square&logo=nodedotjs&logoColor=white)
![Express](https://img.shields.io/badge/Express-4.x-000000?style=flat-square&logo=express&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-WAL-003B57?style=flat-square&logo=sqlite&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-reverse_proxy-009639?style=flat-square&logo=nginx&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04+-E95420?style=flat-square&logo=ubuntu&logoColor=white)

</div>

---

## ¿Qué es Flare Master?

`flare-master` es el panel central del sistema Flare. Se instala en **una sola VPS** y desde ahí controlas todos los nodos conectados. Proporciona una interfaz web para lanzar tareas, gestionar métodos de ataque/ejecución y monitorear el estado de cada nodo en tiempo real.

### Arquitectura general del sistema

```
                        ┌─────────────────────────┐
                        │      FLARE MASTER        │
                        │  ┌───────────────────┐   │
      Tú ──────────────►│  │   Panel Web (UI)  │   │
      (navegador)       │  │   Express + SQLite │   │
                        │  └───────────────────┘   │
                        │     puerto 80 (nginx)     │
                        └────────────┬────────────┘
                                     │  API REST
                          ┌──────────┴──────────┐
                          │   /api/agent/*       │
                          │   (x-agent-token)    │
                          └──────────┬──────────┘
               ┌──────────────┬──────┴──────┬──────────────┐
               ▼              ▼             ▼              ▼
          [nodo-1]       [nodo-2]      [nodo-3]       [nodo-N]
          Francia         Brasil        EE.UU.         Japón
```

> El master **no inicia conexiones** hacia los nodos. Son los nodos quienes hacen polling al master cada ~3 segundos. Esto elimina la necesidad de abrir puertos en los nodos y permite que funcionen detrás de NAT o firewall.

---

## Requisitos

| Requisito | Mínimo |
|-----------|--------|
| OS | Ubuntu 20.04+ / Debian 11+ |
| CPU | 1 vCore |
| RAM | 512 MB |
| Disco | 5 GB |
| Red | IP pública con puerto 80 accesible |
| Usuario | `root` |

**Stack instalado automáticamente:**
- Node.js 20
- Nginx (reverse proxy)
- better-sqlite3 (base de datos embebida)
- Express 4

---

## Instalación

### 1 — Descarga y ejecuta el installer

```bash
wget https://raw.githubusercontent.com/flaresamp/flare-master/main/install-master.sh
sudo bash install-master.sh
```

O en una línea:

```bash
curl -fsSL https://raw.githubusercontent.com/flaresamp/flare-master/main/install-master.sh | sudo bash
```

El installer no hace preguntas — configura todo automáticamente y genera el token del agente.

### 2 — Al finalizar verás esto

```
╔═══════════════════════════════════════════════════════╗
║             INSTALACIÓN COMPLETADA ✅                 ║
╠═══════════════════════════════════════════════════════╣
║  Panel Web  →  http://45.76.123.10                    ║
║  Métodos    →  http://45.76.123.10/methods            ║
║                                                       ║
║  Token Agente: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4      ║
║                e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2      ║
║                                                       ║
║  Token guardado en: /opt/master/.env                  ║
╚═══════════════════════════════════════════════════════╝

⚠ Guarda el AGENT_TOKEN — lo necesitarás al instalar los nodos
```

> **Guarda el `AGENT_TOKEN`**. Lo necesitas para instalar cada nodo. Si lo pierdes, también está en `/opt/master/.env`.

### 3 — Abre el panel en tu navegador

```
http://TU_IP_PUBLICA
```

---

## Estructura de archivos

```
/opt/master/
│
├── server.js           ← Backend principal (Node.js / Express)
├── package.json        ← Dependencias npm
├── .env                ← Token y configuración (chmod 600)
├── master.db           ← Base de datos SQLite (WAL mode)
│
└── public/
    ├── index.html      ← Panel principal (tareas + nodos + logs)
    └── methods.html    ← Gestión de métodos
```

---

## Panel Web — Guía de uso

### Página principal `/`

El panel principal está dividido en cuatro secciones:

#### 🔷 Formulario de lanzamiento de tareas

Donde creas y envías tareas a todos los nodos disponibles. Al seleccionar un método, el formulario se adapta automáticamente:

```
┌─────────────────────────────────────────────────┐
│  MÉTODO      [ UDP Flood ▼ ]   LAYER: [L4]       │
│                                                  │
│  TARGET IP   [ 1.2.3.4         ]                 │
│  PUERTO      [ 80              ]  ← solo si L4   │
│  TIEMPO (s)  [ 60              ]                 │
│                                                  │
│              [  LANZAR TAREA  ]                  │
└─────────────────────────────────────────────────┘
```

- Los campos cambian según el tipo del método (L4 muestra IP+puerto, L7 muestra URL sin puerto)
- Al lanzar, la tarea se asigna a **todos los nodos online** simultáneamente
- Si no hay nodos online, el panel lo indica y bloquea el envío

#### 🔷 Lista de nodos (sidebar derecho)

Muestra todos los nodos conectados con información en tiempo real actualizada por cada nodo:

```
┌─────────────────────────────────────┐
│  🟢 nodo-usa-1          🇺🇸          │
│  45.76.123.10                        │
│  CPU: 23%  RAM: 41%                 │
│  Tareas totales: 147                │
├─────────────────────────────────────┤
│  🟡 nodo-brasil-2       🇧🇷  [busy]  │
│  189.0.123.45                        │
│  CPU: 98%  RAM: 67%                 │
│  Tareas totales: 89                 │
├─────────────────────────────────────┤
│  🔴 nodo-fr-3           🇫🇷 [offline]│
└─────────────────────────────────────┘
```

| Estado | Descripción |
|--------|-------------|
| 🟢 **online** | Disponible para recibir tareas |
| 🟡 **busy** | Ejecutando una tarea actualmente |
| 🔴 **offline** | Sin heartbeat hace más de 35 segundos |

#### 🔷 Últimas 10 tareas

Historial de las tareas más recientes con detalle de cada una:

```
┌────┬──────────────┬────────────────┬──────┬──────────┬───────────────┐
│ ID │ Método       │ Objetivo       │ Seg  │ Estado   │ Nodos usados  │
├────┼──────────────┼────────────────┼──────┼──────────┼───────────────┤
│ #5 │ UDP Flood    │ 1.2.3.4        │ 60s  │ running  │ nodo-1,nodo-2 │
│    │              │                │      │          │ [Cancelar]    │
├────┼──────────────┼────────────────┼──────┼──────────┼───────────────┤
│ #4 │ HTTP Flood   │ ejemplo.com    │ 30s  │ completed│ nodo-1,nodo-3 │
└────┴──────────────┴────────────────┴──────┴──────────┴───────────────┘
```

- Las tareas `running` muestran un botón **Cancelar**
- Al cancelar, el master notifica a los nodos en el próximo poll y estos matan el proceso

#### 🔷 Log en tiempo real (Server-Sent Events)

En la parte inferior del panel hay un log en vivo. Se actualiza automáticamente sin recargar la página:

```
[14:32:01] ✅  Nuevo nodo registrado: nodo-usa-1 | 45.76.123.10 | United States
[14:32:05] 🚀  Tarea #5 | [UDP Flood] → 1.2.3.4 | Nodos: 3 | Tiempo: 60s
[14:32:06] ⚡  Nodo nodo-usa-1 → ejecutando tarea #5
[14:32:06] ⚡  Nodo nodo-brasil-2 → ejecutando tarea #5
[14:33:06] ✅  Tarea #5 completada → 1.2.3.4
[14:35:00] 📡  1 nodo(s) sin respuesta → offline
```

---

### Página de métodos `/methods`

Desde aquí administras qué comandos puede ejecutar el sistema. Cada método define **cómo** se ejecuta un script en los nodos.

#### Crear un método

```
┌─────────────────────────────────────────────────┐
│  NUEVO MÉTODO                                   │
│                                                  │
│  Nombre       [ UDP Flood              ]         │
│  Tipo         [ L4 ▼ ]                           │
│  Requiere puerto  [ Sí ▼ ]                       │
│  Función      [ Bash/Binario ▼ ]                 │
│  Archivo      [ udpflood.sh            ]         │
│  Argumentos   [ {ip} {port} {time}     ]         │
│                                                  │
│  Vista previa: ./scripts/udpflood.sh 1.2.3.4 80 60 │
│                                                  │
│              [  GUARDAR  ]                       │
└─────────────────────────────────────────────────┘
```

#### Campos del método

| Campo | Descripción |
|-------|-------------|
| **Nombre** | Identificador visible en el panel principal |
| **Tipo** | `L4` (capa de transporte) o `L7` (capa de aplicación) |
| **Requiere puerto** | Si el método necesita el campo puerto en el formulario |
| **Función** | Cómo ejecutar el archivo: `Bash/Binario`, `Python`, `Node.js` |
| **Archivo** | Nombre del script en la carpeta `scripts/` del nodo |
| **Argumentos** | Plantilla de argumentos con variables |

#### Variables disponibles en los argumentos

| Variable | Se sustituye por |
|----------|-----------------|
| `{ip}` | IP objetivo (formulario L4) |
| `{url}` | URL objetivo (formulario L7) |
| `{host}` | Alias de `{ip}` o `{url}` |
| `{port}` | Puerto objetivo |
| `{time}` | Duración en segundos |

#### Ejemplos de argumentos por tipo de script

```bash
# Bash con argumentos posicionales:
{ip} {port} {time}
# → ./scripts/flood.sh 1.2.3.4 80 60

# Python con flags:
-h {ip} -p {port} -t {time} --threads 100
# → python3 scripts/flooder.py -h 1.2.3.4 -p 80 -t 60 --threads 100

# Node.js con URL:
{url} --time {time} --concurrency 50
# → node scripts/layer7.js https://ejemplo.com --time 60 --concurrency 50

# Binario compilado:
-target {ip} -port {port} -duration {time}
# → ./scripts/tool -target 1.2.3.4 -port 80 -duration 60
```

#### Tipos de función y comando generado

| Función | Comando enviado al nodo |
|---------|------------------------|
| `Bash / Binario` | `./scripts/archivo.sh {args}` |
| `Python` | `python3 scripts/archivo.py {args}` |
| `Node.js` | `node scripts/archivo.js {args}` |

---

## Flujo completo de una tarea

```
Usuario (panel)               Master                    Nodo(s)
      │                          │                          │
      │  POST /api/tasks         │                          │
      │ ────────────────────────►│                          │
      │                          │  Asigna tarea a todos    │
      │                          │  los nodos online        │
      │  { task_id: 5,           │                          │
      │    nodes: 3 }            │                          │
      │ ◄────────────────────────│                          │
      │                          │                          │
      │                          │◄─── POST /api/agent/poll─│ (cada 3s)
      │                          │                          │
      │                          │─── { task: {command} } ──►│
      │                          │                          │
      │                          │           [ejecuta el comando]
      │                          │                          │
      │                          │◄─── POST /api/agent/poll─│ (sigue reportando)
      │                          │─── { task: null }  ──────►│
      │                          │                          │
      │                          │◄── POST /api/agent/complete│ (al terminar)
      │                          │                          │
      │  [log en tiempo real]    │                          │
      │ ◄────────────────────────│                          │
```

---

## Configuración (`.env`)

El archivo de configuración está en `/opt/master/.env` con permisos `600`:

```ini
# Token de autenticación para los agentes
# Cámbialo si sospechas que fue comprometido (y reinstala los nodos con el nuevo token)
AGENT_TOKEN=a1b2c3d4e5f6...

# Puerto interno de Node.js (nginx hace proxy desde el 80)
PORT=3000
```

### Rotar el AGENT_TOKEN

```bash
# 1. Genera un nuevo token
NEW_TOKEN=$(openssl rand -hex 32)

# 2. Actualiza el .env
sed -i "s/^AGENT_TOKEN=.*/AGENT_TOKEN=$NEW_TOKEN/" /opt/master/.env

# 3. Reinicia el master
systemctl restart master

# 4. Reinstala o reconfigura todos los nodos con el nuevo token
#    (edita agent.conf en cada nodo y reinicia node-agent)
echo "Nuevo token: $NEW_TOKEN"
```

---

## Gestión del servicio

```bash
# Ver estado
systemctl status master

# Ver logs en vivo
journalctl -u master -f

# Reiniciar (después de cambios en .env)
systemctl restart master

# Detener
systemctl stop master

# Ver últimas 50 líneas de log
journalctl -u master -n 50
```

### Nginx

```bash
# Ver estado
systemctl status nginx

# Recargar configuración
nginx -t && systemctl reload nginx

# Ver logs de acceso
tail -f /var/log/nginx/access.log
```

---

## API Reference

El master expone una API REST usada tanto por el panel web como por los nodos.

### Endpoints del agente (requieren `x-agent-token`)

| Método | Ruta | Descripción |
|--------|------|-------------|
| `POST` | `/api/agent/register` | Registro o reconexión de un nodo |
| `POST` | `/api/agent/poll` | Heartbeat + consulta de tarea pendiente |
| `POST` | `/api/agent/complete` | Notifica que una tarea finalizó |

#### `POST /api/agent/register`
```json
// Request
{ "node_id": "node_abc123", "name": "nodo-usa-1" }

// Response
{ "success": true }
```

#### `POST /api/agent/poll`
```json
// Request
{ "node_id": "node_abc123", "cpu": 23.5, "ram": 41.2 }

// Response — sin tarea
{ "task": null }

// Response — con tarea
{ "task": { "id": 5, "command": "./scripts/flood.sh 1.2.3.4 80 60", "time": 60 } }

// Response — tarea cancelada
{ "cancel": true, "task_id": 5 }
```

#### `POST /api/agent/complete`
```json
// Request
{ "node_id": "node_abc123", "task_id": 5, "success": true }

// Response
{ "success": true }
```

### Endpoints del panel web (sin autenticación)

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/api/nodes` | Lista todos los nodos con su estado |
| `GET` | `/api/tasks` | Últimas 10 tareas con detalle de nodos |
| `POST` | `/api/tasks` | Lanzar una nueva tarea |
| `DELETE` | `/api/tasks/:id` | Cancelar una tarea en curso |
| `GET` | `/api/methods` | Lista de métodos configurados |
| `POST` | `/api/methods` | Crear un método |
| `PUT` | `/api/methods/:id` | Editar un método |
| `DELETE` | `/api/methods/:id` | Eliminar un método |
| `GET` | `/api/logs` | Últimos 200 logs |
| `GET` | `/api/logs/stream` | Stream SSE de logs en tiempo real |

---

## Base de datos

El master usa SQLite en modo WAL (Write-Ahead Logging) para mayor rendimiento. El archivo está en `/opt/master/master.db`.

### Tablas principales

```sql
nodes        → Estado y métricas de cada nodo registrado
methods      → Métodos configurados (tipo, script, argumentos)
tasks        → Historial de tareas lanzadas
task_nodes   → Relación tarea ↔ nodo (estado por nodo)
logs         → Logs del sistema (últimos 2000 entradas)
```

### Consultas útiles de diagnóstico

```bash
# Abrir la base de datos
sqlite3 /opt/master/master.db

# Ver nodos registrados
SELECT id, name, ip, country, status, datetime(last_seen/1000, 'unixepoch') as last FROM nodes;

# Ver últimas tareas
SELECT id, method_name, target, port, time, status FROM tasks ORDER BY id DESC LIMIT 20;

# Ver tareas por nodo
SELECT t.id, t.method_name, t.target, tn.node_name, tn.status
FROM tasks t JOIN task_nodes tn ON t.id = tn.task_id
ORDER BY t.id DESC LIMIT 30;

# Limpiar nodos offline antiguos (más de 7 días sin verse)
DELETE FROM nodes WHERE last_seen < (strftime('%s','now') - 604800) * 1000 AND status = 'offline';
```

---

## Jobs automáticos en background

El master tiene dos procesos internos que corren periódicamente sin intervención:

| Job | Intervalo | Función |
|-----|-----------|---------|
| **Detector de offline** | cada 15s | Marca como offline los nodos sin heartbeat en los últimos 35 segundos |
| **Expirador de tareas** | cada 30s | Completa automáticamente tareas cuyo tiempo expiró + 60s de buffer |

---

## Solución de problemas

### El panel no carga en el navegador

```bash
# 1. Verifica que el servicio master corre
systemctl status master

# 2. Verifica que nginx corre
systemctl status nginx

# 3. Comprueba que el puerto 80 está abierto en tu firewall
# En proveedores como Vultr/DO/Linode, verifica las reglas de firewall en el panel del proveedor

# 4. Prueba la conexión local
curl -s http://127.0.0.1:3000/api/nodes
```

### El master no arranca (error en los logs)

```bash
# Ver el error completo
journalctl -u master -n 50

# Problemas comunes:
# - Puerto 3000 en uso:
lsof -i :3000

# - Módulos npm no instalados:
cd /opt/master && npm install

# - Error en better-sqlite3 (compilación):
cd /opt/master && npm rebuild better-sqlite3
```

### Los nodos no aparecen en el panel

```bash
# Verifica que el token del master y del nodo coinciden
cat /opt/master/.env
# En el nodo:
# cat /opt/node-agent/agent.conf

# Prueba manualmente una petición de registro simulada
curl -X POST http://127.0.0.1:3000/api/agent/register \
  -H "Content-Type: application/json" \
  -H "x-agent-token: TU_TOKEN" \
  -d '{"node_id":"test","name":"test-nodo"}'
```

### Las tareas se quedan en "pending"

```bash
# Verifica que hay nodos online
curl -s http://127.0.0.1:3000/api/nodes | python3 -m json.tool

# Las tareas solo se asignan a nodos con status='online'
# Si todos están 'busy' u 'offline', la tarea no se procesa
```

### Reinstalar el master (limpieza total)

```bash
# Detener servicios
systemctl stop master nginx

# Eliminar archivos (¡esto borra la base de datos y métodos configurados!)
rm -rf /opt/master
rm -f /etc/systemd/system/master.service
rm -f /etc/nginx/sites-enabled/master
rm -f /etc/nginx/sites-available/master

systemctl daemon-reload
systemctl reload nginx

# Volver a instalar
bash install-master.sh
```

---

## Recomendaciones de seguridad

- **No expongas el puerto 3000** directamente. Nginx actúa como proxy y es el único punto de entrada
- **Usa HTTPS en producción** — configura un certificado SSL con Let's Encrypt:
  ```bash
  apt install certbot python3-certbot-nginx
  certbot --nginx -d tu.dominio.com
  ```
- **El token se genera automáticamente** con `openssl rand -hex 32` (64 chars hex) — no lo compartas
- **El archivo `.env` tiene permisos 600** — solo root puede leerlo
- **Rota el token periódicamente** si manejas nodos de terceros

---

## Relacionado

- **[flare-node](https://github.com/flaresamp/flare-node)** — Agente para los nodos (instalar en cada servidor)

---

<div align="center">
<sub>Flare Master Panel — parte del sistema Flare de administración distribuida de servidores</sub>
</div>
