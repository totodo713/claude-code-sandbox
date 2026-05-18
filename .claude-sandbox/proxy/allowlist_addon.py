"""mitmproxy addon: allowlist によるドメイン制限。

LANG_PACK と allowlist ディレクトリ配下のテキストファイルから
許可ドメインを読み込み、リクエストの host (HTTPS は SNI、HTTP は Host) を
突き合わせる。違反時は BLOCK_ON_VIOLATION=true なら 502 を返し、
false なら通過させつつ警告ログを出す。
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from mitmproxy import ctx, http

ALLOWLIST_DIR = Path(os.environ.get("ALLOWLIST_DIR", "/allowlist"))
LANG_PACK = os.environ.get("LANG_PACK", "")
BLOCK_ON_VIOLATION = os.environ.get("BLOCK_ON_VIOLATION", "true").lower() == "true"


def _load_file(path: Path) -> list[str]:
    if not path.exists():
        return []
    out: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line.lower())
    return out


def _load_allowlist() -> tuple[set[str], list[str]]:
    """exact set と suffix list (先頭 `*.` 除去後の `.suffix`) を返す。"""
    files = [ALLOWLIST_DIR / "core.txt"]
    for pack in (p.strip() for p in LANG_PACK.split(",") if p.strip()):
        files.append(ALLOWLIST_DIR / f"lang-{pack}.txt")
    extra_dir = ALLOWLIST_DIR / "allowlist.d"
    if extra_dir.is_dir():
        files.extend(sorted(extra_dir.glob("*.txt")))

    exact: set[str] = set()
    suffix: list[str] = []
    for f in files:
        for entry in _load_file(f):
            if entry.startswith("*."):
                suffix.append("." + entry[2:])
            else:
                exact.add(entry)
                # `example.com` は `*.example.com` も意図する慣行が多いので両対応
                suffix.append("." + entry)
    # サフィックスは長いものから (具体的なほうが先に当たるように)
    suffix.sort(key=len, reverse=True)
    return exact, suffix


class AllowlistAddon:
    def __init__(self) -> None:
        self.exact, self.suffix = _load_allowlist()
        self._log_meta(
            event="allowlist_loaded",
            exact=len(self.exact),
            suffix=len(self.suffix),
            block=BLOCK_ON_VIOLATION,
            lang_pack=LANG_PACK,
        )

    @staticmethod
    def _log_meta(**fields: object) -> None:
        fields.setdefault("ts", round(time.time(), 3))
        sys.stdout.write(json.dumps(fields, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    def _is_allowed(self, host: str) -> bool:
        host = host.lower().rstrip(".")
        if host in self.exact:
            return True
        for suf in self.suffix:
            if host.endswith(suf):
                return True
        return False

    # HTTPS CONNECT (TLS 終端前): SNI / target host で判定
    def http_connect(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host or ""
        if not self._is_allowed(host):
            self._log_meta(event="block_connect", host=host, port=flow.request.port)
            if BLOCK_ON_VIOLATION:
                flow.response = http.Response.make(
                    502,
                    b"Blocked by sandbox allowlist (CONNECT)\n",
                    {"Content-Type": "text/plain"},
                )
        else:
            self._log_meta(event="allow_connect", host=host, port=flow.request.port)

    # 通常リクエスト (HTTP + 復号後の HTTPS) : Host で判定
    def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host or ""
        if not self._is_allowed(host):
            self._log_meta(
                event="block_request",
                host=host,
                method=flow.request.method,
                path=flow.request.path,
            )
            if BLOCK_ON_VIOLATION:
                flow.response = http.Response.make(
                    502,
                    b"Blocked by sandbox allowlist\n",
                    {"Content-Type": "text/plain"},
                )
            return
        self._log_meta(
            event="allow_request",
            host=host,
            method=flow.request.method,
            path=flow.request.path,
        )


addons = [AllowlistAddon()]
