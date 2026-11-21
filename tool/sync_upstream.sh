#!/usr/bin/env bash
# 把上游 MewHub 的更新叠加到本仓库。
#
# 为什么不用 git merge / rebase：
#   本仓库的根提交 23ce14a 是「MewHub 快照 + 缠论引擎 + 改好的包名/应用名」一次性导入，
#   与上游 mizaawa/mewhub 没有共同祖先：
#     - merge：没有 base，两边同名文件全判成 add/add 冲突
#     - rebase：第一个改 lib/stock 的提交就报 modify/delete（新 base 上没有这些文件）
#   所以走覆盖式同步：**上游当底座，我们整棵树盖上去**。
#
# 规则（故意保守，宁可漏更新的功能，也不要静默把我们的包名/通道名/引擎改回上游的）：
#   1. 上游有、我们没有的路径 → 保留上游的（那是上游新加的能力）
#   2. 其余一律用我们 main 的版本
#   3. 在上游也改过的文件会列进「需要人工核对」，想跟进就手动并
#
# 用法：
#   tool/sync_upstream.sh
#   BRANCH=my/sync tool/sync_upstream.sh
#   UPSTREAM_URL=... BASE=... tool/sync_upstream.sh
#
# 脚本不碰 main，也不 push。
set -euo pipefail

cd "$(dirname "$0")/.."

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/mizaawa/mewhub.git}"
BRANCH="${BRANCH:-sync/upstream}"
BASE="${BASE:-23ce14a}"

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"

echo "== 拉取上游 =="
git fetch --quiet upstream
UPSTREAM_HEAD=$(git rev-parse --short upstream/main)
echo "   upstream/main = $UPSTREAM_HEAD"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "!! 工作区不干净，先提交或 stash" >&2
  git status --short >&2
  exit 1
fi

echo "== 建分支 $BRANCH（基于 upstream/main）=="
git switch -C "$BRANCH" upstream/main >/dev/null

echo "== 用我们的树覆盖（上游独有的新文件保持不动）=="
git checkout main -- .

# Android 的 Kotlin 包目录只能有一份：上游那份（mizaawa/mewhub）留着会和我们的
# 应用入口打双份，删掉；只保留 main 里有的文件。
KOTLIN_DIR="android/app/src/main/kotlin"
if git cat-file -e "main:$KOTLIN_DIR" 2>/dev/null; then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    git cat-file -e "main:$p" 2>/dev/null || rm -f "$p"
  done <<< "$(git ls-tree -r --name-only upstream/main -- "$KOTLIN_DIR")"
fi

UPSTREAM_CHANGED=$(git diff --name-only "$BASE" upstream/main)
OURS_CHANGED=$(git diff --name-only "$BASE" main)

echo
echo "== 需要人工核对：上游也改过、而这里是我们的版本 =="
REVIEW=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  # 上游根本没有这个路径（base 导入时多出来的），不是「上游改了」，跳过
  git cat-file -e "upstream/main:$p" 2>/dev/null || continue
  # 上游改过、我们没动过 → 说明我们这份是旧快照，上游可能修了 bug / 加了能力
  if ! grep -qxF "$p" <<< "$OURS_CHANGED"; then
    echo "   ! $p   （上游改了，我们没动 → 优先考虑跟进）"
    REVIEW=$((REVIEW + 1))
  else
    echo "   ~ $p   （两边都改过，已用我们的）"
    REVIEW=$((REVIEW + 1))
  fi
done <<< "$UPSTREAM_CHANGED"
[[ "$REVIEW" -eq 0 ]] && echo "   （无）上游自 $BASE 起没有改动"

echo
echo "== 上游新增的文件（已经进树）=="
shown=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if ! git cat-file -e "main:$p" 2>/dev/null; then
    echo "   + $p"
    shown=$((shown + 1))
    [[ "$shown" -ge 40 ]] && break
  fi
done <<< "$(git ls-tree -r --name-only upstream/main)"
[[ "$shown" -eq 0 ]] && echo "   （无）"

if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -q -m "sync: 叠加 MewHub 上游 $UPSTREAM_HEAD"
  echo
  echo "== 已提交到 $BRANCH =="
else
  echo
  echo "== 没有变化（上游与本仓库一致）=="
fi

cat <<EOF

下一步（脚本不会替你做）：
  1. 看上面带 ! 的文件：git diff 23ce14a..upstream/main -- <文件>，想跟进就手动并进来
  2. flutter pub get && flutter analyze --fatal-infos && flutter test
     （本机 arm64 没 Flutter SDK 就推分支让 CI 跑：git push origin $BRANCH）
  3. 绿了再合回 main：
       git switch main && git merge --squash $BRANCH && git commit
       git tag vX.Y.Z && git push origin vX.Y.Z
EOF