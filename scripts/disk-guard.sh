#!/usr/bin/env bash
# Не даёт диску VPS дойти до 100%. Не трогает тома Postgres/pgAdmin/Registry.
set -u

exec 9>/run/deluxe-disk-guard.lock
if ! flock -n 9; then
  exit 0
fi

log() {
  logger -t deluxe-disk-guard -- "$@"
  echo "$(date -Is) $*"
}

df_pct() {
  df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }'
}

df_avail_mb() {
  df -P / | awk 'NR==2 { printf "%d", $4/1024 }'
}

pct="$(df_pct)"
avail="$(df_avail_mb)"
log "start use=${pct}% avail=${avail}MB"

journalctl --vacuum-size=50M >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true

find /tmp /var/tmp -xdev -type f -mtime +1 -delete >/dev/null 2>&1 || true
find /var/tmp -xdev -type f -mtime +1 -delete >/dev/null 2>&1 || true

if command -v docker >/dev/null 2>&1 && timeout 20 docker info >/dev/null 2>&1; then
  timeout 30 docker image prune -f >/dev/null 2>&1 || true
  timeout 30 docker builder prune -f >/dev/null 2>&1 || true
fi

if [[ "${pct}" -ge 80 ]]; then
  docker system prune -f >/dev/null 2>&1 || true
  timeout 30 docker exec deluxe_registry /bin/registry garbage-collect /etc/docker/registry/config.yml >/dev/null 2>&1 || true
  log "level80 prune+registry-gc use=$(df_pct)%"
fi

if [[ "${pct}" -ge 90 ]]; then
  journalctl --vacuum-size=20M >/dev/null 2>&1 || true
  rm -rf /var/lib/apt/lists/* >/dev/null 2>&1 || true
  find /var/log -xdev -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete >/dev/null 2>&1 || true
  log "level90 vacuum use=$(df_pct)%"
fi

log "done use=$(df_pct)% avail=$(df_avail_mb)MB"
exit 0
