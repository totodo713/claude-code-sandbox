#!/usr/bin/env bash
# fine-grained PAT 発行支援 (sandbox コンテナ用の最小権限トークン / case A)
#
# やること:
#   1. grants.conf (許可範囲の宣言) を読む
#   2. fine-grained PAT 発行ページの URL とチェックリストを提示
#        - 自己発行 (既定)        : 自分のブラウザで発行ページを開く
#        - --owner-issued         : ブラウザは開かず「オーナーに送る発行依頼」を出力
#   3. 発行したトークンを貼ると GitHub API で検証
#        - 正テスト: REPOSITORIES に通る
#        - 負テスト: DENY_CONTROL_REPO に通らない (スコープが広すぎないか)
#   4. 検証 OK なら git/credentials を生成 (mode H がこれを mount する)
#
# 使い方 (ホストで実行。コンテナ内では実行しない):
#   cp grants.conf.example grants.conf   # 初回のみ。中身を最小権限に編集
#   ./git-pat.sh                 # 自分/org のリポ、または自分の fork を自己発行
#   ./git-pat.sh --owner-issued  # 他人の個人リポ: オーナーに発行依頼 (RESOURCE_OWNER=オーナー)
#
# 方式選定 (fork が本筋 / オーナー発行が fallback) は docs/git.md を参照。
# 前提: curl が必要。発行ページの事前入力 (repo/権限の自動選択) は GitHub が
#       fine-grained PAT で未対応なので、チェックリストを見ながら手動で選ぶ。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---- args ----
OWNER_ISSUED=0
for arg in "$@"; do
  case "$arg" in
    --owner-issued) OWNER_ISSUED=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf "unknown option: %s\n" "$arg" >&2; exit 1 ;;
  esac
done

CONF="grants.conf"
CRED_DIR="git"
CRED_FILE="git/credentials"
NEW_TOKEN_URL="https://github.com/settings/personal-access-tokens/new"
API="https://api.github.com"

# ---- color ----
if [ -t 1 ]; then
  B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; Z=$'\e[0m'
else
  B=""; D=""; G=""; Y=""; R=""; C=""; Z=""
fi
ok()   { printf "%s[ok]%s %s\n"    "$G" "$Z" "$*"; }
warn() { printf "%s[warn]%s %s\n"  "$Y" "$Z" "$*"; }
die()  { printf "%s[error]%s %s\n" "$R" "$Z" "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl が見つかりません。インストールしてください。"
[ -f "$CONF" ] || die "$CONF がありません。'cp grants.conf.example grants.conf' して編集してください。"

# ---- grants.conf 読み込み ----
# shellcheck source=/dev/null
. "./$CONF"
: "${RESOURCE_OWNER:?grants.conf に RESOURCE_OWNER がありません}"
: "${REPOSITORIES:?grants.conf に REPOSITORIES がありません}"
: "${PERMISSIONS:=metadata:read}"
: "${EXPIRY_DAYS:=30}"
: "${DENY_CONTROL_REPO:=}"

# ---- 権限レベルの表示名 ----
perm_label() {
  case "$1" in
    read)  echo "Read-only" ;;
    write) echo "Read and write" ;;
    *)     echo "$1" ;;
  esac
}

# ---- ブラウザを開く (WSL2 / Mac / Linux) ----
# 優先順: wslview (WSL) → open (Mac) → xdg-open (Linux desktop) → explorer.exe (WSL fallback)
open_url() {
  local url="$1" opener
  for opener in wslview open xdg-open explorer.exe; do
    if command -v "$opener" >/dev/null 2>&1; then
      "$opener" "$url" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

# ---- API ヘルパー ----
api_status() {
  # api_status TOKEN PATH -> HTTP status code
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $1" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}$2"
}
api_body() {
  curl -s \
    -H "Authorization: Bearer $1" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}$2"
}
json_str() {
  # 最初の "key":"value" を拾う簡易パーサ (jq 非依存)
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" <<<"$1" | head -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/'
}

# ---- チェックリスト表示 ----
say_checklist() {
  printf "\n%s==== fine-grained PAT 発行チェックリスト ====%s\n" "$B" "$Z"
  printf "%s発行ページ:%s %s\n\n" "$D" "$Z" "$NEW_TOKEN_URL"
  printf "  %sToken name%s        : sandbox-%s (任意。識別しやすい名前)\n" "$C" "$Z" "$RESOURCE_OWNER"
  printf "  %sResource owner%s    : %s\n" "$C" "$Z" "$RESOURCE_OWNER"
  printf "  %sExpiration%s        : %s 日\n" "$C" "$Z" "$EXPIRY_DAYS"
  printf "  %sRepository access%s : Only select repositories →\n" "$C" "$Z"
  local r
  for r in $REPOSITORIES; do
    printf "                         - %s\n" "$r"
  done
  printf "  %sPermissions%s       :\n" "$C" "$Z"
  local p name level
  for p in $PERMISSIONS; do
    name="${p%%:*}"; level="${p##*:}"
    printf "                         - %-10s → %s\n" "$name" "$(perm_label "$level")"
  done
  printf "\n  %s上記どおり選んで [Generate token] → 表示されたトークンをコピー%s\n\n" "$D" "$Z"
}

# ---- main ----
printf "%sgrants.conf を読み込みました:%s owner=%s repos=[%s]\n" "$B" "$Z" "$RESOURCE_OWNER" "$REPOSITORIES"

if [ "$OWNER_ISSUED" = "1" ]; then
  # 他人の個人リポ: collaborator は発行できないので、オーナーに依頼する。
  # ブラウザは開かず、オーナーへ送る発行手順を提示する。
  printf "\n%s==== オーナーに送る発行依頼 ====%s\n" "$B" "$Z"
  printf "%s以下を %s (リポジトリ所有者) に送り、fine-grained PAT を発行してもらってください。%s\n" \
    "$D" "$RESOURCE_OWNER" "$Z"
  printf "%sオーナーは自分のアカウントでログインし、Resource owner に自分 (%s) を選んで発行します。%s\n" \
    "$D" "$RESOURCE_OWNER" "$Z"
  say_checklist
  printf "%sオーナーから受け取ったトークンを貼り付けて Enter%s (入力は表示されません): " "$B" "$Z"
else
  if open_url "$NEW_TOKEN_URL"; then
    ok "ブラウザで発行ページを開きました"
  else
    warn "ブラウザを自動で開けませんでした。以下を手動で開いてください:"
    printf "  %s\n" "$NEW_TOKEN_URL"
  fi
  say_checklist
  printf "%s発行したトークンを貼り付けて Enter%s (入力は表示されません): " "$B" "$Z"
fi

read -r -s TOKEN
echo ""
[ -n "${TOKEN:-}" ] || die "トークンが空です。中断しました。"

# ---- 検証 ----
printf "\n%s==== トークン検証 ====%s\n" "$B" "$Z"

# 0) トークン自体が有効か
code=$(api_status "$TOKEN" "/user")
[ "$code" = "200" ] || die "トークンが無効か期限切れです (GET /user -> $code)"
LOGIN=$(json_str "$(api_body "$TOKEN" "/user")" "login")
[ -n "$LOGIN" ] || LOGIN="$RESOURCE_OWNER"
ok "トークン有効 (login: $LOGIN)"

# 1) 正テスト: 各 REPOSITORIES に到達できるか
want_write=0
case " $PERMISSIONS " in *" contents:write "*) want_write=1 ;; esac
for repo in $REPOSITORIES; do
  code=$(api_status "$TOKEN" "/repos/$repo")
  case "$code" in
    200)
      if [ "$want_write" = "1" ]; then
        push=$(api_body "$TOKEN" "/repos/$repo" | grep -o '"push"[[:space:]]*:[[:space:]]*\(true\|false\)' | head -n1 | grep -o '\(true\|false\)' || true)
        if [ "$push" = "true" ]; then
          ok "正テスト: $repo に到達・書き込み権限あり"
        else
          warn "正テスト: $repo に到達できるが push 権限が確認できない (Contents が read のみかも: push=${push:-unknown})"
        fi
      else
        ok "正テスト: $repo に到達 (read)"
      fi
      ;;
    404) die "正テスト失敗: $repo にアクセスできません。発行時に repo 選択漏れ、または権限不足です (404)" ;;
    *)   warn "正テスト: $repo の確認で予期しない応答 ($code)" ;;
  esac
done

# 2) 負テスト: 対照リポに到達できないこと (スコープが広すぎないか)
if [ -n "$DENY_CONTROL_REPO" ]; then
  code=$(api_status "$TOKEN" "/repos/$DENY_CONTROL_REPO")
  case "$code" in
    404|403) ok "負テスト: $DENY_CONTROL_REPO には到達不可 (スコープが絞れている: $code)" ;;
    200)     die "負テスト失敗: $DENY_CONTROL_REPO に到達できてしまいます。トークンのスコープが広すぎます (200)" ;;
    *)       warn "負テスト: $DENY_CONTROL_REPO の確認で予期しない応答 ($code)" ;;
  esac
else
  warn "負テスト: DENY_CONTROL_REPO 未設定のためスキップ (grants.conf に設定するとスコープを実測できます)"
fi

# ---- credentials 書き出し ----
# fine-grained PAT は server 側で repo 単位に絞られているため、host レベルの
# 1 行で REPOSITORIES 全てをカバーできる。username は GitHub HTTPS では cosmetic。
mkdir -p "$CRED_DIR"
umask 077
printf "https://%s:%s@github.com\n" "$LOGIN" "$TOKEN" > "$CRED_FILE"
chmod 600 "$CRED_FILE"
unset TOKEN

printf "\n"
ok "検証完了 → $CRED_FILE を生成しました (chmod 600)"
printf "\n%s次の手順:%s\n" "$B" "$Z"
printf "  ./setup.sh --reconfigure   # GIT_AUTH_MODE=H を選ぶと sandbox にこの PAT が mount される\n"
printf "  %s(既に H で構成済みなら override.yml の再生成だけで反映されます)%s\n" "$D" "$Z"
