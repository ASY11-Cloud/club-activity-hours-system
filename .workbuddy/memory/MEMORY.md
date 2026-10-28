# 项目长期记忆（chapter03 · 题号 86 社团活动报名与学时认定系统）

## 文档约定
- **不再产出《修改说明》类文档**（md/docx 均已删除）。改动交接统一写根目录 `HANDOFF.md`，面向接手项目的 AI / 评审者，内容是"改了什么、为什么、在哪、怎么验、环境坑"。多轮改动按章节追加（第 11 节为豆包 v2.2，第 12 节为 v2.3 复查）。
- `docs/使用说明.md` 与根目录 `使用说明文档.docx` 是面向使用者的操作手册，与 HANDOFF 分工不同，保留维护。
- 不为记录改动而生成 Word/中间产物（`output/` 之类不留档）。

## App 架构（v2.2 起）
- 冷启动 `EntryAbility.loadContent('pages/LandingPage')` 引导页；登录/退出根级切换统一走 `common/Nav.resetTo()`（clear + replaceUrl），避免 MainPage 叠栈。
- 主界面 `MainPage` 为 TabBar：活动 / 管理（仅管理员）/ 我的；活动广场已并入「活动」Tab，**没有独立 ActivityListPage**；`pages/Index.ets` 已删除。
- 二级页守卫统一用 `common/GuardViews.ets`（LoginGuardView / AdminGuardView）。
- 已删页面的 router 引用必须清干净，`main_pages.json` 与 pages 目录需一一对应（当前 12 项）。

## 验证基线
- 演示数据：8 活动 / 19 报名 / 5 人共 20.5 学时（榜首李四 5.5，张三 4.5），达标线 20，待审注册 3 条。
- 只读回归：`verify_demo_data.py` 8 项、`verify_v3.py` 34 项、`verify_ui_contract.py` 48 项。
- `test_api.py` 26 项，**会真实审核 `ptest-audit-1` 使张三 +2.0 学时**，跑完需按 HANDOFF 9.6 还原。
- `verify_v3.py` 会留下测试活动，清理顺序：先 `DELETE signup`（JOIN activity 按标题）→ `DELETE activity` → 再调 `POST /api/hours/rebuild` 把学时按已通过报名重建回 20.5（只删记录不回滚学时，会漂移）。

## 环境
- 唯一可用编译器：Dev-C++ 自带 TDM g++ 4.9.2，`-std=c++14`。
- `build.bat` 必须 GBK + CRLF。
- DevEco 在 `D:\HuaWei\DevEco Studio`，构建需 `DEVECO_SDK_HOME` 并用其自带 node。
- 学生登录口径：学号 + 姓名（不是密码）。
