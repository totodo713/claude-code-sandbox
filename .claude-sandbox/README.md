# Claude Code Sandbox

Claude Code (`claude` CLI) を **ネットワーク制限付き Docker コンテナ** の中で動かすためのポータブルパッケージ。フォルダ 1 つコピー + `setup.sh` で他リポジトリにも導入できる。

## TL;DR

- **何**: `claude` をネットワーク allowlist + 隔離コンテナの中で動かす
- **入れ方**: `./.claude-sandbox/setup.sh` (対話) → `./.claude-sandbox/run.sh` で起動
- **Claude 経由の install / 実行は必ずコンテナ内で**:
  `./.claude-sandbox/shell.sh` に入ってから `npm install` / `uv sync` /
  `bundle install` / スクリプト実行を行う。`npm install` の post-install
  script が **ホスト権限で動くのを避ける**ため (サンドボックスの主目的)。
  人間が開発時に動作確認のためホストでも install するのは OK (詳細は
  [運用注意](#運用注意-install--実行はコンテナ内で-特に-claude-経由))
- **診断**: `./.claude-sandbox/doctor.sh` (12 項目チェック) / `./.claude-sandbox/logs.sh` (proxy ログ)
- **詳細**: 下のセクションへ

## Tips

- `.claude-sandbox/logs.sh | grep block_connect` : Outbound通信ブロックのログを監視するときに使う

## どう守られているか

```
┌─────────────────────────────┐
│  agent コンテナ              │   <- claude と子プロセス全部ここ
│  network: sandbox-internal   │   <- internal: true で物理的に外向き不可
│  HTTP(S)_PROXY → egress-proxy│
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  egress-proxy (mitmproxy)   │   <- SSL Bump で TLS 終端
│  allowlist で SNI/Host 判定 │   <- 違反は 502 で遮断
└────────────┬────────────────┘
             │ (許可ドメインのみ)
             ▼
        インターネット
```

二重防御:
1. **ネットワーク隔離**: agent はそもそも外部 IP に到達できない (proxy 以外通信不能)
2. **L7 allowlist**: TLS を終端して URL レベルで監査・遮断

## 前提

- Docker Engine + Docker Compose v2
- Linux / macOS / WSL2 (Docker Desktop の WSL integration ON)
- Bash 4 以降

## クイックスタート

```bash
# 1. 初回セットアップ (対話)
./.claude-sandbox/setup.sh

# 2. claude を起動
./.claude-sandbox/run.sh

# 補助
./.claude-sandbox/shell.sh         # コンテナに bash で入る
./.claude-sandbox/logs.sh          # proxy ログ tail
./.claude-sandbox/doctor.sh        # 環境診断
./.claude-sandbox/copy-to.sh <dst> # 他リポへ .claude-sandbox/ をコピー
./.claude-sandbox/clean.sh         # setup 生成物を消して初期状態に戻す
```

## 設定ファイル: `sandbox.config`

`setup.sh` が対話で生成。後からエディタで編集可能。
変更後は `setup.sh --reconfigure` で `docker-compose.override.yml` と `.runtime.env` を更新する。

| 項目 | 説明 |
|---|---|
| `PROJECT_NAME` | docker compose の `name` |
| `HOST_REPO_PATH` | リポジトリ root への相対パス (default `..`) |
| `CLAUDE_AUTH_MODE` | `A` ホスト認証情報をコピー / `B` コンテナ内 claude login / `C` API key |
| `HOST_CLAUDE_DIR` | mode A 時のコピー元ホスト `.claude` パス |
| `ANTHROPIC_API_KEY` | mode C 時の API key |
| `GIT_AUTH_MODE` | `N` push 無効 (default) / `H` ホスト `~/.gitconfig` と `~/.git-credentials` を read-only mount |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | mode H 時の commit author 上書き。空ならマウントした `.gitconfig` の値を使う |
| `LANG_PACK` | `ruby,node,python,bun` のカンマ区切り (検出は自動)。変更時は `build agent` 必要 |
| `RUBY_VERSION` | プロジェクトの Ruby バージョン。`.ruby-version`→Gemfile から自動検出。変更時は `build agent` 必要 |
| `NODE_VERSION` | プロジェクトの Node バージョン。`.nvmrc`→`.node-version`→`package.json` から自動検出。`X`/`X.Y`/`X.Y.Z`/`lts` 可。変更時は `build agent` 必要 |
| `PYTHON_VERSION` | プロジェクトの Python バージョン。`.python-version`→`runtime.txt`→`pyproject.toml` から自動検出。変更時は `build agent` 必要 |
| `BUN_VERSION` | プロジェクトの bun バージョン。`.bun-version`→`package.json` engines.bun から自動検出。空=latest。変更時は `build agent` 必要 |
| `BLOCK_ON_VIOLATION` | `true` で違反 502 遮断 / `false` で警告のみ通過 |
| `PASSTHROUGH_ENV` | agent に渡すホスト env のキー名 (カンマ区切り) |
| `PROXY_LISTEN_PORT` | mitmproxy 受け口 (default 8080) |
| `AGENT_USER_UID/GID` | コンテナ内ユーザの UID/GID (ホストと合わせる) |

## 認証モード比較

実行時構成は 3 mode 共通（`~/.claude` と `~/.claude.json` をサンドボックス内に
writable で永続化）。違いは **認証情報の入手方法だけ**。

| | A: ホスト認証情報をコピー | B: コンテナ内 claude login | C: API key |
|---|---|---|---|
| 認証情報の入手 | setup 時にホストの `.credentials.json` / `.claude.json` をコピー | コンテナ内で `claude login` | `ANTHROPIC_API_KEY` を env で注入 |
| セットアップ手間 | 既に host で login 済なら 0 | 初回 `claude login` が必要 | key 発行が必要 |
| ホスト FS の露出 | なし (コピーするだけ) | なし | なし |
| host ログインへの影響 | なし (独立したコピー) | なし | なし |
| Pro/Team サブスク | OK | OK | NG (API 課金) |
| 推奨用途 | 個人開発 (host の login を流用) | 強い分離が必要な repo | CI / 自動化 |

> Mode A は当初ホストの `~/.claude` を read-only マウントしていたが、Claude Code が
> sessions/cache を書けず token リフレッシュも失敗するため、コピー方式に変更した。
> コピーは初回のみ。再コピーするには `auth/claude-config/.credentials.json` を
> 削除してから `./setup.sh --reconfigure` を実行する。

### モード切替時の挙動

`sandbox.config` の `CLAUDE_AUTH_MODE` を変更して `setup.sh` / `--reconfigure` を
実行すると、**前モードの認証情報・設定を残すか確認するプロンプト**が出る:

```
認証モードが B → A に変更されています
  リセットしますか? [Y/n] (未入力=リセット):
```

- 既存の `auth/claude-config/` `auth/claude-config.json` は前モードのもので、
  **別アカウントの可能性がある**
- **デフォルト（Enter）= リセット**。クリーンな状態から新モードで再初期化する
- `n` を選ぶと前モードの認証情報・設定を引き継ぐが、別アカウント混入のリスクは
  自己責任。同一アカウントだと確信できる場合のみ
- override.yml の先頭コメント `# CLAUDE_AUTH_MODE=X` で前回モードを記録している

## git push 認証 (`GIT_AUTH_MODE`)

sandbox 内から `git push` できるかを切り替える。デフォルトは `N` (push 不可、
clone / fetch / pull は github が core allowlist に入っているのでそのまま動く)。
push したいときだけ `H` を選んでホストの credential を read-only mount する。

| | N: 無効 (default) | H: ホスト credential を read-only mount |
|---|---|---|
| sandbox 内での push | ✗ | ✓ |
| 認証情報の場所 | — | ホスト `~/.gitconfig` + `~/.git-credentials` を ro mount |
| コンテナへの焼き込み | — | なし (image / volume には残らない) |
| 前提 | — | ホストで `credential.helper=store` を使っていること |

### Mode H の使い方

```bash
# 1. ホストで credential.helper=store にして、認証情報を ~/.git-credentials に書き出す
git config --global credential.helper store
git push    # 初回に認証を聞かれ、HTTPS + token が ~/.git-credentials に保存される
            # (fine-grained PAT 推奨。下記「注意」参照)

# 2. setup.sh / --reconfigure で GIT_AUTH_MODE=H を選ぶ
./.claude-sandbox/setup.sh --reconfigure
```

### Mode H の前提と注意

- **`credential.helper=store` 専用**。macOS keychain / Windows manager は file 読み取りができないため非対応。`store` への切替が必要。
- **`GIT_USER_NAME` / `GIT_USER_EMAIL` で identity を上書き可能**。空ならマウントした `.gitconfig` の user.name/email がそのまま使われる。bot 用 identity を分けたいときに指定する。
- **fine-grained PAT を強く推奨**。`repo` 全権の classic PAT を `~/.git-credentials` に置くと、sandbox 内の agent から **全 repo に push 可能**になる。blast radius を最小にするため、push したい単一 repo に絞った PAT を発行すること。
- **branch protection はサーバ側で**。agent が `git push --force` を物理的に発火するのを sandbox 側で止めるのは難しい。GitHub 側の branch protection / required reviews を最終防衛線にする。
- **mitmproxy が HTTPS を復号する**。push の本文 (差分) は proxy で一瞬平文になる。自分のインフラを通すだけだが、設定次第ではログに残せる構造なので意識しておく。
- **将来の追加候補**: SSH agent forwarding (鍵をホスト側 ssh-agent に残し socket だけ転送) / コンテナ内 `gh auth login`。現状は実装せず、Mode H で困った具体例が出てから検討する。

> sandbox 外でユーザー自身が push できる場合は **Mode N のまま使う方が安全**。
> sandbox 内に credential を露出させる必要がそもそも無い。

## 実行系の構成

```
/usr/local/bin/claude  ← claude-code CLI。公式ネイティブインストーラで導入される
                          自己完結バイナリ。実行時に Node 不要。
/opt/runtimes/<lang>   ← Project 実行系: プロジェクトのコードを動かす。
                          LANG_PACK で選んだ言語をここに入れ、PATH 先頭に置く。
```

claude-code 本体は Node 内蔵の自己完結バイナリとして配布されているため、
プロジェクトが要求する Node/Ruby/Python のバージョンとは完全に独立して動く。
「Node 14 の古いプロジェクトを最新化する」ような場合でも、プロジェクトは
Node 14 で動かしつつ claude-code は無関係に動作する。

### バージョンの指定方法

**Project 実行系のバージョン**は `NODE_VERSION` / `RUBY_VERSION` / `PYTHON_VERSION`:

```bash
# sandbox.config
LANG_PACK=node               # LANG_PACK に node を含める
NODE_VERSION=14.21.3         # プロジェクトが要求するバージョン
```

各 `*_VERSION` は `setup.sh` が以下の順で自動検出する:
- Node: `.nvmrc` → `.node-version` → `package.json` の `engines.node`
- Ruby: `.ruby-version` → Gemfile
- Python: `.python-version` → `runtime.txt` → `pyproject.toml`
- Bun: `.bun-version` → `package.json` の `engines.bun`

指定可能な形式:
- Node: `X` / `X.Y` / `X.Y.Z` / `lts` (Dockerfile 内の `_resolve-node` で具体的なパッチに解決)
- Python: `X.Y` / `X.Y.Z` (`X.Y` は `_resolve-python` で pyenv definitions から最新パッチに解決。`uv` が生成する `.python-version` は major.minor のことが多いのでこの形式に対応)
- Ruby: `X.Y.Z` のみ (ruby-build が完全指定を要求)
- Bun: `X.Y.Z` / 空文字 (空のときはインストーラの最新版を導入)

### bun を入れるとき: ランタイムか PM か

bun は **JavaScript ランタイム** と **パッケージマネージャ** の二役なので、
このサンドボックスでも 2 通りの入れ方をサポートしている:

| 入れ方 | LANG_PACK | PKG_TOOL_NODE | bun の置き場 | 想定用途 |
|---|---|---|---|---|
| ランタイムとして | `bun` (`node` は不要) | (無視) | `/opt/runtimes/bun/bin` | 純 bun プロジェクト。Node を別途入れない |
| Node の PM として | `node` | `bun` | `/opt/bun/bin` | 既存 Node プロジェクトで bun install を使う移行期 |
| 両方 | `node,bun` | `bun` (任意) | 両方に入る | Node 実行系と bun ランタイムの両方が要る場合 |

ランタイム用の `LANG_PACK=bun` は `bun.lockb` / `bun.lock` / `bunfig.toml` が
リポにあれば `setup.sh` が自動で選ぶ。それ以外で `package.json` だけある場合は
`node` がデフォルトなので、ランタイム bun が欲しければ `LANG_PACK=bun` に
明示的に変えること。

### 対応言語を増やすとき

`Dockerfile.agent` の「プロジェクト実行系」`case` にブランチを 1 つ、
`setup.sh` に `detect_<lang>_version()` を 1 つ追加するだけ。契約は
「`$<LANG>_VERSION` を `/opt/runtimes/<lang>` に入れ、`bin/` に実行ファイルを置く」。

## 依存パッケージの保存先 (volume 分離)

各言語の依存パッケージは **ホストリポではなく named volume に置く**。
ホストリポを汚さず、`run.sh` をまたいで永続し、native binding をコンテナ内に
隔離する目的。

| 言語 | volume 名 | マウント先 | 内容 |
|---|---|---|---|
| Ruby | `bundle-cache` | `/opt/bundle` | gem (GEM_HOME / BUNDLE_PATH) |
| Node | `node-modules-cache` | `/workspace/node_modules` | `npm install` / `pnpm install` / `yarn install` / `bun install` の出力 |
| Node | `npm-cache` | `/home/agent/.npm` | npm の tarball キャッシュ |
| Node | `pnpm-store-cache` | `/home/agent/.local/share/pnpm` | pnpm の content-addressable store |
| Node | `yarn-cache` | `/home/agent/.yarn` | Yarn (Berry) のグローバルキャッシュ / config |
| Node | `bun-install-cache` | `/home/agent/.bun/install/cache` | bun の install キャッシュ |
| Python | `venv-cache` | `/workspace/.venv` | `uv sync` / `python -m venv` で作る venv |
| Python | `uv-cache` | `/home/agent/.cache/uv` | uv の wheel / tarball キャッシュ |
| Python | `pip-cache` | `/home/agent/.cache/pip` | pip の wheel キャッシュ |

Node の `node_modules` と Python の `.venv` は bind mount `/workspace` の上に
named volume を重ねる形でマウントする (Docker 標準の挙動)。ホスト側のリポに
`node_modules` / `.venv` があってもコンテナ内からは隠れ、コンテナ内の
`npm install` / `uv sync` の結果はホストには出ない (ホスト側にはマウント
ポイントとして root 所有の空ディレクトリだけが残る)。
**monorepo のネスト `node_modules` は未対応** — 必要なら
`docker-compose.override.yml` で個別に volume をマウントする。

### 運用注意: install / 実行はコンテナ内で (特に Claude 経由)

`npm install` は **post-install script** として任意のシェルコマンドを実行
する。これがホストで走るとサンドボックスの隔離 (ネットワーク allowlist /
ファイルシステム制限) を素通りしてホスト権限で動くため、**サンドボックスの
主目的が損なわれる**。`uv sync` も build hook で同様のリスクがある。

**Claude 経由の install や Claude セッションで動かすスクリプトは必ず
コンテナ内で**:

```bash
./.claude-sandbox/shell.sh
# コンテナ内で
npm install <pkg>        # 依存追加
uv add <pkg>             # Python (uv)
bundle add <gem>         # Ruby
node scripts/foo.js      # スクリプト実行
uv run scripts/foo.py
```

**人間が開発時にホスト側でも install / 実行するのは OK** (認識した上で):

- ホスト/コンテナで `node_modules` / `.venv` は **別実体** (named volume が
  コンテナ内で bind mount に重なるため、ホスト側 install はコンテナからは
  見えない)
- ロックファイル (`package-lock.json` / `uv.lock` / `Gemfile.lock` 等) は
  bind mount で共有されるので、バージョン整合性はロック経由で揃えられる
- 不要になったら掃除: ホスト側で `rm -rf node_modules .venv`

IDE の補完を効かせたい場合は、ホスト install するより **「Dev Containers
/ Remote Interpreter」を IDE 側で設定して、コンテナ内ランタイムを参照させる**
方が筋。これならホスト側に何も作らずに済む。

Ruby (bundle) は `/opt/bundle` というコンテナ専用パスにインストールされる
設計なので、ホスト側で `bundle install` してもコンテナとは衝突しない。
ただし native extension を含む gem はホスト/コンテナで ABI が違うと動かない
ことがあるので、Ruby も基本はコンテナ内で実行する方が安全。

### パッケージマネージャの切替

各言語のパッケージマネージャは `sandbox.config` の `PKG_TOOL_*` で指定する。
`setup.sh` がリポジトリ内の lockfile を見て自動判定する:

| 変数 | 実装済 | 自動検出ソース | 将来枠 |
|---|---|---|---|
| `PKG_TOOL_PYTHON` | `uv` / `pip` | `uv.lock` → uv / `requirements.txt` → pip | `poetry` / `pipenv` |
| `PKG_TOOL_NODE` | `npm` / `pnpm` / `yarn` / `bun` | `bun.lock(b)` → bun / `pnpm-lock.yaml` → pnpm / `yarn.lock` → yarn / `package.json` の `packageManager` → 該当ツール、それ以外 → npm | — |

`Dockerfile.agent` の各言語ブランチに `case "$PKG_TOOL_<LANG>" in ... esac`
の枠があり、新ツール対応はこの case にブランチを足すだけ。実装枠外を指定すると
build 時にエラーになる。poetry / pipenv 等を足したい時は、既存の `uv` /
`pnpm` / `yarn` (corepack 経由) や `bun` (curl install) ブランチを参考に同じ
パターンでブランチを追加する。

volume の中身は `docker volume inspect` や、コンテナ内 `ls /opt/bundle` で確認可。
リセットしたい場合:

```bash
docker compose --env-file sandbox.config down -v   # 全 volume 削除
# or 個別に
docker volume rm <project>_node-modules-cache
```

## allowlist の編集

```
allowlist/
├── core.txt                 # 必須 (anthropic, github, npm)
├── lang-ruby.txt            # gemfile/bundler
├── lang-node.txt            # Node + npm/pnpm/yarn/bun (as PM)
├── lang-bun.txt             # bun ランタイム (LANG_PACK=bun のとき)
├── lang-python.txt          # pypi
└── allowlist.d/
    └── extra.txt            # プロジェクト固有 (commit OK)
```

- 1 行 1 ドメイン、`#` コメント、`*.example.com` でサフィックスマッチ
- `extra.txt` を編集したら proxy 再起動 (`docker compose --env-file sandbox.config restart egress-proxy`)

例: 本リポは SendGrid を叩くので `extra.txt` に以下を追記:
```
api.sendgrid.com
*.sendgrid.net
```

## 認証 B (コンテナ内 claude login) の手順

```bash
./.claude-sandbox/shell.sh
# (コンテナ内で)
claude login
# Web ブラウザでログイン → コードを貼り付け
exit
# 以降は ./.claude-sandbox/run.sh で起動
```

認証情報は `auth/claude-config/` (`~/.claude/` 相当) に永続化される。
オンボーディング状態・履歴・MCP 設定は `auth/claude-config.json` (`~/.claude.json` 相当)
に永続化される。いずれも gitignore 済。コンテナ自体は `run.sh` ごとに使い捨て
(`--rm`) だが、この 2 つだけは明示的にマウントして残している。

## トラブルシュート

### `update-ca-certificates` 段階で build エラー
`proxy/certs/mitmproxy-ca-cert.pem` が無い。`./setup.sh --ca-only` を実行。

### `curl: (60) SSL certificate problem`
- `update-ca-certificates` が走った最新イメージか確認: `./setup.sh --ca-only` で rebuild
- mitmproxy の CA を再生成した場合: `rm -rf proxy/certs/* && ./setup.sh --ca-only`

### `Bad Gateway` (502) しか返らない
allowlist に対象ドメインがない。`allowlist/allowlist.d/extra.txt` に追加して proxy 再起動:
```bash
docker compose --env-file sandbox.config restart egress-proxy
```
`./logs.sh` で `block_*` の JSON ログから足りないドメインを特定できる。

### Go modules / `docker pull` / Stripe SDK 等が動かない
これらは cert pinning しているため SSL Bump では壊れる:
- Go: `GOSUMDB=off` (Dockerfile で設定済み)
- `docker pull` 系: 原則 agent コンテナ内では実行しない
- pinning する SaaS SDK: 個別に CA bundle 上書きが必要

### WSL2 で `/workspace` が書けない
ホストの UID/GID を `sandbox.config` の `AGENT_USER_UID/GID` と一致させる。`setup.sh` は `id -u/-g` を自動採用するが、後から WSL ディストロを変えた場合は再 setup。

### WSL2 sleep 復帰後に TLS 失敗
時刻ずれ。`sudo hwclock -s` でホスト時刻を合わせるか Docker Desktop 再起動。

### CA 再生成
```bash
docker compose --env-file sandbox.config down
rm -rf proxy/certs/* volumes/proxy-data/*
./setup.sh --ca-only
```

## 他リポジトリへ持っていく

`copy-to.sh` は `git archive HEAD` ベースで動くので、`.gitignore` 対象
(sandbox.config / 認証情報 / volumes / proxy CA 等) は自動で除外され、
余計なファイルを持っていかない。

```bash
# 1. コピー (現リポの .claude-sandbox/ を git 管理ファイルだけ転送)
./.claude-sandbox/copy-to.sh /path/to/other-repo

# 2. コピー先で setup
cd /path/to/other-repo
./.claude-sandbox/setup.sh
```

> **注意**: 未コミットの sandbox 改変は持っていかれない。先にコミット
> してから `copy-to.sh` を実行する。

`allowlist/allowlist.d/extra.txt` だけプロジェクトごとに編集してコミット
する想定。

## リセット (再セットアップ / 認証モード切替)

`clean.sh` は **同一リポ**で setup.sh の生成物を消して初期状態に戻す。
認証モードを切り替えたい / 別アカウントの認証情報を完全に消したい時に。

```bash
./.claude-sandbox/clean.sh
./.claude-sandbox/setup.sh   # クリーンに再セットアップ
```

`clean.sh` が消すもの:
- `sandbox.config` / `.runtime.env` / `docker-compose.override.yml`
- `proxy/certs/*` (mitmproxy CA)
- `volumes/` 中身
- `auth/claude-config/*` と `auth/claude-config.json`

named volume (`bundle-cache` 等) はこのスクリプトでは消さない。完全に
クリーンにしたい時は別途:

```bash
docker compose --env-file sandbox.config down -v
```

## ファイル構成

| パス | 役割 | commit? |
|---|---|---|
| `setup.sh` `run.sh` `shell.sh` `logs.sh` `doctor.sh` `copy-to.sh` `clean.sh` | エントリポイント | yes |
| `docker-compose.yml` `Dockerfile.agent` | 基盤 | yes |
| `proxy/allowlist_addon.py` | mitmproxy addon | yes |
| `allowlist/core.txt` `lang-*.txt` | 固定 allowlist | yes |
| `allowlist/allowlist.d/extra.txt` | プロジェクト固有 | yes |
| `sandbox.config.example` | テンプレ | yes |
| `sandbox.config` | 実設定 (秘密含む) | **no** |
| `docker-compose.override.yml` | 自動生成 | **no** |
| `.runtime.env` | 自動生成 | **no** |
| `proxy/certs/` | mitmproxy CA | **no** |
| `auth/claude-config/` | 認証情報・セッション (`~/.claude/`) | **no** |
| `auth/claude-config.json` | オンボーディング状態・設定 (`~/.claude.json`) | **no** |
| `volumes/` | mitmproxy フロー記録 | **no** |
