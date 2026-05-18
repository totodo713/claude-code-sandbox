# Claude Code Sandbox - 動作検証

このディレクトリは `.claude-sandbox/` パッケージが意図通り動くかを検証するためのテスト一式。

## ファイル

| ファイル | 内容 |
|---|---|
| `README.md` | このファイル (テスト計画の全体像) |
| `run.sh` | 自動テストランナ (Bash) |
| `manual.md` | 手動でしか実行できないチェックリスト |

## 推奨実行順序

### 1. 初回セットアップ (手動)
まずパッケージ自体を導入する。`manual.md` の **§1 セットアップ** に従って:
- mode A (推奨) で `./setup.sh` を完走させる
- 完走後、`./doctor.sh` がすべて緑になる

### 2. 自動テストの実行
```bash
./.claude-sandbox/test/run.sh
```
セキュリティ・機能・設定の自動テストを順に流す。各テストは独立しているので、途中で失敗しても残りを実行する。最後に集計結果を表示。

### 3. 手動テスト
`manual.md` の残り (§2 以降) を順次。auth mode B/C の検証、別リポへの移植、claude プロンプトでの実操作などはここ。

## テスト計画 (網羅マトリクス)

### A. セキュリティ (最重要)
| ID | 内容 | 自動 |
|---|---|---|
| A-1 | 非 allowlist ドメイン (example.com) は 502 ブロック | ✓ |
| A-2 | `1.1.1.1:443` への直接 TCP は到達不能 (internal:true) | ✓ |
| A-3 | TLS 信頼チェーン: api.anthropic.com に curl 成功 | ✓ |
| A-4 | HTTPS_PROXY を unset しても外部到達不能 | ✓ |
| A-5 | proxy ログに allow/block イベントが JSON で記録される | ✓ |

### B. 機能
| ID | 内容 | 自動 |
|---|---|---|
| B-1 | `claude --version` がコンテナ内で動く | ✓ |
| B-2 | `/workspace` にリポジトリがマウントされている | ✓ |
| B-3 | agent は非 root (uid=$AGENT_USER_UID) で動く | ✓ |
| B-4 | `PASSTHROUGH_ENV` の値が agent に渡る | ✓ |
| B-5 | `bundle --version` (LANG_PACK=ruby 時) | ✓ |
| B-6 | claude をインタラクティブ起動して ls プロンプトに応答 | manual |

### C. 設定変更
| ID | 内容 | 自動 |
|---|---|---|
| C-1 | `allowlist/allowlist.d/extra.txt` に追加 → restart で反映 | ✓ |
| C-2 | `setup.sh --reconfigure` で override.yml が再生成される | ✓ |
| C-3 | CA 削除 → `setup.sh --ca-only` で復旧 | manual (時間長) |
| C-4 | `BLOCK_ON_VIOLATION=false` で警告ログのみ通過 | ✓ |

### D. 認証モード
| ID | 内容 | 自動 |
|---|---|---|
| D-1 | Mode A: `/home/agent/.claude` が ro でマウントされる | ✓ |
| D-2 | Mode B: `claude login` 後セッションが永続化される | manual |
| D-3 | Mode C: `ANTHROPIC_API_KEY` 経由で動作 | manual |

### E. エラーハンドリング
| ID | 内容 | 自動 |
|---|---|---|
| E-1 | `sandbox.config` が無い状態で `run.sh` → 親切なエラー | ✓ |
| E-2 | CA が無い状態で `run.sh` → 親切なエラー | ✓ |
| E-3 | 未知の `--option` で `setup.sh` → エラー | ✓ |

### F. ポータビリティ
| ID | 内容 | 自動 |
|---|---|---|
| F-1 | 別ディレクトリに `cp -r` → setup → 動作 | manual |

## 合格基準

- **必須**: A-* がすべて pass、B-1〜B-4 が pass
- **強推奨**: C-*、D-1、E-* が pass
- **オプション**: D-2/D-3、F-1、B-5/B-6
