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
4. **学生登录口径是「学号 + 姓名」**（不是密码），管理员是「账号 + 密码」。写测试时最容易搞错。
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
