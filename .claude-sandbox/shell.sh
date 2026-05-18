#!/usr/bin/env bash
# agent コンテナに bash で入る (デバッグ・claude login 用)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

[ -f sandbox.config ] || { echo "sandbox.config がありません。./setup.sh を先に実行してください。" >&2; exit 1; }

exec docker compose --env-file sandbox.config run --rm -it agent bash
