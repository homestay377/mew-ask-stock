#!/usr/bin/env bash
# 把上游 MewHub 的更新叠加到本仓库。
#
# 为什么不用 git merge / rebase：
#   本仓库的根提交 23ce14a 是「MewHub 快照 + 缠论引擎」的一次性导入，
#   与上游 mizaawa/mewhub 没有共同祖先。直接 merge 会因为「没有 base」
#   把两边同名的文件全判成 add/add 冲突；rebase 则在改 lib/stock 的提交上
#   报 modify/delete。所以这里用覆盖式同步：**上游当底座，我们那一层整片盖上去**。
#
# 哪些文件算「我们的」：不手写名单，而是看 `git diff $BASE main` ——
#   上游也有该路径 → 取我们的版本，并在上游也改过时提示人工核对
#   上游没有该路径 → 纯新增，直接取我们的
# 这样以后再加文件也不用改脚本。
#
# 用法：
#   tool/sync_upstream.sh                     # 同步到本地分支 sync/upstream
#   BRANCH=my/sync tool/sync_upstream.sh
#   UPSTREAM_URL=... BASE=... tool/sync_upstream.sh
#
# 脚本不会碰 main，也不会 push。审查 + analyze/test 通过后再自己合回去。
set -euo pipefail

cd "$(dirname "$0")/.."

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/mizaawa/mewhub.git}"
BRANCH="${BRANCH:-sync/upstream}"
# 我们的初始导入提交：用来算「我们改过哪些文件」
BASE="${BASE:-23ce14a}"

# 只在提示里出现，不影响逻辑：这些目录整片属于我们
OWN_HINT=(lib/stock lib/ui/stock assets/stock test/fixtures/chan)

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

# 我们改过/新增的路径（以 main 为准）
OUR_FILES=$(git diff --name-only "$BASE" main)
UPSTREAM_CHANGED=$(git diff --name-only "$BASE" upstream/main)

TAKE=()        # 取我们的版本（上游没有该路径）
SHARED=()      # 取我们的版本（上游也有），但要注意上游的改动
MISSING=0

while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if git cat-file -e "upstream/main:$p" 2>/dev/null; then
    SHARED+=("$p")
  else
    TAKE+=("$p")
  fi
done <<< "$OUR_FILES"

if [[ ${#TAKE[@]} -gt 0 ]]; then
  echo "== 取我们的独占文件（上游没有）：${#TAKE[@]} 个 =="
  git checkout main -- "${TAKE[@]}"
fi

if [[ ${#SHARED[@]} -gt 0 ]]; then
  echo "== 取我们的版本（上游也有同路径）：${#SHARED[@]} 个 =="
  git checkout main -- "${SHARED[@]}"
fi

echo
echo "== 需要人工核对：上游自 $BASE 起也改过 =="
REVIEW=()
for p in "${SHARED[@]}"; do
  if grep -qxF "$p" <<<"$UPSTREAM_CHANGED"; then
    echo "   ! $p"
    REVIEW+=("$p")
  fi
done
if [[ ${#REVIEW[@]} -eq 0 ]]; then
  echo "   （无）上游没动这些文件"
fi

echo
echo "== 上游的其他改动（已经进树了，看一眼有没有新能力要接）=="
shown=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  skip=0
  for own in "${OWN_HINT[@]}"; do
    case "$p" in "$own"|"$own"/*) skip=1; break ;; esac
  done
  for sh in "${SHARED[@]}"; do [[ "$p" == "$sh" ]] && skip=1; done
  if [[ "$skip" -eq 0 ]]; then
    echo "   $p"
    shown=$((shown + 1))
    [[ "$shown" -ge 40 ]] && break
  fi
done <<< "$UPSTREAM_CHANGED"
[[ "$shown" -eq 0 ]] && echo "   （无）"

# 上游自带的 Kotlin 包目录 vs 我们自己的：两份同时存在时容易搞错入口
if [[ -d android/app/src/main/kotlin/io/github ]] \
   && ls android/app/src/main/kotlin/io/github/*/* >/dev/null 2>&1; then
  pkg_count=$(find android/app/src/main/kotlin/io/github -mindepth 2 -maxdepth 2 -type d | wc -l)
  if [[ "$pkg_count" -gt 1 ]]; then
    echo
    echo "   ! android/app/src/main/kotlin/io/github 下有多个包目录："
    find android/app/src/main/kotlin/io/github -mindepth 2 -maxdepth 2 -type d | sed 's/^/       /'
    echo "     确认 AndroidManifest 指向的是哪一个，删掉不用的那份"
  fi
fi

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
  1. 逐个核对上面带 ! 的文件（git diff main -- <文件>），把上游的新改动并进来
  2. flutter pub get && flutter analyze --fatal-infos && flutter test
     （本机 arm64 没有 Flutter SDK 时，推分支让 CI 跑：git push origin $BRANCH）
  3. 绿了再合回 main：
       git switch main && git merge --squash $BRANCH && git commit
       git tag vX.Y.Z && git push origin vX.Y.Z
EOF