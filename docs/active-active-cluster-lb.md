# Active-Active Dual-Node Architecture & Load Balancing (Mac + Gb10)

## Overview
This document specifies the high-availability, active-active dual-node architecture connecting the **primary Mac workstation** and the **remote Gb10 Linux server (`adi1` at `100.85.233.75`)** across Tailscale with automatic health-checking and failover.

---

## 1. Network Topology & Nodes

| Node | Hostname / IP | Role | Services Hosted |
|---|---|---|---|
| **Node A (Mac Primary)** | `localhost` / `mac-local` | Workstation & local-first orchestrator | Pulse daemon (port 31337), DevVisualization (port 8000), Local Ollama (port 11434), Firstmate Treehouse |
| **Node B (Gb10 / `adi1`)** | `100.85.233.75` (Tailscale) | Heavy compute & 24/7 background worker | Podman + Hermes, Secondary Firstmate Secondmate, Remote Ollama / GPU cluster |
| **Load Balancer (Caddy / HAProxy)** | `100.85.233.1` (Mesh VIP) | Reverse proxy & active health check router | Routes API, Webhook, and Dashboard traffic to healthy node |

---

## 2. Load Balancer Configuration (`Caddyfile`)

```caddy
# Active-Active Dual-Node Load Balancer (Mac + Gb10/adi1 @ 100.85.233.75)
# Reverse proxy with automated active health checks, failover, and retry policies.

{
    admin 127.0.0.1:2019
    auto_https disable_redirects
}

# 1. LifeOS / Pulse Daemon Service (Port 31337 / VIP 31330)
http://lifeos.internal, http://localhost:31330, :31330 {
    reverse_proxy {
        to 127.0.0.1:31337 100.85.233.75:31337

        # Health check configuration
        health_uri /api/pulse/health
        health_interval 5s
        health_timeout 2s
        health_status 200

        # Load balancing policy: first healthy upstream (Node A primary, Node B failover)
        lb_policy first
        lb_try_duration 4s
        lb_try_interval 250ms
    }
}

# 2. DevVisualization Dashboard (Port 8000 / VIP 8080)
http://devviz.internal, http://localhost:8080, :8080 {
    reverse_proxy {
        to 127.0.0.1:8000 100.85.233.75:8000

        # Health check configuration
        health_uri /api/health
        health_interval 10s
        health_timeout 2s
        health_status 200

        # Load balancing policy
        lb_policy first
        lb_try_duration 4s
        lb_try_interval 250ms
    }
}

# 3. Ollama / LLM Inference Cluster (Port 11434 / VIP 11430)
http://ollama.internal, http://localhost:11430, :11430 {
    reverse_proxy {
        to 127.0.0.1:11434 100.85.233.75:11434

        # Health check configuration
        health_uri /api/tags
        health_interval 10s
        health_timeout 3s
        health_status 200

        # Load balancing policy
        lb_policy first
        lb_try_duration 5s
        lb_try_interval 500ms
    }
}

# 4. Load Balancer Liveness & Status Endpoint
http://lb.internal, http://localhost:2020, :2020 {
    handle /health {
        respond "OK - Active-Active Dual-Node Load Balancer (Mac + Gb10/adi1 @ 100.85.233.75)" 200
    }
    handle {
        respond "LifeOS Active-Active Load Balancer Ready" 200
    }
}
```

---

## 3. State Synchronization (Litestream + Rsync)

1. **SQLite Databases (`feed-candidates.db`, `session-store.db`, `devviz.db`)**:
   - Replicated continuously using **Litestream** to shared S3/GCS bucket or bidirectional replica stream.
2. **Markdown Knowledge & TELOS (`~/.config/LIFEOS/USER/`)**:
   - Synced bi-directionally on file change via `com.lifeos.derivedsync` and Tailscale SSH rsync.
3. **Firstmate Fleet State & Git Worktrees**:
   - Coordinated through Git remotes (`origin/main`) and remote secondmate protocol (`docs/remote-secondmates.md`).

---

## 4. Disaster Recovery & Failover Mechanics

- If Node A (Mac) goes offline (sleep / restart), Caddy automatically routes inbound webhooks, Telegram pollers, and API requests to Node B (`Gb10`).
- When Node A resumes, the health check passes, and traffic seamlessly rejoins the primary node without dropped sessions or data corruption.

---

## 5. Deployment Check & Health Verification

Validate configuration syntax and probe dual-node connectivity using `bin/fm-active-active-check.sh`:

```bash
# Validate Caddyfile syntax only
bin/fm-active-active-check.sh --validate

# Run full live cluster connectivity and health probes
bin/fm-active-active-check.sh

# Output machine-readable JSON status summary
bin/fm-active-active-check.sh --json

# Simulate Mac outage to test failover routing logic
bin/fm-active-active-check.sh --simulate-failover
```

