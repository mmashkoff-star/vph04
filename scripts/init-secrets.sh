#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

rand() {
  openssl rand -hex 24
}

detect_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

if [[ ! -f .env ]]; then
  SERVER_IP="$(detect_ip)"
  cat > .env <<EOF
POSTGRES_USER=deluxe
POSTGRES_PASSWORD='$(rand)'
POSTGRES_DB=deluxe_auto

PGADMIN_DEFAULT_EMAIL=admin@deluxe-auto.ru
PGADMIN_DEFAULT_PASSWORD='$(rand)'

REGISTRY_USER=deluxe
REGISTRY_PASSWORD='$(rand)'
SERVER_IP=${SERVER_IP:-127.0.0.1}
EOF
  echo "Created .env"
else
  echo ".env already exists, keeping current secrets"
fi

chmod 600 .env

python3 - <<'PY'
from pathlib import Path
import json, subprocess, os

root = Path(".")

def load_env(path: Path) -> dict:
    vals = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        vals[key] = value
    return vals

env = load_env(root / ".env")
required = ["REGISTRY_USER", "REGISTRY_PASSWORD", "SERVER_IP"]
missing = [k for k in required if not env.get(k)]
if missing:
    raise SystemExit(f"Missing keys in .env: {', '.join(missing)}")

auth_dir = root / "registry" / "auth"
auth_dir.mkdir(parents=True, exist_ok=True)
htpasswd = auth_dir / "htpasswd"
with htpasswd.open("w") as fh:
    subprocess.run(
        ["htpasswd", "-Bbn", env["REGISTRY_USER"], env["REGISTRY_PASSWORD"]],
        check=True,
        stdout=fh,
    )
os.chmod(htpasswd, 0o600)

import base64
token = base64.b64encode(
    f'{env["REGISTRY_USER"]}:{env["REGISTRY_PASSWORD"]}'.encode()
).decode()
auths = {
    "auths": {
        "127.0.0.1:5000": {"auth": token},
        "localhost:5000": {"auth": token},
        f'{env["SERVER_IP"]}:5000': {"auth": token},
    }
}
cfg = root / "registry" / "docker-config.json"
cfg.write_text(json.dumps(auths, indent=2) + "\n")
os.chmod(cfg, 0o600)
print("Wrote registry/auth/htpasswd")
print("Wrote registry/docker-config.json")
PY
