-- =====================================================================
-- 测试数据（v3.2 数据一致性核验专用，与演示基线完全隔离）
--
-- 隔离约定（缺一不可，否则会污染演示基线）：
--   活动  id ∈ [9001, 9010]
--   学生  学号 T9001..T9008（id 9001..9008）
--   报名  id ∈ [9001, 9010]，client_id 前缀 'tdata-'
--   学时  hours_total 仅 T9 开头
-- 清理脚本：testdata_clean.sql（幂等，可反复执行）
--
-- 覆盖场景：
--   [容量] 0=不限 / 满员(capacity=2,已占2) / 超大容量(9999)
--   [时间] 无时间窗(NULL) / 已结束 / 零时长(start=end) / 两活动时间重叠
--   [状态] 已下线活动 / 待审核报名 / 已驳回报名 / 已通过报名
--   [签到] 已签到未签退 / 刷卡签到 / 未签到
--   [数据] 0 学时活动 / 学时小数(.5) / 报名类别快照为空(老数据) / 非法类别
--   [计数] 故意把 taken 写错，用于验证服务启动时的对账
--
-- 执行: mysql -u root -p123456 --default-character-set=utf8mb4 < testdata_seed.sql
-- =====================================================================
USE club_system;
SET NAMES utf8mb4;

-- ---------- 0. 幂等清理（保证可重复执行） ----------
DELETE FROM signup     WHERE id BETWEEN 9000 AND 9999 OR client_id LIKE 'tdata-%';
DELETE FROM hours_total WHERE stu_no LIKE 'T9%';
DELETE FROM activity   WHERE id BETWEEN 9000 AND 9999;
DELETE FROM student    WHERE stu_no LIKE 'T9%';

-- ---------- 1. 学生（覆盖 已通过/待审核/已驳回/无班级/长姓名/小写卡号） ----------
-- 登录口令复用演示账号 2023001 的哈希（同一初始密码 123456），只为让 T9001 能调接口，
-- 不复制其身份：哈希串本身不含学号，验证时只认 pwd_hash。
INSERT INTO student (id, stu_no, name, dept, card_no, pwd_hash, status, created_at)
SELECT 9001, 'T9001', '测试-正常', '测试班T01', 'TESTCARD01', pwd_hash, 1, NOW() - INTERVAL 2 DAY
FROM student WHERE stu_no = '2023001';

INSERT INTO student (id, stu_no, name, dept, card_no, status, created_at)
VALUES (9002, 'T9002', '测试-待审核', '测试班T02', NULL, 0, NOW() - INTERVAL 1 DAY);

INSERT INTO student (id, stu_no, name, dept, card_no, status, created_at)
VALUES (9003, 'T9003', '测试-已驳回', '测试班T03', NULL, 2, NOW() - INTERVAL 1 DAY);

INSERT INTO student (id, stu_no, name, dept, card_no, pwd_hash, status, created_at)
SELECT 9004, 'T9004', '测试姓名长度边界用于验证列表截断与换行', '', NULL, pwd_hash, 1, NOW() - INTERVAL 3 DAY
FROM student WHERE stu_no = '2023001';

INSERT INTO student (id, stu_no, name, dept, card_no, pwd_hash, status, created_at)
SELECT 9005, 'T9005', '测试-无班级', '', NULL, pwd_hash, 1, NOW() - INTERVAL 3 DAY
FROM student WHERE stu_no = '2023001';

INSERT INTO student (id, stu_no, name, dept, card_no, pwd_hash, status, created_at)
SELECT 9006, 'T9006', '测试-零学时', '测试班T06', NULL, pwd_hash, 1, NOW() - INTERVAL 3 DAY
FROM student WHERE stu_no = '2023001';

INSERT INTO student (id, stu_no, name, dept, card_no, pwd_hash, status, created_at)
SELECT 9007, 'T9007', '测试-学时临界', '测试班T07', NULL, pwd_hash, 1, NOW() - INTERVAL 3 DAY
FROM student WHERE stu_no = '2023001';

INSERT INTO student (id, stu_no, name, dept, card_no, pwd_hash, status, created_at)
SELECT 9008, 'T9008', '测试-小写卡号', '测试班T08', 'testcard08', pwd_hash, 1, NOW() - INTERVAL 3 DAY
FROM student WHERE stu_no = '2023001';

-- ---------- 2. 活动（10 个边界用例） ----------
INSERT INTO activity (id, title, content, location, start_time, end_time, hours, capacity, category, publisher, status, created_at) VALUES
-- 0 学时 + 不限容量: 校验"零学时通过"与签退不得凭空产生 0.5 学时
(9001, 'T-零学时讲座(边界)', '导入数据可能存在 0 学时活动, 用于验证审核/签退不会凭空产生学时。', '测试场地A', NOW() + INTERVAL 7 DAY, NOW() + INTERVAL 7 DAY + INTERVAL 2 HOUR, 0.0, 0, 'thought', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
-- 满员: capacity=2, 有效报名 2 条(1 通过 + 1 待审) => 剩余 0
(9002, 'T-满员活动(边界)', '容量 2 且已被占满, 用于验证条件更新与"名额已满"提示。', '测试场地B', NOW() + INTERVAL 8 DAY, NOW() + INTERVAL 8 DAY + INTERVAL 2 HOUR, 2.0, 2, 'volunteer', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
-- 无时间窗(NULL): 兼容历史数据, 报名时不参与冲突校验
(9003, 'T-无时间窗活动(兼容老数据)', '历史活动可能没有起止时间, 系统应可正常报名/统计。', '测试场地C', NULL, NULL, 1.5, 10, 'practice', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
-- 已结束
(9004, 'T-已结束活动', '结束时间在过去, 报名应被拒绝。', '测试场地D', NOW() - INTERVAL 10 DAY, NOW() - INTERVAL 9 DAY, 1.0, 5, 'sports', '测试管理员', 1, NOW() - INTERVAL 12 DAY),
-- 已下线
(9005, 'T-已下线活动', 'status=0, 报名应提示活动未开放。', '测试场地E', NOW() + INTERVAL 9 DAY, NOW() + INTERVAL 9 DAY + INTERVAL 2 HOUR, 1.0, 5, 'social', '测试管理员', 0, NOW() - INTERVAL 4 DAY),
-- 零时长: start=end, 折算时 planned=0, 不得除零
(9006, 'T-零时长活动(边界)', '开始与结束相同, 用于验证折算除零与时长展示。', '测试场地F', NOW() + INTERVAL 5 DAY, NOW() + INTERVAL 5 DAY, 1.0, 3, 'innovation', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
-- 特殊字符 + emoji + 超长标题(100 字符)
(9007, 'T-特殊字符 & "引号" <标签> 🚀 长度边界', '包含引号、尖括号、emoji 与 4 字节字符, 验证 utf8mb4 与 JSON 转义。', '测试场地G', NOW() + INTERVAL 6 DAY, NOW() + INTERVAL 6 DAY + INTERVAL 2 HOUR, 4.5, 9999, 'skill', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
-- 志愿公益大额: 与类别上限规则配合
(9008, 'T-志愿公益-大额学时', '3.0 学时, 用于验证类别累计上限裁剪。', '测试场地H', NOW() + INTERVAL 11 DAY, NOW() + INTERVAL 11 DAY + INTERVAL 3 HOUR, 3.0, 20, 'volunteer', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
-- 时间重叠 A / B: 同一学生只能报一个
(9009, 'T-时间重叠A', '与 T-时间重叠B 时间重叠, 用于验证 409 冲突拦截。', '测试场地I', NOW() + INTERVAL 30 DAY, NOW() + INTERVAL 30 DAY + INTERVAL 2 HOUR, 1.0, 5, 'sports', '测试管理员', 1, NOW() - INTERVAL 4 DAY),
(9010, 'T-时间重叠B', '与 T-时间重叠A 重叠 1 小时。', '测试场地J', NOW() + INTERVAL 30 DAY + INTERVAL 1 HOUR, NOW() + INTERVAL 30 DAY + INTERVAL 3 HOUR, 1.0, 5, 'sports', '测试管理员', 1, NOW() - INTERVAL 4 DAY);

-- ---------- 3. 报名（三态 + 签到 + 空类别快照） ----------
INSERT INTO signup (id, client_id, activity_id, stu_no, name, status, category, checkin, checked_at, signout_at, card_no, hours, remark, created_at, audited_at) VALUES
-- 0 学时通过: 审核通过但学时为 0
(9001, 'tdata-zero-hours', 9001, 'T9001', '测试-正常', 1, 'thought', 0, NULL, NULL, '', 0.0, '零学时活动', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 2 DAY),
-- 满员占用 1: 已通过 + 刷卡签到、未签退
(9002, 'tdata-full-1', 9002, 'T9001', '测试-正常', 1, 'volunteer', 1, NOW() - INTERVAL 1 DAY, NULL, 'TESTCARD01', 2.0, '现场刷卡', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 1 DAY),
-- 满员占用 2: 待审核（有效报名，占名额）
(9003, 'tdata-full-2', 9002, 'T9004', '测试姓名长度边界用于验证列表截断与换行', 0, 'volunteer', 0, NULL, NULL, '', 0.0, '', NOW() - INTERVAL 1 DAY, NULL),
-- 已驳回: 不占名额
(9004, 'tdata-rejected', 9004, 'T9001', '测试-正常', 2, 'sports', 0, NULL, NULL, '', 0.0, '活动已结束, 驳回', NOW() - INTERVAL 3 DAY, NOW() - INTERVAL 2 DAY),
-- 零时长活动: 已通过 + 已签到（校验折算不除零）
(9005, 'tdata-zero-duration', 9006, 'T9001', '测试-正常', 1, 'innovation', 1, NOW() - INTERVAL 1 HOUR, NULL, '', 1.0, '零时长', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 2 DAY),
-- 已签到未签退 + .5 学时 + 4.5 大额
(9006, 'tdata-no-signout', 9007, 'T9004', '测试姓名长度边界用于验证列表截断与换行', 1, 'skill', 1, NOW() - INTERVAL 30 MINUTE, NULL, '', 4.5, '未签退', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 1 DAY),
-- 学时临界(7.5 累计 = 4.5 + 3.0)
(9007, 'tdata-critical', 9008, 'T9007', '测试-学时临界', 1, 'volunteer', 0, NULL, NULL, '', 3.0, '大额志愿', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 1 DAY),
-- 老数据: 类别快照为空, 服务启动时应按活动类别回填
(9008, 'tdata-legacy-empty-cat', 9003, 'T9002', '测试-待审核', 0, '', 0, NULL, NULL, '', 0.0, '', NOW() - INTERVAL 1 DAY, NULL),
(9009, 'tdata-legacy-empty-cat-passed', 9003, 'T9005', '测试-无班级', 1, '', 0, NULL, NULL, '', 1.5, '老数据无快照', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 1 DAY),
-- 冲突基准: T9001 已通过「时间重叠A」, 再用接口报「时间重叠B」应 409
(9010, 'tdata-overlap-a', 9009, 'T9001', '测试-正常', 1, 'sports', 0, NULL, NULL, '', 1.0, '冲突基准', NOW() - INTERVAL 2 DAY, NOW() - INTERVAL 1 DAY);

-- ---------- 4. 学时汇总（与通过报名严格相等） ----------
INSERT INTO hours_total (stu_no, name, total_hours, sign_count) VALUES
('T9001', '测试-正常', 4.0, 4),   -- 0(零学时) + 2.0 + 1.0(零时长) + 1.0(重叠基准)
('T9004', '测试姓名长度边界用于验证列表截断与换行', 4.5, 1),
('T9005', '测试-无班级', 1.5, 1),
('T9007', '测试-学时临界', 3.0, 1);

-- ---------- 5. 故意制造 taken 漂移（验证服务启动对账） ----------
UPDATE activity SET taken = 99 WHERE id = 9001;
UPDATE activity SET taken = 0  WHERE id IN (9002, 9003, 9006, 9007, 9008, 9009, 9010);

-- 预期（对账后）：
--   9001=1  9002=2  9003=2  9004=0  9006=1  9007=1  9008=1  9009=1  9010=0
