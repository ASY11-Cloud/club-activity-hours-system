# HANDOFF — 本轮改动交接

> 给接手这个项目的 AI / 评审者看的。**这个文件替代了原先的《修改说明》文档**（md 与 docx 已删除）。
> 只写"改了什么、为什么改、在哪、怎么验"，不重复《使用说明》。
> 最后更新：2026-10-28，改动后代码为当前仓库唯一事实来源。

---

## 1. 项目是什么

课程设计题号 86「社团活动报名与学时认定系统」。三端：

| 端 | 技术 | 位置 |
|---|---|---|
| 鸿蒙 App | ArkTS / ArkUI，本地 SQLite（relationalStore）存草稿与报名缓存 | `chapter03/`（DevEco 打开此目录） |
| 自研 Web 服务器 | C++ / Winsock 手写 HTTP，无任何 Web 框架，MySQL 8.0 | `server/server.cpp`（单文件约 2100 行） |
| 刷卡终端 | ESP32 + MFRC522，HTTP 上报卡号 | `esp32_rfid/rfid_esp32.ino` |

数据流：App 报名先落本地 SQLite → 同步服务器（`client_id` 幂等）→ 管理员审核 → 通过时事务内累计学时 → 报表 / ESP32 刷卡签到。

演示数据：8 个活动、19 条报名、5 人共 20.5 学时（榜首李铭 5.5），达标线 20。

---

## 2. 六批改动总览

| 批次 | 目标 | 主要动作 |
|---|---|---|
| 一 | 确定性 Bug | 补 seed 缺失学生（外键报错）、审核页学时显示 0、编译工具链文档纠错 |
| 二 | 功能完善 | 报名并发超员、容量口径、刷卡绕过审核、localtime 线程安全、连接超时、Token 清理、build.bat 重写、测试脚本去破坏性 |
| 三 | 设计缺陷 | 审核/刷卡原子化、活动生命周期、离线重试、学时可对账、报名可撤销、退出即失效、登录节流、RFID 设备密钥 |
| 四 | 文档 | 曾产出修改说明（**已按需求删除**，内容归档进本文件） |
| 五 | UI 交互完整性 | 12 处"界面有、点了没用"的断点（含 1 处致命：详情页永远打不开） |
| 六 | 工程化 + 交互补全 | 口令摘要、连接池、分页、活动编辑、日志治理、达标线、keep-alive；草稿载入、编辑页、报表导出、日志筛选、引导页接入 |

---

## 3. 服务端 `server/server.cpp`

锚点用函数名定位（行号会漂移）。

### 3.1 安全

| 改动 | 位置 | 为什么 |
|---|---|---|
| 管理员口令改 `sha256("club-system::" + 明文)` | `pwdHash` / `pwdVerify` / `pwdIsHashed`（≈161） | 原来明文入库且拼进 SQL 比较 |
| 历史明文登录成功后自动改写为摘要 | `handleLogin`（≈715，含 `UPDATE admin_user SET password=...`） | 老库不停机升级 |
| 登录失败节流：同账号 60 秒 5 次 → 429 | `LOGIN_FAIL_MAX` / `LOGIN_FAIL_WINDOW_MS`（≈72）、`loginFailAdd` | 防口令爆破 |
| 退出登录注销服务端 Token | `/api/logout`，签发时顺带清理过期 Token | 原来退出只清本地 |
| RFID 设备密钥（可选） | `handleSignin`，`CLUB_DEVICE_KEY` 或启动参数 5，校验 `X-Device-Key` | 局域网内任意设备都能伪造刷卡 |
| 请求体上限 64KB、超限先读完再回 413 | `handleClient` | 避免对端读不到响应（RST） |

### 3.2 并发与数据一致性（这是本项目最要紧的部分）

| 改动 | 位置 | 做法 |
|---|---|---|
| 报名不超员 | `handleSignupAdd`（≈1095） | 事务内 `SELECT id FROM activity WHERE id=? FOR UPDATE` 锁活动行，容量按 `status<>2` 计数 |
| 审核只生效一次 | `handleSignupAudit`（≈1267） | 锁报名行 + `UPDATE ... WHERE status=0` + `affected_rows==1`，冲突回 409；学时只在影响行数为 1 时累加 |
| 刷卡不重复签到 | `handleSignin`（≈1542） | 同样条件化更新；已驳回报名直接 403（原来会"刷卡即转通过"）；无报名分支用 `affected_rows==1` 判断"是否真新建" |
| 撤销报名释放名额 | `handleSignupCancel`（≈1507） | 仅本人、仅待审核 |
| 活动生命周期 | `handleActivityStatus`（≈1477） | 上下线软删除；已下线不出现在成员列表，不可报名/刷卡 |
| 学时对账 | `handleHoursRebuild`（≈1448） | 以 `signup.status=1` 为唯一事实来源重建 `hours_total` |
| 时间解析线程安全 | `localTimeSafe()`（mutex + 副本） | 替换 3 处裸 `localtime` |

### 3.3 接口能力

| 改动 | 位置 | 说明 |
|---|---|---|
| 列表分页 | `handleActivityList`（≈901）、`handleSignupList`（≈1184） | `page`/`size`（≤200），下发 `total/page/size/has_more`；`size=0` 保留取全量旧行为 |
| 服务端筛选 | `handleSignupList` | `status` / `kw`（姓名、学号、活动名）/ `activity_id`，`COUNT(*)` 与数据同条件 |
| 活动编辑 | `handleActivityUpdate`（≈1058） | 允许历史开始时间；`capacity` 不得小于有效报名数，否则 400 并回实际人数 |
| 学时达标线 | `sys_config` 表 + `handleConfigGet`（≈1409）/ `handleConfigSet`（≈1429） | `required_hours ∈ [0,999]`，0 = 不设线；报表下发 `required_hours/achieved/achieved_count/total_hours` |
| 活动列表补字段 | `handleActivityList` | `valid_count`（不含已驳回）、`remaining`、`expired`、`status`，App 不再自己算 |

### 3.4 运维

| 改动 | 位置 | 说明 |
|---|---|---|
| MySQL 连接池 | `dbAcquire` / `dbRelease`，`DB_POOL_MAX=16`（≈456） | `mysql_ping` 失败即丢弃重建，取用超时回退新建，退出统一释放 |
| 日志筛选 | `handleLogs`（≈1648） | `level=err\|slow`、`method`、`kw`，下发 `matched` |
| 日志表裁剪 | `cleanupOldLogs`（≈2040），`LOG_KEEP_ROWS=20000` | 保留 7 天且总量 ≤20000，配 `idx_req_time` |
| keep-alive | `handleClient`（≈1989，循环上限 128，空闲 10s） | 响应头与实际行为一致；HTTP/1.0 默认仍 close |
| 收发超时 | `handleClient` | `SO_RCVTIMEO` / `SO_SNDTIMEO` 各 10s |

---

## 4. 数据库

`server/init_db.sql`

- `admin_user.password` 长度 50 → 100，初始值写 sha256 摘要（不再是 `admin123` 明文）
- 新增 `sys_config(cfg_key, cfg_value)` 表，默认 `required_hours=20`
- `request_log` 增加 `idx_req_time` 索引与说明注释

`server/seed_demo_data.sql`

- 补上缺失的学生 2023004 赵磊。原来全新库执行会因 `fk_signup_student` 外键失败（有报名、无学生）

---

## 5. App（`chapter03/entry/src/main/ets/`）

公共层：

| 文件 | 改动 |
|---|---|
| `common/Models.ets` | `SignupInfo.activity_hours`（审核页学时显示 0 的修复）；`ActivityInfo` 增 `valid_count/remaining/expired/status`；`HoursRow.achieved`；工具函数 `boolOf/numOf/strOf/dataOf/totalOf/hasMoreOf/toDate/csvCell` |
| `common/ApiClient.ets` | 401 统一转「登录已失效，请退出后在首页重新登录」，不再裸抛 HTTP 401 |
| `common/DbHelper.ets` | 新增 `upsertSignupFromServer`（服务端为准回写本地，消掉 RFID 双 `client_id` 造成的重复行）、`getDraft` / `updateDraft`（草稿回填后更新而非新增）、`localAllHours` / `localAllCount`（管理员本地卡全量） |

页面层：

| 文件 | 改动 |
|---|---|
| `pages/MainPage.ets` | **致命修复**：跳详情页由 `?id=` 改为 `params: { activity_id }` 对象传参；`onPageShow` 未登录守卫；管理员隐藏「我的报名」；加「系统介绍」入口 |
| `pages/ActivityDetailPage.ets` | 兼容 `activity_id` / `id` 两键并 `Number()` 归一；报名状态以 `/api/signup/list?activity_id=` 为准并回写本地；管理员按钮按 `status` 切「下线 / 恢复上线」；加「编辑活动」；报名成功后重拉活动刷新名额 |
| `pages/ActivityListPage.ets` | 10 条/页 + `List.onReachEnd` 触底加载；顶部「共 N 个，已加载 M 个」；底部加载态三态文案 |
| `pages/ActivityPublishPage.ets` | 草稿「载入表单」进入编辑态（保存走 UPDATE）；「已发布活动（含已下线）」管理区可上下线、可进编辑；草稿删除二次确认 |
| `pages/ActivityEditPage.ets` | **新增**，回填当前值调 `/api/activity/update`，本地先校验（含上限 ≥ 有效报名数） |
| `pages/AuditPage.ets` | 状态 / 活动下拉（含已下线）/ 关键词三项**服务端**筛选 + 20 条/页翻页；审核后重载当前页，页空则回退一页；通过按钮学时用 `activity_hours` |
| `pages/MySignupPage.ets` | 未同步记录自动补传 + 「立即补传」；「撤销报名」；本地与服务器状态不一致时以服务端覆盖 |
| `pages/HoursReportPage.ets` | 管理员可设达标线并即时重算达标人数；排行显示「达标 / 距达标 X 学时」；CSV 导出（写沙箱 `filesDir` + 复制到剪贴板）；管理员「重算学时」；管理员本地卡改全量统计 |
| `pages/ServerLogPage.ets` | 全部 / 失败 / 慢请求 + ALL / GET / POST + 路径关键词筛选；慢请求标「慢」 |
| `pages/LoginPage.ets` | 底部加「去注册」「服务器设置」 |
| `pages/SettingsPage.ets` | 退出登录先调 `/api/logout` 再 `replaceUrl(Index)` |
| `pages/Index.ets` | 加「系统介绍」入口（LandingPage 此前是无入口死页） |
| `pages/LandingPage.ets` | 展示服务器在线状态、角色功能、验收流程 |
| `resources/base/profile/main_pages.json` | 注册 `pages/ActivityEditPage` |

ESP32：`esp32_rfid/rfid_esp32.ino` 增加可选 `DEVICE_KEY`，非空时随请求带 `X-Device-Key`，与服务端 `CLUB_DEVICE_KEY` 对应。

---

## 6. 本轮删除的文件（别再找它们）

| 路径 | 原因 |
|---|---|
| `docs/修改说明.md`、`docs/修改说明文档.docx` | 原为让第三方 AI 了解改动而写，已被本文件取代 |
| `output/` 整个目录 | Word 生成的中间产物（`md2html*.py`、`stage2/*.html`） |
| `server/server_old_20261028.exe.bak` | 旧版可执行备份 |
| `server/.hvigor/` | 误放在 server 下的鸿蒙构建日志 |
| `server/test_register.py`、`verify_fixes.py`、`verify_wb_server.py` | 早期一次性验证脚本，能力已被下面四个覆盖 |

保留的可执行验证脚本：

| 脚本 | 断言数 | 作用 |
|---|---|---|
| `server/test_api.py` | 26 | 全流程验收（登录/越权/报名-审核-学时/日志/RFID），`--reset` 才会重置数据；**会真实写入，见第 9 节** |
| `server/verify_demo_data.py` | 8 | 演示数据一致性（8 活动 / 19 报名 / 5 人 20.5 学时 / 3 条待审注册），只读 |
| `server/verify_v3.py` | 34 | 服务端新能力（摘要登录、分页、编辑、达标线、日志、keep-alive），只读+自建自清测试活动 |
| `server/verify_ui_contract.py` | 48 | App 读的字段服务端是否真有、语义是否正确；含越权与容量负向用例，跑完自动还原 |

---

## 7. 接口变化

新增：

```
POST /api/activity/update   编辑活动（管理员）
POST /api/activity/status   上线/下线（管理员）
POST /api/signup/cancel     撤销本人待审核报名（成员）
POST /api/hours/rebuild     以已通过报名重建学时（管理员）
POST /api/logout            注销 Token
GET  /api/config/get        读配置（登录）
POST /api/config/set        设达标线（管理员）
```

扩展（向后兼容，不传新参数行为不变）：

```
GET /api/activity/list    + page/size/total/has_more、all=1（仅 admin 含已下线）、valid_count/remaining/expired/status
GET /api/signup/list      + page/size/total/has_more、status/kw/activity_id、activity_hours
GET /api/hours/report     + required_hours/achieved/achieved_count/total_hours
GET /api/logs             + level/method/kw/matched
```

完整接口表见 `README.md`「接口一览」。

---

## 8. 怎么验证（现在是干净的）

```bash
# 服务端在 8000 端口运行: server\server.exe 8000 root 123456 127.0.0.1
python server\verify_demo_data.py 8000        # 8 通过, 0 失败（只读）
python server\verify_v3.py 8000               # 34 通过, 0 失败（跑完需手动删测试活动, 见 9.5）
python server\verify_ui_contract.py 8000      # 48 通过, 0 失败（跑完自动还原）
python server\test_api.py                     # 26 通过（会写入，跑完按第 9.6 节还原）
```

实测结论（2026-10-28）：

- 服务端 `TDM g++ 4.9.2 -std=c++14 -O2 -Wall` 编译 **零警告**
- 三套只读回归 **8/8 + 34/34 + 48/48**，跑完演示数据仍为 8 活动 / 19 报名 / 20.5 学时 / 达标线 20
- `test_api.py` **26/26**，但会把 `ptest-audit-1` 审成通过（张三 +2.0 学时），按 9.6 节两条 SQL 可还原
- `hvigorw assembleHap` **BUILD SUCCESSFUL**，产物 `chapter03/entry/build/default/outputs/default/entry-default-unsigned.hap`
- 并发实测：3 个请求同时审核同一条报名 → 1 成功 + 2 个「该记录已审核」，学时只 +1.5

---

## 9. 接手必看的环境坑

1. **编译器**：唯一能编过的是 Dev-C++ 自带 **TDM g++ 4.9.2 + `-std=c++14`**。`C:\Program Files\mingw64` 的 6.3.0 是 win32 线程模型，缺 `std::thread`，c++11/c++17 都编不过。
2. **`build.bat` 必须 GBK 编码 + CRLF 换行**，否则中文注释会让 cmd 解析异常。
3. **DevEco 在 `D:\HuaWei\DevEco Studio`**，构建要 `export DEVECO_SDK_HOME="D:\HuaWei\DevEco Studio\sdk"`，并用其自带 node 跑 `hvigorw.js`。
4. **学生登录口径已于 §24 改为「学号 + 密码」**（初始密码 `123456`），管理员是「账号 + 密码」。写测试时最容易搞错（旧脚本里传姓名的写法已全部替换）。
5. **`verify_v3.py` 会留下测试活动**（`id` 递增、标题含"历史活动"或 `v3 `），跑完请清理：
   ```sql
   DELETE FROM activity WHERE title LIKE 'v3 %' OR title = '历史活动';
   ```
   否则 `verify_demo_data.py` 的"活动列表 = 8 个"会失败。
6. **`test_api.py` 会真实写入**：它会审核 `client_id='ptest-audit-1'` 这条报名，使张三学时 +2.0。它不再按"学号下第一条待审"取记录（旧写法会误伤 seed 里的演示报名）。跑完要还原演示数据，执行：
   ```sql
   UPDATE signup SET status=0, hours=0, audited_at=NULL WHERE client_id='ptest-audit-1';
   UPDATE hours_total SET total_hours=4.5, sign_count=2 WHERE stu_no='2023001';
   ```
   还原后 `verify_demo_data.py` 应为 8/8（总学时 20.5，榜首李铭 5.5）。
7. **ArkTS 路由传参**用 `router.pushUrl({ url, params })` 的对象形式；拼 `?id=` 在 `getParams()` 里读不到（这正是第五批修掉的致命 bug）。
8. `test_api.py` 以前会重置数据，现在必须显式 `--reset`；但即使不加，它仍会写入第 6 条所述的那一条审核。

---

## 10. 已知取舍（有意不做，非遗漏）

- HTTP 明文、无 HTTPS：自研服务器在课程范围内可接受，生产需前置 TLS。
- 无学期维度：学时是累计值，用可配置达标线代替学期上限。
- 活动只能下线不能物理删除：保留报名与学时溯源，避免误删导致报表断链。
- 日志表按时间+条数裁剪，不做归档表。

---

## 11. v2.2 UI 架构修复（2026-10-28，接手前请先读这节）

> 本轮由接手方（豆包 MainAgent）基于第 5 节之后的磁盘代码做了一次**只读审查 + 架构/UI 修复**，
> 修复范围全部在 App 端（`chapter03/entry/src/main/ets/`），**未改服务端与数据库**。

### 11.1 修复的架构问题（导航）

| 问题 | 修复 |
|---|---|
| 冷启动仍进 `pages/Index`（v1.0 旧首页），LandingPage 引导页从未接入口 | `EntryAbility` 改为 `loadContent('pages/LandingPage')` |
| Index 与 MainPage TabBar 功能重复（"删主页 Tab"没删干净） | **删除 `pages/Index.ets`**，`main_pages.json` 同步移除；全工程无 `pages/Index` 引用 |
| LandingPage 被当"系统介绍"二级页，语义错位 | LandingPage 恢复为唯一启动引导页；已登录按钮文案改「进入主界面 ›」；「我的 → 系统介绍」入口保留（进入后回到主界面形成闭环） |
| 登录/退出两套根页面 | 所有退出登录（MainPage、SettingsPage）统一 `replaceUrl('pages/LandingPage')`；登录成功仍 `replaceUrl('pages/MainPage')` |
| 活动广场两套实现（MainPage 内嵌列表 vs ActivityListPage 独立页） | **删除 `pages/ActivityListPage.ets`**，分页（10 条/页）+ 触底加载 + 下拉刷新（Refresh）+ 底部三态文案全部并入 MainPage 活动 Tab；发布页顶栏的「活动广场」跳转按钮删除 |

### 11.2 权限与角色

| 问题 | 修复 |
|---|---|
| 7 个页面的守卫样式/按钮分裂（去登录 vs 返回首页，跳转不一） | 新增 `common/GuardViews.ets`：`LoginGuardView`（未登录→去登录→replace 引导页）/ `AdminGuardView`（非管理员→返回）；ActivityDetail/MySignup/HoursReport 用登录守卫，Audit/ServerLog/Publish/Edit 用管理员守卫，文案保留原语义 |
| 「我的」页"管理员功能"与「管理」Tab 四卡重复 | 删除 MainPage `profileView` 中的"管理员功能"区块（管理 Tab 已覆盖） |
| 管理员进「我的报名」显示空列表 | MySignupPage 管理员空态改为"管理员账号无报名记录 / 成员报名请前往审核中心" |

### 11.3 数据口径与细节

| 问题 | 修复 |
|---|---|
| 学时报表本地卡"通过 N 条"统计的是**全部**本地记录（含待审核/驳回） | `DbHelper` 新增 `localPassedCount` / `localAllPassedCount`（仅 status=1），HoursReportPage 改用该口径，与本地学时统计一致 |
| 学时报表管理员态顶部三行工具信息过载 | 达标线 + 重算收纳为一张"管理员设置"白卡（分割线分行）；导出 CSV 独立一行 |
| 注册成功页"注册申请已提交!"标题与 msg 重复显示 | 成功 msg 去掉重复标题前缀 |
| 顶栏规格不统一 | 统一：返回 14px `padding(right:10)`、标题 18px Bold、二级页 `top:12 bottom:8`；ActivityDetailPage 标题 16→18 |
| TabBar 选中态无视觉反馈 | 选中项加浅蓝胶囊背景 `#EAF1FF` + 圆角 16 |

### 11.4 有意未改（说明原因，非遗漏）

- **活动时间两级弹窗（日期→时间）保留**：已是滚轮 + 起止合法性校验（开始防过去、结束不早于开始自动纠正），`DatePickerDialog.showTime` 单步弹窗存在 API 版本兼容风险，未引入。
- **ActivityDetailPage 每次返回全量拉活动列表保留**：无单活动查询接口，活动量小（9 条），`onPageShow` 已判空，性能影响可忽略。

### 11.5 验证

```bash
# 构建（DevEco 自带工具链，工程根下执行）
set DEVECO_SDK_HOME=D:\HuaWei\DevEco Studio\sdk
D:\HuaWei\DevEco Studio\tools\hvigor\bin\hvigorw.bat assembleHap --mode module -p product=default --no-daemon
# => BUILD SUCCESSFUL（33 tasks；0 ERROR，仅历史 deprecated 类 WARN）
# 产物 chapter03/entry/build/default/outputs/default/entry-default-unsigned.hap（4.53 MB）
```

- 页面文件 12 个与 `main_pages.json` 12 个注册项一一对应，无悬空引用。
- 未动：`server/server.cpp`、SQL 脚本、ESP32 固件、README；服务端回归脚本（`verify_demo_data.py` / `verify_v3.py` / `verify_ui_contract.py` / `test_api.py`）均未受影响。
- ~~遗留：GitHub `server/server.cpp` 与磁盘 SHA256 不一致~~（经 v2.3 复核不成立，见 12.1）

---

## 12. v2.3 复查：对第 11 节（豆包 UI 改动）的验收与本轮修复

> 本节由复核方在豆包提交 v2.2 后逐项核对写入。**第 11 节保留原文**，问题与纠正在此说明。

### 12.1 第 11 节的声明逐项核对

| 声明 | 核对结果 |
|---|---|
| 删除 `pages/Index.ets`、`pages/ActivityListPage.ets` | ✅ 文件已不存在；`main_pages.json` 12 项与 12 个页面文件一一对应；全工程无 `pages/Index`、`ActivityListPage` 引用（仅 MainPage 头部注释提及历史） |
| `EntryAbility` 改为 `loadContent('pages/LandingPage')` | ✅ 确认 |
| 新增 `common/GuardViews.ets` 并在 7 个页面替换守卫 | ✅ ActivityDetail / MySignup / HoursReport 用 LoginGuardView；Audit / ServerLog / Publish / Edit 用 AdminGuardView |
| `DbHelper` 新增 `localPassedCount` / `localAllPassedCount` 且报表改用 | ✅ 两个方法均按 `status=1` 统计，HoursReportPage 已改调用 |
| 注册成功页标题与 msg 重复 | ✅ `注册申请已提交!` 仅在 `done=true` 时渲染，msg 已改为说明文案 |
| BUILD SUCCESSFUL | ✅ 复跑一致（`16 executed / 17 up-to-date`，0 ERROR） |
| 「GitHub `server/server.cpp` 与磁盘 SHA256 不一致，差 74 字节」 | ❌ **该说法不成立**：当前目录不是 git 仓库（无 `.git`、无 remote），不存在可比的远端版本。属误判，已忽略 |

结论：第 11 节的页面删减、守卫收敛、学时口径修复方向正确，功能未见丢失（注册审批仍在审核中心 mode=1，活动上下线/编辑仍在发布页管理区）。

### 12.2 复查中发现并修复的问题

| # | 问题 | 影响 | 修复 |
|---|---|---|---|
| 1 | **路由栈膨胀**：LandingPage 既是冷启动根页，又被「我的 → 系统介绍」以 `pushUrl` 打开；其 `enter()` 用 `replaceUrl` 进 MainPage，会叠出两个 MainPage 实例 | 返回键回到旧实例、状态错乱；反复进出后栈越来越深 | 新增 `common/Nav.ets`：`resetTo()` = `router.clear()` + `replaceUrl`。登录成功、退出登录、未登录守卫、系统介绍返回共 6 处改用 |
| 2 | **401 假登录**：Token 失效后仅提示文案，本地 `token` 未清空 | 界面仍显示「已登录」，点任何功能都失败，用户不知道要退出 | `ApiClient` 收到 401 且本地有 token 时先 `AppConfig.logout()`，提示改为「已清除本地登录状态」 |
| 3 | **分页页码跳页**：`loadMore` 先 `actPage+1` 再请求，失败时页码已前进 | 断网后重试会跳过整页活动 | 页码改为**请求成功后**才推进；`loading` 中被吞掉的刷新同时收起下拉圈（否则一直转） |
| 4 | **满员后本人重报被拒**：报名事务先做容量检查，`cnt>=cap` 直接 403，未判断该生是否已在名单内 | 活动满员后，已报名学生重复点击/网络重试会看到「activity full」，误以为报名失败 | 事务内加锁后先查该生有效报名（`already`），已在名单内则跳过容量检查与插入后复检 |
| 5 | **重复报名清空审核备注**：`ON DUPLICATE KEY UPDATE ... remark=''` 无条件清 | 已通过记录再次报名，管理员审核意见被抹掉 | 改为 `remark=IF(status=2,'',remark),status=IF(status=2,0,status)`，把 remark 放在 status 之前求值（只有驳回后重报才清） |
| 6 | **设置页测试连接测旧地址**：`testConn` 直接用已保存的 `serverBase` | 改完 IP 直接点「测试连接」测的是旧地址，误判连接失败；端口可填非法值 | `save()` 增加校验（地址非空、不含 `://` 与空格，端口 1~65535 整数），`testConn` 先 `await save()` 再探测 |
| 7 | **契约测试与数据耦合**：用写死的 `capacity=2` 测「上限 ≥ 有效报名数可保存」 | 活动 1 报名数一变（本次变为 3）该用例必失败 | 改为 `target['valid_count'] + 1`，并保留还原后的容量断言 |

### 12.3 文档同步

- `docs/使用说明.md`：5.1 改为「冷启动进引导页」；5.2 由「首页」改写为「引导页 + 主界面 TabBar 三 Tab 表」；5.3 明确活动广场是主界面第一个 Tab（无独立页）；5.9 补充地址校验与 401 自动清会话；验收流程第 1 步同步新路径。
- `README.md`：`pages/` 目录说明改为「引导页、登录注册、主界面 Tab、详情、发布/编辑、审核、学时报表、日志、设置」，`common/` 补 `GuardViews`、`Nav`。

### 12.4 验证（本轮实测）

```bash
# 服务端（8000 端口已换成含修复的新 exe）
python server/verify_demo_data.py 8000     # 8 通过 / 0 失败
python server/verify_v3.py 8000            # 34 通过 / 0 失败
python server/verify_ui_contract.py 8000   # 48 通过 / 0 失败
python server/test_api.py                  # 26 通过（会写入，跑完按下文还原）

# App
hvigorw assembleHap ...                    # BUILD SUCCESSFUL（三次构建均通过）
```

新增场景实测（起 8001 临时实例，测完已清理）：

| 场景 | 结果 |
|---|---|
| 容量 1 的活动：A 首次报名 | 200，id=53 |
| A 用**同一** client_id 重报 | 200，id=53（幂等，未新建） |
| A 用**新** client_id 重报（此时已满员） | 200，id=53（修复前会 403 activity full） |
| B 报名（第三个不同学生） | 403 activity full（正确拦截） |
| 已通过记录重复报名 | status 仍为 1，`remark` 保留「材料齐全OK」（修复前被清空） |

### 12.5 部署状态

- `server/server.exe` 已替换为含修复的新版本（旧版备份 `server/server_prev.exe.bak`，确认无问题后可删）。
- App 需重新安装：`hdc install -r chapter03/entry/build/default/outputs/default/entry-default-unsigned.hap`。
- **跑完 `verify_v3.py` 后**固定三步恢复演示数据（否则活动数与学时都会偏）：
  ```sql
  DELETE s FROM signup s JOIN activity a ON s.activity_id = a.id
    WHERE a.title LIKE 'v3 %' OR a.title = '历史活动';
  DELETE FROM activity WHERE title LIKE 'v3 %' OR title = '历史活动';
  ```
  然后 `POST /api/hours/rebuild`（或 App 学时报表页「重算学时」）把学时按已通过报名重建回 20.5。



## 13. v2.4 需求核查与优化（2026-10-28）

按题号 86 的验收要求逐条核查后，补了 4 处「要求能对上、演示看不见」的地方。核查结论：功能项全部具备，本轮改动不新增业务概念，只补齐可见性与现场稳定性。

### 13.1 需求对照结论

| 要求 | 现状 | 结论 |
|---|---|---|
| 活动发布 / 报名 / 审核流程 | 发布页（含本地草稿箱）、详情报名、审核中心（报名审核 + 注册审批） | 具备 |
| 本地 SQLite 存草稿与报名记录 | `local_activity`（草稿）/ `local_signup`（报名，离线可查、可补传） | 具备 |
| 同步自主 Web 服务器（MySQL） | `client_id` 幂等 + 服务端唯一键，离线落本地后自动补传 | 具备 |
| 审核后自动累计学时 | `handleSignupAudit` 锁行 + 条件更新 + 影响行数校验，只累计一次 | 具备 |
| 学时统计报表 | 排行 + 明细 + 达标线 + CSV；本轮加双端一致判定与校准 | 具备 |
| RFID + ESP32 刷卡签到 | `/api/signin` + `rfid_esp32.ino`；本轮补 App 端签到可见与固件稳定性 | 具备（扩展项） |
| 服务器实时请求日志 | 内存环形缓冲 + `request_log`，App 3 秒轮询，支持级别/方法/关键词筛选 | 具备 |
| 本地库可查 / MySQL 可查 | 我的报名页展示本地记录；MySQL 各表可 SQL 直查 | 具备 |
| 模拟器双通道 | 服务端 `bind 0.0.0.0`；App 默认 `10.0.2.2:8000`，真机改局域网 IPv4 | 具备 |

### 13.2 本轮改动

1. **`/api/health` 补 MySQL 连通性**：返回 `version` 与 `db`（bool）。`db=false` 不影响 `code=0`，避免数据库抖动时 App 误判服务器离线。README 早已写了「含 MySQL 连通性」，此前实现里没有，属文档与实现不符。
2. **学生端可见刷卡签到**：`local_signup` 增加 `checkin` 列（`ALTER TABLE` 带 try/catch 兼容旧库），`LocalSignup` / `upsertSignupFromServer` / `updateSignupStatus` 全链路带上；「我的报名」显示「已刷卡签到」，详情页状态后缀同样显示。此前签到状态只存在于服务器与管理员审核列表，成员端看不到。
3. **学时报表双端一致判定 + 一键校准**：两张对比卡下方直接给「✔ 双端一致 / ⚠ 差 X 学时」，并提供「校准本地缓存」（分页拉 `/api/signup/list` 回填本地）。解决验收时「服务器已审核、本地缓存还停在待审核」导致两个数字对不上、看起来像 bug 的问题。
4. **`/api/signup/add` 返回真实 `checkin` / `hours`**：此前只返回 `id` / `status`，App 在「重复报名命中已通过记录」分支读到 `hours=undefined`，会显示「已通过(undefined 学时)」并把本地学时写成脏值。现在返回 `id` / `status` / `checkin` / `hours` 并带出真实学时。
5. **「我的报名」进入页面静默同步**：先补传未同步记录，再静默拉一次服务器状态（失败不弹错），成员不必手点「同步服务器状态」才能看到审核结果。
6. **ESP32 固件现场加固**：HTTP 超时 5s；WiFi 掉线每 5 秒 `WiFi.reconnect()`；同一张卡 5 秒冷却（卡放在读头上不再每秒上报）；读完卡先 `HaltA` 再上报。

### 13.3 验证

- 服务端：`build.bat` 重编译零警告，8000 已换新版；`/api/health` → `{"version":"2.4","db":true}`
- RFID 端到端（临时活动，测完已删 + `hours/rebuild`）：未绑卡 404；张三刷卡 200 且 `checkin=1`；同卡重复刷 200 且学时只加一次；`signup/list` 与 `hours/report` 同步变化；清理后基线回到 20.5
- `verify_demo_data.py` 8/8、`verify_ui_contract.py` 48/48
- App `assembleHap` BUILD SUCCESSFUL（33 tasks，17 executed），HAP 内含「校准本地缓存 / 双端一致 / 已刷卡签到 / ALTER TABLE local_signup」
- 数据基线保持：8 活动 / 19 报名 / 5 人 20.5 学时 / 榜首李铭 5.5 / required_hours=20

### 13.4 仍然建议但未做（按性价比排序）

| 项 | 说明 | 风险/成本 |
|---|---|---|
| 学时报表服务端导出 | 现在 CSV 由 App 生成写沙箱；若要求「服务器生成报表」，可在服务端加 `/api/hours/export.csv` | 低，但要新增接口与鉴权 |
| 刷卡是否需二次审核 | 当前「到场即认定」会跳过人工审核；若评委强调审核流程，可加 `sys_config.signin_need_audit=1`，刷卡只置 `checkin` 不累计学时 | 中，涉及学时口径与文档 |
| 请求日志写入改队列 | 每个请求 detach 一个线程写 `request_log`，高并发下线程数会涨；改成单消费者队列更稳 | 中，演示规模无感 |
| 会话持久化 | Token 存内存，服务端重启后所有客户端 401（已做自动清会话提示） | 低，课程演示可接受 |

## 14. v2.5 模拟器实测复查（2026-10-28 19:30-19:45）

这次不只跑接口，而是把 HAP 装进模拟器（127.0.0.1:5555）真机点了一遍：启动 → 进入主界面 → 我的 → 我的报名 → 学时报表，并用 `hdc shell sqlite3` 直接查了应用沙箱里的本地库。查出 5 个只有真机才暴露的问题，已全部修掉。

### 14.1 实测发现的问题与修复

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 每次启动日志里都有 SQLite `Error ... duplicate column name: checkin` + 一段 Dfx 异常栈，看着像崩溃 | 迁移用 `try { ALTER } catch {}`，新库建表已含 `checkin`，ALTER 必然抛错 | 先 `PRAGMA table_info(local_signup)` 判断列是否存在，缺列才 ALTER，日志干净 |
| 2 | 两个页面同时 `aboutToAppear` 时可能并发建库/迁移 | `init()` 只判断 `rdb` 未赋值，未收敛并发 | 加 `static initing: Promise<void>` 单飞，失败后允许重试 |
| 3 | 本地「报名时间」五条全是同一秒（如 09:57:20），与服务器真实报名时间不符 | upsert 未写 `created_at`，走表默认 `CURRENT_TIMESTAMP` | `upsertSignupFromServer(..., createdAt)` 写入服务器时间；已存在的旧记录同步时校正 |
| 4 | 同步完成后列表文字不刷新：报名时间仍是旧值（库里的值已更新） | ArkUI `ForEach` 按 key 复用组件，key 只有 `client_id-status-checkin`，字段变了 key 没变 | key 补上 `hours` / `created_at`；同时修主界面活动列表、发布页草稿/已发布列表、审核列表（补 `checkin`）的同类问题 |
| 5 | 列表已有 5 条记录，顶部仍显示「暂无本地报名记录」 | 进页面先 `refreshLocal()` 置空态提示，静默同步补数据后没清 | 刷新到非空且提示仍是该句时清空 |

### 14.2 实测证据

- 本地库直查：`local_signup` 11 条，李铭 5 条时间为 `10-25 15:00`、`10-26 20:00`、`10-28 12:10`、`09:04:22`，与 MySQL 完全一致
- 「我的报名」：状态/学时/「已刷卡签到」标记正确（两段式：`已通过 + 已刷卡签到 + 已同步服务器`）
- 「学时报表」：本地 5.5 / 服务器 5.5，绿色「✔ 双端一致」
- 启动与页面切换日志无 `duplicate column`、无 `PrintInfoForDbError`、无 JsError
- 数据基线保持：8 活动 / 19 报名 / 5 人 20.5 学时 / 榜首李铭 5.5 / required_hours=20

### 14.3 顺带确认的既有能力

- HAP 覆盖安装后本地库保留，旧库自动补 `checkin` 列（升级路径有效）
- 服务端 8000 与模拟器 10.0.2.2 双通道正常，引导页显示「服务器在线」，主界面 8 个活动来自 MySQL
- `test_api.py` 26/26（跑完已把 `ptest-audit-1` 还原为待审并 `hours/rebuild`，基线未漂移）

## 15. v2.6 新增「用户管理」页（2026-10-28 21:00）

应需求「在管理员这里添加一个功能页面，能看到整个系统所有用户的信息，并制作合理的分组查找」，新增管理员专属的用户管理页。

### 15.1 服务端新增接口

- `GET /api/student/list`（仅管理员，`handleStudentList`）
  - 返回每个学生的：注册状态 `status`(0待审核/1已通过/2已驳回)、学号、姓名、班级 `dept`、RFID `card_no`、注册时间、累计学时 `total_hours`(来自 `hours_total`)、通过次数 `sign_count`、是否达标 `achieved`。
  - 分组参数 `group`：`all`(默认) / `pending` / `approved` / `rejected` / `achieved`(已通过且学时>=达标线) / `unachieved`(已通过且学时<达标线)。
  - 关键字 `kw`：按 学号/姓名/班级 模糊匹配，与分组同时生效（全部在 WHERE 里，`total` 与结果一致）。
  - 同时下发 `group_counts`（六个分组各自的计数，不受 kw 影响，用于分组标签数字）与 `required_hours`（达标线）。
  - 排序：待审核在前，其余按学时降序。

### 15.2 前端新增页面

- `chapter03/entry/src/main/ets/pages/UserManagePage.ets`
  - 顶部返回 + 「用户管理」标题 + 「共 N 人」 + 刷新。
  - 分组标签：**两行三列 Grid**（全部/待审核/已通过/已驳回/已达标/未达标，各带计数），选中态主色高亮。用 Grid 而非横向 Scroll 的原因：横向 Scroll 末尾标签会被屏幕右缘裁切。
  - 搜索框：按学号/姓名/班级查找。
  - 用户卡片：头像(状态色) + 姓名 + 状态徽标 + 学号·班级 + 右侧学时摘要 + 达标进度条(仅已通过) + 卡号 + 注册日期。
  - 状态色：已通过=绿、待审核=橙、已驳回=红，卡片左侧竖条同色。
  - 复用 `StateView` 三态(加载/空/错误)，非管理员走 `AdminGuardView`。

### 15.3 模型与路由

- `Models.ets` 新增 `StudentInfo`、`StudentGroupCounts` 接口 + `parseStudentList` / `parseStudentGroupCounts` / `studentStatusText`。
- `main_pages.json` 新增 `pages/UserManagePage`（第 13 项）。
- `MainPage.ets` 管理面板新增「用户管理」卡片（第二位，主色 admin 橙）。

### 15.4 布局坑（这次踩的）

- ArkUI `width('100%')` + `margin({left,right})` 会溢出：盒子总宽 = 100% + 28px > 父容器，导致卡片右缘文字被裁。改法：**去掉卡片 margin，改在 List 上设 `.padding({left,right})`**，卡片 `width('100%')`。
- `@Builder` 里不能用 `if (...) { ...; return; }` 语句形式，`build()` 里也一样——只能 `if/else` 条件渲染。
- 注册时间 `created_at` 是 `YYYY-MM-DD HH:MM:SS` 长串，卡片里只取 `substring(0,10)` 到日，避免右侧溢出。

### 15.5 验证

- 接口：`/api/student/list` 各分组 / `kw=计科` 均返回正确（全部9/待审3/通过5/驳回1/达标0/未达标5，计科5人）。
- 模拟器实测：管理员登录 → 管理面板见「用户管理」卡片 → 进入页面 → 分组切换(待审核=3人) → 搜索(计科=5人) → 选中态/进度条/卡号/状态色均正确。
- 数据基线未污染：`verify_demo_data.py` 8/8。

## 16. v2.7 主界面两个渲染坑的根治（2026-10-28 21:10）

追求完美阶段在模拟器实测时抓到两个「只有真机才暴露」的渲染 bug，均为 ArkUI 响应式机制的坑，已根治并在此留档。

### 16.1 `@Builder` 按值传参不随状态刷新 → 「共 0 个」

- **现象**：活动广场标题栏一直显示「共 0 个」，但下方明明列出了 8 个活动。
- **根因**：`header(title, sub, showSearch)` 的 `sub` 参数是 `@Builder` 的**按值快照**——调用处写 `this.header('活动广场', '共 ' + this.actTotal + ' 个', true)`，`this.actTotal` 在那一刻还是 0，异步加载完成后 `actTotal` 变了，但 `sub` 这个已传入的字符串不会再更新。
- **修法**：动态值一律改成在 `@Builder` 内部直接读 `this.xxx`（响应式），只有 title/showSearch 这类**静态值**才作为参数传入。即 `header(title, showSearch)` 内部读 `this.actTotal` 拼「共 N 个」。
- **排查经验**：凡是「`@Builder` 里显示一个会变的数」，都要怀疑是不是把动态值当参数传进去了。同类问题已一并排查：`navItem`/`bigCard`/`rowItem` 的动态值（角标、选中色）都已确认在 Builder 内部读 `this`，参数只剩常量。

### 16.2 Tabs 角标不刷新 → 自绘底部导航

- **现象**：管理员底部「管理」Tab 的红色待办角标要么不显示、要么被 tabBar 裁切（`Stack`/负 margin 都救不回来）。
- **根因**：`Tabs` 的 `tabBar(CustomBuilder)` 构建器**不随 `@State` 变化重建**，角标数字冻结；且 tabBar 内部是受限布局，`Stack` 定位的角标会被裁掉。
- **修法**：弃用 `Tabs`，改成**自绘底部导航**：一个 `Row` 里放 `navItem(...)` + 顶层 `Stack` 按 `currentTab` 切换内容视图。角标用「图标 Row 内嵌红底数字」实现，完全受控、随 `pendingSignup+pendingReg` 实时刷新。
- 导航图标用自绘 SVG（活动=线条、管理=九宫格、我的=人形），不依赖 emoji（emoji 在部分设备渲染成彩色位图或红点）。
- 顺带：`currentTab` 与 `isAdmin` 决定 tab 数（学生 2 / 管理员 3），`switchTab` 切 Tab 不重置列表（保留分页与滚动位置）。

## 17. v2.8 从零视角复查：颜色 token 化收尾（2026-10-28 21:15）

上一轮规划 16 项已全部落地，本轮以"没用过系统的评委视角"重走全链路，结论：后端安全性/并发防护扎实（登录限流 429、口令加盐哈希+自动升级、报名 FOR UPDATE 行锁+插入后复检+幂等重报、签到 affected_rows 防重复累计学时），前端生命周期与空态完整，无硬伤。

唯一残留：上一轮颜色 token 化漏掉了 12 处硬编码色值，散在 7 个页面：
- `#888888`(次要说明文字) → `Theme.textTertiary`
- `#F0F5FF`/`#F8FAFF`(浅蓝底) → `Theme.primaryBg`
- `#00A884`(导出按钮) → `Theme.report`
- `#F0FAF4`(浅绿底) → `Theme.successBg`
- `#DDDDDD`(分隔竖线) → `Theme.divider`
- `#D4F5DD`/`#FFD9D2`(深底在线/离线状态文字) → 新增 `Theme.onColorSuccess`/`Theme.onColorDanger`

现在全项目已无 16 进制硬编码色值（仅剩 `rgba()` 半透明叠加与 `Theme.xxx` 引用），改主色只动 Theme.ets 一处。编译通过。

## 18. v2.6 账号注销功能（2026-10-28，依据工作记录重建）

> 本节曾在文档覆盖事故中丢失且未提交过 git，2026-10-30 依据工作记录重建；细节以代码与 `test_cancel_api.py` 为准。

### 18.1 接口（server.cpp）
- `GET /api/student/impact`：学生查自己 / 管理员带 `stu_no`；返回 `signup_total/passed/pending/rejected`、`hours_sum/hours_total`、`reg_status`，供前端"将删除什么"如实展示。
- `POST /api/student/cancel`：仅学生本人；`confirm_stu_no` 必须等于本人学号（不可逆防误触）。
- `POST /api/student/delete`：仅管理员；`stu_no + confirm_stu_no` 双参数一致才执行。
- 事务内按 **signup → hours_total → student** 顺序级联删除；`SELECT ... FOR UPDATE` 锁学生行串行化"学生自助"与"管理员同时注销"；`mysql_affected_rows != 1` 视为已被并发删除，整体回滚。
- `dropStudentTokens(stu_no)` 清该学号全部 token（管理员 token 的 stu_no 是账号名，不会误伤）。
- `jsonOkMsg(msg, data)` 为此新增；学号注销后可重新注册。

### 18.2 审计落库机制
处理器把说明写进**响应头 `X-Audit-Note`**，管线 `takeAudit()` 摘出拼到 `request_log.detail`（`AUDIT 自助注销/管理员注销 + 学号姓名 + 删除条数/学时/失效 token 数`），detail 上限 480 字符。

### 18.3 前端
`SettingsPage` 危险操作区（仅普通成员）→ 拉影响面 → 输本人学号 → 确认后清本地报名缓存(`DbHelper.deleteSignupsByStu`) + 退登录回引导页；`UserManagePage` 卡片右下"注销"→ 内联确认面板；`Models.ets` 新增 `StudentInfo/StudentGroupCounts/CancelImpact` 及解析函数；`Theme.ets` 新增 `onColorSuccess/onColorDanger`。

### 18.4 测试与基线
`test_cancel_api.py` 22 项（影响面、确认校验、越权、级联、旧 token 401、无孤儿、学号可复用、管理员注销）；`verify_cancel.py` 4 项（无孤儿/汇总自洽/学时总额一致/基线打印）。基线 8 活动/19 报名/5 人 20.5 学时。

### 18.5 验证后清理
`verify_v3.py` 会留测试活动：先 `DELETE signup`（JOIN activity 按标题）→ `DELETE activity` → 再调 `POST /api/hours/rebuild` 把学时按已通过报名重建回 20.5（只删记录不回滚学时会漂移）。`test_api.py` 26 项会真实审核 `ptest-audit-1` 使张三 +2.0 学时，跑完按 9.6 还原。

### 18.6 thread_local 环境坑（重要，勿再踩）
**MinGW 4.9 (TDM) 的 emutls：`thread_local` 非平凡对象在线程退出析构时崩溃**。本项目曾用 `static thread_local string g_auditNote` 传请求级审计说明 → 服务端"处理完一个请求就死"且无日志。**本项目禁止用 thread_local 传请求级状态**，改用响应头 `X-Audit-Note` + `takeAudit()`。
A/B 定位法：`git show HEAD:server/server.cpp` 编旧版对比。**必须放 `server/` 目录编译运行**——`/tmp` 下缺 `libmysql.dll` 会 exit 127，极易误判为崩溃。

## 19. 操作失败反馈体系（v3.0 阶段, 2026-10-30）

### 19.1 起因与诊断
用户报告: 管理员审核时学生已撤销报名, 点"通过"没有任何提醒。排查发现三层问题:
1. **服务端英文消息**: `jsonErr(404, "signup not found")` 这类消息虽会透传到前端, 但用户看不懂; `db connect failed` 等 22 处同样不友好。
2. **展示太弱**: AuditPage 失败提示和成功提示同为灰色小字(maxLines(1)), 感知不到。
3. **401 防线失效(更严重的隐性 bug)**: 服务端约定"业务错误也走 HTTP 200, 真正 code 在 body 里", 因此 token 过期后返回的是 `HTTP 200 + {code:401}`, 而 ApiClient 只对 **HTTP 401** 清登录态 —— 该分支永远不会命中, 界面一直显示"已登录", 点什么都静默失败。

### 19.2 修复内容
- **ApiClient.ets**: ① 解析 HTTP 200 响应后若 body code==401 且本地有 token → `AppConfig.logout()`(修 401 防线); ② HTTP 4xx/5xx 时尝试解析响应体 JSON 透传服务端 msg(不再压成 "HTTP 404"); ③ **POST 失败默认弹全局 toast**(promptAction, 3s, bottom 120), 新增 `post(path, body, silentToast=false)` 第三参, 批量场景传 true 防刷屏; ④ 连接失败提示改为可操作的中文。
- **server.cpp**: 用户可见英文消息全部中文化 —— signup not found → "该报名已被学生撤销或不存在, 请刷新列表"、activity full → "名额已满, 无法报名"、activity not open → "活动未开放报名"、activity not found → "活动不存在或已下线"、student not found、card not bound、internal error、22 处 db connect failed → "数据库连接失败, 请检查 MySQL 服务"。编程错误类(bad json 等)保留英文。注意 server.cpp 是 UTF-8, 用 Python 批量替换时带断言防止误替换。
- **AuditPage.ets**: 新增 `msgError` 状态, 失败消息染红(danger)加粗且 maxLines(2); 批量通过逐条调用传 silent=true。

### 19.3 验证
- 场景复现 6/6: 学生报名 → 管理员拉列表 → 学生撤销 → 管理员用旧快照点通过 → 收到中文 404 提示, 学生学时/报名数无变化, 无名额泄漏。
- 回归: test_cancel_api 22/22、verify_cancel 4/4(基线 8/19/5/20.5)、verify_demo_data 8/8。
- HAP 构建成功(BUILD SUCCESSFUL)。

### 19.4 环境坑(本轮新增)
- Git Bash 里 `(./server.exe &)` 子 shell 后台进程**随命令结束被回收**, health 能过但下一条命令时已死, 易误判为"启动即崩"。必须用工具的 run_in_background(对应独立后台任务)或让用户双击 `start_server.bat`。


## 20. 版本界定：项目进入 v3.0（2026-10-30）

> 用户指示：往后版本号推进为 **v3.0**。此前版本已归档：`v1.0`（第一版）、`v2.0`（第二版最终版）。
> 后续新功能一律按 **v3.x** 记版本号，不要再写 v2.9/v2.x。

### 20.1 已归入 v3.0 的内容

- **账号注销功能**（第三版核心，已实现并验证）：
  - 接口：`GET /api/student/impact`（影响面预览）、`POST /api/student/cancel`（学生自助，`confirm_stu_no` 必须等于本人学号）、`POST /api/student/delete`（管理员，`stu_no + confirm_stu_no`）
  - 机制：事务内锁学生行（串行化自助/管理员并发注销）、级联删除学生行+报名+学时、注销后旧 Token 立即失效、学号可重新注册、注销动作写请求日志审计（`AUDIT 自助注销 / 管理员注销`）
  - 前端：`SettingsPage.ets` 学生自助注销、`UserManagePage.ets` 管理员注销，二次确认弹窗展示影响面
  - 测试：`test_cancel_api.py` 22/22、`verify_cancel.py` 4/4
- **操作失败反馈体系**（第 19 节）：ApiClient body `code==401` 清会话、全局 toast、服务端 22 处消息中文化、AuditPage 错误红字加粗

### 20.2 文档状态（交接方已恢复，勿再整体覆盖）

- `README.md`、`VERSION.md`、`使用说明文档.docx` 曾被删除，已从 git 历史恢复
- 本文件 1–17 节曾被覆盖丢失（只剩 19 节），已合并恢复：现含 **1–17 + 19 + 20 节**
- **写文档请追加而非整体覆盖**，覆盖会丢历史；改 HANDOFF 前先读尾部确认最新节号

### 20.3 版本约定

- 版本说明统一维护在根目录 `VERSION.md`（含 v2.0 归档说明与 v3.0 实现记录）
- 破坏性数据操作（注销/物理删除）必须写审计日志并在 HANDOFF 记明影响面

## 21. P1/P2 并发权限专项验收 + CSV BOM 修复（v3.0 阶段, 2026-10-30）

### 21.1 起因
外部评审建议(豆包)列出测试方向矩阵。评估后: 部分已覆盖(注销已有 22 项、并发审核已有防护)、部分过时("注销未实现"已不成立), 可接口化的高价值项集中为 P1 并发/权限 + P2 状态机边界。

### 21.2 新增 server/test_p1p2.py —— 26 项, 自建自清理不动演示基线
P1: 越权矩阵(学生 token 打 7 个管理接口全 403) / 伪造 stu_no(body 塞别人学号被忽略, 归属登录者) /
满员竞态(容量 1 两学生并发恰 1 成, valid_count<=1) / 并发重复审核(2 路并发恰 1 成, 学时恰好 +2.0 一次) /
刷卡 5 连刷(学时只加一次, 单条已通过记录) / 未绑卡 404 / 登出后旧 token 401 / 随机 token 401。
P2: 已结束活动拒报名 / 已下线拒报名 / 结束<=开始发布被拒(等号也拒) / 编辑允许历史时间 /
已通过不可撤销 / 驳回存备注→重报复位待审且备注清空 / 容量 0 不限 / 达标线 999 全员未达标→恢复 0 / 分页 total 与行数一致。
结果: 26/26 通过。注意登录节流按 type:account 内存计数, 未在本脚本测(会锁 60s, 接口已确认存在: 761 行 429)。

### 21.3 CSV BOM 修复(豆包怀疑属实)
HoursReportPage.exportCsv 原样写 UTF-8 无 BOM, Excel 双击打开中文乱码(WPS 正常)。
修复: `const text = '\uFEFF' + this.buildCsv()`。HAP 重新构建通过。

### 21.4 结论: 服务端并发与权限防护全部有效
报名(活动行 FOR UPDATE+插入后复检) / 审核(报名行 FOR UPDATE+条件 UPDATE+affected_rows) /
刷卡(needAccumulate 仅首次认定) / 鉴权(每个管理接口 needAdmin) / stu_no 一律取登录态。
演示前回归清单: verify_demo_data(8) + verify_cancel(4) + verify_ui_contract(48) + test_p1p2(26)。

## 22. 文档同步 v3.0 + test_p1p2 偶发失败修复（2026-10-30 12:30）

### 22.1 起因
外部体检（豆包）列出 16 条可能问题。逐条核实后：**1 条真缺陷（CSV，已在 §21 修）、1 条文档严重落后（本条修）、2 条判断有误、其余为既定取舍或环境说明**。

### 22.2 文档同步（本次主要工作）
- `docs/使用说明.md` 从 22.9KB → 35KB，对齐当前界面：
  - 新增 **5.10 用户管理**（六分组服务端过滤 + 关键词叠加 + 卡片字段 + 内联注销面板）；
  - 新增 **5.11 账号注销**（两条通道对比表、影响面预览、级联删除顺序 signup→hours_total→student、Token 回收、审计保留、RFID 解绑、学号可复用、并发恰 1 成功、演示顺序建议）；
  - 新增 **5.12 错误提示与失败反馈**（全局 toast / 中文消息 / 红字 / 401 双判断）；
  - 新增 **第 9 节 自动化验证脚本表**（6 个脚本的项数、覆盖内容、是否改数据 + 演示前四条回归命令）；
  - 更新：功能简介（注册审批/用户管理/注销/失败反馈）、权限表、3.2（`start_server.bat` 用法 + Token 内存态说明）、3.3（真机需签名）、5.2（管理 Tab 五卡片 + 角标=待审报名+待批注册）、5.7（注册申请页签 + 列表过期红字提示）、5.9（模拟刷卡走真实 `/api/signin`）、演示流程加 8~10 步、FAQ 补 7 条。
- `使用说明文档.docx` 由 md **重新生成**（`C:/Users/34520/AppData/Local/Temp/md2docx.py`，python-docx）：160 段 / 9 表 / 11.2k 字；标题用内置 Heading 1-3（导航窗格与自动目录可用），页脚页码，表头深蓝底白字、隔行浅底，代码块与引用块带底纹。**生成后做了 OOXML 子元素顺序校验（pPr/tcPr 各 0 违规）**，避免 Word 打开提示"需要修复"。
- `VERSION.md` 增补「v3.0 阶段补强」小节（§19 失败反馈 / §21 并发专项 / CSV BOM / 文档同步），版本号仍为 3.0（`/api/health` 一致）。
- `README.md` 目录树补 `test_cancel_api.py`、`test_p1p2.py`、`verify_cancel.py`、`start_server.bat`、`VERSION.md`；回归命令改为 6 条并标注哪些会改数据。

### 22.3 test_p1p2.py 偶发失败（本轮发现并修复）
现象：`ValueError: invalid literal for int() with base 10: ''`（第 210 行）。
原因：**脚本自身 flaky**，与产品无关 —— "驳回后重报"用例复用了 `a1`（容量 1），而 a1 的名额已被前面"满员竞态"用例随机占掉；当 2029101 赢得竞态时 2029102 报名被拒，`SELECT id ... ` 返回空。此前 26/26 是乙恰好赢了的运气。
修复：新增独立活动 `a5`（capacity=0）专用于该用例，并纳入 finally 清理。连跑两次均 26/26。

### 22.4 对体检清单的核实结论（供答辩参考）
| 清单条目 | 核实结果 |
|---|---|
| CSV 无字段转义 | **不成立**。`Models.ets:402 csvCell()` 已对含 `,` `"` `\n` 的值加引号并转义内部引号 |
| 注销不清 `local_activity` 草稿 | 风险接近零：草稿只有活动发布页（管理员）读写，学生端无入口；草稿表本身无 stu_no 归属，属"单管理员单设备"设计取舍 |
| 服务端自己退出 | 不成立。8000 端口 PID 22056 持续在监听；此前的"失败"是后台任务句柄随会话被回收 |
| `start_server.bat` 参数不一致 | 不成立。已核对：`server.exe 8000`、先探测 3306、CRLF、纯 ASCII、`cd /d "%~dp0"` |
| 登录节流/Token 在内存 | 属实，属既定取舍；已写入使用说明 3.2 与 FAQ（重启需重登） |
| HAP 未签名 | 属实，已写入使用说明 3.3 与 FAQ（模拟器可装，真机需自动签名） |
| 课程设计正式报告缺失 | 属实，属独立交付物（需求/架构/库表/接口/测试记录），尚未编写 |

### 22.5 验证
- 回归：`verify_demo_data` 8/8、`verify_cancel` 4/4、`verify_ui_contract` 48/48、`test_p1p2` 26/26（连跑两次）。
- 基线未漂移：8 活动 / 19 报名 / 5 人 / 20.5 学时。

---

## 23. 安全加固与缺陷根治（2026-11-09）

> 起因：对全项目做了一次带证据的代码审查，发现 2 个 P0（可用一条请求打崩服务、可接管他人账号并硬删数据）、5 个 P1（数据/交互缺陷）、若干 P2。本节记录全部改动与验证方式。

### 23.1 P0：可远程利用

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | 任意学生可接管他人账号并**硬删除**其报名与学时 | `/api/hours/report` 的排行数组未按角色过滤，把全班**学号+姓名**下发；学生登录口径恰是「学号+姓名」；自助注销只校验本人学号 | 排行对 `role=="student"` **脱敏**（姓名 `张**`、学号前 4 位 `2023****`），本人行用 `is_me=true` 保持明文；管理员视图不变 |
| 2 | 一条请求打崩服务端 | `JsonParser` 纯递归无深度上限；`/api/login`、`/api/register`、`/api/signin` 均在鉴权前解析 body；64KB 的 `[[[[…` 可崩栈 | `JsonParser` 加 `depth_` + `DepthGuard`（RAII），上限 64 层 |

`maskName` / `maskStuNo` / `is_me` 位于 `handleHoursReport` 上方；`DepthGuard` 位于 `JsonParser` 私有区。

### 23.2 P1：数据与交互缺陷

| # | 问题 | 修复 |
|---|---|---|
| 1 | 报名"假成功"：服务器明确拒绝仍置 `signed=true` 并保留本地 `synced=0` 记录 → 幽灵报名无法删除、也无法再报名 | 新增 `ApiClient.isRejected()`；`ActivityDetailPage.doSignup` 区分「业务拒绝」（回滚本地 + 保持未报名）与「网络故障」（保留待补传）；`MySignupPage.retryUnsynced` 对业务拒绝的记录直接清理并汇总提示 |
| 2 | 刷卡签到时间丢失：新建/待审→通过两个分支只写 `checkin=1`，不写 `checked_at` | `handleSignin` 两处补 `checked_at=NOW()`；已通过再刷改 `COALESCE(checked_at,NOW())` 保留首次时间 |
| 3 | `client_id` 被覆盖：同学生换设备重报时服务端改写旧 `client_id`，旧设备本地记录被当成陈旧数据清掉 | 去掉 `client_id=VALUES(client_id)`；`/api/signup/add` 回传服务器真实 `client_id`，App 用 `DbHelper.replaceSignupClientId()` 校正本地 |
| 4 | 卡号无唯一约束；注册/审核都不采集卡号 → 新成员永远刷不了卡；手工绑重卡会刷错人 | 注册接口接受可选 `card_no`（规范化大写、查重）；审核接口支持 `card_no` 绑定；`student.card_no` 改可 NULL + `UNIQUE KEY uk_card`；注册页与审核页各加输入框 |
| 5 | 管理员无法改口令 | 新增 `POST /api/admin/password`（校验原口令）；设置页加「修改管理员口令」卡片 |

### 23.3 P2：工程加固

| 项 | 修复 |
|---|---|
| Token 可预测（`std::mt19937`） | 改 `BCryptGenRandom`（系统 CSPRNG），32 字节 → 64 hex |
| 口令单轮 SHA-256 | 改迭代加盐（`sha256i:` 前缀，12000 轮）；明文/单轮格式登录成功后自动升级，启动迁移只处理明文（单轮哈希无法反推） |
| 每请求 detach 一个线程写日志 | 改「有界队列（4096）+ 单消费者线程批量写（200/批，50ms 轮询）」，队列满丢落库不阻塞业务 |
| 连接数无上限 | `g_conns` 计数 + `MAX_CONNS=256`，超限直接 503 并关闭 |
| 负数 `Content-Length` | `atoll` 判负 → 400（原实现强转巨大 `size_t` 会把线程卡在 drain） |
| chunked 请求 | 明确 411 拒绝（避免块长度被当成下一个请求，形成请求走私） |
| 日志字段超长静默丢 | `path`/`query` 入库前截到 250 字（列宽 255） |
| 登录节流可被用来锁死他人账号 | 节流 key 改为 `ip\|type:account`，并加同 IP 总失败上限（30/60s） |
| `scope=mine` 信任客户端 `stu_no` | 学生强制使用登录学号 |
| 未设达标线时进度恒 0% | `pct()` 在 `requiredHours<=0` 时返回 100 |
| `extractCode` 字符串误判 | 只在响应体开头 12 字节内找首个 `"code":` |

### 23.4 数据库变更（老库自动迁移）

`dbEnsureSchema()` 启动时执行（已存在则报错忽略）：

```sql
ALTER TABLE student MODIFY card_no VARCHAR(32) NULL DEFAULT NULL;
UPDATE student SET card_no=NULL WHERE card_no='';
CREATE UNIQUE INDEX uk_card ON student (card_no);
```

`init_db.sql` 同步：`card_no` 改 `NULL DEFAULT NULL` + `UNIQUE KEY uk_card`；`admin_user.password` 注释改为 `sha256i:` 迭代格式。
`seed_demo_data.sql`：未绑卡学生由 `''` 改为 `NULL`（否则唯一索引冲突）。

### 23.5 验证（2026-11-09 实测）

- 服务端 `TDM g++ 4.9.2 -std=c++14 -O2 -Wall` **零警告**，`server.exe` 已更新
- 原始 HTTP 用例 9/9：深嵌套 JSON → `code 400` 且进程存活；负数 `Content-Length` → `400`；`chunked` → `411`；重复卡号注册 → `409`；已通过再刷卡 → `200` 且 `checked_at` 写入、学时不变
- 接口用例 8/8（除下条）：管理员/学生登录正常；学生排行 **本人明文 + 他人脱敏**；明细仅本人；`scope=mine&stu_no=他人` 返回本人活动；改密错原口令 → `401`
- DB 核对：`admin.password` 前缀 `sha256i:`；`uk_card` 索引存在；`student.card_no` 无空串；基线 **8 活动 / 19 报名 / 20.5 学时** 未漂移
- App `hvigorw assembleHap` **BUILD SUCCESSFUL**（26 tasks）

### 23.6 环境注意（本轮新增）

1. **编译必须加 `-lbcrypt`**（`bcrypt.h` + `libbcrypt.a` 在 TDM 4.9.2 自带），`build.bat` 已补，仍为 GBK + CRLF。
2. 构建 App 除 `DEVECO_SDK_HOME` 外还需 **`NODE_HOME="D:\HuaWei\DevEco Studio\tools\node"`**，否则 hvigorw 报「NODE_HOME is not set」。
3. 本机 `python` 只有 Microsoft Store 存根（执行返回 9009），**6 个 Python 回归脚本当前跑不了**；本轮改用 PowerShell 直接调 HTTP 验证。换机器/装好 Python 后仍应按 §2 跑全套。
4. 删除过 `entry/build` 后首次构建会因 `.tsbuildinfo` 缺失报 `ENOENT`（非代码错误），先跑 `hvigorw clean` 再 `assembleHap`。

### 23.7 有意未做

- **学生登录改密码体系**：会改变演示口径（README/使用说明/答辩均写「学号+姓名」）并影响 6 个回归脚本。本轮通过"排行脱敏"关闭了零门槛接管路径；熟人冒名仍属 §4 声明的弱认证取舍，生产环境应改「学号+口令」或统一身份认证。
- **Token 迁移到 `@ohos.security.asset`**：改动面大（异步 API、全部读写点），当前存 Preferences 明文，属既定取舍。
- **chunked 完整解析**：App 与 ESP32 均不发 chunked，明确拒绝已消除走私风险。

---

## 24. 学生登录升级为「学号 + 密码」（2026-11-09）

> 用户决定彻底根治学生弱认证：学生不再用姓名当口令，改为独立密码；同时**撤销 §23.1 的排行脱敏**——姓名不再是认证要素后，排行/用户列表按原样显示全名不构成风险。

### 24.1 数据库

```sql
ALTER TABLE student ADD COLUMN pwd_hash VARCHAR(100) NOT NULL DEFAULT ''
  COMMENT '登录口令: sha256i:<hex>';
```

- `dbEnsureSchema()` 启动时自动加列，并把 `pwd_hash=''` 的账号**统一初始化为默认密码 `123456`**（`pwdHashStrong`，只算一次哈希）。
- 已改过密码的账号不会被覆盖（`WHERE pwd_hash=''`）。
- `init_db.sql` 同步加列；`seed_demo_data.sql` 不写该列，首次启动自动初始化。

### 24.2 接口

| 变化 | 说明 |
|---|---|
| `POST /api/login`（student） | `secret` 由姓名改为**密码**，`pwdVerify(pwd_hash)` 校验；**先验密码再报审核状态**，避免向未认证者泄露"审核中/已驳回" |
| `POST /api/register` | 新增 **`pwd`（必填，6~64 位）**，入库为迭代加盐哈希 |
| `POST /api/student/password` | 新增：成员改自己密码 `{old_pwd, new_pwd}`，校验原密码 |
| `POST /api/student/reset_pwd` | 新增：管理员重置成员密码 `{student_id, new_pwd}`（成员忘密码时用） |
| `GET /api/hours/report` | **恢复明文** `name`/`stu_no`，保留 `is_me`（仅用于 App 定位本人行） |

### 24.3 App

- `LoginPage`：成员密码框改为 `InputType.Password`，预填 `2023001 / 123456`，文案「学号 + 密码」
- `RegisterPage`：新增「密码 / 确认密码」两个输入，校验 6~64 位且两次一致
- `SettingsPage`：成员可见「修改登录密码」卡片（`/api/student/password`）；管理员「修改管理员口令」保持不变
- `HoursReportPage` / `MainPage`：脱敏适配代码保留 `is_me || stu_no === 本人` 的兼容判断，明文/脱敏两种响应都能正确高亮本人

### 24.4 回归脚本同步（6 个）

| 脚本 | 改动 |
|---|---|
| `test_api.py` | 学生 `secret` → `123456`；错误用例改为 `wrongpwd` |
| `test_cancel_api.py` | 注册补 `pwd`；登录 `secret` → `123456` |
| `test_p1p2.py` | 3 个测试学生注册补 `pwd`；登录 `secret` → `123456` |
| `verify_demo_data.py` | 孙洋/吴桐/冯婷 `secret` → `123456` |
| `verify_v3.py` | 2023001 `secret` → `123456` |
| `verify_ui_contract.py` | 成员登录 `secret` → `123456`，用例名同步 |

### 24.5 验证（2026-11-09 实测）

- DB：`pwd_hash` 列已建；`empty_pwd=0`、`iter_pwd=10`（含 `2024001`，说明历史账号一并初始化）
- 接口 9/9：`2023005/123456` 登录成功；`2023005/孙洋` → `401`（姓名不再可登录）；排行恢复明文（`李铭/2023002`）且 `is_me` 仍为 1；成员改密 → 新密码登录成功 → 改回 → 再登录成功；无密码注册 → `400`
- App `hvigorw clean && assembleHap` **BUILD SUCCESSFUL**
- 基线未漂移：8 活动 / 19 报名 / 20.5 学时 / 榜首李铭 5.5

### 24.6 交付提醒

1. **演示口令表**：管理员 `admin/admin123`；成员 `2023001/123456`、`2023002/123456`，其余成员初始密码同为 `123456`
2. 首次登录后建议在「我的 → 设置」改密；管理员可在用户管理中重置（`/api/student/reset_pwd`）
3. 若现场用旧 HAP（v3.0），登录会失败——必须更新 App 与服务端**成对**部署
4. 密码只走 HTTP 明文传输（无 HTTPS，属既定取舍），仅限局域网演示

---

## 25. 学生自助注销改为密码确认 + 审查遗留项修复（2026-11-09）

> 起因：用户指出「注销还让输入学号不合理」。学号在学时排行、用户管理中都是公开信息，把它当作不可逆操作的凭据等于没有确认——Token 一旦泄露（手机丢失、共享设备未退出），攻击者用公开学号就能把账号连同报名与学时物理删除。

### 25.1 接口变更

| 接口 | 变更 |
|---|---|
| `POST /api/student/cancel` | 确认字段 **`confirm_stu_no` → `confirm_pwd`**（只校验登录密码，不再要求学号）。失败码区分：密码错 → `403`；并发注销/学号已不存在 → `409`；节流命中 → `429` |
| `POST /api/student/delete` | **不变**（`stu_no + confirm_stu_no`）。管理员本就有删除权限，学号用于防误触而非认证 |

### 25.2 零 TOCTOU 的口令校验

`dbDeleteStudent` 增加可选参数，在**同一事务、同一把行锁内**校验口令：

```cpp
static bool dbDeleteStudent(MYSQL* c, const string& stuNo,
                            int& nSignup, double& hoursDeleted, string& err,
                            const string* expectPwd = nullptr, bool* pwdMismatch = nullptr);
```

事务内 `SELECT id,pwd_hash FROM student WHERE stu_no=? FOR UPDATE` 后，若 `expectPwd` 非空且 `pwdVerify` 失败：回滚、置 `pwdMismatch=true`、返回 false。这样"校验通过 → 删除之间被并发改密"的窗口不存在，也不需要第二次查库。管理员路径不传参数，行为与原来完全一致。

### 25.3 注销失败节流

持 Token 者可反复猜密码、猜中即毁号，因此按 **`cancel|IP|学号`** 计数：60 秒内错 5 次即 `429`，成功清零。复用登录节流的 `loginBlocked/loginFailAdd/loginFailClear`，但不与登录计数互相影响。

### 25.4 App

- `SettingsPage` 注销面板：输入框改 `InputType.Password`、placeholder「输入登录密码以确认注销」、按钮在输入 ≥6 位时可用；body 改 `{confirm_pwd}`；面板增加"学号是公开信息，不能作为凭据"的说明
- 前端仍做"非空"前置校验，真实校验只在服务端（绕过 UI 直接打接口同样被拒）

### 25.5 同批修复的审查遗留项

| 编号 | 问题 | 修复 |
|---|---|---|
| M1 | 连接数超限时在 accept 主线程 `sendAll(503)` 无发送超时，对端不读会卡死 accept | 发送前 `setsockopt(SO_SNDTIMEO=1000ms)` |
| M2 | 连接线程无异常兜底：异常逃出线程 → `std::terminate`；且 `g_conns` 不回收 | `handleClient` 不再自行 `closesocket`；lambda 内 `try/catch` 后统一 `closesocket + fetch_sub`，正常/异常都覆盖 |
| M3 | 登录 `secret` 无长度上限 + 12000 轮迭代 → CPU 放大攻击 | `secret > 128` 或 `account > 64` → 400，位置在 `pwdVerify` 之前 |
| M4 | 注册/改密不 trim 而登录 trim → 含首尾空格的密码永远登不上 | 注册、确认密码、学生改密、管理员改密统一 `.trim()` |
| S1 | 401 分支缺 `http_status`，`isRejected()` 把登录过期误判为可重试 | 401 失败体补 `'http_status': 401` |
| S2 | `pwd_hash`/`uk_card` 迁移失败静默（缺列 → 全员 401 却无提示） | 先查 `information_schema` 存在性，补列/建索引后再确认，仍失败则 `std::cerr` 告警 |

### 25.6 脚本与文档

- `test_cancel_api.py`：22 项 → **27 项**。学生侧 4 处改 `confirm_pwd`；新增 5 项节流用例（新建临时学生 → 5 次错密码全 403 → 第 6 次即使密码正确也 429 → 管理员清理）
- `verify_cancel.py`：纯数据校验，无需改动
- `test_p1p2.py`：清理用管理员 `student/delete`，无需改动
- `README.md`：接口表补 `student/password`、`student/reset_pwd`、`student/impact`、`student/cancel`、`student/delete`；修正 `hours/report` 的"脱敏"描述（已于 §24 恢复明文）
- `docs/使用说明.md`：5.11 注销章节改为"学生输密码、管理员输学号"，补充节流与零 TOCTOU 说明
- `VERSION.md`：新增 v3.1 段落
- `CODEBUDDY.md`：**已删除**。它原本是"交给接手 AI 的上手必读"（环境/基线/红线/取舍），实际内容与本文 §16.2、§23/§24、§25 及 README 重复，且已过期（仍写"学生登录=学号+姓名"、HANDOFF 22 节、25 个接口）。删前核对过：`thread_local` 禁令（§2）、`Tabs.tabBar` 不重建（§16.2）、GBK+CRLF（§23.6）、基线 8/19/20.5（§25.7）在本文均有更详细记录，无信息丢失。后续交接只维护 `HANDOFF.md`（只追加）+ `README.md`（现状）

### 25.7 验证（2026-11-09）

- 服务端 `-O2 -Wall` **零警告**（`build.log` 为空），`server.exe` 已重编
- **PowerShell 注销闭环 23/23**（本机 `python` 不可用，改用 `Invoke-WebRequest` 直打接口；服务端业务码在 `body.code`，HTTP 恒为 200）：
  - 错密码 → `403`「登录密码不正确, 注销已取消」且账号保留；正确密码 → 成功（删除报名 0 条 / 0.0 学时，因测试学生无报名）
  - 注销后旧 Token → `401`；`signup`/`hours_total` 级联零残留
  - 管理员走自助通道 → `403`；5 次错密码全 `403`，第 6 次**即使密码正确**也 `429` 且账号仍在
  - 管理员 `student/delete`（学号确认）→ 成功，管理员 Token 不受影响
- 协议防护：深嵌套 JSON（500 层）→ `code 400` 且进程存活；负数 `Content-Length` → `400`；`chunked` → `411`；200/5000 字节口令 → `400` 账号或口令过长（452ms 返回，未进入哈希）；超长 `confirm_pwd`/空密码 → `400`
- `verify_cancel.py` 4 项以 SQL 复核全绿：孤儿记录 0 / 逐人汇总与明细一致 / 总额 20.5 == 明细 20.5
- App `hvigorw clean && assembleHap` **BUILD SUCCESSFUL**（33 tasks，`CompileArkTS` 实际执行 11.9s，0 ERROR）
- 基线未漂移：8 活动 / 19 报名 / 5 人学时报表（榜首李铭 5.5）/ 20.5 学时；`2099*` 测试学生零残留

### 25.8 取舍说明

- 管理员注销**不要求管理员密码**：管理员 Token 本身已是高权限凭证，学号二次确认只防手滑；若要防"管理员 Token 泄露后滥删"，应引入操作审批而非再加一道密码。
- 学生改密后旧 Token 仍有效（与 §24 一致），如需强制下线，应在改密成功后遍历 `g_tokens` 删除该学号的全部 Token。

### 25.9 服务端运行约定（用户要求）

- **服务端常驻，不要每次验证完就关掉**：日常改动只需重启 App 或重新登录，服务端一直开着（`/api/health` 探活即可，返回 `db:true` 说明连库正常）。
- 唯一**必须**先停的场合：重编 `server.exe`——Windows 会因文件占用导致链接失败，流程固定为 `stop → build → start`。`server/stop_server.bat` 就是给这一步和收工用的。
- 除非调试节流/Token 这类**内存态**逻辑（重启即清零），否则不要为了"干净状态"重启服务端；重启意味着全体在线用户掉线。
- 若后台进程随 IDE/会话结束被回收，让用户双击 `server\start_server.bat` 即可常驻（该脚本会自检 3306 端口）。

---

## 26. 文档一致性收尾 + 文档维护约定（2026-11-09）

### 26.1 版本号口径对齐

`VERSION.md` 早已写入 v3.1，但 `/api/health` 仍返回 `"version":"3.0"`、使用说明页首也标"文档对应版本 v3.0"——评审点开接口会以为版本没动。本轮把 `server.cpp` 中 health 的 version 改为 **`3.1`**，重编重启后实测：

```
{"code":0,"msg":"ok","data":{"server":"club-system-server","version":"3.1","db":true,...}}
```

`docs/使用说明.md` 页首与 §3.2 的健康检查说明同步改为 3.1；`README.md` 接口表补 `version 当前 3.1`。

### 26.2 重建 Word 版使用说明

旧 `使用说明文档.docx` 停在 2026-10-30（v3.0）：全文无"登录密码"、注销仍写"输学号"，而 README 却宣称它"与 md 同源"，属**会误导的过期交付物**。

- 本机 `python` 为 Store 存根、无 pandoc，故改用 **Word 16 COM**：先把 md 转成带 CSS 的 HTML（`h1/h2/h3` 对应 Word 内置 Heading 1-3，表头 `#1F3864` 白字、隔行 `#EDF2FA`、代码块灰底、引用块左边框），再 `Documents.Open` → `SaveAs2(..., 16)`。
- 页脚写入居中页码字段（`wdFieldPage`），字号 9pt。
- 生成结果：**17 页 / 9 表 / 1.1 万字**；抽查 `v3.1`、`登录密码`、`5.11 账号注销`、文末回归章节均在，无"输入本人学号"残留。
- 生成脚本 `%TEMP%\md2docx.ps1`（一次性工具，未入库）；若日后要复现，可参照本节描述重写，或装好 Python 后用 python-docx 版本。

### 26.3 文档维护约定（用户明确要求，后续每次改动都执行）

1. **改完代码就同步文档**，不留"下次再说"：接口/行为变了改 `docs/使用说明.md`，目录/接口表/命令变了改 `README.md`，版本能力变了改 `VERSION.md`，过程记录追加到本文件。
2. **本文件只追加不覆盖**：新章节号 = 现有最大节号 + 1（当前到 §26），写前先 `Select-String '^## '` 确认，避免并行会话互相覆盖（§18 曾因此丢失重建）。
3. **md 改完必须重建 docx**，否则 Word 版必然落后一版——本轮就是这种情况的后果。
4. **版本号三处必须一致**：`VERSION.md` 段落标题、`/api/health` 的 `version`、使用说明页首标注。
5. **文档与代码同一次 commit/push**，commit message 里写清范围（如本轮"v3.1 文档收尾"），不要代码一个提交、文档拖到下一轮。
6. **不再新增 CODEBUDDY 类"给 AI 的须知"文档**：内容必然与 HANDOFF 重复并迅速过期。交接只维护两份——本文件（历史与决策）+ `README.md`（当前状态），使用说明另算。

### 26.4 本轮清理

| 项 | 处置 |
|---|---|
| `CODEBUDDY.md` | 删除（与 §16.2/§23/§24/§25 重复且已过期：仍写"学号+姓名"） |
| `server/rename_demo_users.sql` | 删除（2026-10-28 一次性改名迁移，早已执行，新库由 seed 直接给新名字） |
| `server/build.log` | 删除（0 字节生成物，`build.bat` 每次重建） |
| `.gitignore` | 补 `.codebuddy/`（工具内部数据，防误提交） |
| `server/stop_server.bat` | 新增并登记进 README / 使用说明 |

## 27. v3.2 P0 修复（2026-11-09）

六项都是"演示时会被当场问住"的问题，逐条给根因与修法。

### 27.1 报名时间冲突（学时双算）

**根因**：`handleSignupAdd` 只校验名额与活动状态，从不看该生已有报名的时间窗。同一时段报两个活动，两边都通过审核就双算学时。

**修法**：事务内**先锁学生行**再查冲突，锁序固定"学生 → 活动"（报名与审核都走这个顺序，避免 ABBA 死锁）：

```sql
SELECT id FROM student WHERE stu_no=? FOR UPDATE;
SELECT a.title FROM signup s JOIN activity a ON s.activity_id=a.id
 WHERE s.stu_no=? AND s.status<>2 AND a.id<>?
   AND a.start_time<? AND a.end_time>? LIMIT 1;
```

命中返回 `409「与「XX 活动」时间冲突，请先撤销原报名」`。活动时间为 NULL 时跳过校验（历史数据无时间窗，不能因此拒绝报名）。学生行锁顺带把"同一学生的并发报名"串行化——否则两个请求同时查冲突都为空，照样双报。

### 27.2 同步 prune 误删

**根因**：`SyncService.syncMySignups` 固定拉 5 页（`size=200`，上限 1000 条）就执行 prune，把"服务器没返回"的本地记录删掉。超过 1000 条时，后 5 页的有效记录会被当成"服务器已删"清掉。

**修法**：循环拉到 `has_more=false`，最多 50 页保护；**只有完整拉完才 prune**，否则保留本地并提示"数据量超限，已跳过清理"。

### 27.3 深色模式

**根因**：`Theme.ets` 是 `static readonly primary: string = '#2F6BFF'` 这类硬编码，`resources/dark/color.json` 只有 `start_window_background`，系统切深色时整屏发白。

**修法**：20 余个颜色常量改为 `ResourceColor = $r('app.color.c_xxx')`，`base/element/color.json` 与 `dark/element/color.json` 补齐**同名**两套 token（含 `c_gradient_start` 补渐变起点）。页面里散落的 `Color.White`、`'#F3F4F6'`、`Color.Yellow` 等一并收敛为 token。全项目没有对 Theme 颜色做字符串拼接/截取，因此调用点无需改语义。

**踩坑**：批量替换后编译报 22 处 `Type 'ResourceColor' is not assignable to type 'string'`——都是辅助函数把颜色声明成 `string`（`actColor()`、`tag(color: string)`、`markCircle()` 等）。把参数/返回值类型改成 `ResourceColor` 即可，不要试图 `.toString()` 转回字符串（Resource 没有稳定字符串值）。

### 27.4 报表图表

达标率用 `Progress({ type: ProgressType.Ring, value, total })`，环中心叠百分比；分类分布用 `Row` 外层灰条 + 内层 `Row().width(pct%)` 的横向条形。零依赖、随主题变色。数据源是 `/api/hours/report` 新增的 `by_category`（与明细同口径）。

### 27.5 CSV 落盘

`picker.DocumentViewPicker().save()` 让用户自选目录，`fileIo` 写入并保留 UTF-8 BOM；用户取消或权限失败时**回退**到"复制剪贴板 + 显示沙箱路径"，保证任何情况下都能把数据取走。三个页签（排行 / 明细 / 预警）共用一套导出函数。

### 27.6 登录失败计数清理

`g_login_fail` 原先只增不减，长期运行会被扫描攻击撑大内存。现在 `loginFailAdd` 在 `size > 4096` 时先扫一遍删除过期项；触发频率低，摊还成本 O(1)。

## 28. v3.2 P1 四项（2026-11-09）

### 28.1 分类与学时规则

- `activity.category`（七大类 key）/ `signup.category`（报名时快照，报表不依赖 JOIN）；
- 规则全部存 `sys_config`：`rule.<cat>.max_activity`、`rule.<cat>.max_total`，**0 = 不限**，默认全 0；
- 审核通过顺序：`hours = min(activity.hours, max_activity)` → 锁学生行统计该类别已认定 `used` → `allowed = min(hours, max_total - used)`；`allowed<=0` 仍通过但记 0，`remark` 追加"超出「XX」类别上限"；
- 接口透出 `category`，活动增改做白名单校验（非法值回落 `sports`）。**编辑时未传 category 保留原值**，避免旧客户端把类别刷回默认。

### 28.2 学分预警

`GET /api/report/warning`（管理员）：`status=1 AND COALESCE(total_hours,0) < required_hours`，返回 `stu_no/name/dept/total_hours/sign_count/gap/last_activity_at`，按 `gap` 降序。App 报表页新增"预警"页签 + CSV 导出。

### 28.3 动态签到码 + 签退

- `g_signin_secret` 启动时 `BCryptGenRandom` 生成（重启即失效，不落盘）；
- `code = HMAC-SHA256(secret, activity_id + ":" + window)` 取十进制 6 位，`window = now_ms / 60000`；
- 管理员 `GET /api/activity/signin_code` 拿当前码与 `expire_in`；成员 `POST /api/signin/code` 校验 `window` / `window-1`（前后 60 秒宽限），通过后复用 RFID 的"无报名则建并通过 / 待审则通过 / 已通过仅签到 / 已驳回拒绝"逻辑，`client_id = code-<stu_no>-<activity_id>` 保证幂等；身份只取 Token，**不接受 body 里的学号**；
- `POST /api/signin/out` 写 `signout_at`；折算 `ratio = min(1, 在场分钟/计划分钟)`，`hours = round(hours*ratio*2)/2`，下限 0.5，只在 `checkin=1 && signout_at IS NOT NULL` 时生效——**仅 RFID 单点签到的记录仍按全额学时**，这是基线不变的关键。

### 28.4 库存条件更新

`activity.taken` + `UPDATE activity SET taken=taken+1 WHERE id=? AND (capacity=0 OR taken<capacity)`，`affected_rows=1` 才算占位；为 0 时回查 `taken/capacity` 区分"名额已满"与"活动不存在/已下线"。占位/回补收敛为 `signupTakeSlot` / `signupReleaseSlot` 两个 helper，禁止业务代码散写 `taken`。回补覆盖：管理员驳回、学生撤销、学生注销级联删报名、审核撤销（若有）。启动时 `dbEnsureSchema` 按 `COUNT(*) WHERE status<>2` 重算一次，`init_db.sql` / `seed_demo_data.sql` 末尾各回填一次，防止历史漏改点长期漂移。

### 28.5 约定与验证

- **锁序**：任何同时碰 `student` 与 `activity` 的事务，一律学生行在前、活动行在后；
- **基线保护**：新规则默认 0、签到折算只认 `signout_at`，因此 8 活动 / 19 报名 / 5 人 / 20.5 学时 / 榜首李铭 5.5 / 待审注册 3 全部不变（已实测）；
- **接口只增不改**：`verify_ui_contract.py` 已放行并断言 `category` / `taken` / `signout_at` 类型；
- **文档四处同步**：`docs/使用说明.md` §5.3/5.5/5.6/5.7/5.13/5.14、`README.md` 功能与接口表、`VERSION.md` v3.2 段与 v4 待办、本文件 §27/§28；`使用说明文档.docx` 由 md 重新生成；
- **本轮实测**：服务端零警告编译 + 常驻 8000；PowerShell 冒烟 22 项全绿（冲突 409 / taken 自洽 / 签到码 / 签退折算 / 类别上限 / 预警权限 / 基线）；App `assembleHap` BUILD SUCCESSFUL 0 error。本机 `python` 仍是 Store 存根，7 个 Python 脚本未实跑，逻辑已按实测接口口径对齐。

## 29. v3.2 补丁：边界测试数据 + 数据一致性核验（2026-11-09）

### 29.1 为什么要单独造测试数据

演示库只有 19 条"好数据"：全部合法类别、全部正常时间、`taken` 全对、`category` 全非空。这种数据**测不出** v3.2 新增的兼容分支（老快照为空、时间缺失、0 学时、满员、漂移计数）。因此新增一套**与基线隔离**的测试数据集，把边界一次性压出来。

隔离靠命名空间，不靠"记得删"：

| 表 | 测试命名空间 |
|---|---|
| activity | id 9001–9010 |
| student | 学号 `T9001`–`T9008` |
| signup | id 9001–9010、`client_id` 前缀 `tdata-` |
| hours_total | 学号 `T9%` |

`testdata_clean.sql` 只按这四个条件删，并复位自增与 `rule.skill.*`，所以**清理后必然回到基线**（已用 14 项断言复核）。

### 29.2 测试数据覆盖了什么

10 个活动分别对应：0 学时+不限容量、满员（capacity=2 已占 2）、时间窗 NULL、已结束、已下线、零时长（start=end）、特殊字符/emoji/4 字节标题、4.5 学时大额、时间重叠 A/B。8 个学生覆盖：正常、待审核、已驳回、长姓名、无班级、零学时、学时临界、小写卡号。10 条报名覆盖：三种状态、刷卡签到未签退、零时长已签到、类别快照为空（2 条）、冲突基准。

另外**故意把 7 个活动的 `taken` 写错**（99 和 0），用来验证 `dbEnsureSchema` 的启动对账——这是"漏改点长期漂移"的唯一兜底。

### 29.3 执行顺序（关键：重启在 seed 与 api 之间）

```
testdata_seed.sql
verify_test_data.ps1 -Stage schema   # 11 项
verify_test_data.ps1 -Stage seed     # 10 项（确认漂移/空快照确实入库）
restart server.exe                   # 触发 taken 对账 + category 回填
verify_test_data.ps1 -Stage api      # 48 项（真实接口打全部边界）
testdata_clean.sql
verify_test_data.ps1 -Stage baseline # 14 项（基线复原）
```

### 29.4 核验结果与两处修复

83 项断言全绿。过程中确认了两个**真实缺陷**（不是测试脚本写错）：

1. **0 学时活动签退凭空发 0.5 学时**：折算先算 0，再被"下限 0.5"抬走。修法：折算条件加 `actHours > 0`；导入/历史 0 学时活动签退后保持 0。
2. **签退折算步进与文档不一致**：文档写"0.5 学时步进"，代码用 `roundHours()`（0.1）。修法：`floor(x*2+0.5)/2` 后再夹 `[0.5, 活动学时]`；用例把签到时间前移 50 分钟，4.5×50/120=1.875 → **2.0**（旧实现会记 1.9）。

其余"异常"经核实都是预期行为：`taken` 漂移被启动修正、空类别快照被回填、`remaining=-1` 表示不限、零时长活动不折算。

### 29.5 本机没有 Python 的替代方案

`python` 是 Microsoft Store 存根（`python -V` → 9009），所以核验入口写成 `verify_test_data.ps1`：用 `mysql.exe` 直查 + `Invoke-RestMethod` 打接口。踩坑两条（后来者直接抄结论）：

- PowerShell 5.1 读**无 BOM 的 UTF-8 脚本**会按 ANSI 解析，中文断言串直接导致语法错误 → `.ps1` 必须存 UTF-8 **BOM**；
- 函数返回单个字符串时 `$rows[0]` 取到的是**首字符**（不是首行）→ 先 `@()` 包一层再 `[string]`，否则 `COUNT(*)=10` 会被读成 `1`。

报告全文：`docs/数据一致性核验-v3.2.md`。

## 30. v4.0：申诉闭环 / 规则可视化 / 异常检测（2026-11-09）

计划见 `docs/V4-PLAN.md`，验收脚本 `server/verify_v4.ps1`（45 项全绿）。三件事都围绕"学时认定可信"，不引入新依赖。

### 30.1 学时申诉：为什么不是简单加一张表

- **并发**：`appeal/add` 与 `appeal/audit` 都按"学生行 → 申诉/报名行"加锁，和报名/审核同序，避免 ABBA；处理用 `UPDATE ... WHERE status=0` + 影响行数判断，两位管理员同时点只生效一次（实测第二次返回 409）。
- **调学时**：通过后不是"总额 += 差额"，而是按该生 `signup` 明细 **重算** `hours_total`（`INSERT ... SELECT SUM(hours) ... ON DUPLICATE KEY UPDATE`）。差额法在历史已漂移时会放大误差，重算法自带修复。
- **重复申诉**：没建 `(signup_id,status)` 唯一键——那会让"驳回后再次申诉"永远失败。改为学生行锁串行化 + `SELECT ... WHERE signup_id=? AND status=0` 预检；并发后到者拿 409。
- **App 本地没有服务端 signup.id**：`LocalSignup.id` 是本地自增。申诉前用 `/api/signup/list?activity_id=` 查本人已通过记录拿服务端 id，避免改本地库结构。

### 30.2 规则接口：先校验后落库

`handleConfigSet` 原实现只认 `required_hours`，且默认值 `-1` 会让"只传 rules"的请求直接 400。重写后：

- `required_hours` 与 `rules` 均可选，但至少给一个；
- 所有类别/规则项/数值先校验进内存 `vector<KV>`，全通过才开事务逐条 upsert；
- 这样不存在"前 3 类改了、第 4 类报错"的半配置状态；
- `GET` 保留原来的平铺 `rule.<cat>.<key>`（老客户端），新增结构化 `rules`（新客户端）。

### 30.3 异常检测：一个 SQL 模式的坑

批量签到最初写成：

```sql
GROUP BY a.id, FLOOR(UNIX_TIMESTAMP(s.checked_at)/600)
```

`only_full_group_by` 报 1055：SELECT 里的 `DATE_FORMAT(FROM_UNIXTIME(FLOOR(...)))` 与 GROUP BY 表达式被认为"不等价"。改成 `SELECT ... AS w ... GROUP BY a.id,w` 即可（MySQL 允许按别名分组）。**dbQuery 失败时该段会静默为空**，所以第一次跑验收是 43/45，批量签到用例把这个问题抓了出来。

同样值得记住的还有建表坑：`appeal` 最初写 `DEFAULT CHARSET=utf8mb4`，而 `student` 是库级 `utf8mb4_unicode_ci`，外键直接报 **3780 incompatible**。显式写 `COLLATE=utf8mb4_unicode_ci` 才通过；`dbEnsureSchema` 的建表失败是静默的，靠验收脚本查表存在性才发现。

### 30.4 App 侧改动

| 页面 | 改动 |
|---|---|
| `MySignupPage` | 已通过记录增加"学时申诉"内联输入与状态回显；进页面拉一次申诉列表 |
| `AuditPage` | 新增第三个模式"学时申诉"：待处理角标、通过面板（可填 0~活动学时）、驳回面板（必填理由）、已处理结果 |
| `SettingsPage` | 管理员"学时规则"卡片：七大类 × 两列输入，前端先校验 0~999 整数再提交 |
| `HoursReportPage` | 新增"异常检测"页签：三个计数块 + 三类明细 + CSV 导出 |
| `Models.ets` | `AppealInfo` / 三类异常接口与解析函数 |

App 构建 `assembleHap` 0 error；UI 未在模拟器实测（本轮无设备），逻辑与接口字段已由 `verify_v4.ps1` 覆盖。

### 30.5 文档工具的变化

`tools/md2docx.ps1` 已从"Word COM + HTML"改为**纯 OOXML 打包**（ZipArchive）。原因：Word 在非交互会话里会卡在隐藏对话框，进程存活但永远不产出文件（本次连续复现两次）。新实现秒级完成、可重复，输出含 Heading 样式、表头深蓝底、隔行浅底、代码块灰底与页脚页码。**md 改完直接跑脚本重建 docx**：

```bat
powershell -ExecutionPolicy Bypass -File tools\md2docx.ps1 -Md docs\使用说明.md -Docx 使用说明文档.docx
```

### 30.6 验收结果

- `verify_v4.ps1`：权限 6 + 申诉 14 + 规则 8 + 异常 6 + 清理/基线 11 = **45 项全绿**；
- 申诉用例覆盖：越权（管理员发起、学生处理）、他人报名、理由过短、重复待处理、通过调学时、汇总重算、重复处理、驳回必填理由、驳回不改学时；
- 规则用例覆盖：结构化下发、七大类齐全、未知类别/负数拒绝、设置 1.5 后审核裁剪到 1.5、复位 0；
- 异常用例覆盖：5 条 10 分钟内签到命中 burst、30 小时未签退命中、学时 5>4 命中；清理后异常归零；
- 基线：8 活动 / 19 报名 / 5 人 / 20.5 学时 / 李铭 5.5 / 待审 3。
