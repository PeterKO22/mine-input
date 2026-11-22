# 开发签名证书（稳定授权）· Dev Signing Setup

W32 `stable-signing-and-c1-optin`。解决：装机版 ad-hoc 签名 → `codesign -dr-` 显示
`designated => cdhash H"…"`（哈希锚定）→ 每次重装/重建 cdhash 变 → macOS TCC 录屏授权
（kTCCServiceScreenCapture）永远 `Failed to match existing code requirement` → 反复弹
「Squirrel-dev 想要录制此电脑的屏幕」、同意/开关无效（W27 弹窗风暴事故根因之一）。

## 一键生成（幂等）

```bash
bash scripts/make-dev-cert.sh
```

脚本做四件事（已存在身份即跳过，可重复运行）：

1. 检查 keychain 是否已有签名身份 **Mine Input Dev**（有 → 跳过）；
2. `openssl` 生成自签名证书：CN=Mine Input Dev、RSA 2048/SHA-256、
   `extendedKeyUsage=codeSigning`、有效期 3650 天（10 年）；
3. 打包 PKCS#12 → `security import` 进 **login keychain**（`-T /usr/bin/codesign`
   允许 codesign 使用该密钥）；
4. 验证身份可见。

之后 `bash build/install-dev.sh` 自动以 **Mine Input Dev** 签名装机副本（找不到身份时
回退 ad-hoc 并大声警告）。

## 一次性手动动作（首次签名）

首次用该证书签名时 macOS 可能弹 **「codesign 想使用密钥」** → 点一次 **「始终允许」**
（Allow Always）。此后不再弹。若点了「拒绝」，可在 钥匙串访问 → 登录 → 找到
Mine Input Dev 私钥 → 显示简介 → 访问控制 里改为「允许所有应用程序」。

## 验收（装机后）

```bash
bash macos/w32/scripts/w32-sign-probe.sh
```

预期：`designated => identifier "im.rime.inputmethod.Squirrel.dev" and
certificate leaf = H"…"`——**identifier + certificate 锚，非 cdhash**。同一证书重签
（重装/重建后 install-dev.sh 再签）designated requirement 逐字不变 → TCC 授权跨重装
存活，不再反复弹窗。

手工核对同一条：

```bash
codesign -dr- ~/Library/Input\ Methods/Squirrel-dev.app
```

## 说明与坑

- 自签证书在 `security find-identity -p codesigning` 显示 `CSSMERR_TP_NOT_TRUSTED`
  ——正常（本机既有本地开发签名证书同状态）；codesign 签名与 designated requirement
  锚定不受影响。**不要用 `find-identity -v`（valid only）判断身份存在**——它会漏掉
  自签身份（脚本已按此修正）。
- `security import` 对**空口令** PKCS#12 报
  `The user name or passphrase you entered is not correct`——脚本用一次性口令打包 p12
  并以 `-P` 显式传入（口令随临时目录即弃）。
- 变量紧邻中文字符（如 `「$CN」`）bash 会把汉字并入变量名报 unbound——脚本一律
  `${CN}` 花括号写法。
- TCC 权限在**进程启动时**读取：系统设置授权后必须重启 IME 进程
  （`pkill -f "Squirrel-dev.app/Contents/MacOS/Squirrel" && open ~/Library/Input\ Methods/Squirrel-dev.app`）。
- 旧授权记录（ad-hoc 时代残留）：`tccutil reset ScreenCapture im.rime.inputmethod.Squirrel.dev`。
- 本证书仅供本机 dev 装机版；发布签名/公证不在本文件范围（不设 DEV_ID，不做公证）。
