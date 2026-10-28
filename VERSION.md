# 社团活动报名与学时认定系统 · v1.0

> 归档说明：本分支为鸿蒙课程设计（题号 86）**第一版设计**的完整快照，
> 归档于 2026-10-28，用于大改版前留存基线。后续 v2.0 将重构为
> 「登录/注册引导页 + 底部 TabBar 分页 + 注册审核」的新架构。

## 版本基线

- commit: `3a09955e`（main 分支在 v1.0 归档时的最新提交）
- 鸿蒙 App（ArkTS）：首页卡片式导航（Index）+ 全屏功能页（router.pushUrl）
- 服务端：C++ Winsock 多线程 HTTP 服务器（server.cpp）+ MySQL 8.0（club_system 库）
- 本地库：SQLite relationalStore（草稿/报名记录/登录会话）

## v1.0 功能清单

- 双角色登录：管理员（账号+密码）/ 普通成员（学号+姓名），Token 鉴权
- 活动发布：表单 + 本地草稿箱（SQLite），可同步发布到服务器
- 活动广场：浏览活动列表、报名（幂等去重、满员禁用）
- 我的报名：本地 SQLite 记录 + 服务器同步、状态回写
- 审核中心：管理员审核报名（通过/驳回 + 备注），自动累计学时
- 学时报表：排行榜 + 个人明细（双端一致）
- 服务器实时日志：自动刷新、显示请求详情（同步写 MySQL request_log）
- 设置页：服务器地址配置、登录态展示、退出登录
- 时间选择：DatePicker + TimePicker 两级滚轮（杜绝随意输入）
- 权限矩阵：页面级守卫（非管理员访问管理页显示无权限）
- 嵌入式扩展：ESP32 + RC522 RFID 刷卡签到（esp32_rfid/rfid_esp32.ino）

## 目录结构

```
chapter03/            # 鸿蒙工程（DevEco Studio 打开此目录）
server/               # C++ 服务端（server.cpp / init_db.sql / build.bat / test_api.py）
esp32_rfid/           # RFID 刷卡签到固件
docs/                 # 使用说明文档
```
