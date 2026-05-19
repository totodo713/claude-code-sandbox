# claude-code-sandbox

運用・サポート業務向けスクリプトを JavaScript / Python / Ruby の 3 言語で管理するマルチランタイム ワークスペース。各言語のスクリプトは、ネットワーク制限付きの Claude Code サンドボックス (`.claude-sandbox/`) 内で実行することを前提としています。

## 現在の中身

| ディレクトリ | 言語 | 内容 |
|---|---|---|
| `jsscript/client_test.js` | JavaScript (Node) | `axios` で `https://httpbin.org/get` を叩く疎通テスト |
| `pyscript/client_test.py` | Python | `httpx` で `https://httpbin.org/get` を叩く疎通テスト |
| `rbscript/client_test.rb` | Ruby | `net/http` で `https://httpbin.org/get` を叩く疎通テスト |

宛先の `httpbin.org` は **既定 allowlist には入っていない** ため、サンドボックス内でそのまま実行するとプロキシが 502 で遮断します。これを **自動テスト (ブロックが効いていることの確認)** として扱い、「通過する側」を確認したい場合は手動で allowlist を一時的に広げる手順を用意しています ([テスト実行](#テスト実行) を参照)。

## ランタイムと依存関係管理

| 言語 | バージョン | パッケージマネージャ | マニフェスト |
|---|---|---|---|
| Node.js | `package.json` の `packageManager` (pnpm 10.33.4) | **pnpm** | `package.json` / `pnpm-lock.yaml` |
| Python | `.python-version` (3.13) | **uv** | `pyproject.toml` / `uv.lock` |
| Ruby | `.ruby-version` (3.4.9) | **bundler** | `Gemfile` / `Gemfile.lock` |

ロックファイルが正となる単一の事実源です。ホスト側でのインストールはサンドボックス内に伝播しません。

## セットアップ

すべての `install` / `run` はサンドボックスコンテナ内で実行してください。ホスト上で実行すると、`npm`/`uv` のポストインストールフックが `.claude-sandbox/` のネットワーク許可リストと FS 分離をバイパスしてしまいます。

### 初回セットアップ

```bash
./.claude-sandbox/setup.sh   # sandbox.config 生成 (対話)
```

### 依存パッケージのインストール

```bash
./.claude-sandbox/shell.sh   # エージェントコンテナに入る
# --- 以降コンテナ内 ---
pnpm install                 # Node 依存
uv sync                      # Python 依存
bundle install               # Ruby 依存 (gem 追加後のみ必要)
```

### Claude Code を起動

```bash
./.claude-sandbox/run.sh
```

## テスト実行

### 自動テスト: ブロック確認 (既定状態のまま)

スクリプトの宛先 `httpbin.org` は allowlist 未登録なので、何も設定変更せずに実行すると 502 で遮断されます。**「502 が返ってくる = ブロックが効いている」** という確認です。

```bash
./.claude-sandbox/shell.sh   # コンテナ内へ
node jsscript/client_test.js
uv run pyscript/client_test.py
ruby rbscript/client_test.rb
```

期待出力 (Ruby の例):

```
〇 インターネット上のAPIに接続中...
❌ 通信エラーが発生しました: 502 "Bad Gateway"
```

ここで ✅ が出る場合は、過去に追加した allowlist 行が戻されていない可能性が高いです。下の「戻す」手順を実行してから再確認してください。

### 手動テスト: 通過確認 (allowlist を一時的に開ける)

「サンドボックス経由でも外部 API に **到達できる**」ことを確認するパターン。手動で実行する想定です。

**1. ホスト側** で `httpbin.org` を allowlist に追加してプロキシを再起動:

```bash
echo "httpbin.org" >> .claude-sandbox/allowlist/allowlist.d/extra.txt
docker compose --env-file .claude-sandbox/sandbox.config restart egress-proxy
```

**2. コンテナ内** でスクリプトを実行 (今度は ✅ で抜ける):

```bash
./.claude-sandbox/shell.sh
node jsscript/client_test.js
uv run pyscript/client_test.py
ruby rbscript/client_test.rb
```

**3. 戻す** (ホスト側): `extra.txt` から追加行を削除してプロキシを再起動:

```bash
sed -i '/^httpbin\.org$/d' .claude-sandbox/allowlist/allowlist.d/extra.txt
docker compose --env-file .claude-sandbox/sandbox.config restart egress-proxy
```

戻った確認は、もう一度「自動テスト: ブロック確認」を実行して 502 が返ることで行います。

## 外向きドメインを追加する

スクリプトが新しいホストに通信する必要が出たら、`.claude-sandbox/allowlist/allowlist.d/extra.txt` に 1 行 1 ドメインで追記し (サフィックス一致は `*.example.com`)、プロキシを再起動します。

```bash
docker compose --env-file .claude-sandbox/sandbox.config restart egress-proxy
```

ブロックされたホストは `./.claude-sandbox/logs.sh` の `block_*` JSON エントリに記録されます。

## サンドボックス運用コマンド

```bash
./.claude-sandbox/setup.sh --reconfigure  # 設定を再適用
./.claude-sandbox/doctor.sh               # 環境ヘルスチェック (12 項目)
./.claude-sandbox/logs.sh                 # egress-proxy のログ
./.claude-sandbox/clean.sh                # 生成物と認証情報を削除 (volume は保持)
```

サンドボックスの内部構成・認証モード (A/B/C)・トラブルシューティング (証明書エラー、502、WSL2 のクロック ドリフト)、言語パックの追加方法は [`.claude-sandbox/README.md`](.claude-sandbox/README.md) を参照してください。

## ディレクトリ構成

```
.
├── .claude-sandbox/   # サンドボックス基盤 (Docker, mitmproxy, allowlist)
├── jsscript/          # Node スクリプト
├── pyscript/          # Python スクリプト
├── rbscript/          # Ruby スクリプト
├── package.json       # Node マニフェスト
├── pyproject.toml     # Python マニフェスト
├── Gemfile            # Ruby マニフェスト
└── CLAUDE.md          # Claude Code 向けのリポジトリ運用ガイド
```
