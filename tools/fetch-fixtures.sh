#!/usr/bin/env bash
# ⭐ 重新抓 e2e fixture（站方改版时跑）
#
# ⚠️ **抓下来的字节数变了 ⇒ 说明站方改版了** ⇒ 要人工确认选择器还能不能命中。
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/conformance/fixtures/e2e"
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
BASE="https://www.52dzxy.com"

mkdir -p "$DIR"
curl -sS --max-time 25 -A "$UA" "$BASE/bkzs/all.html" \
  -o "$DIR/list.html"    -w "list.html    %{http_code} %{size_download} bytes\n"
curl -sS --max-time 25 -A "$UA" "$BASE/2026/bkzs/202614/index.html" \
  -o "$DIR/detail.html"  -w "detail.html  %{http_code} %{size_download} bytes\n"
curl -sS --max-time 25 -A "$UA" "$BASE/2026/bkzs/202614/articles/yizhiguanhuanweiyifashouzhuqingkong.html" \
  -o "$DIR/chapter.html" -w "chapter.html %{http_code} %{size_download} bytes\n"

echo
echo "基线（2026-10-23）：list=15175  detail=10234  chapter=15415"
echo "⇒ 字节数变了 ⇒ 站方改版 ⇒ 跑一次门禁看选择器还能不能命中："
echo "  swift test --filter EndToEndSourceTests"
