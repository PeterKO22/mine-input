/*
 * SPDX-FileCopyrightText: 2015 - 2024 Rime community
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * W16 胶水层：复刻自 Trime v3.3.13 RimeKeyEvent.kt（去掉 KeyValue/KeyModifiers 依赖）。
 * JNI_OnLoad（GlobalRefSingleton）会 FindClass 本类并 GetMethodID("<init>", "(IILjava/lang/String;)V")，
 * 故构造签名必须为 (Int, Int, String)，勿改。
 */
package com.osfans.trime.core

data class RimeKeyEvent(
    val value: Int,
    val modifiers: Int,
    val repr: String,
) {
    override fun toString() = repr

    companion object {
        val None = RimeKeyEvent(0, 0, "0x0000")
    }
}
