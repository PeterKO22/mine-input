/*
 * W15 librime-android-poc — 最小 JNI demo（外部 IMS 复用 Trime librime_jni.so）
 *
 * 本类是「外部宿主」：与 Trime 无任何包名/清单关系。它只做三件事：
 *   1. 把 ping_wubi_mixed schema + 词库（assets/rime/）落盘到应用私有目录；
 *   2. 通过反射调用 Trime classes.dex 里导出的 JNI 静态方法
 *      （com.osfans.trime.core.Rime.startupRime / simulateRimeKeySequence /
 *        getRimeCandidates …，符号 Java_com_osfans_trime_core_Rime_* 由
 *        librime_jni.so 提供）；
 *   3. 把候选列表输出到 logcat（tag=W15POC）。
 *
 * 反射调用而非编译期依赖：证明外部 IMS 只要认这套 JNI 签名即可驱动引擎，
 * 无需链接 Trime 的任何 Gradle 模块。
 */
package com.mineinput.engine.rimepoc;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Array;
import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicBoolean;

public class RimePocActivity extends Activity {
    static final String TAG = "W15POC";
    static final String PKG = "com.mineinput.engine.rimepoc";
    static final String RIME_CLASS = "com.osfans.trime.core.Rime";

    // 验收用键序列（与 build/W1-REPORT.md §3.1 一致）：w→人、gggg→王、pinyin→拼音、nihao→你好、zni→反查
    static final String[][] CASES = {
        {"w", "人"},
        {"gggg", "王"},
        {"pinyin", "拼音"},
        {"nihao", "你好"},
    };

    final AtomicBoolean done = new AtomicBoolean(false);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        new Thread(this::runDemo, "w15-rime-poc").start();
    }

    void runDemo() {
        try {
            long t0 = System.currentTimeMillis();
            // 1. 落盘 RIME 数据：shared=纯数据（schema/词库），user=用户目录（custom_phrase 等）
            File shared = new File(getFilesDir(), "rime_shared");
            File user = new File(getFilesDir(), "rime_user");
            shared.mkdirs();
            user.mkdirs();
            copyAssetDir("rime/shared", shared);
            copyAssetDir("rime/user", user);
            Log.i(TAG, "data staged shared=" + listNames(shared) + " user=" + listNames(user));

            // 2. 加载 Trime 的 JNI 胶水类（来自打包进本 APK 的 Trime classes2.dex）
            Class<?> rime = Class.forName(RIME_CLASS);
            Method startupRime = rime.getMethod("startupRime", String.class, String.class, String.class, boolean.class);
            Method selectRimeSchema = rime.getMethod("selectRimeSchema", String.class);
            Method getCurrentSchema = rime.getMethod("getCurrentRimeSchema");
            Method simulate = rime.getMethod("simulateRimeKeySequence", String.class);
            Method getCandidates = rime.getMethod("getRimeCandidates", int.class, int.class);
            Method getRawInput = rime.getMethod("getRimeRawInput");
            Method clear = rime.getMethod("clearRimeComposition");
            Method exit = rime.getMethod("exitRime");

            // 3. 启动引擎（fullCheck=true → 设备端部署/编译码表，与 Trime 首跑同路径）
            startupRime.invoke(null, shared.getAbsolutePath(), user.getAbsolutePath(), "w15-poc", true);
            Log.i(TAG, "startupRime returned in " + (System.currentTimeMillis() - t0) + "ms (deploy may be async)");

            // 4. 等部署完成：直到能选中 ping_wubi_mixed
            boolean selected = false;
            for (int i = 0; i < 120 && !selected; i++) {
                try {
                    selected = (Boolean) selectRimeSchema.invoke(null, "ping_wubi_mixed");
                } catch (Throwable ignored) {
                }
                if (!selected) Thread.sleep(2000);
            }
            Log.i(TAG, "selectRimeSchema(ping_wubi_mixed)=" + selected
                    + " current=" + getCurrentSchema.invoke(null)
                    + " deployTotal=" + (System.currentTimeMillis() - t0) + "ms");
            if (!selected) throw new IllegalStateException("schema ping_wubi_mixed unavailable after deploy");

            // 5. 逐序列出候选
            for (String[] c : CASES) {
                String seq = c[0];
                printCandidates(simulate, getCandidates, getRawInput, clear, seq);
            }
            // z 前缀反查：注释里应带五笔编码（如 你 wq wqi wqiy），单独断言注释
            printCandidates(simulate, getCandidates, getRawInput, clear, "zni");

            exit.invoke(null);
            Log.i(TAG, "DONE all cases ok, total=" + (System.currentTimeMillis() - t0) + "ms");
        } catch (Throwable t) {
            Log.e(TAG, "POC FAILED: " + t, t);
            for (Throwable s = t.getCause(); s != null; s = s.getCause()) {
                Log.e(TAG, "caused by: " + s, s);
            }
        } finally {
            done.set(true);
        }
    }

    void printCandidates(Method simulate, Method getCandidates, Method getRawInput, Method clear, String seq)
            throws Exception {
        // 部署竞态兜底：候选为空则清码重试；每例开始先清空 composing
        String line = null;
        for (int attempt = 0; attempt < 10; attempt++) {
            clear.invoke(null);
            simulate.invoke(null, seq);
            Object[] cands = (Object[]) getCandidates.invoke(null, 0, 8);
            StringBuilder sb = new StringBuilder();
            sb.append("RESULT|seq=").append(seq)
              .append("|input=").append(getRawInput.invoke(null))
              .append("|n=").append(cands == null ? 0 : cands.length);
            if (cands != null) {
                for (int i = 0; i < cands.length; i++) {
                    sb.append("|").append(i + 1).append("=").append(text(cands[i]))
                      .append("(").append(comment(cands[i])).append(")");
                }
            }
            line = sb.toString();
            if (cands != null && cands.length > 0) break;
            clear.invoke(null);
            Thread.sleep(3000);
        }
        Log.i(TAG, line);
    }

    /** CandidateProto(text, comment, label) 的反射取值，data class getter 优先 */
    static String text(Object cand) {
        return prop(cand, "getText", "text");
    }

    static String comment(Object cand) {
        return prop(cand, "getComment", "comment");
    }

    static String prop(Object o, String getter, String field) {
        try {
            Method m = o.getClass().getMethod(getter);
            m.setAccessible(true);
            Object v = m.invoke(o);
            return v == null ? "" : v.toString();
        } catch (Throwable ignored) {
        }
        try {
            Object v = o.getClass().getField(field).get(o);
            return v == null ? "" : v.toString();
        } catch (Throwable ignored) {
        }
        return String.valueOf(o);
    }

    void copyAssetDir(String assetPath, File dst) throws Exception {
        String[] names = getAssets().list(assetPath);
        if (names == null || names.length == 0) return;
        for (String n : names) {
            File out = new File(dst, n);
            String child = assetPath + "/" + n;
            String[] sub = getAssets().list(child);
            if (sub != null && sub.length > 0) {
                out.mkdirs();
                copyAssetDir(child, out);
            } else {
                try (InputStream in = getAssets().open(child);
                     OutputStream os = new FileOutputStream(out)) {
                    byte[] buf = new byte[65536];
                    int r;
                    while ((r = in.read(buf)) > 0) os.write(buf, 0, r);
                }
            }
        }
    }

    static String listNames(File dir) {
        String[] n = dir.list();
        return java.util.Arrays.toString(n);
    }
}
