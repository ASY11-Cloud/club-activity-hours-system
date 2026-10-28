# 社团活动报名与学时认定系统

题号 86 · HarmonyOS 课程设计（进阶级・系统 · 95 分）

**鸿蒙 App（SQLite 本地库）+ 自主 C++ Web 服务器（服务端 MySQL）+ ESP32 RFID 刷卡签到扩展**

> 本轮改动明细、为什么改、验证方式与环境坑，见 [`HANDOFF.md`](HANDOFF.md)。
> 操作步骤与验收演示见 [`docs/使用说明.md`](docs/使用说明.md)（Word 版 `使用说明文档.docx`）。

## 功能总览

- 活动发布：管理员创建活动（名称 / 内容 / 地点 / 时间 / 学时 / 人数上限），支持**本地草稿**保存与一键同步发布到服务器；时间采用**滚轮选择器**（DatePicker + TimePicker），自动校验“结束晚于开始、开始不早于当前”，杜绝非法输入
- 活动报名：普通成员浏览并报名，记录同时写入**本地 SQLite** 与服务器 MySQL，本地/服务端双重幂等去重；容量校验在服务端事务内加活动行锁完成（并发不超员），已驳回报名不占名额；**剩余名额由服务端统一计算下发**，App 与服务端口径一致
- 报名撤销：待审核报名可由成员本人撤销（释放名额），已通过/已驳回不可撤销；**离线报名落本地后可一键补传**（服务端按 `client_id` 幂等，重试不会重复报名）
- 审核认定：管理员在审核中心“通过 / 驳回”，通过后服务器**事务化自动累计学时**。审核在事务内 `SELECT ... FOR UPDATE` 锁报名行 + 条件更新（`WHERE status=0`）+ 影响行数校验，**并发/重复点击只累计一次**
- 学时报表：成员排行 + 认定明细，**本地 SQLite 统计与服务器 MySQL 统计双端对比**，直接给出「✔ 双端一致 / 差 X 学时」判定，并可**一键校准本地缓存**（按服务器报名记录回填本地）；管理员可一键“重算学时”（以 `signup` 通过记录为唯一事实来源重建 `hours_total`，修复历史漂移）
- 活动生命周期：活动可**下线**（软删除，历史报名与学时保留）；**已结束活动不可报名、不可刷卡认定学时**（原先可对任意历史活动报名）
- 学时达标线：`sys_config.required_hours` 可在 App 内设置，报表每行直接给出「达标 / 距达标 X 学时」结论，并统计达标人数
- 服务器实时日志：每次请求内存日志 + MySQL `request_log` 双写，毫秒级时间戳，管理员在线查看；支持按**级别（失败/慢请求）/ 方法 / 路径关键词**筛选，`request_log` 按 7 天且不超过 20000 条自动裁剪
- 活动编辑：管理员可在原记录上修改标题/内容/地点/时间/学时/人数上限（已报名记录与学时不动，人数上限不得小于有效报名数）
- 列表分页：活动广场滚动到底自动加载下一页（10 条/页），审核中心 20 条/页并可在服务端按状态/活动/关键词筛选
- 学时导出：报表可按当前标签页导出 CSV（写入应用沙箱并支持一键复制到剪贴板）
- 嵌入式扩展：ESP32 + MFRC522 读卡实机刷卡签到，到场即认定学时（已被管理员驳回的报名需先重新报名，刷卡不会绕过审核）；签到状态通过 `checkin` 同步回本地库，成员在「我的报名」与活动详情可直接看到「已刷卡签到」；固件带 WiFi 断线自动重连与同卡 5 秒冷却；可选 `X-Device-Key` 设备密钥，防止局域网内伪造刷卡

## 系统架构

```
鸿蒙 App (HarmonyOS relationalStore 本地库)
   │  HTTP (10.0.2.2:8000 模拟器 / 宿主机局域网 IPv4 真机)
   ▼
自主 C++ Web 服务器 (bind 0.0.0.0:8000, Token 鉴权, 连接池, keep-alive, 事务化报名/学时)
   │
   ▼
MySQL 8.0 (club_system: admin_user / student / activity / signup / hours_total / request_log / sys_config)
```

- 双角色权限：**管理员**（发布 / 审核 / 学时全量 / 服务器日志）与**普通成员**（报名 / 我的报名 / 本人学时），服务端 Token 统一校验 + App 页面级守卫；登录支持**失败节流**（同账号 60 秒内失败 5 次临时拒绝，防口令暴力猜测），退出登录同时**注销服务端 Token**
- 数据一致性三层保证：本地唯一 `client_id` 幂等 + 服务端唯一键（`uk_client`、`uk_act_stu`）去重 + 事务化容量 / 学时累计（审核、刷卡均为“锁行 + 条件更新 + 影响行数校验”）

## 目录结构

```
chapter03/
├── chapter03/                 # 鸿蒙工程（DevEco Studio 打开此目录）
│   └── entry/src/main/ets/    # 页面与数据层源码
│       ├── common/            # ApiClient / AppConfig / DbHelper / Models / GuardViews / Nav
│       └── pages/             # 引导页、登录注册、主界面(活动/管理/我的 Tab)、详情、发布/编辑、审核、学时报表、日志、设置
├── server/                    # 自主 C++ Web 服务器
│   ├── server.cpp             # 全部服务端逻辑（含解析、校验、Token、事务、日志）
│   ├── init_db.sql            # MySQL 建库建表 + 演示数据
│   ├── test_api.py            # 26/26 回归测试
│   ├── verify_demo_data.py    # 演示数据一致性校验（8 项）
│   ├── verify_v3.py           # 服务端新功能回归（34 项）
│   ├── verify_ui_contract.py  # App 读取字段契约测试（48 项）
│   └── build.bat              # 编译脚本
├── esp32_rfid/rfid_esp32.ino  # ESP32 + MFRC522 刷卡签到固件
├── docs/使用说明.md            # 操作手册与验收流程（可读版）
├── HANDOFF.md                 # 本轮改动交接（改了什么 / 为什么 / 怎么验）
└── 使用说明文档.docx           # 使用说明 Word 版（含验收演示流程与 FAQ）
```

## 快速开始

1. 初始化数据库：`mysql -u root -p123456 --default-character-set=utf8mb4 -e "source C:/.../server/init_db.sql"`
2. 编译服务端：运行 `server\build.bat`（自动探测可用的 g++，`-std=c++14`；本机 PATH 中的 MinGW 若为 win32 线程模型会因缺少 `std::thread` 被自动跳过，实际使用 Dev-C++ 自带 TDM g++），运行 `server.exe`（监听 0.0.0.0:8000）
3. 构建鸿蒙 App：`hvigorw assembleHap --mode module -p product=default --no-daemon`，产物 `entry-default-unsigned.hap`
4. 安装运行：`hdc install -r entry-default-unsigned.hap`，模拟器默认服务器地址 `10.0.2.2:8000`
5. 回归测试：`python server\test_api.py`（默认不改动演示数据；如需重置数据加 `--reset`）
   - `python server\verify_demo_data.py 8000` 演示数据一致性
   - `python server\verify_v3.py 8000` 服务端新功能（会创建并清理测试活动）
   - `python server\verify_ui_contract.py 8000` App 读取字段契约

## 接口一览（自主 C++ 服务器）

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| GET | `/api/health` | 公开 | 健康检查（含 MySQL 连通性与服务器时间） |
| POST | `/api/login` | 公开 | 登录签发 Token（失败节流：60 秒内 5 次失败临时拒绝） |
| POST | `/api/register` | 公开 | 成员注册申请（待管理员审批） |
| POST | `/api/signin` | 公开／设备密钥 | ESP32 刷卡签到（可选 `X-Device-Key`） |
| POST | `/api/logout` | 登录 | 注销当前 Token |
| GET | `/api/student/requests` | 管理员 | 待审批注册申请列表 |
| POST | `/api/student/audit` | 管理员 | 注册申请通过／驳回（条件更新防重复） |
| GET | `/api/activity/list` | 登录 | 活动列表（含 `valid_count` / `remaining` / `expired`；支持 `page`/`size` 分页，管理员 `all=1` 含已下线） |
| POST | `/api/activity/add` | 管理员 | 发布活动（时间窗与数值校验） |
| POST | `/api/activity/update` | 管理员 | 编辑活动（允许历史开始时间；上限不得小于有效报名数） |
| POST | `/api/activity/status` | 管理员 | 活动上线／下线（软删除） |
| GET | `/api/signup/list` | 登录 | 报名列表（`status`/`kw`/`activity_id` 筛选 + `page`/`size` 分页；学生强制本人） |
| POST | `/api/signup/add` | 成员 | 报名（`client_id` 幂等、事务锁活动行控容量） |
| POST | `/api/signup/audit` | 管理员 | 审核并累计学时（锁报名行 + 条件更新，只累计一次） |
| POST | `/api/signup/cancel` | 成员 | 撤销本人待审核报名（释放名额） |
| GET | `/api/hours/report` | 登录 | 学时排行 + 认定明细（按角色过滤；下发 `required_hours` / `achieved` / `achieved_count`） |
| POST | `/api/hours/rebuild` | 管理员 | 以已通过报名重建学时汇总 |
| GET | `/api/config/get` | 登录 | 读取系统配置（学时达标线等） |
| POST | `/api/config/set` | 管理员 | 设置学时达标线 `required_hours`（0 表示不设线） |
| GET | `/api/logs` | 管理员 | 实时请求日志（内存环形缓冲；`level=err\|slow`、`method`、`kw` 筛选） |

## 演示账号

| 身份 | 账号 | 口令 | 说明 |
|---|---|---|---|
| 管理员 | admin | admin123 | 账号 + 密码 |
| 普通成员 | 2023001 | 张三 | 学号 + 姓名 |
| 普通成员 | 2023002 | 李铭 | 学号 + 姓名 |
| RFID 卡 | A1B2C3D4 | — | 张三签到卡（扩展） |
| RFID 卡 | E5F60708 | — | 李铭签到卡（扩展） |

## 验收演示流程

报名 → 同步 → 服务端审核 → 学时累计双端一致；服务器实时请求日志；本地 SQLite 可查；MySQL 各表可查。详细步骤见《使用说明文档.docx》。
