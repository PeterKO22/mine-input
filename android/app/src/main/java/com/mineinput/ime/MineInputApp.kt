package com.mineinput.ime

import android.app.Application
import com.mineinput.ime.sync.SyncManager

/** W11：全局初始化（SyncManager/Prefs 的上下文入口）。 */
class MineInputApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SyncManager.init(this)
    }
}
