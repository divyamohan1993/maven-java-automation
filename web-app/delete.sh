#!/usr/bin/env bash
# oneclick-destroy.sh — remove resources created by oneclick-deploy-enterprise.sh
# Safe: does NOT uninstall packages and does NOT touch SSH/22 or firewall policies.

set -euo pipefail

APP_NAME="${APP_NAME:-hello-boot}"
DOMAIN="${DOMAIN:-}"              # optional; if omitted, will try to read from Nginx site
CLEAN_CERTS="${CLEAN_CERTS:-no}"  # yes|no — delete Let's Encrypt cert for DOMAIN
KEEP_BACKUPS="${KEEP_BACKUPS:-1}" # keep nginx.conf backup(s)

INSTALL_DIR="/opt/${APP_NAME}"
RELEASES_DIR="${INSTALL_DIR}/releases"
CURRENT_DIR_LINK="${INSTALL_DIR}/current"
CHECKSUMS_DIR="${INSTALL_DIR}/checksums"
ENV_FILE="/etc/${APP_NAME}/env"
SVC_TEMPLATE="/etc/systemd/system/${APP_NAME}@.service"
NGX_SITE="/etc/nginx/sites-available/${APP_NAME}"
NGX_LINK="/etc/nginx/sites-enabled/${APP_NAME}"
NGX_CONF="/etc/nginx/nginx.conf"

log(){ echo ">>> $*"; }
warn(){ echo "!!! $*" >&2; }

# --- 0) Detect domain from Nginx site if not provided ---
if [ -z "${DOMAIN}" ] && [ -f "${NGX_SITE}" ]; then
  # grab first non-underscore server_name
  sn="$(awk '/server_name/ {for(i=1;i<=NF;i++) if ($i!="server_name") print $i}' "${NGX_SITE}" | tr -d ';' | head -n1 || true)"
  if [ -n "${sn:-}" ] && [ "${sn}" != "_" ]; then DOMAIN="${sn}"; fi
fi

# --- 1) Stop & disable all instances of ${APP_NAME}@*.service ---
log "Stopping ${APP_NAME} instances (if any)..."
if command -v systemctl >/dev/null 2>&1; then
  # list any active or inactive instantiated units
  mapfile -t units < <(systemctl list-units --all --no-legend --plain "${APP_NAME}@*.service" 2>/dev/null | awk '{print $1}')
  for u in "${units[@]:-}"; do
    sudo systemctl stop "$u" || true
    sudo systemctl disable "$u" || true
  done
  # also try known blue/green ports
  for p in 8081 8082; do
    sudo systemctl stop "${APP_NAME}@${p}" 2>/dev/null || true
    sudo systemctl disable "${APP_NAME}@${p}" 2>/dev/null || true
  done
else
  warn "systemctl not found; skipping service stop/disable."
fi

# --- 2) Remove systemd unit template & reload daemon ---
if [ -f "${SVC_TEMPLATE}" ]; then
  log "Removing systemd unit template: ${SVC_TEMPLATE}"
  sudo rm -f "${SVC_TEMPLATE}"
  command -v systemctl >/dev/null 2>&1 && sudo systemctl daemon-reload || true
fi

# --- 3) Remove Nginx site (enabled & available) and reload Nginx ---
if [ -L "${NGX_LINK}" ] || [ -f "${NGX_LINK}" ]; then
  log "Removing Nginx enabled symlink: ${NGX_LINK}"
  sudo rm -f "${NGX_LINK}" || true
fi
if [ -f "${NGX_SITE}" ]; then
  log "Removing Nginx site file: ${NGX_SITE}"
  sudo rm -f "${NGX_SITE}" || true
fi

# Clean the limit_req_zone line we inserted (only that exact 'reqs' zone).
# Backup nginx.conf first.
if [ -f "${NGX_CONF}" ]; then
  TS="$(date +%Y%m%d_%H%M%S)"
  BK="${NGX_CONF}.bak-${TS}"
  sudo cp -p "${NGX_CONF}" "${BK}"
  # Remove any lines that look exactly like our injected zone.
  sudo sed -i "/limit_req_zone[[:space:]]\+\$binary_remote_addr[[:space:]]\+zone=reqs:10m[[:space:]]\+rate=/d" "${NGX_CONF}"
  # If nginx test fails, restore backup.
  if command -v nginx >/dev/null 2>&1; then
    if ! sudo nginx -t >/dev/null 2>&1; then
      warn "nginx -t failed; restoring ${NGX_CONF} from backup."
      sudo mv -f "${BK}" "${NGX_CONF}"
    else
      # keep only the latest backups, if configured
      if [ "${KEEP_BACKUPS}" -eq 0 ]; then
        sudo rm -f "${BK}" || true
      else
        # prune older .bak-* keeping the last KEEP_BACKUPS
        mapfile -t baks < <(ls -1t /etc/nginx/nginx.conf.bak-* 2>/dev/null || true)
        idx=0
        for f in "${baks[@]:-}"; do
          idx=$((idx+1))
          [ $idx -le "${KEEP_BACKUPS}" ] && continue
          sudo rm -f "$f" || true
        done
      fi
    fi
  fi
  # Reload nginx to apply site removal (safe if nginx present)
  command -v nginx >/dev/null 2>&1 && { sudo nginx -t && sudo systemctl reload nginx || true; }
fi

# --- 4) Optionally delete Let's Encrypt cert for DOMAIN ---
if [ "${CLEAN_CERTS}" = "yes" ] && [ -n "${DOMAIN}" ]; then
  if command -v certbot >/dev/null 2>&1; then
    log "Deleting Let's Encrypt certificate for ${DOMAIN} (if exists)..."
    # non-interactive deletion if cert exists
    (sudo certbot delete --cert-name "${DOMAIN}" -n || true)
  else
    warn "certbot not found; skipping cert deletion."
  fi
fi

# --- 5) Remove env file and app directories ---
if [ -f "${ENV_FILE}" ]; then
  log "Removing env file: ${ENV_FILE}"
  sudo rm -f "${ENV_FILE}" || true
  # Remove parent directory if empty
  sudo rmdir --ignore-fail-on-non-empty "/etc/${APP_NAME}" 2>/dev/null || true
fi

if [ -d "${INSTALL_DIR}" ]; then
  log "Removing install dir: ${INSTALL_DIR}"
  sudo rm -rf "${INSTALL_DIR}" || true
fi

# --- 6) (Optional) remove the service user if it exists and no home dir remains ---
if id "${APP_NAME}" >/dev/null 2>&1; then
  # Only remove if home is our INSTALL_DIR and it no longer exists
  HOME_DIR="$(getent passwd "${APP_NAME}" | cut -d: -f6 || true)"
  if [ "${HOME_DIR}" = "${INSTALL_DIR}" ] && [ ! -d "${INSTALL_DIR}" ]; then
    log "Removing service user: ${APP_NAME}"
    sudo userdel "${APP_NAME}" || true
    # Remove leftover home dir if userdel didn't clean (race-safe)
    sudo rm -rf "${HOME_DIR}" 2>/dev/null || true
  else
    warn "Not removing user ${APP_NAME} (home not ${INSTALL_DIR} or still present)."
  fi
fi

# --- 7) Final status ---
echo "------------------------------------------------------------"
echo "Destroyed resources for app: ${APP_NAME}"
echo "- Services    : ${APP_NAME}@<port> (stopped/disabled if present)"
echo "- Systemd     : ${SVC_TEMPLATE} (removed if present)"
echo "- Nginx site  : ${NGX_SITE} (+ enabled symlink) (removed if present)"
echo "- Nginx conf  : cleaned 'limit_req_zone ... zone=reqs' line (if present)"
[ -n "${DOMAIN}" ] && echo "- Certbot     : cert for ${DOMAIN} deleted: ${CLEAN_CERTS}"
echo "- Files       : ${INSTALL_DIR} tree, ${ENV_FILE} (removed)"
echo "- User        : ${APP_NAME} (removed only if safe)"
echo "NOTE          : SSH/22 was NOT modified. Packages were NOT uninstalled."
echo "------------------------------------------------------------"
