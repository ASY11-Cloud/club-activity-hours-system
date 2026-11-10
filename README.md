# 社团活动报名与学时认定系统

题号 86 · HarmonyOS 课程设计（进阶级・系统 · 95 分）

**鸿蒙 App（SQLite 本地库）+ 自主 C++ Web 服务器（服务端 MySQL）+ ESP32 RFID 刷卡签到扩展**

> 版本演进与 v2.0 相对 v1.0 的升级说明见 [`VERSION.md`](VERSION.md)；归档分支：`v1.0`（第一版）、`v2.0`（第二版最终版，同 main）。
> 本轮改动明细、为什么改、验证方式与环境坑，见 [`HANDOFF.md`](HANDOFF.md)。
> 操作步骤与验收演示见 [`docs/使用说明.md`](docs/使用说明.md)（Word 版 `使用说明文档.docx`，与 md 同源，均对应 v5.0）。
>
> **版本归档**：第三版最终版（v3.0）已单独归档为分支 `v3.0` 与标签 `v3.0`（commit `5bcf487`）；第四版归档为分支/标签 `v4.0`；初版 v5.0（预置单社团设计，被判失败）留档于分支/标签 `v5.0-old`，均不随后续演进被覆盖。
>
> **v5.0（当前，重构版）核心变更**：社团像成员一样**注册制**——注册（自设账号/社团名/密码）→ 平台管理员审核 → 获得独立编号；学生可在**社团广场**浏览/搜索社团并**申请加入**，退出需**社团账号审批**（审批时显示申请人已加入的社团供参考），可同时属于多个社团；**活动发布/编辑/上下线收敛为社团账号专属**（平台管理员 403），平台管理员职责收敛为社团注册审核 + 停用/恢复 + 学生注册审核与全量管理；社团账号保留换届、参与范围（仅本社团/全校开放）、成员管理、通知公告、社团维度统计。初版 v5.0 的「预置单社团 + 管理页直接维护归属」设计已被本版取代（留档 `v5.0-old`）。

## 功能总览

- 活动发布：管理员创建活动（名称 / 内容 / 地点 / 时间 / 学时 / 人数上限），支持**本地草稿**保存与一键同步发布到服务器；时间采用**滚轮选择器**（DatePicker + TimePicker），自动校验“结束晚于开始、开始不早于当前”，杜绝非法输入
- 活动报名：普通成员浏览并报名，记录同时写入**本地 SQLite** 与服务器 MySQL，本地/服务端双重幂等去重；容量用 `activity.taken` + **条件 UPDATE 占位**（`WHERE taken < capacity`）实现，锁持有时间从整个事务降到单条语句，并发不超员；**同一成员不得报名时间重叠的两个活动**（服务端返回 409 + 冲突活动名，防止学时双算）；已驳回报名不占名额；剩余名额由服务端统一计算下发
- 报名撤销：待审核报名可由成员本人撤销（释放名额），已通过/已驳回不可撤销；**离线报名落本地后可一键补传**（服务端按 `client_id` 幂等，重试不会重复报名）
- 审核认定：管理员在审核中心“通过 / 驳回”，通过后服务器**事务化自动累计学时**。审核在事务内 `SELECT ... FOR UPDATE` 锁报名行 + 条件更新（`WHERE status=0`）+ 影响行数校验，**并发/重复点击只累计一次**
- 学时报表：成员排行 + 认定明细，**本地 SQLite 统计与服务器 MySQL 统计双端对比**，直接给出「✔ 双端一致 / 差 X 学时」判定，并可**一键校准本地缓存**（按服务器报名记录回填本地）；管理员可一键“重算学时”（以 `signup` 通过记录为唯一事实来源重建 `hours_total`，修复历史漂移）
- 活动生命周期：活动可**下线**（软删除，历史报名与学时保留）；**已结束活动不可报名、不可刷卡认定学时**（原先可对任意历史活动报名）
- 学时达标线：`sys_config.required_hours` 可在 App 内设置，报表每行直接给出「达标 / 距达标 X 学时」结论，并统计达标人数
- 服务器实时日志：每次请求内存日志 + MySQL `request_log` 双写，毫秒级时间戳，管理员在线查看；支持按**级别（失败/慢请求）/ 方法 / 路径关键词**筛选，`request_log` 按 7 天且不超过 20000 条自动裁剪
- 活动编辑：管理员可在原记录上修改标题/内容/地点/时间/学时/人数上限（已报名记录与学时不动，人数上限不得小于有效报名数）
- 列表分页：活动广场滚动到底自动加载下一页（10 条/页），审核中心 20 条/页并可在服务端按状态/活动/关键词筛选
- 活动分类：七大类（思想成长 / 实践实习 / 志愿公益 / 创新创业 / 文体活动 / 社会工作 / 技能特长）归档，广场按类别筛选，活动卡显示类别与已报人数
- 学时规则：`sys_config` 支持"单活动上限"与"类别累计上限"（默认 0 = 不限），审核通过时依次裁剪，结果 0 也算通过并在备注注明；规则变更不影响已认定学时
- 学分预警：`/api/report/warning` 列出未达标学生（学号 / 姓名 / 班级 / 已认定 / 活动数 / 缺口 / 最近认定），按缺口降序，可一键导出
- 现场签到：管理员出示 **60 秒轮换签到码**（HMAC-SHA256 + 启动随机密钥），成员输码签到、签退，按实际在场时长折算学时（0.5 步进、下限 0.5）；与 RFID 刷卡并存，未签退仍按活动全额学时
- 学时导出：报表可按当前标签页（排行 / 明细 / 预警）通过系统文件选择器保存 CSV（UTF-8 BOM），失败回退剪贴板 + 沙箱路径
- 深色模式：`Theme` 颜色全部改为资源 token，`resources/dark` 提供同名校色板，跟随系统深浅色自动切换
- 学时申诉（v4.0）：成员对已通过记录发起申诉；管理员在审核中心"学时申诉"页签通过（可调整 0~活动学时）或驳回；通过后在事务内按明细重算 `hours_total`，全程留痕
- 规则可视化（v4.0）：`GET /api/config/get` 下发七大类 `rules`，`POST /api/config/set` 接受 `rules` 白名单；App 设置页可视化编辑，保存后下一次审核立即生效
- 签到异常检测（v4.0）：`GET /api/report/anomaly` 输出批量签到（10 分钟 ≥5 人）、签到超 24h 未签退、认定学时大于活动学时三类风险，报表页"异常检测"页签展示并可导出
- **社团注册制（v5.0 重构）**：社团像成员一样注册（自设登录账号 + 社团名 + 密码，均唯一性校验），提交后 `status=0` 待审核不能登录；平台管理员在「社团审核」面板通过（分配独立编号 `club.id`）/ 驳回（必填理由），另可停用/恢复；`club.status` 三态（0 待审 / 1 正常 / 2 已驳回 / 3 已停用），审核全程留痕（`reject_reason` + `audited_at`）
- **入社/退社审批（v5.0 重构）**：学生在「社团广场」浏览/搜索社团并申请加入，退出需提交申请；社团账号在用户管理页审批（默认待审列表，**每条附申请人已加入社团名单供参考**）；同意加入 `ON DUPLICATE KEY UPDATE` 入册（退社可复入、原岗位保留）、同意退出置离册（学时保留）；申请判重 409、审批 `WHERE status=0` 条件更新并发恰一次、社长不可退出/被移除；**可见性天然联动**——在册才可见内部活动，退出审批通过即失效；可同时属于多个社团
- **社团账号与换届（v5.0）**：`club` 表承载社团账号与口令，`leader_name / leader_stu_no / leader_since` 为社团对象上的可变三元组；换届接口需输入当前账号密码 + `expect_leader` 乐观并发比对 + 行锁串行化，只追加一条历任记录（在任唯一），**不签发新账号、不重建 Token**，账号/密码/历史活动与学时全部保留
- **活动发布归属社团（v5.0 重构）**：`/api/activity/add|update|status` 仅社团账号可调（平台管理员 403「活动发布归属于社团」），上下线只能操作本社团活动；App 管理面板同步调整——社团账号保留发布入口，平台管理员改为「社团审核」卡片
- **活动参与范围（v5.0）**：发布/编辑可选「仅本社团成员」/「全校开放」；列表按可见性过滤、内部活动带专用标签；**范围校验前置到建记录之前**——外社团学生直接报名 403、用转发签到码签到 403 且不产生报名行与学时、刷卡 403；公开活动引来外社团报名时审核面板标记「外社团」，审核权归活动所属社团
- **成员 / 公告 / 统计（v5.0）**：社团成员按岗位与状态筛选、移除保留学生账号与历史学时（现任社长不可直接移除）；公告支持发布/置顶/撤回与成员未读标记；`/api/stats/club` 单条聚合 SQL 输出社团维度统计，含公开活动带来的外社团参与人数与人次
- 嵌入式扩展：ESP32 + MFRC522 读卡实机刷卡签到，到场即认定学时（已被管理员驳回的报名需先重新报名，刷卡不会绕过审核）；签到状态通过 `checkin` 同步回本地库，成员在「我的报名」与活动详情可直接看到「已刷卡签到」；固件带 WiFi 断线自动重连与同卡 5 秒冷却；可选 `X-Device-Key` 设备密钥，防止局域网内伪造刷卡

## 系统架构

```
鸿蒙 App (HarmonyOS relationalStore 本地库)
   │  HTTP (10.0.2.2:8000 模拟器 / 宿主机局域网 IPv4 真机)
   ▼
自主 C++ Web 服务器 (bind 0.0.0.0:8000, Token 鉴权, 连接池, keep-alive, 事务化报名/学时)
   │
   ▼
MySQL 8.0 (club_system: admin_user / club / club_member / club_leader_history / student / activity / signup / hours_total / announcement / announcement_read / request_log / sys_config)
```

- 三类角色：**平台管理员**（跨社团：发布 / 审核报名与注册 / 用户管理 / 学时全量 / 服务器日志）、**社团管理员**（`club_id>0`，仅本社团：社团主页与换届 / 成员 / 本社团活动与审核 / 公告 / 报表）、**普通成员**（报名 / 我的报名 / 本人学时 / 注销本人账号）。服务端 Token（`role + club_id`）统一校验 + App 页面级守卫；对外 `role` 仍下发 `admin`（兼容旧脚本与 App 的 `isAdmin`），新语义走 `club_id` / `club_name` / `account_type`；登录支持**失败节流**（同账号 60 秒内失败 5 次临时拒绝，防口令暴力猜测），退出登录同时**注销服务端 Token**
- 数据边界：`activity.club_id` 与 `signup.club_id`（报名时快照）决定归属；可见性、可报性、审核权、学时归属全部由服务端 SQL 判定，App 不做权限判定；写接口的 `club_id` 只取 Token，不接受请求体传入
- 数据一致性三层保证：本地唯一 `client_id` 幂等 + 服务端唯一键（`uk_client`、`uk_act_stu`）去重 + 事务化容量 / 学时累计（审核、刷卡均为“锁行 + 条件更新 + 影响行数校验”）
- 账号注销：学生自助（**必须输入本人登录密码**，学号是公开信息不能当凭据）/ 管理员代注销（学号二次确认防误触），事务级联删除报名 + 学时 + 账号，回收全部 Token，审计留痕，学号可复用；错密码连续 5 次触发 60 秒节流
- 失败可解释：所有写操作失败均返回中文原因并弹 toast，登录失效自动清会话（详见 HANDOFF 第 19 节）

## 目录结构

```
chapter03/
├── chapter03/                 # 鸿蒙工程（DevEco Studio 打开此目录）
│   └── entry/src/main/ets/    # 页面与数据层源码
│       ├── common/            # ApiClient / AppConfig / DbHelper / Models / GuardViews / Nav / Theme
│       └── pages/             # 引导页、登录注册、社团注册(ClubRegisterPage)、主界面(活动/管理/我的 Tab)、详情、发布/编辑、
│                              # 审核(报名+注册)、用户管理(含入社退社审批)、学时报表、日志、设置、社团主页(ClubProfilePage)、
│                              # 社团广场(ClubSquarePage)、社团审核(ClubAuditPage)、通知公告(AnnouncementPage)
├── server/                    # 自主 C++ Web 服务器
│   ├── server.cpp             # 全部服务端逻辑（含解析、校验、Token、事务、日志）
│   ├── init_db.sql            # MySQL 建库建表 + 演示数据
│   ├── start_server.bat       # 一键启动（自检 MySQL → server.exe 8000），日常推荐
│   ├── stop_server.bat        # 一键停止（taskkill server.exe，释放 8000 端口）
│   ├── test_api.py            # 33 项回归测试（会真实审核，跑完需还原）
│   ├── test_cancel_api.py     # 注销接口 30 项（含密码确认、失败节流、名额回补，自建自清理）
│   ├── test_p1p2.py           # 并发与权限 38 项（含时间冲突 / 签到码 / 类别上限，自建自清理）
│   ├── verify_demo_data.py    # 演示数据一致性校验（13 项，只读）
│   ├── verify_cancel.py       # 注销后数据一致性（7 项，只读）
│   ├── verify_v3.py           # 服务端新功能回归（45 项）
│   ├── verify_ui_contract.py  # App 读取字段契约测试（53 项）
│   ├── testdata_seed.sql      # 边界测试数据（id≥9000 / 学号 T9xxx，与基线隔离）
│   ├── testdata_clean.sql     # 测试数据清理（幂等，清理后基线复原）
│   ├── verify_test_data.ps1   # 结构/落库/接口/基线 四阶段核验（83 项，无 Python 可用）
│   ├── verify_v4.ps1          # v4.0 验收（45 项：申诉/规则/异常/权限/基线）
│   ├── audit_v4.ps1           # 系统全面测试（103 项：功能/边界/安全/性能/一致性/兼容）
│   ├── verify_club.ps1        # v5.0 社团账号与换届（60 项：含并发恰一次、成员、公告、统计）
│   ├── verify_scope.ps1       # v5.0 活动参与范围（17 项：不可见/403/无学时/外社团报名/冲突）
│   ├── verify_membership.ps1  # v5.0 社团注册/入社退社审批（56 项：注册三态/审核/并发审批恰一次/可见性联动/复入/边界）
│   └── build.bat              # 编译脚本
├── esp32_rfid/rfid_esp32.ino  # ESP32 + MFRC522 刷卡签到固件
├── docs/使用说明.md            # 操作手册与验收流程（可读版，与 docx 同源）
├── docs/数据一致性核验-v3.2.md # 测试数据设计与 83 项核验结果、两处边界缺陷修复记录
├── docs/V4-PLAN.md            # v4.0 目标 / 范围 / 实施步骤 / 验收标准
├── docs/系统测试报告-v4.0.md   # 六维测试范围/验收标准、性能数据、缺陷分级与改进优先级
├── tools/md2docx.ps1          # Markdown → Word（纯 OOXML，不依赖 Word）
├── HANDOFF.md                 # 改动交接（改了什么 / 为什么 / 怎么验）
├── VERSION.md                 # 版本演进（v1.0 → v2.0 → v3.0 → v3.1 → v3.2 → v4.0 → v5.0）
└── 使用说明文档.docx           # 使用说明 Word 版（v5.0，含社团账号 / 换届 / 参与范围 / 成员 / 公告 / 统计章节 与验收 FAQ）
```

## 快速开始

1. 初始化数据库：`mysql -u root -p123456 --default-character-set=utf8mb4 -e "source C:/.../server/init_db.sql"`
2. 编译服务端：运行 `server\build.bat`（自动探测可用的 g++，`-std=c++14`；本机 PATH 中的 MinGW 若为 win32 线程模型会因缺少 `std::thread` 被自动跳过，实际使用 Dev-C++ 自带 TDM g++），运行 `server.exe`（监听 0.0.0.0:8000）
3. 构建鸿蒙 App：`hvigorw assembleHap --mode module -p product=default --no-daemon`，产物 `entry-default-unsigned.hap`
4. 安装运行：`hdc install -r entry-default-unsigned.hap`，模拟器默认服务器地址 `10.0.2.2:8000`
5. 回归测试（**演示前建议全跑一遍**）：
   - `python server\verify_demo_data.py` 演示基线（8 活动 / 19 报名 / 5 人 / 20.5 学时，只读）
   - `python server\verify_cancel.py` 注销后数据一致性（无孤儿 / 汇总相符，只读）
   - `python server\verify_ui_contract.py` App 读取字段契约（53 项，只读）
   - `python server\test_p1p2.py` 并发与权限专项（38 项，越权 / 满员竞态 / 时间冲突 / 签到码 / 类别上限，自建自清理）
   - `python server\test_cancel_api.py` 注销接口全链路（30 项，含名额回补，自建自清理）
   - `python server\test_api.py` 基础回归（**会真实审核 `ptest-audit-1`，跑完需按 HANDOFF 9.6 还原**）
   - `python server\verify_v3.py 8000` 服务端新功能（会创建并清理测试活动）
   - **无 Python 时的数据核验**：依次执行 `testdata_seed.sql` → `verify_test_data.ps1 -Stage schema/seed` → 重启服务端 → `-Stage api` → `testdata_clean.sql` → `-Stage baseline`（83 项，见 `docs/数据一致性核验-v3.2.md`）
   - `powershell -ExecutionPolicy Bypass -File server\verify_v4.ps1` v4.0 验收（45 项：申诉闭环 / 规则读写 / 异常检测 / 越权 / 基线，自建自清理）
   - `powershell -ExecutionPolicy Bypass -File server\audit_v4.ps1` 系统全面测试（103 项：功能 / 边界 / 安全 / 性能 / 一致性 / 兼容，含 p95 与并发指标）
   - `powershell -ExecutionPolicy Bypass -File server\verify_club.ps1` v5.0 社团账号与换届（60 项：含**并发换届恰一次成功**、成员口径、公告、统计；历任社长历史刻意保留）
   - `powershell -ExecutionPolicy Bypass -File server\verify_scope.ps1` v5.0 活动参与范围（17 项：内部活动不可见 / 报名 403 / **输码签到 403 且无报名无学时** / 刷卡 403 / 公开活动外社团报名 / 满员 403 / 跨社团冲突 409）
   - `powershell -ExecutionPolicy Bypass -File server\verify_membership.ps1` v5.0 社团注册与入社退社（56 项：注册三态 / 管理员审核 / **并发审批恰一次** / other_clubs 参考信息 / 可见性联动 / 退出复入 / 社长边界 / 平台管理员发布 403）

## 接口一览（自主 C++ 服务器）

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| GET | `/api/health` | 公开 | 健康检查（`version` 当前 5.0、`db` 为 MySQL 连通性、`time` 为服务器时间） |
| POST | `/api/login` | 公开 | 登录签发 Token（`type=student\|admin\|club`；社团账号下发 `club_id` / `club_name` / `account_type`，对外 `role` 仍为 `admin`；失败节流：60 秒内 5 次失败临时拒绝） |
| POST | `/api/register` | 公开 | 成员注册申请（待管理员审批；可选 `card_no`，卡号全局唯一、自动转大写） |
| POST | `/api/club/register` | 公开 | **社团注册申请**（自设账号/社团名均唯一；提交后 `status=0` 待审核不能登录） |
| GET | `/api/club/square` | 登录 | **社团广场**：全部正常社团 + 成员/活动计数；学生额外返回 `my_status`（0 未加入 / 1 在册 / 2 加入审核中 / 3 被驳回 / 4 已退出 / 5 退出审核中） |
| POST | `/api/club/join` | 成员 | **申请加入社团**（同社团同类型待审判重 409；先锁学生行） |
| POST | `/api/club/leave` | 成员 | **申请退出社团**（在册才可；社长 400；审批通过前仍是成员） |
| POST | `/api/signin` | 公开／设备密钥 | ESP32 刷卡签到（可选 `X-Device-Key`） |
| POST | `/api/logout` | 登录 | 注销当前 Token |
| GET | `/api/student/requests` | 管理员 | 待审批注册申请列表 |
| POST | `/api/student/audit` | 管理员 | 注册申请通过／驳回（条件更新防重复；通过时可带 `card_no` 补绑 RFID 卡） |
| POST | `/api/student/password` | 成员 | 修改本人登录密码（校验原密码，存 `sha256i:` 迭代加盐哈希） |
| POST | `/api/student/reset_pwd` | 管理员 | 重置指定成员登录密码（成员忘记密码时使用） |
| GET | `/api/student/impact` | 登录 | 注销影响面预览（学生查自己；管理员带 `stu_no`） |
| POST | `/api/student/cancel` | 成员 | 学生自助注销（`confirm_pwd` 输本人登录密码；事务内校验，错 5 次节流 60 秒） |
| POST | `/api/student/delete` | 管理员 | 管理员注销学生（`stu_no` + `confirm_stu_no` 一致才执行，防误触） |
| POST | `/api/admin/password` | 管理员 | 修改管理员口令（校验原口令，存 `sha256i:` 迭代加盐哈希） |
| GET | `/api/activity/list` | 登录 | 活动列表（含 `valid_count` / `remaining` / `expired` / `category` / `taken` / **`join_scope`**；按可见性过滤：学生 = 全校开放 + 本人社团内部活动，社团管理员 = 本社团，平台管理员 = 全部；支持 `page`/`size` 分页，管理员 `all=1` 含已下线） |
| POST | `/api/activity/add` | **社团账号** | 发布活动（时间窗与数值校验；`category` 白名单，非法值回落 `sports`；**`join_scope` 白名单 `club`/`all`**；平台管理员 403「活动发布归属于社团」） |
| POST | `/api/activity/update` | **社团账号** | 编辑活动（仅本社团；允许历史开始时间；上限不得小于有效报名数；`join_scope` 未传递时保留原值，返回 `outsider_count` 供提示） |
| POST | `/api/activity/status` | **社团账号** | 活动上线／下线（软删除；只能操作本社团活动） |
| GET | `/api/activity/signin_code?activity_id=` | 管理员 | 当前 60 秒签到码（`code` / `expire_in` / `window`） |
| POST | `/api/signin/code` | 成员 | `{activity_id, code}` 输码签到（宽限前后 60 秒；无报名自动建并通过） |
| POST | `/api/signin/out` | 成员 | `{activity_id}` 签退，按在场时长折算学时 |
| GET | `/api/signup/list` | 登录 | 报名列表（`status`/`kw`/`activity_id` 筛选 + `page`/`size` 分页；学生强制本人） |
| POST | `/api/signup/add` | 成员 | 报名（`client_id` 幂等；先锁学生行校验时间冲突，再 `taken` 条件 UPDATE 占位控容量） |
| POST | `/api/signup/audit` | 管理员 | 审核并累计学时（锁报名行 + 条件更新；按类别上限裁剪，返回 `hours` / `hours_capped`） |
| POST | `/api/signup/cancel` | 成员 | 撤销本人待审核报名（释放名额） |
| POST | `/api/appeal/add` | 成员 | 对本人已通过报名发起学时申诉（`signup_id` + `reason`，同报名仅一条待处理） |
| GET | `/api/appeal/list` | 登录 | 申诉列表（学生本人 / 管理员全量，支持 `status`、`stu_no`、分页） |
| POST | `/api/appeal/audit` | 管理员 | 处理申诉：`pass` 可调整 `hours`（0~活动学时）并重算汇总；`reject` 需理由 |
| GET | `/api/hours/report` | 登录 | 学时排行 + 认定明细 + 分类汇总（`by_category`，图表数据源）；按角色过滤，本人行 `is_me=1`；下发 `required_hours` / `achieved` / `achieved_count` |
| GET | `/api/report/warning` | 管理员 | 未达标学生名单（`stu_no` / `name` / `dept` / `total_hours` / `sign_count` / `gap` / `last_activity_at`），按缺口降序 |
| GET | `/api/report/anomaly` | 管理员 | 签到异常：`burst`（10 分钟 ≥5 人）/ `not_signed_out`（>24h）/ `hours_exceed`（学时超活动） |
| POST | `/api/hours/rebuild` | 管理员 | 以已通过报名重建学时汇总 |
| GET | `/api/config/get` | 登录 | 读取系统配置：`required_hours` + 七大类 `rules`（`max_activity` / `max_total`，0=不限） |
| POST | `/api/config/set` | 管理员 | 设置 `required_hours` 与/或 `rules`（类别白名单、数值 0~999，非法项整体拒绝） |
| GET | `/api/logs` | 管理员 | 实时请求日志（内存环形缓冲；`level=err\|slow`、`method`、`kw` 筛选） |
| GET | `/api/club/info` | 社团账号 | 社团信息 + 现任社长与在任天数 + 成员/活动/报名/学时统计（`club_id` 只取 Token） |
| POST | `/api/club/leader` | 社团账号 | 换届 `{new_name,new_stu_no,confirm_pwd,reason,expect_leader}`：行锁串行化 + 密码确认 + 乐观并发（冲突 409）+ 密码错误节流 429 |
| GET | `/api/club/leaders` | 社团账号 | 历任社长（分页，`is_current` 标记在任；只追加不覆盖） |
| POST | `/api/club/password` | 社团账号 | 修改社团账号口令（校验原口令） |
| GET | `/api/club/members` | 社团账号 | 本社团成员（`role`/`status`/`kw` 筛选 + 岗位计数） |
| POST | `/api/club/member/remove` | 社团账号 | 移除成员（置 `status=0`，保留学生账号与历史学时；现任社长返回 400） |
| GET | `/api/club/requests` | 社团账号 | **入社/退社申请列表**（默认待审；`type`/`status`/分页；每条附 `other_clubs` 申请人已加入社团） |
| POST | `/api/club/request/audit` | 社团账号 | **审批申请** `{request_id, approve, reply}`：同意加入即入册（复入保留原岗位）/ 同意退出置离册；驳回必填理由；条件更新并发恰一次，重复审批 409 |
| GET | `/api/admin/clubs` | 平台管理员 | **全量社团列表**（`status`/`kw`/分页 + `pending_count` 待审数） |
| POST | `/api/admin/club/audit` | 平台管理员 | **社团审核** `{club_id, action, reason}`：approve 通过 / reject 驳回（必填理由）/ disable 停用 / enable 恢复；状态机条件更新，重复操作 409 |
| GET | `/api/announcement/list` | 登录 | 公告列表（学生=本人所属社团已发布；社团管理员=本社团全部；含 `unread_count` / `is_read`） |
| POST | `/api/announcement/add` | 管理员 | 发布公告（`club_id` 取 Token，平台管理员可显式指定；支持 `top_flag` 置顶） |
| POST | `/api/announcement/status` | 管理员 | 撤回/恢复公告（`ann_id` + `status`；跨社团 403） |
| POST | `/api/announcement/read` | 成员 | 标记公告已读（幂等写入 `announcement_read`） |
| GET | `/api/stats/club` | 管理员 | 社团维度统计：成员/活动（内部·公开）/报名/通过率/学时/学时分布/热门活动/**外社团参与人数与人次** |

## 演示账号

| 身份 | 账号 | 口令 | 说明 |
|---|---|---|---|
| 平台管理员 | admin | admin123 | 账号 + 密码（`club_id=0`，跨社团；社团注册审核 / 学生注册审核 / 全量管理） |
| 社团管理员 | club | club123 | v5.0：社团账号（计算机协会，`club_id=1`），登录页身份选"管理员" |
| 社团管理员 | ball | club123 | v5.0：社团账号（篮球协会，`club_id=2`，已审核） |
| 待审社团 | tea | — | 茶艺社（`club_id=3`，`status=0` 待审核，供演示平台管理员审核动作） |
| 普通成员 | 2023001 | 123456 | 学号 + 密码（张三，初始密码 123456） |
| 普通成员 | 2023002 | 123456 | 学号 + 密码（李铭，初始密码 123456） |
| 普通成员 | 2023006 | 123456 | 学号 + 密码（周凯，无社团，有一条待审加入申请，演示广场/审批） |
| RFID 卡 | A1B2C3D4 | — | 张三签到卡（扩展） |
| RFID 卡 | E5F60708 | — | 李铭签到卡（扩展） |

## 验收演示流程

报名 → 同步 → 服务端审核 → 学时累计双端一致；服务器实时请求日志；本地 SQLite 可查；MySQL 各表可查。详细步骤见《使用说明文档.docx》。
