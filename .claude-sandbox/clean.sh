#!/usr/bin/env bash
# setup.sh で作られる動的生成物を全て削除し、コミット直後の状態に戻す。
#
# 使い方:
#   ./.claude-sandbox/clean.sh
#
# 用途:
#   - 認証モード (A/B/C) を切り替えてゼロから初期化したい
#   - 別アカウントの認証情報が残っているのが気になる
#   - 配布前に手元の sandbox.config を消したい
#
# 影響範囲:
#   - sandbox.config / .runtime.env / docker-compose.override.yml を削除
#   - proxy/certs/* (mitmproxy CA) を削除 (.gitkeep は残す)
#   - volumes/ 中身を削除 (mitmproxy フロー記録など)
#   - auth/claude-config/* と auth/claude-config.json を削除 (.gitkeep は残す)
#   - git/ (mode H の PAT credential と生成 gitconfig) を削除
#     ※ grants.conf (許可範囲の宣言。トークン本体は含まない) は残す
#
# 注意:
#   docker named volume (bundle-cache / node-modules-cache / venv-cache 等)
#   はこのスクリプトでは消さない。完全リセットしたい場合は別途:
#     docker compose --env-file sandbox.config down -v
#   worker.sh で作った worktree (.git/.worktrees/<name>) も消さない
#   (未 push 作業が残っている可能性があるため)。個別に後始末する:
#     ./.claude-sandbox/worker.sh --remove <branch>
#   worker.sh がホストリポの .git に残す変更 (gc.worktreePruneExpire /
#   .git/info/exclude) もここでは戻さない。全 worktree 削除後に:
#     ./.claude-sandbox/worker.sh --reset
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> .claude-sandbox/ の動的生成物を削除..."
rm -fv sandbox.config .runtime.env docker-compose.override.yml

# proxy/certs/* — .gitkeep は残す
find proxy/certs -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true

# auth/claude-config/* と auth/claude-config.json — .gitkeep は残す
find auth/claude-config -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
rm -fv auth/claude-config.json 2>/dev/null || true

# volumes/ 中身 (.gitkeep が無い構造なので mindepth 1 で全消し)
find volumes -mindepth 1 -delete 2>/dev/null || true

# git/ — mode H の PAT credential と生成 gitconfig (grants.conf は残す)
rm -rfv git 2>/dev/null || true

echo ""
echo "次の手順:"
echo "  ./setup.sh                                         # クリーンに再セットアップ"
echo "  # コンテナ・named volume も完全リセットするなら:"
echo "  docker compose --env-file sandbox.config down -v   # (setup.sh 後に実行可能)"
