# oneclick-deploy-enterprise

**Zero-downtime one-click deployment for Spring Boot on Ubuntu/Debian.**
Blue/Green releases on `8081/8082`, hardened `systemd` service, Nginx reverse proxy, optional Let’s Encrypt TLS, SBOM (CycloneDX), checksums, release retention, and instant rollback — all from a single script.

> **SSH-safe by design**: the script explicitly ensures OpenSSH is running and keeps TCP/22 allowed if UFW/nftables exist. It never disables or tightens your SSH access.

---

## Table of Contents

* [What you get](#what-you-get)
* [How it works](#how-it-works)
* [Requirements](#requirements)
* [Quick start](#quick-start)
* [Configuration](#configuration)
* [Directory layout](#directory-layout)
* [TLS / HTTPS](#tls--https)
* [Rollback](#rollback)
* [Destroy / cleanup](#destroy--cleanup)
* [Security hardening](#security-hardening)
* [Troubleshooting](#troubleshooting)
* [What this is NOT](#what-this-is-not)
* [Contributing](#contributing)
* [License](#license)

---

## What you get

* **Blue/Green** deploys (ports **8081** & **8082**) with health-gated cutover.
* **Nginx** reverse proxy on :80 (and :443 with TLS), with:

  * Security headers (CSP, X-Frame-Options, etc.)
  * Request **rate limiting**
  * gzip compression (and brotli if installed)
* **Hardened `systemd`** unit (non-root user, sandboxing directives).
* **Supply-chain safety**: per-release **SBOM (CycloneDX)** + **SHA256 checksums**.
* **Release management**: atomic `current → release-<timestamp>` symlink, retention policy, **one-shot rollback**.
* **Idempotent**: safe to re-run.
* **SSH guardrails**: OpenSSH ensured active; 22/tcp stays allowed if UFW/nftables present.

---

## How it works

1. Generates a Spring Boot project (via [start.spring.io](https://start.spring.io) or local scaffold fallback).
2. Builds a **fat JAR** with Maven.
3. Creates a **versioned release** under `/opt/<app>/releases/release-YYYYMMDD_HHMMSS/`.
4. Updates `current → release-…` **directory symlink** (atomic).
5. Starts the **inactive color** (`8081` or `8082`) as a `systemd` instance `<app>@<port>`.
6. Waits for `/actuator/health` → `UP`, then flips Nginx upstream and stops the old color.
7. Optionally issues/renews **Let’s Encrypt** certificate and enforces HTTPS.

---

## Requirements

* **OS**: Ubuntu/Debian with `systemd`
* **Network**: Outbound internet to Maven Central and (ideally) start.spring.io
* **Ports** (cloud/VPC firewall):

  * **22/tcp** (SSH) — **must be open** (script preserves it)
  * **80/tcp** (HTTP) — required for HTTP and Let’s Encrypt HTTP-01
  * **443/tcp** (HTTPS) — if using TLS
* **Privileges**: `sudo` (for systemd/nginx/files under `/opt`)

---

## Quick start

Clone and run:

```bash
git clone https://github.com/<your-org-or-user>/<repo>.git
cd <repo>

# Make executable
chmod +x oneclick-deploy-enterprise.sh

# Basic (HTTP only)
sudo ./oneclick-deploy-enterprise.sh
```

Enable **TLS with Let’s Encrypt**:

```bash
# Use your real domain (DNS must point to the VM's public IP)
DOMAIN=app.example.com EMAIL=admin@example.com sudo ./oneclick-deploy-enterprise.sh
```

Re-deploy (zero-downtime) by simply re-running the script. It will build a new release, health-check it, switch traffic, and retain prior releases.

---

## Configuration

All knobs are environment variables (sane defaults shown):

| Variable        |            Default | Description                                     |
| --------------- | -----------------: | ----------------------------------------------- |
| `APP_NAME`      |       `hello-boot` | Application & systemd unit base name.           |
| `GROUP_ID`      |      `com.example` | Maven groupId for scaffolded project.           |
| `PACKAGE`       | `com.example.demo` | Java package base.                              |
| `JAVA_RELEASE`  |               `17` | Java release for compilation.                   |
| `JDK_PKG`       |   `openjdk-17-jdk` | JDK package to install (e.g. `openjdk-21-jdk`). |
| `USE_NGINX`     |              `yes` | `yes` to manage Nginx reverse proxy.            |
| `DOMAIN`        |          *(empty)* | Your domain; enables TLS if `EMAIL` also set.   |
| `EMAIL`         |          *(empty)* | ACME email for Let’s Encrypt.                   |
| `PORT_A`        |             `8081` | Blue port.                                      |
| `PORT_B`        |             `8082` | Green port.                                     |
| `KEEP_RELEASES` |                `5` | How many releases to retain.                    |
| `RATE`          |            `10r/s` | Nginx rate limit per IP.                        |
| `BURST`         |               `20` | Nginx rate limit burst.                         |
| `ROLLBACK`      |                `0` | Set to `1` to perform a rollback.               |

Examples:

```bash
# Change app name and use JDK 21
APP_NAME=myapp JDK_PKG=openjdk-21-jdk sudo ./oneclick-deploy-enterprise.sh

# Force rollback to previous release
ROLLBACK=1 sudo ./oneclick-deploy-enterprise.sh
```

---

## Directory layout

```
/opt/<APP_NAME>/
├── current -> /opt/<APP_NAME>/releases/release-YYYYMMDD_HHMMSS/
├── releases/
│   ├── release-20250910_090107/
│   │   ├── app.jar
│   │   └── SBOM-cyclonedx.xml           (if generated)
└── checksums/
    └── app-20250910_090107.sha256

/etc/<APP_NAME>/env                      # JVM & app env (systemd EnvironmentFile)
/etc/systemd/system/<APP_NAME>@.service  # templated systemd unit
/etc/nginx/sites-available/<APP_NAME>    # nginx site (linked into sites-enabled)
```

---

## TLS / HTTPS

Provide `DOMAIN` and `EMAIL`:

```bash
DOMAIN=app.example.com EMAIL=admin@example.com sudo ./oneclick-deploy-enterprise.sh
```

* Requests/renews a Let’s Encrypt cert via `certbot --nginx`.
* Adds **HSTS** and security headers.
* Make sure your DNS A/AAAA records point to the VM public IP and your cloud firewall allows **80/443**.

---

## Rollback

Roll back to the last release (the script flips traffic to the previous color and rewrites the `current` symlink atomically):

```bash
ROLLBACK=1 sudo ./oneclick-deploy-enterprise.sh
```

---

## Destroy / cleanup

This repo also includes a **non-destructive cleanup** script that removes all artifacts created by the deploy (services, Nginx site, `/opt/<APP_NAME>` tree), **without uninstalling packages** or touching SSH/22:

```bash
chmod +x oneclick-destroy.sh
# basic cleanup:
sudo ./oneclick-destroy.sh

# also delete Let's Encrypt certificate:
DOMAIN=app.example.com CLEAN_CERTS=yes sudo ./oneclick-destroy.sh
```

---

## Security hardening

* Runs as a **dedicated non-login user** (`useradd -r -U -s /usr/sbin/nologin`).
* `systemd` sandboxing:

  * `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=true`,
  * `ProtectKernelTunables=yes`, `ProtectControlGroups=yes`, `ProtectProc=invisible`,
  * `CapabilityBoundingSet=` (empty), `RestrictSUIDSGID=yes`,
  * `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute=yes`, etc.
* Nginx:

  * **Security headers**: CSP, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy.
  * **Rate limiting** (`limit_req_zone`, burst).
  * gzip enabled (add brotli if you prefer).
* **SBOM** (CycloneDX) and **SHA256** checksums per release.

> The script **never** enables UFW or changes default-deny policies. If UFW/nftables exist, it only **adds allow rules for 22/tcp** to avoid accidental lockouts. OpenSSH is ensured to be installed and running.

---

## Troubleshooting

Common commands:

```bash
# Check active color/port
cat /opt/<APP_NAME>/active_port

# App service status & logs (replace PORT with 8081/8082)
sudo systemctl status <APP_NAME>@PORT --no-pager
sudo journalctl -u <APP_NAME>@PORT -n 200 --no-pager

# Health endpoint (local)
curl -fsS http://127.0.0.1:8081/actuator/health
curl -fsS http://127.0.0.1:8082/actuator/health

# Nginx config & reload
sudo nginx -t && sudo systemctl reload nginx

# Confirm SSH is listening
ss -ltn | grep ':22 '
```

If `start.spring.io` is unreachable, the script auto-scaffolds a minimal Boot app locally and proceeds.

---

## What this is NOT

* Not a database or secrets manager (bring your own Postgres/Redis/Vault, etc.).
* Not a cluster scheduler or autoscaler (consider k8s/nomad if you need that).
* Not a replacement for full observability. You can enable `/actuator/prometheus` and integrate Prometheus/Grafana as a follow-up.

---

## Contributing

Issues and PRs are welcome!
Ideas: containerized build option (`podman`/`docker`), Prometheus scrape config, brotli by default, dual-stack TLS config templates.

---

## License

MIT (or your preferred OSS license). Add a `LICENSE` file at the repo root.

---

## Script

The full script lives here: **`oneclick-deploy-enterprise.sh`** (excerpted in the issue).
Make sure it’s executable:

```bash
chmod +x oneclick-deploy-enterprise.sh
```

Then run with `sudo`, optionally supplying `DOMAIN`/`EMAIL` for TLS.

---

**Happy zero-downtime shipping 🚀**
