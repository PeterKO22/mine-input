/*
 * SPDX-FileCopyrightText: 2015 - 2026 Rime community
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * W16 胶水层（接线草案 1a「胶水类复刻」）：复刻自 Trime v3.3.13
 * app/src/main/java/com/osfans/trime/core/RimeProto.kt，去掉 equals/hashCode 等
 * 非 JNI 面（librime_jni.so 只经 FindClass/GetMethodID 构造这些对象）。
 *
 * ⚠ 契约（jni-utils.h GlobalRefSingleton 实证）：类名、构造器参数顺序/类型与
 * librime_jni.so 的 GetMethodID 签名严格一致，勿改名、勿改序：
 *   CommitProto(String) / CandidateProto(String,String,String)
 *   CompositionProto(IIII,String,String) / ContextProto(CompositionProto,String,int)
 *   StatusProto(String,String,ZZZZZZZ) / RimeResponse(Commit,Composition,Candidates,Status)
 *   Candidates$Paged(ZZZI,CandidateProto[]) / Candidates$Bulk(II,CandidateProto[])
 * 复刻 Trime 源码 → 本项目 android/ 端衍生部分为 GPL-3.0-or-later（见 LICENSE.md）。
 */
package com.osfans.trime.core

/** 上屏文本（text 可为 null：librime 无 commit 时 JNI 传 null，保持可空）。 */
data class CommitProto(
    val text: String?,
)

/** 候选：text=候选文本，comment=注释（z 反查五笔码等），label=序号标签。 */
data class CandidateProto(
    val text: String,
    val comment: String,
    val label: String,
)

data class CompositionProto(
    val length: Int = 0,
    val cursorPos: Int = 0,
    val selStart: Int = 0,
    val selEnd: Int = 0,
    val preedit: String? = null,
    val commitTextPreview: String? = null,
)

data class ContextProto(
    val composition: CompositionProto = CompositionProto(),
    val input: String = "",
    val caretPos: Int = 0,
)

data class StatusProto(
    val schemaId: String = "",
    val schemaName: String = "",
    val isDisabled: Boolean = true,
    val isComposing: Boolean = false,
    val isAsciiMode: Boolean = true,
    val isFullShape: Boolean = false,
    val isSimplified: Boolean = false,
    val isTraditional: Boolean = false,
    val isAsciiPunct: Boolean = true,
)

sealed interface Candidates {
    val candidates: Array<CandidateProto>
    val highlighted: Int

    data class Paged(
        val hasPrevPage: Boolean = false,
        val hasNextPage: Boolean = false,
        val isHorizontalLayout: Boolean = false,
        override val highlighted: Int = 0,
        override val candidates: Array<CandidateProto> = arrayOf(),
    ) : Candidates

    data class Bulk(
        val total: Int = -1,
        override val highlighted: Int = 0,
        override val candidates: Array<CandidateProto> = arrayOf(),
    ) : Candidates
}

data class RimeResponse(
    val commit: CommitProto,
    val composition: CompositionProto,
    val candidates: Candidates,
    val status: StatusProto,
)
