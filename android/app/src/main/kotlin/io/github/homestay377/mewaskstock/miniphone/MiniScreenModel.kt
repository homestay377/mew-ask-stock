package io.github.homestay377.mewaskstock.miniphone

/** 读屏结果里的一条元素（给模型看的那份）。 */
data class MiniElement(
    val ref: String,
    val role: String,
    val name: String,
    val centerX: Int,
    val centerY: Int,
    val bounds: List<Int>,
    val resourceId: String?,
    val clickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val focused: Boolean,
    val checked: Boolean,
    val enabled: Boolean,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "ref" to ref,
        "role" to role,
        "name" to name,
        "center" to listOf(centerX, centerY),
        "bounds" to bounds,
        "resourceId" to resourceId,
        "clickable" to clickable,
        "editable" to editable,
        "scrollable" to scrollable,
        "focused" to focused,
        "checked" to checked,
        "enabled" to enabled,
    )
}

/** 窗口层级里的一个节点：只有结构与编号，文字在 [MiniElement] 里。 */
data class MiniNode(
    val role: String,
    val ref: String,
    val depth: Int,
) {
    fun toMap(): Map<String, Any?> = mapOf("role" to role, "ref" to ref, "depth" to depth)
}

data class MiniWindow(
    val id: Int,
    val type: Int,
    val packageName: String?,
    val active: Boolean,
    val focused: Boolean,
    val nodes: List<MiniNode>,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "type" to type,
        "packageName" to packageName,
        "active" to active,
        "focused" to focused,
        "nodes" to nodes.map { it.toMap() },
    )
}

/** 一次读屏的全部内容。 */
data class MiniScreen(
    val packageName: String?,
    val width: Int,
    val height: Int,
    val elements: List<MiniElement>,
    val windows: List<MiniWindow>,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "ok" to true,
        "package" to packageName,
        "size" to listOf(width, height),
        "elements" to elements.map { it.toMap() },
        "windows" to windows.map { it.toMap() },
    )
}
