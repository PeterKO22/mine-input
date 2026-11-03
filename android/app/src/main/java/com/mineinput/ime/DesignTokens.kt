package com.mineinput.ime

import android.graphics.Color

/**
 * 视觉 token —— 唯一来源：design/design-language.md §1 色彩 Token。
 * 改风格 → 先改 design-language.md，再同步此文件。
 */
object DesignTokens {
    // 基底
    val bg = Color.parseColor("#0E2924")        // 全局背景
    val card = Color.parseColor("#18352F")      // 卡片/键帽填充
    val stroke = Color.parseColor("#2B4B44")    // 全部描边（1px 细描边）
    // 强调
    val gold = Color.parseColor("#D4A857")      // 主强调：PTT 主按钮/选中候选/数值
    val cyan = Color.parseColor("#388A83")      // 次强调：听写中/状态/定位
    val purple = Color.parseColor("#5D3D8C")    // 分类强调（备用）
    val red = Color.parseColor("#A84B3D")       // 危险/低置信
    val green = Color.parseColor("#4CB368")     // 成功/完成
    // 文字层级
    val textTitle = Color.parseColor("#E0E6E4") // 模块标题
    val textBody = Color.parseColor("#C8D0CC")  // 正文/核心
    val textMuted = Color.parseColor("#8A9E99") // 弱化/辅助
    val white = Color.WHITE                     // 数值强调（配 mono）
}
