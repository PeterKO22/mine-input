# 朋友部署一页纸（mine-input AI Hub，W17）

> 目标：一台 Mac/主机跑 Hub，2–5 个朋友用各自账号连上来——数据互相隔离、全链路 HTTPS。
> 一页讲完：装什么、跑哪几条命令、发给朋友什么、数据怎么隔离、出事怎么恢复。

## 0. 需要什么

| 项 | 要求 |
|---|---|
| 主机 | macOS（Apple Silicon 最佳，模型走 Metal）或任意能跑 Docker 的机器 |
| 软件 | Docker Desktop / docker compose、openssl（系统自带）、bash |
| 模型 | `models/fetch_model.sh install`（0.5B）或直接 `models/` 放 7B GGUF（W13 现状：7B 已在） |
| 端口 | 8443/tcp（HTTPS，对朋友开放）、8092/tcp（模型，仅本机）、8088（HTTP 回退，仅本机） |

## 1. 三条命令起服务

```bash
./models/run-llama-native.sh load    # 模型服务：launchd 托管（开机自启/崩溃拉起/日志轮转）
cd hub && ./tls/gen-certs.sh         # 自签 CA + HTTPS 证书（产物 tls/certs/，私钥不入库）
docker compose up -d --build         # Hub + nginx TLS 边车（restart:unless-stopped）
./smoke.sh                           # 全绿（PASS=43）即可对外
```

防火墙/路由器：只转发 **8443** 到主机（朋友侧）。8088/8092 不要暴露。

## 2. 发给朋友的三样东西

1. **地址**：`https://<你的主机名或IP>:8443`；
2. **CA 证书** `hub/tls/certs/ca.crt`（微信/网盘发一次即可）——客户端装上它或路径引用
   （curl `--cacert`、SDK `ClientConfig::ca_bundle`、iOS `ATS` 例外或装描述文件）；
3. **注册方式**：让朋友自己调 `POST /v1/auth/register {username,password}`（或你代注册发账号）。
   注册返回 `user_id` + 独立密钥分区 `key_partition:{id,key}`（E2E 预留，见 §4）。

客户端拿 token：`POST /v1/auth/token` → `Authorization: Bearer <token>`（7 天有效）。

## 3. 多用户隔离（朋友数据互不可见）

- **存储分区**：所有表（userdb/counters/hotwords/ingest_events/pushes）都带 `user_id`，
  查询层强制过滤——A 的 token 只能读写 A 的行（smoke 第 9 步实测：B pull 空集）；
- **鉴权分区**：token 内嵌 `user_id`，HMAC 签名（服务端 `hub-secret`）防伪造；
  抓包也看不到别人的 key（TLS 加密传输）；
- **密钥分区**（FR8）：每用户独立 `key_partition.key`，为端到端加密预留——当前 Hub 尚未
  E2E 加密落库，**主机管理员技术上可读库文件**（见 §6 信任边界）；
- **配额**：无（个人/朋友场景不设限；滥用只影响你自己机器）。

## 4. TLS 与信任模型

- 对外仅 HTTPS（nginx 边车终结 TLS，SSE 流式直通）；HTTP 明文只留本机 loopback 回退；
- 证书是**自签 CA** 签发（不是公网 CA）：朋友必须装 `ca.crt` 才能验证——这是特性不是麻烦，
  没拿到 CA 的人连不上（防冒充）；
- 证书 RSA-2048（勿改 EC：macOS 系统 curl 的 TLS 1.3 + ECDSA 握手有 bug，见 W17-REPORT §5）；
- 证书过期（825 天）或换机：主机重跑 `./tls/gen-certs.sh`（`FORCE=1` 重签）+ 重发 `ca.crt`。

## 5. 日常维护

```bash
./backup.sh                  # 一键备份（SQLite 在线一致快照 + hub-secret + SHA256 清单）
./restore.sh latest          # 一键恢复（校验→换入→起服→行数核对）
docker compose logs -f tls   # 看 HTTPS 访问日志
./models/run-llama-native.sh status   # 模型服务（launchd 托管状态）
```

- 备份包含 **hub-secret**（token 签名密钥）：按 0600 保管，泄密=可伪造 token；
- 建议 cron 每日 `./backup.sh`（备份目录 `hub/backups/`，不入库）；
- 恢复是**整体覆盖**（回到备份时间点），恢复后备份期间的新增数据丢失（演练实证 W17-REPORT §4）。

## 6. 信任边界（说清楚，别误会）

| 项 | 现状 |
|---|---|
| 传输 | TLS 加密 + CA 验证 ✅ |
| 用户隔离 | user_id 分区 + token 签名 ✅（smoke 实测） |
| 落库加密 | ❌ 未做——主机管理员可读 hub.db（备份同理）；敏感输入建议客户端侧摘要化（W12 已做） |
| E2E（零知识） | 预留（key_partition 已发），未启用 |
| 审计 | print 级（W4 遗留），不落库 |

朋友问起就答：**“别人看不到你的数据，但我这台机器看得到；介意就别同步敏感内容。”**

## 7. 故障速查

| 症状 | 处理 |
|---|---|
| curl 报证书错 | 没带 `--cacert ca.crt`（或系统没装 CA） |
| curl 报 `tlsv1 alert decode error` | 用了 EC 证书或旧配置——重跑 gen-certs.sh（RSA）|
| 朋友连不上 | 查防火墙/端口转发 8443；`curl --cacert ca.crt https://<host>:8443/healthz` |
| 建议变慢/降级桩 | 模型服务挂了：`./models/run-llama-native.sh status`（launchd 会自动拉起）|
| 恢复后 token 全失效 | 恢复包里的 hub-secret 与现网不同——用备份同包恢复或让用户重登 |
