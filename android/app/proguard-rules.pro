# Flutter embedding and plugins ship their own consumer rules; these cover
# the remaining reflection users.

# flutter_local_notifications (Gson-serialised notification details)
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# Keep generic type info for Gson TypeToken subclasses.
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Play Core (deferred components) is referenced by the Flutter engine but unused.
-dontwarn com.google.android.play.core.**

# ---- 虚拟屏（Shizuku）----
# Shizuku 用反射按类名实例化 UserService，类名和构造方法不能被混淆/删除
-keep class io.github.homestay377.mewaskstock.shell.ShizukuShellUserService { *; }
-keep class io.github.homestay377.mewaskstock.shell.IShellDisplay { *; }
-keep class io.github.homestay377.mewaskstock.shell.IShellDisplay$Stub { *; }
-keep class io.github.homestay377.mewaskstock.shell.ShellDisplayService { *; }
# app_process 入口（B 路线）同样按类名启动
-keep class io.github.homestay377.mewaskstock.shell.ShellContext { *; }
# 无障碍服务由系统按清单实例化
-keep class io.github.homestay377.mewaskstock.miniphone.MiniPhoneAccessibility { *; }
# Shizuku 自己的类不混淆
-keep class rikka.shizuku.** { *; }
