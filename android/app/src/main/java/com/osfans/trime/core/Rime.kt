/*
 * SPDX-FileCopyrightText: 2015 - 2026 Rime community
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * W16 胶水层（接线草案 1a）：复刻自 Trime v3.3.13
 * app/src/main/java/com/osfans/trime/core/Rime.kt 的 JNI 静态面
 * （28 个 external + handleRimeMessage 回调），删去 Trime 的
 * RimeApi/RimeLifecycle/协程调度等非 JNI 语义。
 *
 * ⚠ 契约（librime_jni.so v3.3.13 实证）：
 *   - 28 个 native 方法为 com.osfans.trime.core.Rime 的 PUBLIC STATIC FINAL NATIVE，
 *     符号 Java_com_osfans_trime_core_Rime_*；签名勿改。
 *   - handleRimeMessage(I[Ljava/lang/Object;)V 必须是 Rime 的**静态**方法：
 *     JNI_OnLoad 里 GetStaticMethodID 即取它，缺失则库加载失败。
 *   - System.loadLibrary("rime_jni") 触发 JNI_OnLoad → FindClass 全部胶水类
 *     （Rime/CandidateProto/CommitProto/ContextProto/CompositionProto/StatusProto/
 *      RimeResponse/Candidates$Bulk/Candidates$Paged/SchemaItem/RimeKeyEvent），
 *     任一类缺失都会加载失败——故胶水类必须先于首次调用存在于 APK。
 *
 * 消息类型（rime_jni.cc notificationHandler 实证）：
 *   0=unknown 1=schema 2=option 3=deploy（params[0] 为 start/success/failure 等）。
 * 复刻 Trime 源码 → 本项目 android/ 端衍生部分为 GPL-3.0-or-later（见 LICENSE.md）。
 */
package com.osfans.trime.core

class Rime {
    companion object {
        init {
            System.loadLibrary("rime_jni")
        }

        /** W16：librime 通知回调的监听口（deploy/schema/option 消息），线程安全、永抛不进 JNI。 */
        @Volatile
        @JvmStatic
        var messageListener: ((type: Int, params: Array<Any>) -> Unit)? = null

        /** JNI 回调落点（签名固定 (I[Ljava/lang/Object;)V，勿改）。 */
        @JvmStatic
        fun handleRimeMessage(type: Int, params: Array<Any>) {
            try {
                messageListener?.invoke(type, params)
            } catch (_: Throwable) {
                // 绝不把异常抛回 JNI（会留 pending exception）
            }
        }

        // ---- init ----
        @JvmStatic
        external fun startupRime(
            sharedDir: String,
            userDir: String,
            versionName: String,
            fullCheck: Boolean,
        )

        @JvmStatic
        external fun exitRime()

        @JvmStatic
        external fun deployRimeSchemaFile(schemaFile: String): Boolean

        @JvmStatic
        external fun deployRimeConfigFile(
            fileName: String,
            versionKey: String,
        ): Boolean

        @JvmStatic
        external fun syncRimeUserData(): Boolean

        // ---- input ----
        @JvmStatic
        external fun processRimeKey(
            keycode: Int,
            mask: Int,
        ): Boolean

        @JvmStatic
        external fun commitRimeComposition(): Boolean

        @JvmStatic
        external fun clearRimeComposition()

        // ---- output ----
        @JvmStatic
        external fun getRimeCommit(): CommitProto

        @JvmStatic
        external fun getRimeContext(): ContextProto

        @JvmStatic
        external fun getRimeStatus(): StatusProto

        // ---- runtime options ----
        @JvmStatic
        external fun setRimeOption(
            option: String,
            value: Boolean,
        )

        @JvmStatic
        external fun getRimeOption(option: String): Boolean

        @JvmStatic
        external fun getRimeSchemaList(): Array<SchemaItem>

        @JvmStatic
        external fun getCurrentRimeSchema(): String

        @JvmStatic
        external fun selectRimeSchema(schemaId: String): Boolean

        // ---- testing ----
        @JvmStatic
        external fun simulateRimeKeySequence(keySequence: String): Boolean

        @JvmStatic
        external fun getRimeRawInput(): String

        @JvmStatic
        external fun getRimeCaretPos(): Int

        @JvmStatic
        external fun setRimeCaretPos(caretPos: Int)

        @JvmStatic
        external fun selectRimeCandidate(index: Int, global: Boolean): Boolean

        @JvmStatic
        external fun deleteRimeCandidate(index: Int, global: Boolean): Boolean

        @JvmStatic
        external fun changeRimeCandidatePage(backward: Boolean): Boolean

        @JvmStatic
        external fun getAvailableRimeSchemaList(): Array<SchemaItem>

        @JvmStatic
        external fun getSelectedRimeSchemaList(): Array<SchemaItem>

        @JvmStatic
        external fun selectRimeSchemas(schemaIds: Array<String>): Boolean

        @JvmStatic
        external fun getRimeCandidates(
            startIndex: Int,
            limit: Int,
        ): Array<CandidateProto>

        @JvmStatic
        external fun getRimeResponse(pagingMode: Boolean): RimeResponse
    }
}
