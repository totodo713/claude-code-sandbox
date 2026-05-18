#!/usr/bin/env bash
# claude をサンドボックスコンテナ内で起動
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

[ -f sandbox.config ] || { echo "sandbox.config がありません。./setup.sh を先に実行してください。" >&2; exit 1; }
[ -f proxy/certs/mitmproxy-ca-cert.pem ] || { echo "CA がありません。./setup.sh --ca-only を実行してください。" >&2; exit 1; }

exec docker compose --env-file sandbox.config run --rm -it agent claude "$@"
