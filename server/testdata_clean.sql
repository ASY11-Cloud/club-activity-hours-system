-- =====================================================================
-- 清理 v3.2 测试数据（testdata_seed.sql 的对偶脚本，幂等）
-- 只删除测试命名空间：活动 id 9000-9999 / 学号 T9% / client_id tdata-%
-- 演示基线（8 活动 / 19 报名 / 5 人 / 20.5 学时 / 待审注册 3）不受影响
-- 执行: mysql -u root -p123456 --default-character-set=utf8mb4 < testdata_clean.sql
-- =====================================================================
USE club_system;

DELETE FROM signup      WHERE id BETWEEN 9000 AND 9999 OR client_id LIKE 'tdata-%';
DELETE FROM hours_total WHERE stu_no LIKE 'T9%';
DELETE FROM activity    WHERE id BETWEEN 9000 AND 9999;
DELETE FROM student     WHERE stu_no LIKE 'T9%';

-- 核验过程可能改过类别规则：恢复为基线默认值（0 = 不限）
UPDATE sys_config SET cfg_value = '0'
WHERE cfg_key IN ('rule.skill.max_activity', 'rule.skill.max_total');

-- 复位自增起点，避免测试 id 段把后续真实数据推到 9000+
ALTER TABLE signup   AUTO_INCREMENT = 100;
ALTER TABLE activity AUTO_INCREMENT = 100;
ALTER TABLE student  AUTO_INCREMENT = 100;
