/*
 * SPDX-FileCopyrightText: 2015 - 2024 Rime community
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * W16 胶水层：复刻自 Trime v3.3.13 SchemaItem.kt（构造签名 (String,String) 与
 * librime_jni.so 的 SchemaListItemInit 一致，勿改）。
 */
package com.osfans.trime.core

data class SchemaItem(
    val id: String,
    val name: String = "",
)
