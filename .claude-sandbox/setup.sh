#!/usr/bin/env bash
# Claude Code Sandbox - 対話セットアップ
# 使い方:
#   ./setup.sh                # 通常セットアップ
#   ./setup.sh --reconfigure  # sandbox.config と override.yml のみ作り直し
#   ./setup.sh --ca-only      # CA bootstrap だけやり直し

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

CONFIG_FILE="sandbox.config"
EXAMPLE_FILE="sandbox.config.example"
OVERRIDE_FILE="docker-compose.override.yml"
RUNTIME_ENV_FILE=".runtime.env"
CA_FILE="proxy/certs/mitmproxy-ca-cert.pem"

RECONFIGURE_ONLY=0
CA_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE_ONLY=1 ;;
    --ca-only)     CA_ONLY=1 ;;
    -h|--help)
      sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ---- color helpers ----
if [ -t 1 ]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi
say()  { printf "%s\n" "$*"; }
info() { printf "%s==>%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%s[ok]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf "%s[error]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

ask() {
  # ask "質問" "デフォルト値"
  local prompt="$1" default="${2-}" reply
  if [ -n "$default" ]; then
    read -r -p "${C_BOLD}? ${prompt}${C_RESET} [${C_DIM}${default}${C_RESET}]: " reply
    printf "%s" "${reply:-$default}"
  else
    read -r -p "${C_BOLD}? ${prompt}${C_RESET}: " reply
    printf "%s" "$reply"
  fi
}
ask_secret() {
  local prompt="$1" reply
  read -r -s -p "${C_BOLD}? ${prompt}${C_RESET} (入力は表示されません): " reply
  echo "" >&2
  printf "%s" "$reply"
}
ask_choice() {
  # ask_choice "質問" "A:説明" "B:説明" ... デフォルトは1番目
  local prompt="$1"; shift
  local options=("$@")
  local default_letter="${options[0]%%:*}"
  # 注: この関数は $(...) 経由で呼ばれるため、画面表示は必ず stderr に出す
  echo "${C_BOLD}? ${prompt}${C_RESET}" >&2
  for opt in "${options[@]}"; do
    local letter="${opt%%:*}" desc="${opt#*:}"
    echo "    ${C_BOLD}${letter}${C_RESET}: ${desc}" >&2
  done
  local reply
  read -r -p "  選択 [${C_DIM}${default_letter}${C_RESET}]: " reply
  reply="${reply:-$default_letter}"
  reply=$(echo "$reply" | tr '[:lower:]' '[:upper:]')
  for opt in "${options[@]}"; do
    [ "${opt%%:*}" = "$reply" ] && { printf "%s" "$reply"; return; }
  done
  die "不正な選択: $reply"
}

# ---- 前提チェック ----
check_prereqs() {
  info "前提チェック"
  command -v docker >/dev/null 2>&1 || die "docker が見つかりません。Docker Desktop / Docker Engine をインストールしてください。"
  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose v2 が見つかりません (docker-compose v1 は非対応)。"
  fi
  ok "docker: $(docker --version)"
  ok "docker compose: $(docker compose version --short)"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "WSL2 環境を検出"
    if ! docker info >/dev/null 2>&1; then
      die "docker に接続できません。Docker Desktop の WSL integration が有効か確認してください。"
    fi
  fi
}

# ---- 言語パック自動検出 ----
# bun と node は両方とも package.json を持つので、bun の手掛かり (lockfile /
# bunfig.toml) がある場合のみ bun を採用し、それ以外で package.json があれば
# node とする。両方欲しいケース (LANG_PACK=node,bun) は対話で上書きする想定。
detect_lang_pack() {
  local repo_root
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  local detected=""
  [ -f "$repo_root/Gemfile" ] && detected+="ruby,"
  if [ -f "$repo_root/bun.lockb" ] || [ -f "$repo_root/bun.lock" ] \
       || [ -f "$repo_root/bunfig.toml" ]; then
    detected+="bun,"
  elif [ -f "$repo_root/package.json" ]; then
    detected+="node,"
  fi
  if [ -f "$repo_root/pyproject.toml" ] || [ -f "$repo_root/requirements.txt" ]; then
    detected+="python,"
  fi
  detected="${detected%,}"
  printf "%s" "${detected:-none}"
}

# ---- 既存 .env からキー抽出 ----
detect_env_keys() {
  local repo_root
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  [ -f "$repo_root/.env" ] || { printf ""; return; }
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$repo_root/.env" \
    | sed 's/=.*//' \
    | paste -sd, -
}

# ---- Ruby バージョン検出 (.ruby-version → Gemfile の ruby 指定) ----
# 各 detect_* 関数は `set -euo pipefail` 下の `$(detect_*)` で呼ばれるため、
# grep のマッチなしや pipefail でスクリプトを落とさないよう、grep パイプは
# `|| true` で包んで空文字列にフォールバックする。
detect_ruby_version() {
  local repo_root v
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  if [ -f "$repo_root/.ruby-version" ]; then
    tr -dc '0-9.' < "$repo_root/.ruby-version"
    return
  fi
  if [ -f "$repo_root/Gemfile" ]; then
    v=$(grep -oE "^[[:space:]]*ruby[[:space:]]+[\"'][0-9]+\.[0-9]+\.[0-9]+" "$repo_root/Gemfile" 2>/dev/null \
         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || true
    printf "%s" "$v"
    return
  fi
  printf ""
}

# ---- Node バージョン検出 (.nvmrc → .node-version → package.json engines.node) ----
detect_node_version() {
  local repo_root v
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  if [ -f "$repo_root/.nvmrc" ]; then
    tr -d ' \t\n' < "$repo_root/.nvmrc"
    return
  fi
  if [ -f "$repo_root/.node-version" ]; then
    tr -d ' \t\n' < "$repo_root/.node-version"
    return
  fi
  if [ -f "$repo_root/package.json" ]; then
    v=$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]+"' "$repo_root/package.json" 2>/dev/null \
         | grep -oE '[0-9]+(\.[0-9]+){0,2}' | head -n1) || true
    printf "%s" "$v"
    return
  fi
  printf ""
}

# ---- Bun バージョン検出 (.bun-version → package.json engines.bun) ----
detect_bun_version() {
  local repo_root v
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  if [ -f "$repo_root/.bun-version" ]; then
    tr -dc '0-9.' < "$repo_root/.bun-version"
    return
  fi
  if [ -f "$repo_root/package.json" ]; then
    v=$(grep -oE '"bun"[[:space:]]*:[[:space:]]*"[^"]+"' "$repo_root/package.json" 2>/dev/null \
         | grep -oE '[0-9]+(\.[0-9]+){0,2}' | head -n1) || true
    printf "%s" "$v"
    return
  fi
  printf ""
}

# ---- Python パッケージマネージャ検出 (lockfile 優先 → default uv) ----
detect_pkg_tool_python() {
  local repo_root
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  [ -f "$repo_root/uv.lock" ]      && { printf "uv";     return; }
  [ -f "$repo_root/poetry.lock" ]  && { printf "poetry"; return; }
  [ -f "$repo_root/Pipfile.lock" ] && { printf "pipenv"; return; }
  [ -f "$repo_root/requirements.txt" ] && { printf "pip"; return; }
  printf "uv"
}

# ---- Node パッケージマネージャ検出 (lockfile / package.json packageManager) ----
detect_pkg_tool_node() {
  local repo_root v
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  [ -f "$repo_root/bun.lockb" ]      && { printf "bun";  return; }
  [ -f "$repo_root/bun.lock" ]       && { printf "bun";  return; }
  [ -f "$repo_root/pnpm-lock.yaml" ] && { printf "pnpm"; return; }
  [ -f "$repo_root/yarn.lock" ]      && { printf "yarn"; return; }
  if [ -f "$repo_root/package.json" ]; then
    v=$(grep -oE '"packageManager"[[:space:]]*:[[:space:]]*"[^"]+"' "$repo_root/package.json" 2>/dev/null \
         | grep -oE '(pnpm|yarn|bun|npm)' | head -n1) || true
    [ -n "$v" ] && { printf "%s" "$v"; return; }
  fi
  printf "npm"
}

# ---- Node パッケージマネージャの「バージョン」検出 (package.json packageManager) ----
# 引数 $1 = 確定済みのツール名 (pnpm/yarn)。"pnpm@8.15.0+sha512..." の @ 以降の
# バージョン部だけ返す (integrity hash は捨てる)。packageManager のツール名が $1 と
# 一致するときだけ返し、不一致なら空にする (lockfile やプロンプト上書きで決めた
# ツールと、packageManager が指す別ツールの版を取り違えて pnpm@<yarn の版> のような
# 不正な spec を作るのを防ぐ)。見つからなければ空 (Dockerfile 側で latest/stable に既定)。
detect_pkg_tool_node_version() {
  local repo_root pm v
  pm="$1"
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  [ -f "$repo_root/package.json" ] || { printf ""; return; }
  v=$(grep -oE "\"packageManager\"[[:space:]]*:[[:space:]]*\"${pm}@[0-9]+(\.[0-9]+){0,2}" "$repo_root/package.json" 2>/dev/null \
       | grep -oE '@[0-9]+(\.[0-9]+){0,2}' | head -n1 | tr -d '@') || true
  printf "%s" "$v"
}

# ---- Python バージョン検出 (.python-version → runtime.txt → pyproject.toml) ----
detect_python_version() {
  local repo_root v
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  if [ -f "$repo_root/.python-version" ]; then
    tr -dc '0-9.' < "$repo_root/.python-version"
    return
  fi
  if [ -f "$repo_root/runtime.txt" ]; then
    v=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$repo_root/runtime.txt" 2>/dev/null | head -n1) || true
    printf "%s" "$v"
    return
  fi
  if [ -f "$repo_root/pyproject.toml" ]; then
    v=$(grep -oE 'requires-python[[:space:]]*=[[:space:]]*"[^"]+"' "$repo_root/pyproject.toml" 2>/dev/null \
         | grep -oE '[0-9]+(\.[0-9]+){0,2}' | head -n1) || true
    printf "%s" "$v"
    return
  fi
  printf ""
}

# ---- 対話で値を集める ----
gather_inputs() {
  info "セットアップ質問"
  local default_project default_lang default_passthrough host_uid host_gid
  default_project=$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")
  default_lang=$(detect_lang_pack)
  default_passthrough=$(detect_env_keys)
  host_uid=$(id -u)
  host_gid=$(id -g)

  PROJECT_NAME=$(ask "プロジェクト名 (docker compose の name に使用)" "$default_project")
  LANG_PACK=$(ask "言語パック (ruby/node/python, カンマ区切り or none)" "$default_lang")
  [ "$LANG_PACK" = "none" ] && LANG_PACK=""

  # 各言語パックを含む場合のみ、その実行系のバージョンを尋ねる。
  # 新アーキテクチャでは実行系は /opt/runtimes/<lang> に必ずバージョン指定で
  # 導入するため、当該言語が LANG_PACK にあればバージョンは必須。
  # (bun は空のときインストーラの最新版をそのまま入れるので必須ではない)
  RUBY_VERSION="" NODE_VERSION="" PYTHON_VERSION="" BUN_VERSION=""
  # パッケージマネージャ: LANG_PACK にその言語があるときだけ lockfile から
  # 自動検出して対話で確認。Dockerfile.agent の case 分岐に対応がないツール
  # (yarn / poetry / pipenv 等) を選ぶと build 時にエラーになる。
  PKG_TOOL_PYTHON="uv"
  PKG_TOOL_NODE="npm"
  PKG_TOOL_NODE_VERSION=""
  # corepack の署名検証バイパスは安全側に倒し、対話では尋ねない。必要な人だけ
  # 生成後の sandbox.config を手で 1/true/yes に編集する緊急避難スイッチ。
  PKG_TOOL_NODE_ALLOW_UNSIGNED=""
  case ",${LANG_PACK}," in
    *,ruby,*)
      local default_ruby
      default_ruby=$(detect_ruby_version)
      RUBY_VERSION=$(ask "Ruby バージョン (.ruby-version/Gemfile から検出)" "$default_ruby")
      [ -n "$RUBY_VERSION" ] || die "ruby パックには Ruby バージョンが必要です (.ruby-version か Gemfile で指定、または sandbox.config の RUBY_VERSION を設定)"
      ;;
  esac
  case ",${LANG_PACK}," in
    *,node,*)
      local default_node default_pkg_node default_pkg_node_ver
      default_node=$(detect_node_version)
      default_pkg_node=$(detect_pkg_tool_node)
      NODE_VERSION=$(ask "Node バージョン (.nvmrc/.node-version/package.json から検出、空=lts)" "${default_node:-lts}")
      PKG_TOOL_NODE=$(ask "Node パッケージマネージャ (npm/pnpm/yarn/bun 実装済)" "$default_pkg_node")
      # pnpm/yarn は corepack で固定する。package.json の packageManager から
      # 拾ったバージョンを既定提示 (空なら latest/stable)。古い Node では固定推奨。
      case "$PKG_TOOL_NODE" in
        pnpm|yarn)
          default_pkg_node_ver=$(detect_pkg_tool_node_version "$PKG_TOOL_NODE")
          PKG_TOOL_NODE_VERSION=$(ask "${PKG_TOOL_NODE} バージョン (package.json packageManager から検出、空=latest/stable)" "$default_pkg_node_ver")
          ;;
        *) PKG_TOOL_NODE_VERSION="" ;;
      esac
      ;;
  esac
  case ",${LANG_PACK}," in
    *,python,*)
      local default_python default_pkg_py
      default_python=$(detect_python_version)
      default_pkg_py=$(detect_pkg_tool_python)
      PYTHON_VERSION=$(ask "Python バージョン (.python-version/pyproject.toml から検出)" "$default_python")
      [ -n "$PYTHON_VERSION" ] || die "python パックには Python バージョンが必要です (.python-version 等で指定、または sandbox.config の PYTHON_VERSION を設定)"
      PKG_TOOL_PYTHON=$(ask "Python パッケージマネージャ (uv/pip 実装済)" "$default_pkg_py")
      ;;
  esac
  case ",${LANG_PACK}," in
    *,bun,*)
      local default_bun
      default_bun=$(detect_bun_version)
      BUN_VERSION=$(ask "Bun バージョン (.bun-version/package.json engines.bun から検出、空=latest)" "$default_bun")
      ;;
  esac

  CLAUDE_AUTH_MODE=$(ask_choice "Claude Code の認証方式" \
    "A:ホスト ~/.claude を read-only mount (既存ログイン流用)" \
    "B:コンテナ内で claude login (鍵をホストから分離)" \
    "C:ANTHROPIC_API_KEY を直接利用")

  HOST_CLAUDE_DIR=""
  ANTHROPIC_API_KEY=""
  case "$CLAUDE_AUTH_MODE" in
    A)
      HOST_CLAUDE_DIR=$(ask "ホスト ~/.claude のパス" "$HOME/.claude")
      [ -d "$HOST_CLAUDE_DIR" ] || warn "$HOST_CLAUDE_DIR がまだ存在しません。先にホスト側で claude login してください。"
      ;;
    C)
      ANTHROPIC_API_KEY=$(ask_secret "ANTHROPIC_API_KEY")
      [ -n "$ANTHROPIC_API_KEY" ] || die "API key が空です。"
      ;;
  esac

  # ---- git push 認証 ----
  # H を選ぶと sandbox 専用の fine-grained PAT (git-pat.sh が発行) を mount する。
  # ホストの ~/.gitconfig / ~/.git-credentials やキーチェーンには一切触れない (case A)。
  # コンテナ用 .gitconfig (credential.helper=store + identity) はここで生成する。
  GIT_AUTH_MODE=$(ask_choice "git push 認証 (sandbox 内から push できるようにするか)" \
    "N:無効 (clone/fetch/pull のみ)" \
    "H:sandbox 専用の fine-grained PAT を mount (git-pat.sh で発行)")
  GIT_USER_NAME=""
  GIT_USER_EMAIL=""
  if [ "$GIT_AUTH_MODE" = "H" ]; then
    [ -f "git/credentials" ] \
      || warn "git/credentials が未発行です。setup 後に ./git-pat.sh を実行して PAT を発行してください (grants.conf で許可範囲を宣言)。"
    # commit identity はここで確定させる。ホストの --global user.* をデフォルト提示し
    # (空なら未入力で出る)、確認/上書きの機会を与える。値は sandbox.config に保存され、
    # 生成 git/gitconfig の [user] に焼き込まれる (write_override では条件分岐しない)。
    local host_name host_email
    host_name=$(git config --global user.name  2>/dev/null || true)
    host_email=$(git config --global user.email 2>/dev/null || true)
    GIT_USER_NAME=$(ask "sandbox commit の author 名 (ホスト --global user.name をデフォルト表示)" "$host_name")
    GIT_USER_EMAIL=$(ask "sandbox commit の author email (ホスト --global user.email をデフォルト表示)" "$host_email")
    { [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; } \
      || warn "commit identity が空です。コンテナ内 commit は identity 未設定で失敗します。後で sandbox.config の GIT_USER_NAME/EMAIL を設定してください。"
  fi

  if [ -n "$default_passthrough" ]; then
    say ""
    say "ホスト側 .env から検出したキー: ${C_DIM}${default_passthrough}${C_RESET}"
    say "${C_DIM}(Enter でデフォルト採用 / 何も渡さないなら 'none' と入力)${C_RESET}"
  fi
  PASSTHROUGH_ENV=$(ask "agent に渡す env (カンマ区切り、none で無効)" "$default_passthrough")
  case "$PASSTHROUGH_ENV" in
    none|NONE|-) PASSTHROUGH_ENV="" ;;
  esac

  AGENT_USER_UID="$host_uid"
  AGENT_USER_GID="$host_gid"
}

# ---- sandbox.config 生成 ----
write_config() {
  info "sandbox.config を生成"
  if [ -f "$CONFIG_FILE" ] && [ "$RECONFIGURE_ONLY" -eq 0 ]; then
    local reply
    read -r -p "${CONFIG_FILE} が既にあります。上書きしますか? [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { warn "skip"; return; }
  fi
  # sed の区切り文字 | と衝突する文字をエスケープ (パス・API キー・name 対策)
  local esc_claude_dir esc_api_key esc_git_name esc_git_email
  esc_claude_dir=$(printf '%s' "$HOST_CLAUDE_DIR" | sed 's/[|&\\]/\\&/g')
  esc_api_key=$(printf '%s' "$ANTHROPIC_API_KEY" | sed 's/[|&\\]/\\&/g')
  esc_git_name=$(printf '%s' "$GIT_USER_NAME" | sed 's/[|&\\]/\\&/g')
  esc_git_email=$(printf '%s' "$GIT_USER_EMAIL" | sed 's/[|&\\]/\\&/g')
  sed \
    -e "s|__PROJECT_NAME__|${PROJECT_NAME}|g" \
    -e "s|__CLAUDE_AUTH_MODE__|${CLAUDE_AUTH_MODE}|g" \
    -e "s|__HOST_CLAUDE_DIR__|${esc_claude_dir}|g" \
    -e "s|__ANTHROPIC_API_KEY__|${esc_api_key}|g" \
    -e "s|__GIT_AUTH_MODE__|${GIT_AUTH_MODE}|g" \
    -e "s|__GIT_USER_NAME__|${esc_git_name}|g" \
    -e "s|__GIT_USER_EMAIL__|${esc_git_email}|g" \
    -e "s|__LANG_PACK__|${LANG_PACK}|g" \
    -e "s|__RUBY_VERSION__|${RUBY_VERSION}|g" \
    -e "s|__NODE_VERSION__|${NODE_VERSION}|g" \
    -e "s|__PYTHON_VERSION__|${PYTHON_VERSION}|g" \
    -e "s|__BUN_VERSION__|${BUN_VERSION}|g" \
    -e "s|__PKG_TOOL_PYTHON__|${PKG_TOOL_PYTHON}|g" \
    -e "s|__PKG_TOOL_NODE__|${PKG_TOOL_NODE}|g" \
    -e "s|__PKG_TOOL_NODE_VERSION__|${PKG_TOOL_NODE_VERSION}|g" \
    -e "s|__PKG_TOOL_NODE_ALLOW_UNSIGNED__|${PKG_TOOL_NODE_ALLOW_UNSIGNED}|g" \
    -e "s|__PASSTHROUGH_ENV__|${PASSTHROUGH_ENV}|g" \
    -e "s|__AGENT_USER_UID__|${AGENT_USER_UID}|g" \
    -e "s|__AGENT_USER_GID__|${AGENT_USER_GID}|g" \
    "$EXAMPLE_FILE" > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "$CONFIG_FILE 生成完了 (mode=${CLAUDE_AUTH_MODE})"
}

# ---- 認証モード変更の検知と対応 ----
# override.yml の先頭に前回モードを記録しておき、モードが変わっていたら、
# 前モードの認証情報・設定 (別アカウントの可能性あり) をどうするか確認する。
# デフォルトはリセット (未入力 Enter でリセット)。
handle_auth_mode_change() {
  local prev_mode=""
  [ -f "$OVERRIDE_FILE" ] && prev_mode=$(sed -n 's/^# CLAUDE_AUTH_MODE=\([ABC]\).*/\1/p' "$OVERRIDE_FILE")
  [ -n "$prev_mode" ] || return 0
  [ "$prev_mode" = "$CLAUDE_AUTH_MODE" ] && return 0

  warn "認証モードが ${prev_mode} → ${CLAUDE_AUTH_MODE} に変更されています"
  say ""
  say "  既存の認証情報・設定はすべて前モード (${prev_mode}) のものです:"
  say "    auth/claude-config/      … 認証トークン・セッション・履歴"
  say "    auth/claude-config.json  … アカウント情報・オンボーディング・MCP 設定"
  say ""
  say "  ${C_BOLD}保持${C_RESET}    : 前モードのアカウント・設定・履歴をそのまま引き継ぐ。"
  say "            同一アカウントだと${C_BOLD}確信できる場合のみ${C_RESET}選ぶこと。"
  say "  ${C_BOLD}リセット${C_RESET}: クリーンな状態から ${CLAUDE_AUTH_MODE} で再初期化する。"
  say ""
  say "  ${C_YELLOW}${C_BOLD}リスクが分からない場合は必ずリセットしてください。${C_RESET}"
  say "  ${C_YELLOW}別アカウントのトークンを保持したまま使うと、意図しないアカウントでの${C_RESET}"
  say "  ${C_YELLOW}操作や情報漏洩につながります。保持を選んだ状態でセキュリティ事故が${C_RESET}"
  say "  ${C_YELLOW}発生しても、その責任は負えません。${C_RESET}"
  say ""
  local reply
  read -r -p "  リセットしますか? [${C_BOLD}Y${C_RESET}/n] (未入力=リセット): " reply
  case "$reply" in
    n|N)
      warn "保持を選択。前モード (${prev_mode}) の認証情報・設定を引き継ぎます (自己責任)"
      ;;
    *)
      find auth/claude-config -mindepth 1 ! -name .gitkeep -exec rm -rf {} + 2>/dev/null || true
      rm -f auth/claude-config.json
      ok "auth/claude-config/ と auth/claude-config.json をリセットしました"
      ;;
  esac
}

# ---- docker-compose.override.yml 生成 ----
# 実行時構成は全 mode 共通 (~/.claude と ~/.claude.json をサンドボックス内に
# writable で永続化)。mode の違いは「認証情報をどう用意するか」だけ:
#   A = ホストの認証情報を初期化時にコピー
#   B = コンテナ内で claude login (別途実行)
#   C = ANTHROPIC_API_KEY を env で渡す (docker-compose.yml 側)
write_override() {
  info "$OVERRIDE_FILE を生成 (auth mode=${CLAUDE_AUTH_MODE})"

  # モード変更時は前モードの認証情報・設定の扱いを確認する (デフォルト=リセット)
  handle_auth_mode_change

  # ~/.claude.json (オンボーディング状態・履歴・MCP 設定) を用意する。
  # 単一ファイル bind mount はホスト側にファイルが無いと Docker が
  # ディレクトリを作ってしまうため、マウント前に必ず実体を作る。
  if [ ! -f auth/claude-config.json ]; then
    local host_claude_json
    host_claude_json="$(dirname "${HOST_CLAUDE_DIR:-$HOME/.claude}")/.claude.json"
    if [ "$CLAUDE_AUTH_MODE" = "A" ] && [ -f "$host_claude_json" ]; then
      cp "$host_claude_json" auth/claude-config.json
      ok "ホストの ~/.claude.json をコピー (オンボーディング状態を流用)"
    else
      echo '{}' > auth/claude-config.json
    fi
  fi

  # Mode A: ホストの認証情報をサンドボックス内にコピーして流用する。
  # ホストの ~/.claude を丸ごと ro マウントすると Claude Code が
  # sessions/cache を書けず token リフレッシュも失敗するため、コピー方式。
  if [ "$CLAUDE_AUTH_MODE" = "A" ]; then
    if [ ! -f auth/claude-config/.credentials.json ]; then
      if [ -f "$HOST_CLAUDE_DIR/.credentials.json" ]; then
        cp "$HOST_CLAUDE_DIR/.credentials.json" auth/claude-config/.credentials.json
        chmod 600 auth/claude-config/.credentials.json
        ok "ホストの認証情報を auth/claude-config/ にコピー"
      else
        warn "$HOST_CLAUDE_DIR/.credentials.json が見つかりません。ホスト側で claude login 済みか確認してください。"
      fi
    else
      info "auth/claude-config/.credentials.json は既存のため流用 (再コピーは削除後に再実行)"
    fi
  fi

  # Mode H: sandbox 専用の git 認証ファイルを mount する (ホスト ~/.git* は使わない)。
  #   git/credentials … git-pat.sh が発行した fine-grained PAT
  #   git/gitconfig   … ここで生成 (credential.helper=store + commit identity)
  # 警告は stdout に書かれるので override.yml 生成ブロックの外で済ませ、
  # YAML への混入を防ぐ。マウント対象パスは変数で渡す。
  local git_mount_config="" git_mount_creds=""
  if [ "${GIT_AUTH_MODE:-N}" = "H" ]; then
    if [ -f "git/credentials" ]; then
      git_mount_creds="./git/credentials"
      # commit identity は sandbox.config の GIT_USER_NAME/EMAIL をそのまま使う
      # (gather_inputs でホスト値をデフォルト提示して確定済み)。ここでは条件分岐しない。
      # ホストの .gitconfig 自体は mount しないので、値だけ git/gitconfig に焼き込む。
      mkdir -p git
      {
        echo "# generated by setup.sh — 編集しないこと (PAT は git-pat.sh / grants.conf が source)"
        echo "[credential]"
        echo "    helper = store"
        if [ -n "$GIT_USER_NAME" ] || [ -n "$GIT_USER_EMAIL" ]; then
          echo "[user]"
          [ -n "$GIT_USER_NAME" ]  && echo "    name = ${GIT_USER_NAME}"
          [ -n "$GIT_USER_EMAIL" ] && echo "    email = ${GIT_USER_EMAIL}"
        fi
      } > git/gitconfig
      chmod 600 git/gitconfig
      git_mount_config="./git/gitconfig"
      if [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; then
        warn "git: commit identity が空 (sandbox.config の GIT_USER_NAME/EMAIL 未設定)。コンテナ内 commit は失敗します。"
      fi
    else
      warn "git: git/credentials 不在のため mount をスキップ (push 認証は無効)。./git-pat.sh で PAT を発行してください。"
    fi
  fi

  # 先頭に現モードを記録する (次回の handle_auth_mode_change が参照する)。
  # ここから先は stdout が override.yml に redirect されるので、
  # info/warn/ok を呼ばないこと (YAML に混入する)。
  {
    echo "# generated by setup.sh — 編集しないこと"
    echo "# CLAUDE_AUTH_MODE=${CLAUDE_AUTH_MODE}"
    echo "# GIT_AUTH_MODE=${GIT_AUTH_MODE:-N}"
    cat <<'EOF'
services:
  agent:
    volumes:
      - "./auth/claude-config:/home/agent/.claude"
      - "./auth/claude-config.json:/home/agent/.claude.json"
EOF
    # Mode H で生成・確認できた sandbox 専用 file だけマウントする (RO)。
    # コンテナ内に焼かれず、image / volume にも残らない。commit identity は
    # 生成した git/gitconfig の [user] に含まれる (env での上書きは不要)。
    [ -n "$git_mount_config" ] && echo "      - \"${git_mount_config}:/home/agent/.gitconfig:ro\""
    [ -n "$git_mount_creds" ]  && echo "      - \"${git_mount_creds}:/home/agent/.git-credentials:ro\""
  } > "$OVERRIDE_FILE"
  ok "$OVERRIDE_FILE 生成完了 (git=${GIT_AUTH_MODE:-N})"
}

# ---- .runtime.env 生成 (PASSTHROUGH_ENV を実値で書き出す) ----
write_runtime_env() {
  info "$RUNTIME_ENV_FILE を生成"
  : > "$RUNTIME_ENV_FILE"
  if [ -z "$PASSTHROUGH_ENV" ]; then
    ok "passthrough なし"
    return
  fi
  local repo_root
  repo_root=$(cd "$SCRIPT_DIR/.." && pwd)
  IFS=',' read -ra keys <<< "$PASSTHROUGH_ENV"
  for key in "${keys[@]}"; do
    key=$(echo "$key" | xargs)
    [ -z "$key" ] && continue
    local val=""
    # 1) ホスト環境変数を優先、2) なければリポ root の .env を見る
    if [ -n "${!key+x}" ]; then
      val="${!key}"
    elif [ -f "$repo_root/.env" ]; then
      val=$(grep -E "^${key}=" "$repo_root/.env" | head -n1 | cut -d= -f2-)
    fi
    printf "%s=%s\n" "$key" "$val" >> "$RUNTIME_ENV_FILE"
  done
  chmod 600 "$RUNTIME_ENV_FILE"
  ok "$RUNTIME_ENV_FILE 生成完了 (${#keys[@]} 項目)"
}

# ---- CA bootstrap ----
bootstrap_ca() {
  info "mitmproxy CA bootstrap"
  if [ -f "$CA_FILE" ]; then
    ok "$CA_FILE 既存 (再生成する場合は proxy/certs/ を削除してから再実行)"
    return
  fi
  mkdir -p proxy/certs volumes/proxy-data
  info "egress-proxy を起動して CA 生成を待機"
  docker compose --env-file "$CONFIG_FILE" up -d egress-proxy
  local i
  for i in $(seq 1 30); do
    [ -f "$CA_FILE" ] && break
    sleep 1
  done
  if [ ! -f "$CA_FILE" ]; then
    docker compose --env-file "$CONFIG_FILE" logs egress-proxy >&2 || true
    die "CA ファイルが 30 秒以内に生成されませんでした"
  fi
  ok "CA bootstrap 完了: $CA_FILE"
}

# ---- agent イメージビルド ----
build_agent() {
  info "agent イメージをビルド"
  docker compose --env-file "$CONFIG_FILE" build agent
  ok "ビルド完了"
}

# ---- 認証後処理の案内 ----
post_auth_hint() {
  case "$CLAUDE_AUTH_MODE" in
    A)
      ok "Mode A: ホストの認証情報を auth/claude-config/ にコピー済み。追加操作なし。"
      ;;
    B)
      say ""
      say "${C_BOLD}Mode B の次の手順:${C_RESET}"
      say "  ./shell.sh          # コンテナに入る"
      say "  claude login        # コンテナ内で初回ログイン (Web フロー)"
      say "  exit"
      say "  ./run.sh            # 以降はこれで claude を起動"
      ;;
    C)
      ok "Mode C: API key を sandbox.config に保存しました。"
      ;;
  esac
}

# ---- 既存 sandbox.config を読み込む (--reconfigure 用) ----
load_config() {
  [ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE が無い。先に通常セットアップ (引数なし) を実行してください。"
  info "$CONFIG_FILE を読み込み"
  # shellcheck source=/dev/null
  set -a; . "./$CONFIG_FILE"; set +a
  : "${CLAUDE_AUTH_MODE:?sandbox.config に CLAUDE_AUTH_MODE がありません}"
  : "${HOST_CLAUDE_DIR:=}"
  : "${ANTHROPIC_API_KEY:=}"
  : "${GIT_AUTH_MODE:=N}"
  : "${GIT_USER_NAME:=}"
  : "${GIT_USER_EMAIL:=}"
  : "${PASSTHROUGH_ENV:=}"
  : "${RUBY_VERSION:=}"
  : "${NODE_VERSION:=}"
  : "${PYTHON_VERSION:=}"
  : "${BUN_VERSION:=}"
  : "${PKG_TOOL_PYTHON:=uv}"
  : "${PKG_TOOL_NODE:=npm}"
  : "${PKG_TOOL_NODE_VERSION:=}"
  : "${PKG_TOOL_NODE_ALLOW_UNSIGNED:=}"
  # mode 固有の必須値を検証・補完。sandbox.config を手で編集して mode を
  # 切り替えると、その mode で必要な値が空のままになることがあるため。
  case "$CLAUDE_AUTH_MODE" in
    A)
      if [ -z "$HOST_CLAUDE_DIR" ]; then
        HOST_CLAUDE_DIR="$HOME/.claude"
        warn "HOST_CLAUDE_DIR が空のため ${HOST_CLAUDE_DIR} を使用します (sandbox.config に明記推奨)"
      fi
      [ -d "$HOST_CLAUDE_DIR" ] || warn "$HOST_CLAUDE_DIR が存在しません。ホスト側で claude login 済みか確認してください。"
      ;;
    C)
      [ -n "$ANTHROPIC_API_KEY" ] || die "Mode C には ANTHROPIC_API_KEY が必要です。sandbox.config に設定してください。"
      ;;
  esac
  ok "読み込み完了 (mode=${CLAUDE_AUTH_MODE}, lang=${LANG_PACK:-none})"
}

# ---- 動作確認 ----
run_doctor() {
  if [ -x "./doctor.sh" ]; then
    info "doctor.sh を実行"
    ./doctor.sh || warn "doctor で警告あり。詳細は上記参照。"
  fi
}

# ============================================================
# main
# ============================================================
say "${C_BOLD}Claude Code Sandbox setup${C_RESET}"
say ""

if [ "$CA_ONLY" -eq 1 ]; then
  [ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE が無い。先に通常セットアップを実行してください。"
  rm -f "$CA_FILE"
  bootstrap_ca
  build_agent
  exit 0
fi

check_prereqs

# --reconfigure: 既存 sandbox.config を読み、派生ファイルだけ作り直す。
# sandbox.config 自体は上書きしない (対話もしない)。
if [ "$RECONFIGURE_ONLY" -eq 1 ]; then
  load_config
  write_override
  write_runtime_env
  ok "reconfigure 完了 (override.yml と .runtime.env を再生成)"
  exit 0
fi

gather_inputs
write_config
write_override
write_runtime_env
bootstrap_ca
build_agent
post_auth_hint
run_doctor

say ""
ok "セットアップ完了。${C_BOLD}./run.sh${C_RESET} で claude が起動できます。"
