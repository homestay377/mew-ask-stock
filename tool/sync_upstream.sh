#!/usr/bin/env bash
# 把上游 MewHub 的更新叠加到本仓库。
#
# 为什么不用 git merge / rebase：
#   本仓库的根提交 23ce14a 是「MewHub 快照 + 缠论引擎 + 改好的包名」一次性导入，
#   与上游 mizaawa/mewhub 没有共同祖先：
#     - merge：没有 base，两边同名文件全判成 add/add 冲突
#     - rebase：第一个改 lib/stock 的提交就报 modify/delete（新 base 上没有这些文件）
#   所以走覆盖式同步：**上游当底座，我们那一层整片盖上去**。
#
# 三类文件，三种处理：
#   1. 品牌/构建（包名、Manifest、图标配置、pubspec、README）→ 永远用我们的
#   2. 上游没有、我们有的路径（lib/stock 等）→ 用我们的
#   3. 两边都有、我们改过（git diff $BASE main）→ 用我们的，并在上游也改过时提示人工核对
#   其余一律保留上游最新版本。
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

# ① 品牌与构建：上游也有同路径，但内容必须是我们这份（包名/签名/应用名都在里面）
BRAND=(
  android/app/build.gradle.kts
  android/app/src/main/AndroidManifest.xml
  android/app/src/main/res/values/strings.xml
  ios/Runner/Info.plist
  pubspec.yaml
  README.md
)

# ② 整片目录：里面只能有我们那份（上游同名的旧包目录要删掉，否则编译出两份入口）
OWN_DIRS=(
  android/app/src/main/kotlin
)

# 仅用于提示
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

OUR_FILES=$(git diff --name-only "$BASE" main)
UPSTREAM_CHANGED=$(git diff --name-only "$BASE" upstream/main)

# ① 品牌文件
if [[ ${#BRAND[@]} -gt 0 ]]; then
  echo "== 品牌/构建文件取我们的：${#BRAND[@]} 个 =="
  for p in "${BRAND[@]}"; do
    git checkout main -- "$p"
    echo "   * $p"
  done
fi

# ② 整片目录：先删后取
for d in "${OWN_DIRS[@]}"; do
  if git cat-file -e "main:$d" 2>/dev/null || [[ -d "$d" ]]; then
    rm -rf "$d"
    git checkout main -- "$d"
    echo "== 目录整体取我们的：$d =="
  fi
done

# ② 上游没有、我们有的路径：自动算，不手写名单
TAKE=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  skip=0
  for d in "${OWN_DIRS[@]}"; do case "$p" in "$d"/*) skip=1; break ;; esac; done
  for b in "${BRAND[@]}"; do [[ "$p" == "$b" ]] && skip=1; done
  [[ "$skip" -eq 1 ]] && continue
  git cat-file -e "upstream/main:$p" 2>/dev/null || TAKE+=("$p")
done <<< "$(git ls-tree -r --name-only main)"
if [[ ${#TAKE[@]} -gt 0 ]]; then
  echo "== 上游没有的路径取我们的：${#TAKE[@]} 个 =="
  git checkout main -- "${TAKE[@]}"
fi

# ③ 两边都有、我们改过的
SHARED=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  git cat-file -e "upstream/main:$p" 2>/dev/null || continue
  skip=0
  for d in "${OWN_DIRS[@]}"; do case "$p" in "$d"/*) skip=1; break ;; esac; done
  for b in "${BRAND[@]}"; do [[ "$p" == "$b" ]] && skip=1; done
  [[ "$skip" -eq 1 ]] && continue
  SHARED+=("$p")
done <<< "$OUR_FILES"
if [[ ${#SHARED[@]} -gt 0 ]]; then
  echo "== 两边都有且我们改过的取我们的：${#SHARED[@]} 个 =="
  git checkout main -- "${SHARED[@]}"
fi

echo
echo "== 需要人工核对：上游自 $BASE 起也改过我们这份 =="
REVIEW=0
for p in "${SHARED[@]}" "${BRAND[@]}"; do
  if grep -qxF "$p" <<< "$UPSTREAM_CHANGED"; then
    echo "   ! $p"
    REVIEW=$((REVIEW + 1))
  fi
done
for d in "${OWN_DIRS[@]}"; do
  if grep -q "^$d/" <<< "$UPSTREAM_CHANGED"; then
    echo "   ! $d/（上游在这个目录里也有改动，已整体用我们的，确认没漏功能）"
    REVIEW=$((REVIEW + 1))
  fi
done
[[ "$REVIEW" -eq 0 ]] && echo "   （无）上游没动这些文件"

echo
echo "== 上游的其他改动（已经进树了，看一眼有没有新能力要接）=="
shown=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  skip=0
  for own in "${OWN_HINT[@]}"; do case "$p" in "$own"|"$own"/*) skip=1; break ;; esac; done
  for b in "${BRAND[@]}" "${SHARED[@]}"; do [[ "$p" == "$b" ]] && skip=1; done
  for d in "${OWN_DIRS[@]}"; do case "$p" in "$d"/*) skip=1; break ;; esac; done
  if [[ "$skip" -eq 0 ]]; then
    echo "   $p"
    shown=$((shown + 1))
    [[ "$shown" -ge 40 ]] && break
  fi
done <<< "$UPSTREAM_CHANGED"
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
  1. 逐个核对上面带 ! 的文件（git diff main -- <文件>），把上游的新改动并进来
  2. flutter pub get && flutter analyze --fatal-infos && flutter test
     （本机 arm64 没 Flutter SDK 就推分支让 CI 跑：git push origin $BRANCH）
  3. 绿了再合回 main：
       git switch main && git merge --squash $BRANCH && git commit
       git tag vX.Y.Z && git push origin vX.Y.Z
EOF