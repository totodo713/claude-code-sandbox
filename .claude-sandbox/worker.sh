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
#   ./worker.sh --reset                  ホストリポの worker.sh 由来 .git 変更を戻す
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
#     pnpm は store を /workspace (home と別 fs) 配下に自動配置するので hardlink も効く。
#     node_modules / .venv / gem 保存先 .worker-bundle はいずれも .git/info/exclude へ
#     冪等追記して git status を汚さない (配布先 repo の .gitignore に依存しない)。
#     (named volume を worktree に重ねたり node_modules を symlink にすると、
#      `git worktree add` の "already exists" や pnpm の ENOTDIR で失敗する。)
#   - ブランチ名・base はコンテナ内スクリプトへ **文字列補間せず env で渡す** (branch
#     名経由のシェルインジェクション防止)。入口で branch 名を検証する。
#   - 起動は bash -c (非ログイン)。bash -l は /etc/profile が PATH を上書きし
#     /opt/runtimes/* を落とすため (run.sh が claude を直接 exec するのと同じ理由)。
#   - UV_PYTHON_PREFERENCE=only-system: uv 既定の managed Python ダウンロード
#     (~/.local/share/uv は root 所有で書けない) を止め、ピン留めの
#     /opt/runtimes/python を使わせる。
#   - ホスト git でうっかり prune しないよう gc.worktreePruneExpire=never を立てる
#     (worktree の記録パス /workspace/... はホストに存在せず prune 対象に見える)。
#   - 上記の gc 設定と .git/info/exclude 追記は **ホストリポ本体への恒久変更** (.git/config /
#     .git/info/exclude) で、clean.sh では戻らない。--reset で明示的に取り消せる。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

[ -f sandbox.config ] || { echo "sandbox.config がありません。./setup.sh を先に実行してください。" >&2; exit 1; }
[ -f proxy/certs/mitmproxy-ca-cert.pem ] || { echo "CA がありません。./setup.sh --ca-only を実行してください。" >&2; exit 1; }

WORKTREE_ROOT="/workspace/.git/.worktrees"

usage() {
  cat <<'EOF'
worker.sh — worktree 単位で隔離した worker claude をサンドボックスで起動する。

使い方:
  ./worker.sh <branch> [base-ref]      worktree を用意して worker claude を起動
  ./worker.sh --shell <branch> [base]  同上だが bash で入る (デバッグ用)
  ./worker.sh --list                   登録済み worktree を一覧
  ./worker.sh --remove <branch>        worktree (と中の依存) を削除 (branch は残す)
  ./worker.sh --reset                  ホストリポの worker.sh 由来 .git 変更を戻す

注意: --remove は worktree 内の未コミット変更も破棄する (push/commit 済みか確認)。

例:
  ./worker.sh fix/issue-123 main       main から fix/issue-123 を切って worker 起動

branch 名は英数で始まり [A-Za-z0-9 . _ / -] のみ。base 省略時は HEAD
(= main 側コンテナの現在チェックアウト) から切るので、意図したベースは明示推奨。
EOF
}

# branch 名をパス安全な slug へ変換 (英数 . _ - 以外は - に畳む)。検証後のみ呼ぶ。
slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# branch 名を検証 (path / コンテナ内スクリプトに乗せる前に弾く)。bash の [[ =~ ]] は
# 文字列全体に対して評価するので、改行入りの値も 1 段目で弾ける (grep -E の行単位
# マッチだとすり抜ける)。
validate_branch() {
  local b="$1"
  [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
    echo "不正なブランチ名 '$b': 英数で始まり [A-Za-z0-9 . _ / -] のみ使用できます。" >&2; exit 1; }
  case "$b" in
    */|*//*|*..*) echo "不正なブランチ名 '$b': 連続/末尾の '/' や '..' は使えません。" >&2; exit 1 ;;
  esac
  git check-ref-format --branch "$b" >/dev/null 2>&1 || {
    echo "git が受け付けないブランチ名: '$b'" >&2; exit 1; }
}

# base-ref を検証 (env 渡しなので注入はしないが、明らかに不正な値は早期に弾く)。
# validate_branch と同じく [[ =~ ]] で文字列全体を評価し、改行入りの値も弾く
# (grep -E の行単位マッチだとすり抜ける)。
validate_base() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/~^@{}-]*$ ]] || {
    echo "不正な base-ref '$1'。" >&2; exit 1; }
}

# worktree の参照・削除・reset は egress-proxy を必要としないので --no-deps で proxy を
# 起こさず実行する (proxy のビルド/ヘルスチェック待ちを避ける)。
cmd_list() {
  docker compose --env-file sandbox.config run --rm -T --no-deps agent \
    git -C /workspace worktree list
}

cmd_remove() {
  local branch="$1" name wt
  validate_branch "$branch"
  name=$(slug "$branch"); wt="${WORKTREE_ROOT}/${name}"
  docker compose --env-file sandbox.config run --rm -T --no-deps -e WT="$wt" agent bash -c '
    if git -C /workspace worktree list --porcelain | grep -qx "worktree $WT"; then
      git -C /workspace worktree remove --force "$WT" && echo ">> 削除しました: $WT (branch は残ります)"
    else
      echo ">> 該当する worktree はありません: $WT"
    fi
    # gc.worktreePruneExpire=never の影響を受けず確実に admin entry を掃除する。
    git -C /workspace worktree prune --expire=now
  '
}

# worker.sh がホストリポ本体 (/workspace/.git) に残す恒久変更を取り消す。
# worktree が残っていると gc 保護を外した瞬間にホスト git の prune 対象になるため、
# 先に全 worker worktree を --remove させてから実行させる。
cmd_reset() {
  docker compose --env-file sandbox.config run --rm -T --no-deps -e WROOT="$WORKTREE_ROOT" agent bash -c '
    set -e
    remaining=$(git -C /workspace worktree list --porcelain | sed -n "s/^worktree //p" | grep -F "$WROOT/" || true)
    if [ -n "$remaining" ]; then
      echo "ERROR: worker worktree がまだ残っています。先に worker.sh --remove で削除してください:" >&2
      echo "$remaining" >&2
      exit 1
    fi
    if git -C /workspace config --unset gc.worktreePruneExpire 2>/dev/null; then
      echo ">> gc.worktreePruneExpire を解除しました"
    else
      echo ">> gc.worktreePruneExpire は未設定 (skip)"
    fi
    excl=/workspace/.git/info/exclude
    if [ -f "$excl" ]; then
      tmp=$(mktemp)
      grep -vxF -e node_modules -e .venv -e .worker-bundle "$excl" > "$tmp" || true
      if cmp -s "$excl" "$tmp"; then
        echo ">> .git/info/exclude に worker の追記行なし (skip)"
      else
        cat "$tmp" > "$excl"
        echo ">> .git/info/exclude から node_modules / .venv / .worker-bundle を除去しました"
      fi
      rm -f "$tmp"
    fi
    echo ">> reset 完了。worker.sh 由来のホストリポ変更を戻しました。"
  '
}

# コンテナ内 bootstrap。値は env (WT/BR/BASE/MODE) で渡し、スクリプト本文へは補間しない
# (branch 名経由のシェルインジェクション防止)。本文に ' を含めないこと (単一引用符で囲うため)。
BOOT='
set -e
export GEM_HOME="$WT/.worker-bundle" BUNDLE_PATH="$WT/.worker-bundle" UV_PYTHON_PREFERENCE=only-system
git -C /workspace config gc.worktreePruneExpire never
# 依存の保存先を git status から隠す (配布先 repo の .gitignore に依存しないため自前で)。
for p in node_modules .venv .worker-bundle; do
  grep -qxF "$p" /workspace/.git/info/exclude 2>/dev/null || echo "$p" >> /workspace/.git/info/exclude
done
# 作業ツリーだけ消えた worktree の admin entry を掃除して自己回復する。--expire=now で
# gc.worktreePruneExpire=never の影響を受けず確実に。生存 worktree の /workspace パスは
# コンテナ内で実在するので誤 prune しない。
git -C /workspace worktree prune --expire=now
if [ -d "$WT" ] && git -C /workspace worktree list --porcelain | grep -qx "worktree $WT"; then
  cur=$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null || true)
  if [ -z "$cur" ]; then
    echo "ERROR: $WT は detached HEAD の worktree です。worker.sh --remove で削除してから再実行してください。" >&2
    exit 1
  fi
  if [ "$cur" != "$BR" ]; then
    echo "ERROR: $WT は既にブランチ \"$cur\" を使用中です (要求: \"$BR\")。slug 衝突の可能性。別のブランチ名にするか worker.sh --remove で削除してください。" >&2
    exit 1
  fi
elif git -C /workspace show-ref --verify --quiet "refs/heads/$BR"; then
  git -C /workspace worktree add "$WT" "$BR" || {
    echo "ERROR: ブランチ \"$BR\" は別の worktree で使用中の可能性があります (git -C /workspace worktree list で確認)。" >&2
    exit 1; }
else
  git -C /workspace worktree add "$WT" -b "$BR" "$BASE"
fi
cd "$WT"
if [ "$MODE" = shell ]; then exec bash; else exec claude; fi
'

launch() {
  local mode="$1" branch="$2" base="${3:-HEAD}"
  [ -n "$branch" ] || { usage; exit 1; }
  validate_branch "$branch"
  validate_base "$base"
  local name wt
  name=$(slug "$branch"); wt="${WORKTREE_ROOT}/${name}"

  exec docker compose --env-file sandbox.config run --rm -it \
    -e WT="$wt" -e BR="$branch" -e BASE="$base" -e MODE="$mode" \
    agent bash -c "$BOOT"
}

case "${1:-}" in
  --list)        cmd_list ;;
  --remove)      shift; [ -n "${1:-}" ] || { usage; exit 1; }; cmd_remove "$1" ;;
  --reset)       cmd_reset ;;
  --shell)       shift; launch shell "${1:-}" "${2:-}" ;;
  -h|--help|"")  usage ;;
  *)             launch claude "$1" "${2:-}" ;;
esac
