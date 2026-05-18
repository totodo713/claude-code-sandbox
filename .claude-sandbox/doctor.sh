#!/usr/bin/env bash
# 環境診断: CA 信頼 / allowlist / 認証 / proxy 経路
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

if [ -t 1 ]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi
pass=0; fail=0; warn_count=0
check() {
  local label="$1"; shift
  printf "  %-50s" "$label"
  if "$@" >/tmp/sandbox-doctor.out 2>&1; then
    printf "%s[ok]%s\n" "$G" "$N"; pass=$((pass+1))
  else
    printf "%s[FAIL]%s\n" "$R" "$N"
    sed 's/^/    /' /tmp/sandbox-doctor.out
    fail=$((fail+1))
  fi
}
warn_check() {
  local label="$1"; shift
  printf "  %-50s" "$label"
  if "$@" >/tmp/sandbox-doctor.out 2>&1; then
    printf "%s[ok]%s\n" "$G" "$N"; pass=$((pass+1))
  else
    printf "%s[warn]%s\n" "$Y" "$N"
    sed 's/^/    /' /tmp/sandbox-doctor.out
    warn_count=$((warn_count+1))
  fi
}

[ -f sandbox.config ] || { echo "sandbox.config がありません。./setup.sh を先に実行してください。" >&2; exit 1; }
# shellcheck source=/dev/null
set -a; . ./sandbox.config; set +a

echo "${B}Claude Code Sandbox - doctor${N}"
echo ""

echo "${B}[1] 基本ファイル${N}"
check "sandbox.config が存在"                   test -f sandbox.config
check "docker-compose.override.yml が存在"      test -f docker-compose.override.yml
check ".runtime.env が存在"                     test -f .runtime.env
check "mitmproxy CA が存在"                     test -f proxy/certs/mitmproxy-ca-cert.pem
echo ""

echo "${B}[2] コンテナ${N}"
check "egress-proxy コンテナが healthy" \
  bash -c 'docker compose --env-file sandbox.config ps --format json egress-proxy | grep -q "\"Health\":\"healthy\""'
check "agent イメージがビルド済み" \
  bash -c "docker image inspect ${PROJECT_NAME:-claude-sandbox}-agent:latest >/dev/null"
echo ""

echo "${B}[3] ネットワーク (agent 内から)${N}"
check "agent: api.anthropic.com に到達 (TLS OK)" \
  docker compose --env-file sandbox.config run --rm -T agent \
    bash -c 'curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com | grep -qE "^(200|401|403|404)$"'
check "agent: github.com に到達 (TLS OK)" \
  docker compose --env-file sandbox.config run --rm -T agent \
    bash -c 'curl -sS -o /dev/null -w "%{http_code}\n" https://github.com | grep -qE "^[23]"'
# HTTPS は CONNECT 段で 502 が返るため %{http_code} は 000 になる。
# curl の出力に "502" が含まれるか (= proxy が遮断したか) で判定する。
check "agent: example.com が allowlist で 502 ブロック" \
  bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "curl -sS --max-time 8 https://example.com" 2>&1 | grep -q 502'
warn_check "agent: 直接 1.1.1.1 へは到達不可 (internal:true 動作確認)" \
  docker compose --env-file sandbox.config run --rm -T agent \
    bash -c '! timeout 3 bash -c "</dev/tcp/1.1.1.1/443" 2>/dev/null'
echo ""

echo "${B}[4] Claude CLI${N}"
check "agent 内に claude CLI が存在" \
  docker compose --env-file sandbox.config run --rm -T agent \
    bash -c 'command -v claude'
case "${CLAUDE_AUTH_MODE:-A}" in
  A) check "認証 A: コピーした認証情報があり ~/.claude が writable" \
       docker compose --env-file sandbox.config run --rm -T agent \
         bash -c 'test -w /home/agent/.claude && test -s /home/agent/.claude/.credentials.json' ;;
  B) warn_check "認証 B: コンテナ内 ~/.claude に既存セッションあり" \
       docker compose --env-file sandbox.config run --rm -T agent \
         bash -c 'test -s /home/agent/.claude/.credentials.json || test -d /home/agent/.claude/sessions' ;;
  C) check "認証 C: ANTHROPIC_API_KEY が渡っている" \
       docker compose --env-file sandbox.config run --rm -T agent \
         bash -c 'test -n "${ANTHROPIC_API_KEY:-}"' ;;
esac
echo ""

# 言語ランタイムとパッケージマネージャの導入確認。LANG_PACK / PKG_TOOL_* で
# 指定したものがコンテナ内で実際に呼べるかを見る。
if [ -n "${LANG_PACK:-}" ]; then
  echo "${B}[5] 言語ランタイム / パッケージマネージャ${N}"
  case ",${LANG_PACK}," in
    *,ruby,*)
      check "agent: ruby が PATH にある (${RUBY_VERSION:-?})" \
        docker compose --env-file sandbox.config run --rm -T agent \
          bash -c 'command -v ruby && command -v bundle' ;;
  esac
  case ",${LANG_PACK}," in
    *,node,*)
      check "agent: node が PATH にある (${NODE_VERSION:-?})" \
        docker compose --env-file sandbox.config run --rm -T agent \
          bash -c 'command -v node'
      case "${PKG_TOOL_NODE:-npm}" in
        npm)  check "agent: npm が PATH にある" \
                docker compose --env-file sandbox.config run --rm -T agent \
                  bash -c 'command -v npm' ;;
        pnpm) check "agent: pnpm が PATH にある" \
                docker compose --env-file sandbox.config run --rm -T agent \
                  bash -c 'command -v pnpm' ;;
        yarn) check "agent: yarn が PATH にある" \
                docker compose --env-file sandbox.config run --rm -T agent \
                  bash -c 'command -v yarn' ;;
        bun)  check "agent: bun が PATH にある" \
                docker compose --env-file sandbox.config run --rm -T agent \
                  bash -c 'command -v bun' ;;
      esac ;;
  esac
  case ",${LANG_PACK}," in
    *,python,*)
      check "agent: python が PATH にある (${PYTHON_VERSION:-?})" \
        docker compose --env-file sandbox.config run --rm -T agent \
          bash -c 'command -v python'
      case "${PKG_TOOL_PYTHON:-uv}" in
        uv)  check "agent: uv / uvx が PATH にある" \
               docker compose --env-file sandbox.config run --rm -T agent \
                 bash -c 'command -v uv && command -v uvx' ;;
        pip) check "agent: pip が python 経由で呼べる" \
               docker compose --env-file sandbox.config run --rm -T agent \
                 bash -c 'python -m pip --version' ;;
      esac ;;
  esac
  echo ""
fi

echo "------------------------------------------------------------"
printf "結果: %s%d pass%s / %s%d warn%s / %s%d fail%s\n" \
  "$G" "$pass" "$N" "$Y" "$warn_count" "$N" "$R" "$fail" "$N"
[ "$fail" -eq 0 ] || exit 1
