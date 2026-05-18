#!/usr/bin/env bash
# Claude Code Sandbox - 自動テストランナ
#
# 使い方:
#   ./test/run.sh           # 全テスト実行
#   ./test/run.sh -v        # verbose (各テストの詳細出力)
#   ./test/run.sh A-1 A-2   # 特定 ID だけ実行
#
# 前提:
#   - ./setup.sh が完走済 (sandbox.config と CA が存在)
#   - egress-proxy と agent が起動可能
#
# 終了コード: pass=0 / fail>0

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SANDBOX_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$SANDBOX_DIR"

VERBOSE=0
FILTER=()
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) FILTER+=("$arg") ;;
  esac
done

# ---- 色 ----
if [ -t 1 ]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=""; R=""; Y=""; B=""; D=""; N=""
fi

pass=0; fail=0; skip=0
fail_ids=()

# ---- フレームワーク ----
should_run() {
  local id="$1"
  if [ "${#FILTER[@]}" -eq 0 ]; then return 0; fi
  for f in "${FILTER[@]}"; do [ "$f" = "$id" ] && return 0; done
  return 1
}

run_test() {
  # run_test <ID> <description> <command...>
  local id="$1" desc="$2"; shift 2
  if ! should_run "$id"; then return; fi
  printf "  %s%-5s%s %-58s" "$B" "$id" "$N" "$desc"
  local out
  if out=$("$@" 2>&1); then
    printf "%s[pass]%s\n" "$G" "$N"
    pass=$((pass+1))
    [ "$VERBOSE" -eq 1 ] && [ -n "$out" ] && printf "%s%s%s\n" "$D" "$(echo "$out" | sed 's/^/      /')" "$N"
  else
    printf "%s[FAIL]%s\n" "$R" "$N"
    fail=$((fail+1))
    fail_ids+=("$id")
    echo "$out" | sed 's/^/      /'
  fi
}

skip_test() {
  local id="$1" desc="$2" reason="${3:-}"
  if ! should_run "$id"; then return; fi
  printf "  %s%-5s%s %-58s%s[skip]%s %s\n" "$B" "$id" "$N" "$desc" "$Y" "$N" "$reason"
  skip=$((skip+1))
}

# 1 行ヘルパ: agent 内でコマンドを実行 (rm 付き短命コンテナ)
agent_run() {
  docker compose --env-file sandbox.config run --rm -T agent bash -c "$1"
}

# 1 行ヘルパ: HTTP ステータスコードだけ取り出す
agent_http_code() {
  agent_run "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 '$1'"
}

# ---- 前提チェック ----
echo "${B}=== Claude Code Sandbox: 自動テスト ===${N}"
echo ""

if [ ! -f sandbox.config ]; then
  echo "${R}sandbox.config が無い。先に ./setup.sh を実行してください。${N}"
  exit 2
fi
if [ ! -f proxy/certs/mitmproxy-ca-cert.pem ]; then
  echo "${R}CA が無い。先に ./setup.sh --ca-only を実行してください。${N}"
  exit 2
fi

# shellcheck source=/dev/null
set -a; . ./sandbox.config; set +a

# egress-proxy が起動していなければ起動
if ! docker compose --env-file sandbox.config ps --status running --services 2>/dev/null | grep -q '^egress-proxy$'; then
  echo "${D}egress-proxy を起動...${N}"
  docker compose --env-file sandbox.config up -d egress-proxy >/dev/null
  sleep 2
fi

# ============================================================
# A. セキュリティ
# ============================================================
echo ""
echo "${B}[A] セキュリティ${N}"

# HTTPS は CONNECT 段階で 502 が返るため curl は exit 56・http_code 000 になる。
# よって curl 出力に "502" が含まれるか (= proxy が遮断したか) で判定する。
run_test "A-1" "非 allowlist (example.com) は 502 ブロック" \
  bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "curl -sS --max-time 8 https://example.com" 2>&1 | grep -q 502'

run_test "A-2" "直接 TCP (1.1.1.1:443) には到達不能" \
  bash -c '! docker compose --env-file sandbox.config run --rm -T agent bash -c "timeout 3 bash -c </dev/tcp/1.1.1.1/443" 2>/dev/null'

run_test "A-3" "TLS 信頼 OK: api.anthropic.com が 2xx/4xx で返る" \
  bash -c 'code=$(docker compose --env-file sandbox.config run --rm -T agent bash -c "curl -sS -o /dev/null -w %{http_code} --max-time 10 https://api.anthropic.com"); echo "$code" | grep -qE "^(200|400|401|403|404|405)$"'

run_test "A-4" "HTTPS_PROXY を unset しても example.com 到達不能" \
  bash -c '! docker compose --env-file sandbox.config run --rm -T -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= agent bash -c "curl -sS --max-time 5 -o /dev/null https://example.com" 2>/dev/null'

run_test "A-5" "proxy ログに JSON イベントが出力されている" \
  bash -c 'docker compose --env-file sandbox.config logs --tail=200 egress-proxy 2>/dev/null | grep -q "\"event\":"'

# ============================================================
# B. 機能
# ============================================================
echo ""
echo "${B}[B] 機能${N}"

run_test "B-1" "claude --version がコンテナ内で動く" \
  bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "claude --version" >/dev/null'

run_test "B-2" "/workspace にリポジトリがマウントされている" \
  bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "test -f /workspace/CLAUDE.md || test -f /workspace/.gitignore"'

run_test "B-3" "agent が非 root で動く (uid=$AGENT_USER_UID)" \
  bash -c "uid=\$(docker compose --env-file sandbox.config run --rm -T agent bash -c 'id -u' | tr -d '\r'); [ \"\$uid\" = \"${AGENT_USER_UID:-1000}\" ]"

if [ -n "${PASSTHROUGH_ENV:-}" ]; then
  first_key=$(echo "$PASSTHROUGH_ENV" | cut -d, -f1 | xargs)
  if [ -n "$first_key" ]; then
    run_test "B-4" "PASSTHROUGH_ENV: $first_key が agent に渡る" \
      bash -c "docker compose --env-file sandbox.config run --rm -T agent bash -c 'test -n \"\${$first_key+x}\"'"
  else
    skip_test "B-4" "PASSTHROUGH_ENV の検証" "passthrough key 空"
  fi
else
  skip_test "B-4" "PASSTHROUGH_ENV の検証" "PASSTHROUGH_ENV 未設定"
fi

case ",${LANG_PACK:-}," in
  *,ruby,*)
    run_test "B-5" "Ruby pack: bundle --version が動く" \
      bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "bundle --version" >/dev/null'
    ;;
  *,node,*|",,")
    run_test "B-5" "Node pack: npm --version が動く" \
      bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "npm --version" >/dev/null'
    ;;
  *,python,*)
    run_test "B-5" "Python pack: pip3 --version が動く" \
      bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "pip3 --version" >/dev/null'
    ;;
  *)
    skip_test "B-5" "言語パックのパッケージマネージャ" "LANG_PACK=$LANG_PACK"
    ;;
esac

# ============================================================
# C. 設定変更
# ============================================================
echo ""
echo "${B}[C] 設定変更${N}"

# C-1: extra.txt 動的更新
if should_run "C-1"; then
  EXTRA_FILE="allowlist/allowlist.d/extra.txt"
  BACKUP_FILE="$EXTRA_FILE.bak.$$"
  cp "$EXTRA_FILE" "$BACKUP_FILE"
  echo "example.com" >> "$EXTRA_FILE"
  docker compose --env-file sandbox.config restart egress-proxy >/dev/null 2>&1
  sleep 3
  run_test "C-1" "extra.txt に example.com 追加 → 502 でなくなる" \
    bash -c '[ "$(docker compose --env-file sandbox.config run --rm -T agent bash -c "curl -sS -o /dev/null -w %{http_code} --max-time 10 https://example.com")" != "502" ]'
  # 復元
  mv "$BACKUP_FILE" "$EXTRA_FILE"
  docker compose --env-file sandbox.config restart egress-proxy >/dev/null 2>&1
  sleep 2
fi

# --reconfigure は既存 sandbox.config を読むだけで上書きしない (非破壊)。
# override.yml を消して再生成されるかで確認する。
run_test "C-2" "setup.sh --reconfigure で override.yml 再生成" \
  bash -c 'rm -f docker-compose.override.yml; ./setup.sh --reconfigure >/dev/null 2>&1; test -f docker-compose.override.yml'

skip_test "C-3" "CA 削除 → --ca-only で復旧" "破壊的、手動 (manual.md §3)"

# C-4: BLOCK_ON_VIOLATION=false
if should_run "C-4"; then
  ORIG_BLOCK="${BLOCK_ON_VIOLATION:-true}"
  sed -i.bak "s/^BLOCK_ON_VIOLATION=.*/BLOCK_ON_VIOLATION=false/" sandbox.config
  docker compose --env-file sandbox.config restart egress-proxy >/dev/null 2>&1
  sleep 3
  run_test "C-4" "BLOCK_ON_VIOLATION=false で example.com が 502 にならない" \
    bash -c '[ "$(docker compose --env-file sandbox.config run --rm -T agent bash -c "curl -sS -o /dev/null -w %{http_code} --max-time 10 https://example.com")" != "502" ]'
  # 復元
  sed -i "s/^BLOCK_ON_VIOLATION=.*/BLOCK_ON_VIOLATION=${ORIG_BLOCK}/" sandbox.config
  rm -f sandbox.config.bak
  docker compose --env-file sandbox.config restart egress-proxy >/dev/null 2>&1
  sleep 2
fi

# ============================================================
# D. 認証モード
# ============================================================
echo ""
echo "${B}[D] 認証モード (現在: ${CLAUDE_AUTH_MODE:-?})${N}"

case "${CLAUDE_AUTH_MODE:-A}" in
  A)
    run_test "D-1" "Mode A: ~/.claude が writable で認証情報がコピー済み" \
      bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "test -w /home/agent/.claude && test -s /home/agent/.claude/.credentials.json"'
    skip_test "D-2" "Mode B 検証" "現在 mode=A"
    skip_test "D-3" "Mode C 検証" "現在 mode=A"
    ;;
  B)
    skip_test "D-1" "Mode A 検証" "現在 mode=B"
    skip_test "D-2" "Mode B: claude login 後セッション永続" "対話必須 (manual.md §4)"
    skip_test "D-3" "Mode C 検証" "現在 mode=B"
    ;;
  C)
    skip_test "D-1" "Mode A 検証" "現在 mode=C"
    skip_test "D-2" "Mode B 検証" "現在 mode=C"
    run_test "D-3" "Mode C: ANTHROPIC_API_KEY が agent に渡る" \
      bash -c 'docker compose --env-file sandbox.config run --rm -T agent bash -c "test -n \"\$ANTHROPIC_API_KEY\""'
    ;;
esac

# ============================================================
# E. エラーハンドリング
# ============================================================
echo ""
echo "${B}[E] エラーハンドリング${N}"

if should_run "E-1"; then
  mv sandbox.config sandbox.config.test-bak
  run_test "E-1" "sandbox.config 無しで run.sh → 親切なエラー" \
    bash -c './run.sh 2>&1 | grep -q "sandbox.config"'
  out=$?
  mv sandbox.config.test-bak sandbox.config
fi

if should_run "E-2"; then
  mv proxy/certs/mitmproxy-ca-cert.pem proxy/certs/mitmproxy-ca-cert.pem.test-bak
  run_test "E-2" "CA 無しで run.sh → 親切なエラー" \
    bash -c './run.sh 2>&1 | grep -qiE "CA|cert"'
  mv proxy/certs/mitmproxy-ca-cert.pem.test-bak proxy/certs/mitmproxy-ca-cert.pem
fi

run_test "E-3" "未知の option で setup.sh → 非 0 終了" \
  bash -c '! ./setup.sh --no-such-option 2>/dev/null'

# ============================================================
# 集計
# ============================================================
echo ""
echo "============================================================"
printf "結果: %s%d pass%s / %s%d fail%s / %s%d skip%s\n" \
  "$G" "$pass" "$N" "$R" "$fail" "$N" "$Y" "$skip" "$N"
if [ "$fail" -gt 0 ]; then
  echo "FAIL ID: ${fail_ids[*]}"
  echo ""
  echo "失敗した項目を verbose で再実行: ./test/run.sh -v ${fail_ids[*]}"
  exit 1
fi
echo ""
echo "次は手動チェック: ${B}cat .claude-sandbox/test/manual.md${N}"
exit 0
