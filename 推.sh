#!/bin/sh
# legado-engine —— 一键推到 GitHub（iSH / macOS / Linux 都能跑）
#
# ⚠️ **前置：GitHub 上要先建好空仓库**（沙盒里的 fine-grained PAT 没有「建仓库」权限）
#    网页建：https://github.com/new  →  仓库名填 `legado-engine`，勾 Public
#
# 用法（iSH）：
#   cd ~ && curl -sL -o legado-engine.zip '<OSS 直链>'
#   cd ~ && rm -rf legado-engine && mkdir -p legado-engine && cd legado-engine
#   unzip -qo "$HOME/legado-engine.zip" && sh 推.sh
#
set -e
cd "$(dirname "$0")"

REPO="${REPO:-legado-engine}"
REMOTE_URL="${REMOTE_URL:-ssh://git@ssh.github.com:443/806927125/$REPO.git}"
MSG="${MSG:-自研 Legado 兼容规则引擎：Phase 0 语义规格 + Phase 1 规则前端（AST）}"

echo "============================================"
echo "  legado-engine —— 推送到 GitHub"
echo "  远端: $REMOTE_URL"
echo "============================================"
echo

if [ ! -d .git ]; then
  echo "[1/4] 初始化本地仓库…"
  git init -q
  git branch -M main
else
  echo "[1/4] 已有本地仓库，跳过初始化"
fi

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_URL"

echo "[2/4] 接远端历史…"
if git fetch -q --depth=50 origin main 2>/dev/null; then
  # 把 HEAD 对准远端 main，但**保留工作区文件**（不用 reset --hard，会删未提交文件）
  git reset --soft origin/main
  echo "      已对齐 origin/main（历史保留）"
else
  echo "      ⚠️ 取不到远端 main ⇒ 按【空仓库】处理（首次推送）"
fi

echo "[3/4] 提交改动…"
git add -A
if git diff --cached --quiet; then
  echo "      没有新改动，跳过提交"
else
  git -c user.email="mavis@local" -c user.name="mavis" commit -q -m "$MSG"
  echo "      已提交"
fi

echo "[4/4] 推送到远端…"
set +e
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30" \
  git push -u origin HEAD:main 2>&1 | tail -6
RC=$?
set -e

echo
echo "============================================"
if [ $RC -eq 0 ]; then
  echo "  ✅ 推送完成"
  echo
  echo "  仓库地址：https://github.com/806927125/$REPO"
  echo
  echo "  下一步（沙盒里跑门禁）："
  echo "    1) 装 Swift 工具链（877MB，见 README「环境」段）"
  echo "    2) npm install --registry=https://registry.npmmirror.com"
  echo "    3) swift test && bash tools/conformance-diff.sh"
else
  echo "  ❌ 推送失败，看上面的报错"
  echo "     常见原因："
  echo "       · GitHub 上还没建这个仓库 ⇒ 先去 https://github.com/new 建一个空的"
  echo "       · iSH 没配 SSH 密钥 ⇒ 先在 iSH 里跑一次 ssh -T git@github.com"
  echo "       · 端口 443 被挡 ⇒ 把远端换成 ssh://git@github.com:22/806927125/$REPO.git"
fi
echo "============================================"
exit 0
