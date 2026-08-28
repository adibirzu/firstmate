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
# Caddy Active-Active Reverse Proxy with Health Checks
lifeos.internal {
    reverse_proxy {
        to 127.0.0.1:31337 100.85.233.75:31337

        # Health check configuration
        health_uri /api/pulse/health
        health_interval 5s
        health_timeout 2s
        health_status 200

        # Load balancing policy: round_robin or first (failover)
        lb_policy first
        lb_try_duration 4s
        lb_try_interval 250ms
    }
}

devviz.internal {
    reverse_proxy {
        to 127.0.0.1:8000 100.85.233.75:8000
        health_uri /api/health
        health_interval 10s
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
