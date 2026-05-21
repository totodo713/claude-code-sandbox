#!/usr/bin/env bash
# worker.sh — worktree 単位で隔離した worker claude をサンドボックスで起動する。
#
# Main agent (run.sh) とは別ブランチ・別 worktree で動く worker を立てる。egress-proxy
# と DL キャッシュ (pnpm store / uv cache 等) は run.sh と共有しつつ、作業ツリーと
# インストール済み依存 (.venv / node_modules / gem) は worktree 内に閉じ込めて隔離する。
#
# 使い方:
#   ./worker.sh <branch> [base-ref]      worktree を用意して worker claude を起動
#   ./worker.sh --shell <branch> [base]  同上だが bash で入る (デバッグ用)
#   ./worker.sh --list                   登録済み worktree を一覧
#   ./worker.sh --remove <branch>        worktree (と中の依存) を削除 (branch は残す)
#
# 例:
#   ./worker.sh fix/issue-123 main       main から fix/issue-123 を切って worker 起動
#
# 設計メモ:
#   - worktree は /workspace/.git/.worktrees/<name> (= .git 配下) に作る。git は .git
#     配下を走査しないので追跡されず、ホスト側もプロジェクトフォルダ内に収まる。
#   - worktree は **コンテナ内で** 作る。git 2.43 は相対パス worktree
#     (worktree.useRelativePaths, 2.48+) を持たず gitdir を絶対パスで記録するため、
#     /workspace を正準パスに統一しないとコンテナ内で gitdir が解決できない。
#   - 依存は worktree 内に置く。worktree は元々別ディレクトリなのでこれだけで分離でき、
#     pnpm store と同一 fs なので hardlink も効く。node_modules/.venv は repo の
#     .gitignore (/node_modules/ /.venv/) が、gem の保存先 .worker-bundle は
#     .git/info/exclude への追記が、それぞれ git status を汚さないようにする。
#     (named volume を worktree に重ねたり node_modules を symlink にすると、
#      `git worktree add` の "already exists" や pnpm の ENOTDIR で失敗する。)
#   - 起動は bash -c (非ログイン)。bash -l は /etc/profile が PATH を上書きし
#     /opt/runtimes/* を落とすため (run.sh が claude を直接 exec するのと同じ理由)。
#   - UV_PYTHON_PREFERENCE=only-system: uv 既定の managed Python ダウンロード
#     (~/.local/share/uv は root 所有で書けない) を止め、ピン留めの
#     /opt/runtimes/python を使わせる。
#   - ホスト git でうっかり prune しないよう gc.worktreePruneExpire=never を立てる
#     (worktree の記録パス /workspace/... はホストに存在せず prune 対象に見える)。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

[ -f sandbox.config ] || { echo "sandbox.config がありません。./setup.sh を先に実行してください。" >&2; exit 1; }

WORKTREE_ROOT="/workspace/.git/.worktrees"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

# branch 名をパス/ボリューム名に使える slug へ変換 (英数 . _ - 以外は - に畳む)
slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

cmd_list() {
  docker compose --env-file sandbox.config run --rm -T agent \
    git -C /workspace worktree list
}

cmd_remove() {
  local branch="$1" name
  name=$(slug "$branch")
  echo ">> worktree '${WORKTREE_ROOT}/${name}' を削除 (branch '${branch}' は残します)..."
  docker compose --env-file sandbox.config run --rm -T agent bash -c "
    git -C /workspace worktree remove --force '${WORKTREE_ROOT}/${name}' 2>/dev/null || true
    git -C /workspace worktree prune
  "
  echo ">> done"
}

launch() {
  local mode="$1" branch="$2" base="${3:-HEAD}"
  [ -n "$branch" ] || { usage; exit 1; }
  local name wt boot final
  name=$(slug "$branch")
  wt="${WORKTREE_ROOT}/${name}"

  # コンテナ内 bootstrap: worktree 用意 → status 汚染防止 → cd
  boot="
set -e
git -C /workspace config gc.worktreePruneExpire never
# gem 保存先 .worker-bundle は .gitignore に無いので info/exclude で隠す (冪等)。
grep -qxF .worker-bundle /workspace/.git/info/exclude 2>/dev/null || echo .worker-bundle >> /workspace/.git/info/exclude
if ! git -C /workspace worktree list --porcelain | grep -qx 'worktree ${wt}'; then
  if git -C /workspace show-ref --verify --quiet 'refs/heads/${branch}'; then
    git -C /workspace worktree add '${wt}' '${branch}'
  else
    git -C /workspace worktree add '${wt}' -b '${branch}' '${base}'
  fi
fi
cd '${wt}'
"
  if [ "$mode" = shell ]; then
    final="${boot} exec bash"
  else
    final="${boot} exec claude"
  fi

  exec docker compose --env-file sandbox.config run --rm -it \
    -e UV_PYTHON_PREFERENCE=only-system \
    -e GEM_HOME="${wt}/.worker-bundle" \
    -e BUNDLE_PATH="${wt}/.worker-bundle" \
    agent bash -c "${final}"
}

case "${1:-}" in
  --list)        cmd_list ;;
  --remove)      shift; [ -n "${1:-}" ] || { usage; exit 1; }; cmd_remove "$1" ;;
  --shell)       shift; launch shell "${1:-}" "${2:-}" ;;
  -h|--help|"")  usage ;;
  *)             launch claude "$1" "${2:-}" ;;
esac
