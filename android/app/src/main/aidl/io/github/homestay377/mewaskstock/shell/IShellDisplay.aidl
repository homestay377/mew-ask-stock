// 运行在 shell 身份进程里的显示/输入服务。
//
// 只有 shell 身份（uid 2000）或 root 才建得出虚拟屏，普通 App 拿不到这个权限。
// 本接口只做"建屏 / 启动 / 注入 / 释放"四件事——不做剪贴板、不做静音、不做多用户，
// 那些是 Mika 为了替代用户操作才需要的，我们不碰用户的账号和支付。
package io.github.homestay377.mewaskstock.shell;

import android.view.Surface;

interface IShellDisplay {
    /** 建一块虚拟屏，画面输出到 [surface]；返回 displayId，失败返回 -1。 */
    int createDisplay(in Surface surface, int width, int height, int dpi) = 1;

    /** 释放这块屏（上面所有 App 一起消失）。 */
    void releaseDisplay(int displayId) = 2;

    /**
     * 在 [displayId] 上打开 [packageName]。
     * 返回 0=已启动 1=用户正在主屏用这个 App（不打扰） 2=没有可启动的入口 3=出错
     */
    int startApp(int displayId, String packageName) = 3;

    /** 这块屏最上面任务的任务号；没有任务返回 -1。 */
    int topTaskId(int displayId) = 4;

    /** 点击 [displayId] 上 (x, y)。 */
    boolean injectTap(int displayId, int x, int y) = 5;

    /** 从 (x1,y1) 滑到 (x2,y2)，[durationMs] 是手指走的时长。 */
    boolean injectSwipe(int displayId, int x1, int y1, int x2, int y2, long durationMs) = 6;

    /** 按一个键（返回键等），只投给这块屏。 */
    boolean injectKey(int displayId, int keyCode) = 7;

    /** 服务所在进程的 [uid, pid]，App 侧据此确认 binder 来自预期的身份。 */
    int[] identity() = 8;

    /** 上一次建屏失败的原因（success 后清空）；没失败过返回 null。 */
    String lastError() = 9;

    /**
     * 把可打印 ASCII 当键盘事件打进这块屏的当前焦点——不需要无障碍、不需要输入法。
     * 中文打不了（要输入法），但股票代码、搜索词、英文够了。
     * 返回 0=未发送 1=已全部投递 2=可能只投递了前缀（别再换条路重发，会重复输入）
     */
    int injectAsciiText(int displayId, String text) = 10;

    /**
     * 以 shell 身份跑一条命令（`/system/bin/sh -c`）。
     * 输出里最后一行是 `__exit=<code>`；超时会在开头写 `__error=timeout`。
     *
     * 用途：把本应用的无障碍服务写进 secure 设置——shell 身份才有 WRITE_SECURE_SETTINGS，
     * 这样用户不用自己去系统设置里点开（做法对齐 Mika 的 RecoveryPermissions）。
     */
    String execShell(String command) = 11;
}
