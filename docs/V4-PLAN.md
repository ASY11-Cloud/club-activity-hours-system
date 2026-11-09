# v4.0 开发计划：从"能演示"到"能运营"

- 基线：v3.2（`5bcf487`，含数据一致性核验补丁）
- 目标版本：v4.0（服务端 `/api/health` → `4.0`）
- 约束：零新增依赖（沿用 C++14 + MySQL 8.0 + ArkTS/ArkUI + SQLite）；**演示基线零漂移**（8 活动 / 19 报名 / 5 人 / 20.5 学时 / 榜首李铭 5.5 / 待审注册 3）

## 1. 为什么是这三件事

v3.2 的核验暴露了三个"运营层"缺口：

1. **学时结果不可申辩**：审核通过后，学生认为学时算少了（签到时长、类别上限裁剪）只能线下找管理员，系统里没有任何入口与留痕；
2. **规则只能改库**：`rule.<类别>.max_activity/max_total` 存在 `sys_config`，但 `/api/config/set` 只认 `required_hours`，改规则必须登 MySQL——核验时就是直接 UPDATE 的；
3. **异常不可见**：短时间批量签到、签到后长期不签退、认定学时大于活动学时，这些异常目前只能靠人肉翻日志。

三件事都直接服务于"学时认定可信"，且不改变现有 API 语义，风险可控。

## 2. 功能范围

### F1 学时申诉闭环

**流程**：学生对"已通过"的报名发起申诉 → 管理员在审核中心"学时申诉"页签处理 → 通过时可调整认定学时（0 ~ 活动学时）并自动修正 `hours_total`；驳回需填理由。全程留痕。

**数据表**：

```sql
CREATE TABLE appeal (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  stu_no       VARCHAR(20) NOT NULL,
  signup_id    INT NOT NULL,
  reason       VARCHAR(500) NOT NULL,
  status       TINYINT NOT NULL DEFAULT 0 COMMENT '0待处理 1已通过 2已驳回',
  reply        VARCHAR(500) NOT NULL DEFAULT '',
  hours_before DECIMAL(5,1) NOT NULL DEFAULT 0,
  hours_after  DECIMAL(5,1) NULL,
  created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
  handled_at   DATETIME NULL,
  handler      VARCHAR(50) NOT NULL DEFAULT '',
  UNIQUE KEY uk_pending (signup_id, status),
  KEY idx_stu (stu_no),
  KEY idx_status (status),
  CONSTRAINT fk_appeal_signup FOREIGN KEY (signup_id) REFERENCES signup(id),
  CONSTRAINT fk_appeal_student FOREIGN KEY (stu_no) REFERENCES student(stu_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

> "同一报名最多一条待处理申诉"由**学生行锁串行化 + 业务校验**保证（并发发起时后到者拿到 `409`），
> 不建 `(signup_id,status)` 唯一键——那会让同一报名只能被驳回一次，反而限制二次申诉。

**接口**：

| 方法 | 路径 | 角色 | 说明 |
|---|---|---|---|
| POST | `/api/appeal/add` | 学生 | `{signup_id, reason}`；仅本人、仅 `status=1`、无待处理申诉 |
| GET | `/api/appeal/list` | 登录 | 学生仅本人；管理员全量，支持 `status`/`page`/`size` |
| POST | `/api/appeal/audit` | 管理员 | `{appeal_id, action: pass\|reject, reply, hours}`；pass 时 `hours` 必须在 `[0, 活动学时]` |

**事务与一致性**（关键）：

- `appeal/add`：锁学生行 → 校验 signup 归属/状态 → 插入；`409` 表示已有待处理申诉；
- `appeal/audit`：锁 appeal 行 → 条件更新 `WHERE status=0`（并发只成功一次）→ pass 时锁学生行 + 更新 `signup.hours` + `hours_total` 按差额增减（`GREATEST(0, ...)`）→ 写 `hours_before/hours_after/handler/handled_at`；
- 申诉**不改变** `taken`（报名仍然有效），不改变审核状态；
- 审计前缀 `AUDIT 学时申诉`。

### F2 学时规则可视化

**接口扩展（向后兼容）**：

- `GET /api/config/get` 增加 `rules` 对象：

```json
{ "required_hours": 20,
  "rules": { "volunteer": { "max_activity": 0, "max_total": 0 }, "...": {} } }
```

- `POST /api/config/set` 支持三种入参（可同时）：
  - `required_hours`（保持原语义，缺省不改）；
  - `rules: { "<cat>": { "max_activity": n, "max_total": m } }`，仅接受七大类 key，数值 `0..999`（0=不限），非法 key 直接 400（不静默丢弃，避免"以为改了其实没改"）。

**App**：设置页管理员新增"学时规则"卡片，7 类 × 2 输入框 + 保存；保存成功后就地回显，规则下一次审核立即生效（服务端每次审核实时读 `sys_config`，无需重启）。

### F3 签到异常检测

**接口**：`GET /api/report/anomaly`（管理员），返回三类只读清单：

| 类型 | 判定 | 用途 |
|---|---|---|
| `burst` | 同一活动、10 分钟窗口内 `checkin=1` 的记录 ≥ 5 条 | 发现"一个人拿一群人的卡/码代签" |
| `not_signed_out` | `checkin=1 AND signout_at IS NULL AND checked_at < NOW()-24h` | 发现"签到就走、不签退"，学时按全额认定偏高 |
| `hours_exceed` | `signup.hours > activity.hours` | 发现历史脏数据/手工改库 |

返回统一结构：`{ generated_at, burst: [...], not_signed_out: [...], hours_exceed: [...], summary: { burst: n, not_signed_out: n, hours_exceed: n } }`。

**App**：学时报表新增"异常"页签，展示三类计数与明细；无异常时显示空态文案。

## 3. 实施步骤

1. **数据层**：`init_db.sql` 增加 `appeal` 表；`dbEnsureSchema` 幂等建表（缺表自动补，老库无需手工迁移）；
2. **服务端**：
   - 申诉三个 handler（含事务、并发、限额校验、审计）；
   - `handleConfigGet` 输出 `rules`，`handleConfigSet` 支持 `rules` 白名单校验；
   - `handleAnomalyReport` 三条 SQL + JSON 组装；
   - 路由注册 + health 版本 `4.0`；
3. **App**：
   - `Models.ets` 增 `AppealInfo`、`AnomalyReport`；
   - `ApiClient` 复用现有 get/post；
   - `MySignupPage`：已通过记录增"申诉"入口 + 状态徽标；
   - `AuditPage`：新增"学时申诉"页签（列表 + 通过/驳回弹窗，通过可填调整学时）；
   - `SettingsPage`：管理员"学时规则"卡片；
   - `HoursReportPage`：新增"异常"页签；
4. **脚本**：新增 `verify_v4.ps1`（申诉闭环 / 规则读写 / 异常判定 / 权限 / 基线），沿用 v3.2 的 PowerShell 口径；
5. **文档**：`docs/使用说明.md` 增申诉、规则、异常章节；`README` 接口表与目录；`VERSION` v4.0 段；`HANDOFF` §30；重建 docx；
6. **回归与发布**：服务端零警告编译 → App `assembleHap` → 基线 8/19/5/20.5/5.5/3 → 提交、打 `v4.0`、推送。

## 4. 验收标准

- 申诉：本人可发起、他人不可；重复待处理 409；管理员通过后学时按差额修正且 `hours_total` 与明细仍相等；驳回不改学时；并发审核只生效一次；
- 规则：读写往返一致；非法类别 400；`0` 表示不限；设置 `volunteer.max_total=5` 后审核一条 3 学时志愿活动，累计被裁到不超过 5；
- 异常：构造 5 条同活动 10 分钟内签到 → `burst` 命中；构造 25 小时前签到未签退 → `not_signed_out` 命中；手工把某条 `hours` 改大于活动学时 → `hours_exceed` 命中；
- 权限：三个新接口的学生/管理员越权矩阵全部符合预期；
- 基线：清理测试数据后 8 活动 / 19 报名 / 5 人 / 20.5 学时 / 李铭 5.5 / 待审 3；
- 构建：服务端 `-O2 -Wall` 零警告；App `BUILD SUCCESSFUL`。

## 5. 不做（留给 v4.1 / v5）

- 签到码离线校验（需客户端时钟同步与密钥分发，安全边界复杂）；
- 申诉附件/图片（需要文件存储与鉴权，超出本版范围）；
- 报表 Excel 多 Sheet + 内嵌图表（当前 CSV + ArkUI 图表已够演示）；
- `signup` 归档与冷热分离（数据量未到瓶颈再设计）；
- 服务端配置热加载（规则已实时读库，只有端口/密钥需要重启）。
