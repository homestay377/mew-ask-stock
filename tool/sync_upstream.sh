#!/usr/bin/env bash
# 把上游 MewHub 的更新叠加到本仓库。
#
# 为什么不用 git merge/rebase：
#   本仓库的根提交 23ce14a 是「MewHub 快照 + 缠论引擎」的一次性导入，
#   与上游 mizaawa/mewhub 没有共同祖先。直接 merge 会因为「没有 base」
#   把两边同名的文件全判成 add/add 冲突；rebase 则在改 lib/stock 的提交上
#   报 modify/delete。所以这里用覆盖式同步：**上游当底座，我们的层整片盖上去**。
#
# 用法：
#   tool/sync_upstream.sh              # 同步到 sync/upstream 分支
#   BRANCH=my/sync tool/sync_upstream.sh
#   UPSTREAM_URL=... tool/sync_upstream.sh
#
# 跑完它会在 sync/upstream 上留下一个提交，并打印「需要人工核对」的文件。
# 审查、跑 analyze/test 通过后再合到 main —— 脚本不会碰 main。
set -euo pipefail

cd "$(dirname "$0")/.."

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/mizaawa/mewhub.git}"
BRANCH="${BRANCH:-sync/upstream}"
# 我们的初始导入提交：用来判断「上游自那以后改过哪些我们也碰过的文件」
BASE="${BASE:-23ce14a}"

# 完全属于我们的路径：上游没有，整片取本仓库版本
OWNED=(
  lib/stock
  lib/ui/stock
  assets/stock
  test/fixtures/chan
  test/chanlun_test.dart
  test/chart_context_test.dart
  test/minute_avg_test.dart
  test/period_resolver_test.dart
  tool/verify_golden.dart
  docs/chanlun-limits.md
  docs/data-sources.md
  docs/sync-upstream.md
  docs/releases/v1.10.0.md
  docs/releases/v1.10.1.md
)

# 上游也有、我们改过的文件：取我们的版本，但要人工核对上游这段时间改了什么
SHARED=(
  README.md
  pubspec.yaml
  lib/main.dart
  lib/data/assistant.dart
  lib/data/stock_defaults.dart
  lib/chat/chat_controller.dart
  lib/state/settings_store.dart
  lib/tools/stock_tools.dart
  lib/ui/assistant/assistant_edit_page.dart
  lib/ui/chat/chat_page.dart
)

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"

echo "== 拉取上游 =="
git fetch --quiet upstream
UPSTREAM_HEAD=$(git rev-parse --short upstream/main)
echo "   upstream/main = $UPSTREAM_HEAD"

# 工作区必须干净，否则覆盖式 checkout 会把没提交的东西一起盖掉
if [[ -n "$(git status --porcelain)" ]]; then
  echo "!! 工作区不干净，先提交或 stash" >&2
  git status --short >&2
  exit 1
fi

echo "== 建分支 $BRANCH（基于 upstream/main）=="
git switch -C "$BRANCH" upstream/main >/dev/null

echo "== 覆盖我们的独占路径 =="
for p in "${OWNED[@]}"; do
  if git cat-file -e "main:$p" 2>/dev/null; then
    git checkout main -- "$p"
    echo "   + $p"
  fi
done

echo "== 覆盖我们改过的上游文件 =="
for p in "${SHARED[@]}"; do
  if git cat-file -e "main:$p" 2>/dev/null; then
    git checkout main -- "$p"
    echo "   * $p"
  fi
done

ERRORS=0

echo
echo "== 需要人工核对的文件（上游自 $BASE 起改过，且我们也在改）=="
UPSTREAM_CHANGED=$(git diff --name-only "$BASE" upstream/main || true)
NEED_REVIEW=0
for p in "${SHARED[@]}"; do
  if grep -qxF "$p" <<<"$UPSTREAM_CHANGED"; then
    echo "   ! $p"
    NEED_REVIEW=$((NEED_REVIEW + 1))
  fi
done
if [[ "$NEED_REVIEW" -eq 0 ]]; then
  echo "   （无）上游没动这些文件，直接过"
fi

echo
echo "== 上游新增/修改的其他文件（已经在树里了，看一眼有没有新能力要接）=="
UPSTREAM_CHANGED_FILE=$(mktemp)
printf '%s\n' "$UPSTREAM_CHANGED" > "$UPSTREAM_CHANGED_FILE"
shown=0
while IFS= read -r p; do
  skip=0
  for own in "${OWNED[@]}"; do
    case "$p" in "$own"|"$own"/*) skip=1; break ;; esac
  done
  for sh in "${SHARED[@]}"; do
    [[ "$p" == "$sh" ]] && skip=1
  done
  if [[ "$skip" -eq 0 ]]; then
    echo "   $p"
    shown=$((shown + 1))
    [[ "$shown" -ge 40 ]] && break
  fi
done < "$UPSTREAM_CHANGED_FILE"
rm -f "$UPSTREAM_CHANGED_FILE"
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
  1. git diff main -- <上面 NEED_REVIEW 的文件>   # 逐个人工合并上游的新改动
  2. flutter pub get && flutter analyze --fatal-infos && flutter test
  3. 本地起不来（arm64 没有 Flutter SDK）就推分支让 CI 跑：
       git push origin $BRANCH
  4. 绿了再合回 main，然后打标签发版：
       git switch main && git merge --squash $BRANCH && git commit
       git tag vX.Y.Z && git push origin vX.Y.Z

冲突面为什么这么小：我们总共只碰了 ${#SHARED[@]} 个上游文件，其余全在 lib/stock、lib/ui/stock。
EOF

exit "$ERRORS"