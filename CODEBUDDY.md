# CODEBUDDY.md — 交给接手 AI 的项目须知（v5.0 版重写）

> 读者：接手本项目的 AI（CodeBuddy）或新开发者。
> 本文是"上手必读"，记录**环境、基线、红线、取舍**四件事；逐轮改动历史见 `HANDOFF.md`（当前至 §44，只追加不覆盖）。
> ⚠️ 本文件曾在 v3.1 提交中被删除过一次，后恢复——**删除或重写前请先在 HANDOFF 里说明理由**。

---

## 0. 项目一句话

题号 86「社团活动报名与学时认定系统」。当前 **v5.0：认证主体上移为社团**——平台管理员 + 社团账号（club 类型）双角色，社团注册/入社退社审批/成员岗位（leader/minister/member）/活动参与范围（内部活动仅本社团可见）。
技术栈：HarmonyOS ArkTS App（17 页面）+ 自研 C++ HTTP 服务器（`server/server.cpp` ~4800 行，`/api/health` 返回 version 5.0）+ MySQL 8.0 + ESP32/RFID 扩展。

## 1. 环境与构建

### 1.1 服务端（C++）
- **唯一可用编译器**：Dev-C++ 自带 TDM g++ 4.9.2。PATH 里的 g++ 是 win32 线程模型，**编 `std::thread` 必报错**。完整命令（在 `server/` 目录内执行，exe 旁必须有 `libmysql.dll`，换目录跑会 exit 127——不是崩溃，是缺 DLL）：
  ```
  "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\g++.exe" -std=c++14 -O2 -Wall server.cpp -o server.exe -I "C:/Program Files/MySQL/MySQL Server 8.0/include" -L "C:/Program Files/MySQL/MySQL Server 8.0/lib" -lmysql -lws2_32
  ```
- MySQL：`root / 123456`，库 `club_system`。CLI 查库**必须带** `--default-character-set=utf8mb4`。
- **启动/停止**：双击 `server\start_server.bat` / `stop_server.bat`（端口 8000）。
  ⚠️ **AI 会话里后台启动的 server.exe 会随会话结束被杀**——需要长期服务时让用户双击 start_server.bat。
- Token / 登录节流在内存：**服务端重启 = 全员掉线**（不是 bug，别"修"）。

### 1.2 App（ArkTS/HarmonyOS）
- 构建（注意嵌套目录）：
  ```
  cd chapter03/chapter03
  DEVECO_SDK_HOME="D:\HuaWei\DevEco Studio\sdk" "D:\HuaWei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default --no-daemon
  ```
- 产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`；模拟器 `hdc install -r`。**未签名**，真机需用户在 DevEco 登录华为账号配调试签名。
- 模拟器联调地址 `10.0.2.2:8000`；真机改宿主机局域网 IP（App 设置页可改）。
- 登录：管理员 `admin/admin123`；v3.1 起学生为**学号 + 密码**；v5.0 新增**社团账号**（club 类型）。

## 2. 验证基线（v5.0 起 PowerShell 化，自隔离不碰演示数据）

| 脚本（server/ 下，`-ExecutionPolicy Bypass -File` 运行） | 项数 | 覆盖 |
|---|---|---|
| `verify_membership.ps1` | 56 | 社团注册/入社退社审批/复入/岗位边界 |
| `verify_club.ps1` | 60 | 社团账号/换届/公告（`-WithThrottle` 加节流用例） |
| `verify_scope.ps1` | 17 | 内部活动可见性/越权报名 403 |
| `verify_v4.ps1` | 45 | 学时申诉闭环/七大类规则/签到异常 |
| `audit_v4.ps1` | 103 | v4 全量六维测试 |
| `verify_test_data.ps1` | 分阶段 | 一致性核验（需先 seed + restart 对账） |

- 全部自隔离（测试学号 A90xx/V90xx、活动 9100-9299，前后自清理）。
- **Python 回归（2026-11-10 已适配 v5.0，全绿）**：`verify_demo_data` 13、`verify_cancel` 7、`verify_v3` 45、`verify_ui_contract` 63、`test_p1p2` 38、`test_cancel_api` 33。
  - ⚠️ 本机 `python` 是 **Store 存根**（返回 9009）；用 **`D:\WorkBuddy\resources\vendor\python\python.exe`**（3.13）执行。
  - v5.0 已把活动发布/编辑/上下线收敛到**社团账号**，这些脚本里的 `activity/add|update|status` 必须用 `club/club123` 令牌，admin 会 403。
  - `verify_v3.py` 会留下一个测试活动（id>=9000），跑完按 HANDOFF §9.6 清理：删报名 → 删活动 → `POST /api/hours/rebuild`。
- 基线口径：v5 种子在 `server/seed_demo_data.sql`；**19 条报名 = 9 通过 + 8 待审 + 2 驳回演示**（驳回不占名额，所以 taken 合计 17 才是对的）。
- 修复"汇总 vs 明细"不一致的入口：`POST /api/hours/rebuild`（管理员）。

## 3. 红线：这些坑已经踩过，别再踩

### 3.1 服务端
- **禁止 `thread_local`**（非平凡对象）：MinGW 4.9 emutls 线程退出析构必崩且无日志（server.cpp 头部有教训注释）。请求级状态用响应头传递（范例：`X-Audit-Note` + `takeAudit()`）。
- **业务错误 = HTTP 200 + body code**（0 成功；401/403/404/500 业务语义），全 App 依赖此约定，前端只在 `ApiClient.ets` 收口。**别改成真 HTTP 状态码**。
- 并发正确性 = 事务 + `FOR UPDATE` + 条件 `UPDATE ... WHERE status=0` + `affected_rows` 校验。动报名/审核/刷卡链路必须重跑对应验收。
- 注销为硬删除（v3.1 起需密码确认）：事务内 `signup → hours_total → student` 显式顺序删 + token 回收 + 审计保留。**不要加 ON DELETE CASCADE**。
- 越权校验要落在服务端（§43 先例：社团审报名先查 `activity.club_id` 归属，不能只靠前端隐藏）。
- `club_id` 口径统一按**活动归属**（`activity.club_id`），`signup.club_id` 靠启动迁移回填对齐——新增查询别再按学生所在社团过滤。

### 3.2 ArkTS
- `@Builder` 值参数是快照不随 @State 刷新；动态文案在 Builder 内读 `this.xxx`。
- 主界面是自绘 bottomNav + Stack（`MainPage.ets`），别改回 `Tabs.tabBar(CustomBuilder)`（不随 @State 重建）。
- `width('100%')` + 左右 `margin` 溢出裁字 → 留白用容器 `padding`。
- `build()` 内不允许 `if(...) return`，用 if/else。
- `main_pages.json` 与 `pages/` 一一对应（当前 17 项）。
- **界面禁 emoji**（历史清理过；RegisterPage 的 ✓ 是特意替换 emoji 的产物，保留）；颜色一律走 `Theme.ets` 令牌，**禁止 16 进制硬编码**。
- CSV 导出带 BOM + `csvCell()` 字段转义，别退化。

### 3.3 编码与流程
- `.bat`：GBK + CRLF；源码 UTF-8。批量改 server.cpp 带断言防误替换。
- **PowerShell 测试脚本读 DB 中文做断言，头部必须加 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`**——GBK 控制台会把 mysql 的 utf8 输出读成乱码，中文比对必挂（环境相关 flaky，verify_v4 曾假报 FAIL，已全部修过，新增脚本照做）。
- `HANDOFF.md` **只追加不覆盖**：新节号 = 现有最大 + 1，写前 `grep "^## "`；每节完成立即 git 提交（曾有覆盖丢失 §18 的事故）。
- **删除/重写根目录交接文档（含本文件）前先说明理由**——本文件曾被静默删除过。
- 不产出《修改说明》类文档；手册源是 `docs/使用说明.md`。

## 4. 有意的取舍（能解释，别"顺手优化"）

1. Token/节流内存态 → 重启掉线。
2. HTTP 200 + body code。
3. `hours_total` 冗余汇总 = 物化视图，rebuild 是重建契约。
4. 活动只有上下线无物理删除。
5. 无学期维度、无 HTTPS、无 API 版本前缀。

## 5. 当前遗留（2026-11-10）

- [ ] 课程设计正式报告（需求/架构/库表/接口/测试记录）未写。
- [ ] 真机调试签名未配置。
- [ ] ESP32 实物未联调（`esp32_rfid/rfid_esp32.ino`，刷卡走 `POST /api/signin`）。
- [ ] 模拟器界面级验证：§37 引导/登录合并、§43 审核分工两种账号的页签与角标，未实测。
- [x] ~~v3 时代的 python 测试脚本口径过时~~ —— 2026-11-10 已全部适配 v5.0 并跑通（见 §2）。
