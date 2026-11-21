# 跟着上游 MewHub 更新

本仓库是 **MewHub 的产品化分支**：底座（对话、模型供应商、MCP、世界书、记忆、后台生成、坐标绘图…）全部来自
[`mizaawa/mewhub`](https://github.com/mizaawa/mewhub)，我们在上面加了一层「问股」。

所以上游发新版本时，按理应该能同步过来，而不是整包重抄。这篇写清楚**能怎么同步、会撞在哪、验证什么**。

## 为什么不能用 git merge / rebase

本仓库的根提交 `23ce14a`（`mew问股: 以 MewHub 为底座，接入缠论 Dart 引擎`）是一次性导入的快照，
**和上游没有共同祖先**。后果：

| 做法 | 实际结果（实测） |
|---|---|
| `git merge upstream/main` | 没有 base，两边同名文件全判成 add/add，冲突面 = 所有共同文件 |
| `git rebase --onto upstream/main 23ce14a main` | 第一个改 `lib/stock` 的提交就报 `modify/delete`：文件在新 base 上不存在 |

所以同步走**覆盖式叠加**：以上游最新为底座，把我们这一层整片盖上去。

```bash
# 同步到本地分支 sync/upstream（脚本不碰 main）
tool/sync_upstream.sh

# 换分支名 / 换上游地址
BRANCH=my/sync UPSTREAM_URL=https://github.com/xxx/mewhub.git tool/sync_upstream.sh
```

脚本做的事：fetch 上游 → 从 `upstream/main` 建分支 → **用我们整棵树覆盖**（上游独有、我们没有的新文件保留）→
删掉上游那份重复的 Kotlin 包目录 → 打印「需要人工核对」清单。

策略是刻意保守的：**宁可漏更新上游某个新功能，也不要静默把包名、MethodChannel、应用标题改回上游的**。
上面实测那 8 个共同路径里就有 3 个是这种「改回上游就出事」的文件（`lib/app.dart` 的标题、
`background_generation.dart` 的通道名、`build.gradle.kts` 的包名），所以不做自动合并，只列清单让人判断。

## 我们到底动了上游多少

我们和上游 `mizaawa/mewhub` 的关系是「一层薄壳」：`lib/stock/`、`lib/ui/stock/`、`assets/stock/` 这些整片属于我们，
上游没有同路径，永远不冲突；真正共享的只有下面这些。

**品牌与打包（上游也有，内容必须是我们的）**
`android/app/build.gradle.kts`（包名 `io.github.homestay377.mewaskstock`）、
`AndroidManifest.xml`、`res/values/strings.xml`、`android/app/src/main/kotlin/`（整片）、
`ios/Runner/Info.plist`、`lib/app.dart`（标题「mew问股」）、
`lib/state/background_generation.dart`（MethodChannel 名）、`pubspec.yaml`、`README.md`。

**逻辑 hook（改过上游的业务文件）**
`lib/main.dart`、`lib/chat/chat_controller.dart`、`lib/state/settings_store.dart`、
`lib/tools/stock_tools.dart`、`lib/data/assistant.dart`、`lib/data/stock_defaults.dart`、
`lib/ui/assistant/assistant_edit_page.dart`、`lib/ui/chat/chat_page.dart`。

**实测（2026-11-21，快照 → 上游 `b1c09bf`）**
上游自我们快照以来改了 15 个路径：android 5 个、iOS 1 个、`lib/app.dart`、`lib/state/background_generation.dart`、
`pubspec.yaml`，以及 4 个在 base 导入里就属于我们的 stock 路径（上游根本没有，不算冲突）。
落在「共同路径」上的 8 个，**全部是品牌/打包相关**——也就是说这次同步的实际代码增量为 0，
`tool/sync_upstream.sh` 跑完得到的树与 `main` 完全一致。

真正需要读一遍的，是上游改 `lib/chat/`、`lib/tools/`、`lib/state/` 这类通用逻辑的时候。
脚本会把这些路径列进「需要人工核对」，不会静默丢掉。

## 同步后的检查清单

1. **`pubspec.yaml`**：上游加了依赖就并进来，别把我们自己的（`gbk_codec` 等）弄丢。
2. **`lib/main.dart` / `lib/ui/chat/chat_page.dart`**：上游改了启动顺序或 dock 布局时，
   我们挂 K 线面板的位置要跟着挪。
3. **`lib/chat/chat_controller.dart`**：上游改工具调用循环时要确认 stock 工具还接得上。
4. **`lib/tools/stock_tools.dart`**：工具注册的表结构若变了，按新结构登记 stock 工具。
5. 跑验证：
   ```bash
   flutter pub get
   flutter analyze --fatal-infos     # 注意：CI 把 info 也当失败
   dart format --page-width 120 --output=none --set-exit-if-changed lib test
   flutter test
   ```
   本机（arm64、无 Flutter SDK）跑不了就推分支让 CI 跑。

## 版本策略

- 我们自己的版本号独立走：`v1.10.0`、`v1.10.1` …，`pubspec.yaml` 里的 version 不跟随上游。
- 发版就是打标签：`git tag vX.Y.Z && git push origin vX.Y.Z`，
  `release.yml` 会构建并发布 GitHub Release（Android 三个 ABI + universal + AAB + 未签名 IPA）。
- 应用内的「检查更新」读的是**本仓库**的 latest release
  （`lib/core/release_update.dart` 的 `latestReleaseApi`），不要改回上游：
  我们的 applicationId 是 `io.github.homestay377.mewaskstock`，上游 APK 装不上。

## 已知取舍

- 覆盖式同步后，**共享文件的冲突要在本地人肉合**，脚本不替你判断语义。
- 上游若重命名/挪动了我们引用的文件（比如 `chat_controller.dart` 拆分），同步后编译会立刻报错——
  这是好事，比静默错位强。按报错点修 hook 即可。
- 上游目前**没有** `lib/stock/`，所以我们这层不会被上游覆盖；但如果上游哪天也做了股票模块，
  同步时必须先做一次人工决策（合并还是保留两套）。