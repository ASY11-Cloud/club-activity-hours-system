# CODEBUDDY.md — 交给接手 AI 的项目须知

> 读者：接手本项目的 AI（CodeBuddy）或新开发者。
> 本文是"上手必读"，记录**环境、基线、红线、取舍**四件事；逐轮改动历史见 `HANDOFF.md`（22 节，只追加不覆盖）。

---

## 0. 项目一句话

题号 86「社团活动报名与学时认定系统」：HarmonyOS ArkTS App（13 页面，6709 行）+ 自研 C++ HTTP 服务器（单文件 `server/server.cpp` 2639 行，25 个接口）+ MySQL 8.0（6 表）+ ESP32/RFID 刷卡扩展（代码就绪，硬件未实测）。版本口径 **v3.x**（`/api/health` 返回 `"version":"3.0"`）。

## 1. 环境与构建

### 1.1 服务端（C++）
- **唯一可用编译器**：Dev-C++ 自带 TDM g++ 4.9.2。PATH 里的 g++ 是 win32 线程模型，**编译含 `std::thread` 的代码必报错**，不要用。完整命令：
  ```
  "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\g++.exe" -std=c++14 -O2 -Wall server.cpp -o server.exe -I "C:/Program Files/MySQL/MySQL Server 8.0/include" -L "C:/Program Files/MySQL/MySQL Server 8.0/lib" -lmysql -lws2_32
  ```
  （在 `server/` 目录内执行；`server.exe` 旁边必须有 `libmysql.dll`，换目录运行会 exit 127——**不是崩溃，是缺 DLL**。）
- `server/build.bat` 必须 **GBK + CRLF** 编码，改完注意保持。
- MySQL：`root / 123456`，库 `club_system`。用 mysql CLI 查库时**必须带** `--default-character-set=utf8mb4`，否则中文乱码。
- **启动/停止**：双击 `server\start_server.bat` / `server\stop_server.bat`（端口 8000）。
  ⚠️ **AI 在会话里后台启动的 server.exe 会随会话结束被杀**——需要服务时请让用户双击 start_server.bat，或者你启动后当轮就把验证做完。
- Token 与登录失败计数都在内存：**服务端重启 = 全员掉线**，App 需重新登录（不是 bug，别"修"）。

### 1.2 App（ArkTS/HarmonyOS）
- DevEco 在 `D:\HuaWei\DevEco Studio`，构建必须带 SDK 环境变量：
  ```
  cd chapter03/chapter03   （注意是嵌套目录）
  DEVECO_SDK_HOME="D:\HuaWei\DevEco Studio\sdk" "D:\HuaWei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default --no-daemon
  ```
- 产物：`chapter03/entry/build/default/outputs/default/entry-default-unsigned.hap`，模拟器安装 `hdc install -r <hap>`。**HAP 未签名**，真机装不上（需用户在 DevEco 登录华为账号做调试签名，AI 代做不了）。
- 模拟器联调地址 `10.0.2.2:8000`；真机要改成宿主机局域网 IP（App 设置页可改）。
- 登录口径：管理员 `admin/admin123`；学生 **学号 + 姓名**（姓名当密码）。

## 2. 验证基线（改完任何东西必须回归）

| 脚本（server/ 下） | 项数 | 会改数据？ |
|---|---|---|
| `verify_demo_data.py` | 8 | 否（只读） |
| `verify_cancel.py` | 4 | 否（只读） |
| `verify_ui_contract.py` | 48 | 否（只读） |
| `test_p1p2.py` | 26 | 否（自建自清理） |
| `test_cancel_api.py` | 22 | 否（自建自清理） |
| `verify_v3.py` | 34 | **留测试活动**，清理法见下 |
| `test_api.py` | 26 | **会改数据**：真实审核 `ptest-audit-1` 使张三 +2.0 学时，跑完按 HANDOFF §9.6 还原 |

**演示数据基线（不许漂移）**：8 活动 / 19 报名 / 5 人 / 共 20.5 学时 / 榜首李铭 5.5 / 达标线 20 / 待审注册 3。

- `verify_v3.py` 跑完的清理顺序：先 `DELETE signup`（JOIN activity 按标题找）→ `DELETE activity` → 再调 `POST /api/hours/rebuild` 把学时按已通过报名重建。**只删记录不回滚学时，基线会漂移**（历史上真漂移过一次）。
- 任何"汇总 vs 明细"不一致，修复入口是 `POST /api/hours/rebuild`（仅管理员）。

## 3. 红线：这些坑已经踩过，别再踩

### 3.1 服务端
- **禁止 `thread_local`**（尤其非平凡对象如 `std::string`）：MinGW 4.9 的 emutls 在线程退出析构时**必崩，且无任何日志**。请求级状态用响应头传递——现有范例：审计说明写进 `X-Audit-Note` 响应头，管线里 `takeAudit()` 摘出拼进 `request_log.detail`。
- **业务错误 = HTTP 200 + body 里的 code**（0 成功；401/403/404/500 业务语义）。这是全 App 依赖的约定，前端 `ApiClient.ets` 按 body code 做 401 清登录态。**不要改成真 HTTP 状态码**，除非连前端一起改并全量回归。
- 报名/审核/刷卡的并发正确性靠「事务 + `FOR UPDATE` 行锁 + 条件 `UPDATE ... WHERE status=0` + `mysql_affected_rows` 校验」保证，已由 `test_p1p2.py` 26 项并发用例验证。**动这三条链路必须重跑该脚本**。
- 注销是**硬删除**：事务内按 `signup → hours_total → student` 顺序删 + 回收该学号全部 token + `request_log` 审计保留。**不要给外键加 `ON DELETE CASCADE`**——显式顺序是有意设计（DB 隐式级联会丢审计叙事，且 `hours_total` 外键无 CASCADE 是现状）。
- 确认学号双保险：前端比较一次、服务端再校验一次（`confirm_stu_no`），改接口时两处都要看。

### 3.2 ArkTS
- `@Builder` 的**值参数是快照，不随 @State 刷新**——动态文案必须在 Builder 内部读 `this.xxx`（"共 0 个" bug 的根源）。
- `Tabs.tabBar(CustomBuilder)` 不随 @State 重建 → 主界面用的是**自绘 bottomNav + Stack**（`MainPage.ets`），别改回 Tabs。
- `width('100%')` + 左右 `margin` 会溢出裁字 → 宽度放容器、留白用 `padding`（放 `List` 上）。
- `build()` 内**不允许 `if (...) return`**，条件渲染用 `if/else`。
- `main_pages.json` 与 `pages/` 目录必须一一对应（当前 13 项）；删页面必须同步删 router 引用与 json 条目。
- **界面禁止 emoji**（已全部清零，换成文字方块/图标字），颜色一律走 `Theme.ets` 设计令牌，**不得写 16 进制硬编码色值**（曾专项清过 12 处）。
- CSV 导出已带 UTF-8 BOM（`\uFEFF`，Excel 兼容）且 `Models.ets` 的 `csvCell()` 做了字段转义，别退化。

### 3.3 编码与流程
- 所有 `.bat`：GBK + CRLF；所有源码 UTF-8。批量改 server.cpp 用脚本时**带断言**（count 校验）防误替换。
- `HANDOFF.md` **只追加不覆盖**：新章节号 = 现有最大节号 + 1（当前到 §22），写前先 `grep "^## "` 确认。每完成一节**立即 git 提交**（曾有并行会话覆盖导致 §18 丢失、只能靠工作记录重建的事故）。
- 不再产出《修改说明》类文档；面向使用者的手册是 `docs/使用说明.md`（源）+ `使用说明文档.docx`（由 md 生成）。
- README/VERSION/使用说明 曾被误删过一次又从 git 恢复——**改文档前先 git status，别整体覆盖别人的提交**。

## 4. 有意的取舍（评委问起要能解释，AI 别"顺手优化"）

1. Token / 登录节流在内存：重启掉线换实现简单（文档已写）。
2. HTTP 200 + body code：见 3.1。
3. `hours_total` 冗余汇总 = 物化视图思路，`/api/hours/rebuild` 是重建契约。
4. 学生弱认证（学号+姓名）+ 自助注销即时生效：按用户决定实现的硬删除，如要加强建议改成"提交注销申请→管理员确认"，别私自改。
5. 活动只有上下线没有物理删除（历史数据保留）。
6. 无学期维度、无 HTTPS、无 API 版本前缀：课程范围外。

## 5. 当前遗留（2026-11-09）

- [ ] 课程设计正式报告（需求/架构/库表/接口/测试记录）未写——唯一的大缺口。
- [ ] 真机调试签名未配置（模拟器演示不受影响）。
- [ ] ESP32 + RC522 实物未联调（固件在 `esp32_rfid/rfid_esp32.ino`，刷卡走 `POST /api/signin`，`X-Device-Key` 可选）。
- [ ] 注销两条链路的**界面级**验证未在模拟器跑过（接口级 22+26 项全绿；测试预建账号已消耗，再验需临时建号）。
- [ ] 若有余量：前端抽 `common/api/` 层、服务端线程池限流、`server/run_all.bat` 一键回归。

## 6. 目录速览

```
chapter03/
├── chapter03/entry/src/main/ets/   # App：pages(13) + common(9: ApiClient/AppConfig/DbHelper/
│                                   #      Models/SyncService/Nav/GuardViews/Theme/TimeFmt)
├── server/                         # server.cpp(全部后端) + init_db.sql + 7 个测试脚本
│                                   # + start_server.bat / stop_server.bat + build.bat
├── esp32_rfid/rfid_esp32.ino       # RFID 固件
├── docs/使用说明.md                # 操作手册源文件
├── HANDOFF.md                      # 逐轮改动史（22 节，只追加）
└── 使用说明文档.docx               # 由 md 生成的 Word 版
```
