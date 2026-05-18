#!/usr/bin/env bash
# egress-proxy のログを tail (allowlist 判定の JSON が流れる)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

[ -f sandbox.config ] || { echo "sandbox.config がありません。" >&2; exit 1; }
exec docker compose --env-file sandbox.config logs -f egress-proxy
