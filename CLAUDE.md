# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 共通ルール

プロジェクト横断のルール (応答言語ポリシー等) は `.claude/CLAUDE.md` に置く。
以下の import で読み込む:

@.claude/CLAUDE.md

## What this repo is

`claude-code-sandbox` — a multi-language workspace (JavaScript / Python / Ruby) for operational/support scripts. Today it only holds smoke-test clients that hit `https://httpbin.org/get` (`jsscript/client_test.js`, `pyscript/client_test.py`, `rbscript/client_test.rb`). `httpbin.org` is intentionally **not** on the allowlist: running the scripts as-is is the automatic block-confirmation test (expect 502). Confirming the pass-through path is a manual procedure that temporarily adds `httpbin.org` to `allowlist.d/extra.txt` and reverts it — see `README.md` "テスト実行". The bulk of the repo is the `.claude-sandbox/` infrastructure that runs Claude Code under network egress restrictions.

## Critical: run installs and scripts inside the sandbox container

When acting via Claude, do **not** run `npm`/`pnpm`/`uv`/`bundle` or execute project scripts on the host. `npm install` post-install scripts and `uv sync` build hooks execute arbitrary code; on the host they would bypass the network allowlist and FS isolation that are the whole point of `.claude-sandbox/`. Enter the container first:

```bash
./.claude-sandbox/shell.sh
# then, inside the container:
pnpm install            # node deps  (PKG_TOOL_NODE=pnpm)
uv sync                 # python deps (PKG_TOOL_PYTHON=uv)
bundle install          # ruby deps  (only after gems are added)

node jsscript/client_test.js
uv run pyscript/client_test.py
ruby rbscript/client_test.rb
```

The host's `node_modules/` and `.venv/` are separate from the container's (named volumes shadow the bind mount inside the container), so host-side installs do not propagate to the sandbox. Lockfiles (`pnpm-lock.yaml`, `uv.lock`, `Gemfile.lock`) are the shared source of truth.

If a script needs a new outbound domain, add it to `.claude-sandbox/allowlist/allowlist.d/extra.txt` (one domain per line, `*.example.com` for suffix match) and restart the proxy:

```bash
docker compose --env-file .claude-sandbox/sandbox.config restart egress-proxy
```

`./.claude-sandbox/logs.sh` surfaces `block_*` JSON entries that name the blocked host.

## Sandbox lifecycle commands

```bash
./.claude-sandbox/setup.sh              # initial interactive setup (generates sandbox.config etc.)
./.claude-sandbox/setup.sh --reconfigure # re-apply sandbox.config edits
./.claude-sandbox/run.sh                # launch claude inside the sandbox
./.claude-sandbox/shell.sh              # drop into a bash shell in the agent container
./.claude-sandbox/doctor.sh             # 12-point environment health check
./.claude-sandbox/logs.sh               # tail egress-proxy logs (allow/block decisions)
./.claude-sandbox/clean.sh              # wipe generated config + auth, keep named volumes
```

Full sandbox documentation, including auth modes (A/B/C), volume layout, troubleshooting (cert errors, 502s, WSL2 clock drift), and how to add a new language pack, is in `.claude-sandbox/README.md`. Read it before changing anything under `.claude-sandbox/`.

## Sandbox architecture in one paragraph

`docker-compose.yml` defines two services on an `internal: true` network: the `agent` container (where `claude` and all child processes run, with no direct internet route) and an `egress-proxy` running mitmproxy with SSL Bump. All TLS from the agent is terminated at the proxy, matched against the allowlist files (`core.txt`, `lang-*.txt`, `allowlist.d/extra.txt`), and either forwarded or 502'd based on `BLOCK_ON_VIOLATION`. The agent's `/usr/local/bin/claude` is a self-contained binary independent of the project's Node/Python/Ruby/Bun, which live under `/opt/runtimes/<lang>` and are pinned by `NODE_VERSION` / `PYTHON_VERSION` / `RUBY_VERSION` / `BUN_VERSION` in `sandbox.config` (auto-detected from `.nvmrc` / `.python-version` / `.ruby-version` / `.bun-version` / lockfiles during `setup.sh`).
