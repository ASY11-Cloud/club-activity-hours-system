# 社团活动报名与学时认定系统

题号 86 · HarmonyOS 课程设计（进阶级・系统 · 95 分）

**鸿蒙 App（SQLite 本地库）+ 自主 C++ Web 服务器（服务端 MySQL）+ ESP32 RFID 刷卡签到扩展**

## 功能总览

- 活动发布：管理员创建活动（名称 / 内容 / 地点 / 时间 / 学时 / 人数上限），支持**本地草稿**保存与一键同步发布到服务器；时间采用**滚轮选择器**（DatePicker + TimePicker），自动校验“结束晚于开始、开始不早于当前”，杜绝非法输入
- 活动报名：普通成员浏览并报名，记录同时写入**本地 SQLite** 与服务器 MySQL，本地/服务端双重幂等去重
- 审核认定：管理员在审核中心“通过 / 驳回”，通过后服务器**事务化自动累计学时**，不重复累计
- 学时报表：成员排行 + 认定明细，**本地 SQLite 统计与服务器 MySQL 统计双端对比**
- 服务器实时日志：每次请求内存日志 + MySQL `request_log` 双写，毫秒级时间戳，管理员在线查看
- 嵌入式扩展：ESP32 + MFRC522 读卡实机刷卡签到，到场即认定学时

## 系统架构

```
鸿蒙 App (HarmonyOS relationalStore 本地库)
   │  HTTP (10.0.2.2:8000 模拟器 / 宿主机局域网 IPv4 真机)
   ▼
自主 C++ Web 服务器 (bind 0.0.0.0:8000, Token 鉴权, 事务化报名/学时)
   │
   ▼
MySQL 8.0 (club_system: admin_user / student / activity / signup / hours_total / request_log)
```

- 双角色权限：**管理员**（发布 / 审核 / 学时全量 / 服务器日志）与**普通成员**（报名 / 我的报名 / 本人学时），服务端 Token 统一校验 + App 页面级守卫
- 数据一致性三层保证：本地唯一 `client_id` 幂等 + 服务端唯一键（`uk_client`、`uk_act_stu`）去重 + 事务化容量 / 学时累计

## 目录结构

```
chapter03/
├── chapter03/                 # 鸿蒙工程（DevEco Studio 打开此目录）
│   └── entry/src/main/ets/    # 页面与数据层源码
│       ├── common/            # ApiClient / AppConfig / DbHelper / Models
│       └── pages/             # 登录、首页、活动广场、报名、发布、审核、学时报表等
├── server/                    # 自主 C++ Web 服务器
│   ├── server.cpp             # 全部服务端逻辑（含解析、校验、Token、事务、日志）
│   ├── init_db.sql            # MySQL 建库建表 + 演示数据
│   ├── test_api.py            # 20/20 回归测试
│   └── build.bat              # 编译脚本
├── esp32_rfid/rfid_esp32.ino  # ESP32 + MFRC522 刷卡签到固件
└── 使用说明文档.docx           # 使用说明（含验收演示流程与 FAQ）
```

## 快速开始

1. 初始化数据库：`mysql -u root -p123456 --default-character-set=utf8mb4 -e "source C:/.../server/init_db.sql"`
2. 编译服务端（MinGW）：`g++ -std=c++11 -O2 -Wall server.cpp -o server.exe -I "C:\Program Files\MySQL\MySQL Server 8.0\include" -L "C:\Program Files\MySQL\MySQL Server 8.0\lib" -lmysql -lws2_32`，运行 `server.exe`（监听 0.0.0.0:8000）
3. 构建鸿蒙 App：`hvigorw assembleHap --mode module -p product=default --no-daemon`，产物 `entry-default-unsigned.hap`
4. 安装运行：`hdc install -r entry-default-unsigned.hap`，模拟器默认服务器地址 `10.0.2.2:8000`

## 演示账号

| 身份 | 账号 | 口令 | 说明 |
|---|---|---|---|
| 管理员 | admin | admin123 | 账号 + 密码 |
| 普通成员 | 2023001 | 张三 | 学号 + 姓名 |
| 普通成员 | 2023002 | 李四 | 学号 + 姓名 |
| RFID 卡 | A1B2C3D4 | — | 张三签到卡（扩展） |
| RFID 卡 | E5F60708 | — | 李四签到卡（扩展） |

## 验收演示流程

报名 → 同步 → 服务端审核 → 学时累计双端一致；服务器实时请求日志；本地 SQLite 可查；MySQL 各表可查。详细步骤见《使用说明文档.docx》。
