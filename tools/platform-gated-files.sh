#!/usr/bin/env bash
# ⭐⭐⭐⭐⭐ **平台专属文件的改动检查**（2026-10-26 真机回归的根治门禁）
#
# ────────────────────────────────────────────────────────────
# 背景（今天连栽四次「Linux 全绿、macOS CI 编译失败」）
# ────────────────────────────────────────────────────────────
#   `Sources/LegadoCore/JS/JSCExecutor.swift` 被 `#if canImport(JavaScriptCore)` 包着
#   ⇒ **Linux 上根本不编译** ⇒ 我对它的改动**本地一次都没验过** ⭐⭐⭐
#   ⇒ 连着四次：Linux 绿、macOS CI 红 ⇒ 每次都要等一轮 CI 才发现
#
# ⭐⭐⭐⭐⭐ **本门禁做什么**
#   ① 列出所有被 `#if canImport(...)` / `#if os(...)` 包住的文件（**平台专属文件**）
#   ② 若**最近一次提交**动了这些文件 ⇒ **必须等 macOS CI 绿**才能出包
#   ③ 提供 `--changed <sha>` 参数 ⇒ 校验某个 commit 是否碰了平台专属文件
#
# 用法：
#   bash tools/platform-gated-files.sh --list          # 只列出平台专属文件
#   bash tools/platform-gated-files.sh --check <sha>  # 那个 commit 碰了平台专属文件吗
#   bash tools/platform-gated-files.sh --check HEAD
set -uo pipefail
cd "$(dirname "$0")/.."

# ⭐⭐⭐ **平台专属文件清单**（人工维护 ⇒ 新增平台专属文件时记得加进来）
PLATFORM_GATED=(
  "Sources/LegadoCore/JS/JSCExecutor.swift"
  "Sources/LegadoCore/JS/NodeJSExecutor.swift"
  "Sources/LegadoCore/JS/JavaScriptCoreStub.swift"
  "Sources/LegadoCore/JS/JSHostAPI.swift"
  "Sources/LegadoCore/JS/JavaCompat.swift"
  "Sources/LegadoCore/Host/HostServices.swift"
  "QiReaderLite/Core/RuleSandbox.swift"
  "QiReaderLite/Core/SourceLoginSheet.swift"
)

list() {
  echo "平台专属文件（改动它们 ⇒ 必须等 macOS CI 绿）："
  for f in "${PLATFORM_GATED[@]}"; do
    [ -f "$f" ] && echo "  · $f"
  done
}

check() {
  local sha="${1:-HEAD}"
  local touched=()
  for f in "${PLATFORM_GATED[@]}"; do
    [ -f "$f" ] || continue
    if git diff --name-only "${sha}^" "$sha" 2>/dev/null | grep -qx "$f"; then
      touched+=("$f")
    fi
  done
  if [ ${#touched[@]} -eq 0 ]; then
    echo "✅ $sha 没碰平台专属文件 ⇒ Linux 绿就够"
    return 0
  fi
  echo "⚠️⚠️ $sha 碰了平台专属文件："
  for f in "${touched[@]}"; do echo "  · $f"; done
  echo "⇒ ⇒ **必须等 macOS CI（JSC job + iOS 编译 job）全绿再出包**"
  echo "⇒ ⇒ 否则会重演今天连栽四次的「Linux 全绿、macOS CI 编译失败」"
  return 1
}

case "${1:---list}" in
  --list) list ;;
  --check) check "${2:-HEAD}" ;;
  *) echo "用法：$0 --list | --check <sha>"; exit 2 ;;
esac
