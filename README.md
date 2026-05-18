# claude-code-sandbox

運用・サポート業務向けスクリプトを JavaScript / Python / Ruby の 3 言語で管理するマルチランタイム ワークスペース。各言語のスクリプトは、ネットワーク制限付きの Claude Code サンドボックス (`.claude-sandbox/`) 内で実行することを前提としています。

## 現在の中身

| ディレクトリ | 言語 | 内容 |
|---|---|---|
| `jsscript/client_test.js` | JavaScript (Node) | `axios` で `https://httpbin.org/get` を叩く疎通テスト |
| `pyscript/client_test.py` | Python | `httpx` で `https://httpbin.org/get` を叩く疎通テスト |
| `rbscript/client_test.rb` | Ruby | `net/http` で `https://httpbin.org/get` を叩く疎通テスト |

いずれも「サンドボックス経由でも外部 API に到達できるか」を確認するためのスモークテストです。

## ランタイムと依存関係管理

| 言語 | バージョン | パッケージマネージャ | マニフェスト |
|---|---|---|---|
| Node.js | `package.json` の `packageManager` (pnpm 10.33.4) | **pnpm** | `package.json` / `pnpm-lock.yaml` |
| Python | `.python-version` (3.13) | **uv** | `pyproject.toml` / `uv.lock` |
| Ruby | `.ruby-version` (3.4.9) | **bundler** | `Gemfile` / `Gemfile.lock` |

ロックファイルが正となる単一の事実源です。ホスト側でのインストールはサンドボックス内に伝播しません。

## セットアップと実行

すべての `install` / `run` はサンドボックスコンテナ内で実行してください。ホスト上で実行すると、`npm`/`uv` のポストインストールフックが `.claude-sandbox/` のネットワーク許可リストと FS 分離をバイパスしてしまいます。

### 初回セットアップ

```bash
./.claude-sandbox/setup.sh   # sandbox.config 生成 (対話)
```

### スクリプト実行

```bash
./.claude-sandbox/shell.sh   # エージェントコンテナに入る
# --- 以降コンテナ内 ---
pnpm install                 # Node 依存
uv sync                      # Python 依存
bundle install               # Ruby 依存 (gem 追加後のみ必要)

node jsscript/client_test.js
uv run pyscript/client_test.py
ruby rbscript/client_test.rb
```

### Claude Code を起動

```bash
./.claude-sandbox/run.sh
```

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
