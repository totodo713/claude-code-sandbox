# 手動チェックリスト

`run.sh` で自動化できない項目をここで実行する。各項目は **目的 / 手順 / 期待結果** の 3 段構え。チェックは `[ ]` → `[x]`。

すべて `.claude-sandbox/` を CWD として実行する想定:
```bash
cd /home/devman/RubymineProjects/operation-support-tools/.claude-sandbox
```

---

## §1 初回セットアップ (mode A)

### 1.1 setup.sh の対話完走

**目的**: 対話セッションが期待通りに進み、必要なファイルが揃うこと。

**手順**:
```bash
./setup.sh
```

対話に以下を入力 (デフォルトを受け入れる場合は Enter):
- プロジェクト名: `operation-support-tools` (default)
- 言語パック: `ruby` (Gemfile があるので自動検出)
- 認証方式: `A`
- ホスト ~/.claude のパス: `/home/devman/.claude` (default)
- agent に渡す env: `.env` から検出されたキーをそのまま受け入れ

**期待結果**:
- [x] 「セットアップ完了」と表示される
- [x] 以下のファイルが生成されている:
  - `sandbox.config` (600 パーミッション)
  - `docker-compose.override.yml`
  - `.runtime.env`
  - `proxy/certs/mitmproxy-ca-cert.pem`
- [x] agent イメージがビルドされている: `docker image inspect operation-support-tools-agent:latest` が成功
- [x] 最後に走る `doctor.sh` がすべて緑

### 1.2 doctor.sh の単独実行

**目的**: 後からでも環境診断ができること。

**手順**:
```bash
./doctor.sh
```

**期待結果**:
- [x] `[1] 基本ファイル`: 4 件 ok
- [x] `[2] コンテナ`: 2 件 ok
- [x] `[3] ネットワーク`: 3 件 ok + 1 件 ok or warn
- [x] `[4] Claude CLI`: 2 件 ok
- [x] 最終的に `fail` 0 件

---

## §2 自動テストの実行

### 2.1 全テスト
```bash
./test/run.sh
```
- [x] 集計が `0 fail` で終わる

### 2.2 verbose 再実行 (失敗時)
失敗があった場合のみ:
```bash
./test/run.sh -v <失敗 ID>
```
- [x] 詳細出力から原因が特定できる

---

## §3 CA 再生成 (破壊的)

### 3.1 CA 削除 → 復旧

**目的**: CA を消しても `--ca-only` で完全復旧できること。

**手順**:
```bash
docker compose --env-file sandbox.config down
rm -rf proxy/certs/* volumes/proxy-data/*
./setup.sh --ca-only
```

**期待結果**:
- [x] `proxy/certs/mitmproxy-ca-cert.pem` が再生成される
- [x] agent イメージが再ビルドされる (CA fingerprint が変わるため `--no-cache` 相当の挙動)
- [x] その後 `./doctor.sh` がすべて緑

---

## §4 認証モード B の検証

### 4.1 mode B に切替 → claude login

**目的**: コンテナ内で完結する認証フローが動くこと。

**手順**:
```bash
# 1. mode を B に変更
sed -i 's/^CLAUDE_AUTH_MODE=.*/CLAUDE_AUTH_MODE=B/' sandbox.config
./setup.sh --reconfigure

# 2. コンテナに入って login
./shell.sh
# (コンテナ内で)
claude login
# → 表示される URL をホスト側ブラウザで開いてログイン
# → コードを貼り付ける
exit
```

**期待結果**:
- [x] `claude login` がブラウザ URL を表示する
- [x] ログイン完了後 `auth/claude-config/` 配下にセッションファイルができる
- [x] `./run.sh` で claude が起動し、認証エラーが出ない

### 4.2 セッション永続化

**手順**:
```bash
docker compose --env-file sandbox.config down
./run.sh
```

**期待結果**:
- [ ] コンテナを破棄して再起動しても **再 login 不要** で claude が動く

### 4.3 mode A に戻す（モード変更検知の確認）

**手順**:
```bash
sed -i 's/^CLAUDE_AUTH_MODE=.*/CLAUDE_AUTH_MODE=A/' sandbox.config
./setup.sh --reconfigure
```

**期待結果**:
- [x] 「認証モードが B → A に変更されています」の警告が出る
- [x] `リセットしますか? [Y/n] (未入力=リセット)` のプロンプトが出る
- [x] **Enter（未入力）or `y`** → `auth/claude-config/` と `auth/claude-config.json` が削除され、Mode A はホストの認証情報を再コピーする
- [x] **`n`** → 前モード(B)の認証情報・設定をそのまま引き継ぐ（自己責任の警告が出る）
- [x] override.yml の先頭が `# CLAUDE_AUTH_MODE=A` になる

> 別アカウントの可能性があるなら必ずリセット側（Enter）を選ぶこと。

---

## §5 認証モード C の検証 (任意)

API key を持っている場合のみ。

**手順**:
```bash
./setup.sh --reconfigure
# 対話で auth mode に C を選び、key を貼り付け
./run.sh
```

> §4 から mode を切り替えるため、モード変更検知のプロンプトが出る。
> 別アカウントの API key なら**リセット（Enter）**を選ぶこと。

**期待結果**:
- [ ] `sandbox.config` に `ANTHROPIC_API_KEY=...` が書かれている (パーミッション 600)
- [ ] claude が起動し、`/login` を求められない
- [ ] 終了後 mode A に戻す: 上記 §4.3 と同じ手順

---

## §6 claude プロンプトでの実操作

### 6.1 基本動作

**目的**: 実際の利用シナリオで claude が正しく動くこと。

**手順**:
```bash
./run.sh
# claude プロンプトで:
> /workspace の README はある?
> ls app/
> CLAUDE.md の最初の 20 行を表示して
```

**期待結果**:
- [x] `Read` ツールでファイルが読める
- [x] `Bash` ツールで `ls` が実行できる
- [x] ホストの `app/` 配下が見える

### 6.2 ファイル編集

**手順**:
```bash
./run.sh
# プロンプトで:
> /tmp/sandbox-test.txt に "hello" と書いて
```

**期待結果**:
- [x] コンテナ内 `/tmp/sandbox-test.txt` に書ける (コンテナ内)
- [x] `/workspace/sandbox-test.txt` (リポ root) に書いた場合、ホスト側でも見える

### 6.3 ネットワーク制限の体感

**手順**:
```bash
./run.sh
# プロンプトで:
> curl -sI https://example.com を実行して
```

**期待結果**:
- [x] `502 Bad Gateway` で返ってくる (sandbox の防御が claude 自身にも効く)
- [x] `./logs.sh` で `event:"block_*"` の JSON が見える

---

## §7 言語パック (Ruby) の実利用

### 7.1 bundle install

**手順**:
```bash
./shell.sh
# コンテナ内で
cd /workspace
bundle install
```

**期待結果**:
- [ ] `rubygems.org` から gem が取れる (allowlist の `lang-ruby.txt`)
- [ ] 既存テストが走る (依存があれば): `APP_ENV=test bundle exec rspec --dry-run`

### 7.2 allowlist 外への試行

**手順**: コンテナ内で
```bash
curl -I https://example.com
gem fetch some-random-gem --source https://example.com
```

**期待結果**:
- [ ] curl が `502` を返す
- [ ] gem fetch が SSL/network error で失敗する

### 7.3 依存パッケージの volume 分離

**手順 (マウント確認)**: コンテナ内で
```bash
mount | grep -E "/opt/bundle|/workspace/node_modules|/home/agent/\.npm"
```

**期待結果**:
- [ ] `/opt/bundle` が `bundle-cache` にマウント
- [ ] `/workspace/node_modules` が `node-modules-cache` にマウント
- [ ] `/home/agent/.npm` が `npm-cache` にマウント

**手順 (実 install で漏れ確認)**: コンテナ内で
```bash
cd /workspace
echo '{"name":"vol-test","version":"0.0.0"}' > package.json
npm install --no-audit --no-fund lodash
ls node_modules/lodash >/dev/null && echo "container: ok"
```

ホスト側 (別ターミナル) で:
```bash
ls /home/devman/RubymineProjects/operation-support-tools/node_modules/ | wc -l
# → 0 (空のマウントポイントのみ。中身 (lodash) は named volume に隔離)
```

片付け (コンテナ内):
```bash
rm /workspace/package.json /workspace/package-lock.json
```

> ホスト側に root 所有の空ディレクトリ `node_modules/` が残るのは Docker の
> named volume を bind mount に重ねた時の構造的な副作用。中身はコンテナ内
> volume にしか存在しない。リポの `.gitignore` に `node_modules/` を含めて
> おくと commit 事故を防げる。

**期待結果**:
- [ ] コンテナ内 `node_modules/lodash` が存在
- [ ] ホスト側 `node_modules/` の中身は空 (上のコマンドで `0`)
- [ ] `run.sh` をまたいでも `npm install` の結果が消えない (`down`/`up` 後に `ls node_modules/lodash` で確認)

### 7.4 Python (uv) の依存パッケージ volume 分離

**前提**: `LANG_PACK` に `python` を含む。本リポは `pyproject.toml` /
`.python-version` / `uv.lock` を持つので `uv sync` で `.venv` が作られる。

**手順 (実 sync で漏れ確認)**: コンテナ内で
```bash
cd /workspace
uv sync
ls .venv/bin/python >/dev/null && echo "container: .venv ok"
uv run pyscript/client_test.py
```

ホスト側 (別ターミナル) で:
```bash
ls /home/devman/RubymineProjects/operation-support-tools/.venv/ | wc -l
# → 0 (空のマウントポイントのみ。中身は venv-cache に隔離)
```

**期待結果**:
- [ ] コンテナ内 `.venv/bin/python` が存在
- [ ] `uv run pyscript/client_test.py` が allowlist 内で完走 (httpbin.org 等が
      未許可なら通信エラーになるが、`.venv` 自体は作られていれば OK)
- [ ] ホスト側 `.venv/` の中身は空 (上のコマンドで `0`)
- [ ] `down`/`up` 後も `.venv/bin/python` が残る (venv-cache の永続)

---

## §8 ポータビリティ

### 8.1 別ディレクトリへの移植

**目的**: フォルダコピー + setup.sh で他リポでも動くこと。

**手順**:
```bash
# 1. 適当な空の Node.js プロジェクトを用意 (なければ作る)
mkdir -p /tmp/portability-test
cd /tmp/portability-test
git init
echo '{"name":"test"}' > package.json

# 2. .claude-sandbox をコピー
cp -r /home/devman/RubymineProjects/operation-support-tools/.claude-sandbox .

# 3. 生成物を消してクリーン状態に
rm -f .claude-sandbox/sandbox.config .claude-sandbox/.runtime.env \
       .claude-sandbox/docker-compose.override.yml
rm -rf .claude-sandbox/proxy/certs/* \
       .claude-sandbox/volumes/proxy-data/* \
       .claude-sandbox/auth/claude-config/*

# 4. setup
cd .claude-sandbox
./setup.sh
```

**期待結果**:
- [ ] LANG_PACK が `node` で自動検出される
- [ ] setup が完走、doctor が緑
- [ ] `./run.sh` で claude が動く
- [ ] `./test/run.sh` の自動テストが pass

### 8.2 後片付け
```bash
cd /tmp/portability-test/.claude-sandbox && docker compose --env-file sandbox.config down
rm -rf /tmp/portability-test
```

---

## §9 リソース解放確認

### 9.1 down で全停止

**手順**:
```bash
cd /home/devman/RubymineProjects/operation-support-tools/.claude-sandbox
docker compose --env-file sandbox.config down
```

**期待結果**:
- [ ] `operation-support-tools-agent` `operation-support-tools-egress-proxy` の両コンテナが消える
- [ ] `docker network ls` でも `operation-support-tools_sandbox-internal` 等が消える

### 9.2 image のクリーンアップ (任意)
```bash
docker image rm operation-support-tools-agent:latest
docker image rm mitmproxy/mitmproxy:latest
```

---

## チェック結果サマリ

完了したらここに日付と結果を残しておくと便利:

```
日付: 2026-__-__
mode A: §1, §2, §3, §6, §7, §9 → pass
mode B: §4 → pass
mode C: §5 → (skip / pass)
ポータビリティ: §8 → pass
備考: __________________________________
```
