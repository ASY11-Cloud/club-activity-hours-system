-- ============================================================
-- 演示数据姓名真实化(2026-10-28)
-- 将"李四/王五/赵六/孙七/周八/吴九/郑十/冯十一"等数字假名
-- 改为常见真实姓名, 张三保持不变(主演示账号)。
-- 学号 / 班级 / 卡号均不变; 只更新 name 字段。
-- 新库直接执行 seed_demo_data.sql / init_db.sql 即可, 本脚本
-- 仅用于把已运行旧库里的演示数据原地改名。
-- 执行: mysql -u root -p --default-character-set=utf8mb4 < rename_demo_users.sql
-- ============================================================
USE club_system;

-- ---------- student ----------
UPDATE student SET name='李铭' WHERE stu_no='2023002';
UPDATE student SET name='王俊' WHERE stu_no='2023003';
UPDATE student SET name='赵磊' WHERE stu_no='2023004';
UPDATE student SET name='孙洋' WHERE stu_no='2023005';
UPDATE student SET name='周凯' WHERE stu_no='2023006';
UPDATE student SET name='吴桐' WHERE stu_no='2023007';
UPDATE student SET name='郑雪' WHERE stu_no='2023008';
UPDATE student SET name='冯婷' WHERE stu_no='2023009';

-- ---------- signup (仅有报名的学号需要改) ----------
UPDATE signup SET name='李铭' WHERE stu_no='2023002';
UPDATE signup SET name='赵磊' WHERE stu_no='2023004';
UPDATE signup SET name='孙洋' WHERE stu_no='2023005';
UPDATE signup SET name='周凯' WHERE stu_no='2023006';

-- ---------- hours_total ----------
UPDATE hours_total SET name='李铭' WHERE stu_no='2023002';
UPDATE hours_total SET name='赵磊' WHERE stu_no='2023004';
UPDATE hours_total SET name='孙洋' WHERE stu_no='2023005';
UPDATE hours_total SET name='周凯' WHERE stu_no='2023006';

-- ---------- 核对 ----------
SELECT stu_no, name, dept, status FROM student ORDER BY stu_no;
