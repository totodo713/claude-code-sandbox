#!/usr/bin/env bash
# .claude-sandbox/ を別のリポジトリにコピーする。
#
# 使い方:
#   ./.claude-sandbox/copy-to.sh <destination-repo-path>
#
# 仕組み:
#   `git archive HEAD .claude-sandbox/` を使うので、現リポの **HEAD コミット**
#   に含まれる .claude-sandbox/ 配下のファイルだけが転送される。.gitignore
#   対象 (sandbox.config / .runtime.env / docker-compose.override.yml /
#   proxy/certs/*.pem / volumes/ / auth/claude-config/* など) は自動で
#   除外されるので、新規リポでは setup.sh から作り直しになる。
#
# 注意:
#   - 未コミットの sandbox 改変は持っていかれない。先にコミットしておくこと。
#   - コピー先で既に .claude-sandbox/ がある場合は上書き確認プロンプト。
set -euo pipefail

dst="${1:-}"
[ -n "$dst" ] || { echo "usage: $0 <destination-repo-path>" >&2; exit 1; }
[ -d "$dst" ] || { echo "$dst is not a directory" >&2; exit 1; }

src_root=$(git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "current directory is not in a git repo" >&2; exit 1; }

if [ -e "$dst/.claude-sandbox" ]; then
  read -r -p "$dst/.claude-sandbox は既に存在します。上書きしますか? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "中止"; exit 0; }
  rm -rf "$dst/.claude-sandbox"
fi

( cd "$src_root" && git archive HEAD .claude-sandbox/ ) | tar -x -C "$dst"

cat <<EOF

.claude-sandbox/ を $dst にコピーしました。
次の手順:
  cd "$dst"
  ./.claude-sandbox/setup.sh      # 初回セットアップ (対話)
EOF
