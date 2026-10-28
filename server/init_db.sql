-- =====================================================================
-- 社团活动报名与学时认定系统 - 服务端 MySQL 建库脚本
-- 适用: MySQL 8.0
-- 用法: mysql -u root -p123456 < init_db.sql
-- =====================================================================

CREATE DATABASE IF NOT EXISTS club_system
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

USE club_system;

-- ---------------------------------------------------------------------
-- 0. 管理员账号表 (管理员登录: 账号 + 密码)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS admin_user;

CREATE TABLE admin_user (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  username   VARCHAR(50)  NOT NULL UNIQUE COMMENT '管理员登录账号',
  password   VARCHAR(100) NOT NULL COMMENT '管理员登录密码',
  name       VARCHAR(50)  NOT NULL DEFAULT '' COMMENT '管理员姓名',
  created_at DATETIME     DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='管理员账号表';

-- ---------------------------------------------------------------------
-- 1. 学生表
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS request_log;
DROP TABLE IF EXISTS hours_total;
DROP TABLE IF EXISTS signup;
DROP TABLE IF EXISTS activity;
DROP TABLE IF EXISTS student;

CREATE TABLE student (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  stu_no     VARCHAR(20)  NOT NULL UNIQUE COMMENT '学号(登录账号)',
  name       VARCHAR(50)  NOT NULL COMMENT '姓名',
  dept       VARCHAR(100) DEFAULT '' COMMENT '班级/院系',
  card_no    VARCHAR(32)  NOT NULL DEFAULT '' COMMENT 'RFID卡号(嵌入式刷卡签到绑定)',
  created_at DATETIME     DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='学生表(权限见 admin_user, 不再使用 is_admin 字段)';

-- ---------------------------------------------------------------------
-- 2. 活动表
-- ---------------------------------------------------------------------
CREATE TABLE activity (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  title      VARCHAR(100)  NOT NULL COMMENT '活动名称',
  content    TEXT          COMMENT '活动内容描述',
  location   VARCHAR(100)  DEFAULT '' COMMENT '活动地点',
  start_time DATETIME      COMMENT '开始时间',
  end_time   DATETIME      COMMENT '结束时间',
  hours      DECIMAL(5,1)  NOT NULL DEFAULT 1.0 COMMENT '本次活动学时数',
  capacity   INT           NOT NULL DEFAULT 0 COMMENT '人数上限, 0=不限',
  publisher  VARCHAR(50)   DEFAULT '' COMMENT '发布人姓名',
  status     TINYINT       NOT NULL DEFAULT 1 COMMENT '1=已发布 0=下线',
  created_at DATETIME      DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='活动表';

-- ---------------------------------------------------------------------
-- 3. 报名表 (服务端审核通过后自动累计学时)
-- ---------------------------------------------------------------------
CREATE TABLE signup (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  client_id   VARCHAR(64)  NOT NULL COMMENT 'App本地报名记录唯一ID(幂等去重)',
  activity_id INT          NOT NULL COMMENT '活动ID',
  stu_no      VARCHAR(20)  NOT NULL COMMENT '学号',
  name        VARCHAR(50)  NOT NULL DEFAULT '' COMMENT '姓名',
  status      TINYINT      NOT NULL DEFAULT 0 COMMENT '0=待审核 1=已通过 2=已驳回',
  checkin     TINYINT      NOT NULL DEFAULT 0 COMMENT '0=未签到 1=已刷卡签到(ESP32)',
  card_no     VARCHAR(32)  DEFAULT '' COMMENT 'RFID卡号(嵌入式签到)',
  hours       DECIMAL(5,1) NOT NULL DEFAULT 0 COMMENT '认定学时(审核通过=活动学时)',
  remark      VARCHAR(200) DEFAULT '' COMMENT '审核备注',
  created_at  DATETIME     DEFAULT CURRENT_TIMESTAMP,
  audited_at  DATETIME     NULL COMMENT '审核时间',
  UNIQUE KEY uk_client (client_id),
  UNIQUE KEY uk_act_stu (activity_id, stu_no),
  KEY idx_status (status),
  KEY idx_stu (stu_no),
  CONSTRAINT fk_signup_activity FOREIGN KEY (activity_id) REFERENCES activity(id),
  CONSTRAINT fk_signup_student  FOREIGN KEY (stu_no)     REFERENCES student(stu_no)
) ENGINE=InnoDB COMMENT='报名表';

-- ---------------------------------------------------------------------
-- 4. 学时汇总表 (审核通过时自动累计, 用于学时统计报表)
-- ---------------------------------------------------------------------
CREATE TABLE hours_total (
  stu_no      VARCHAR(20)  PRIMARY KEY,
  name        VARCHAR(50)  NOT NULL DEFAULT '',
  total_hours DECIMAL(8,1) NOT NULL DEFAULT 0 COMMENT '累计认定学时',
  sign_count  INT          NOT NULL DEFAULT 0 COMMENT '通过活动次数',
  updated_at  DATETIME     DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_hours_student FOREIGN KEY (stu_no) REFERENCES student(stu_no)
) ENGINE=InnoDB COMMENT='学时汇总表';

-- ---------------------------------------------------------------------
-- 5. 服务端请求日志表 (服务器控制台/接口实时可查)
-- ---------------------------------------------------------------------
CREATE TABLE request_log (
  id       BIGINT AUTO_INCREMENT PRIMARY KEY,
  req_time DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  method   VARCHAR(10)  NOT NULL,
  path     VARCHAR(255) NOT NULL,
  query    VARCHAR(255) DEFAULT '',
  ip       VARCHAR(64)  DEFAULT '',
  status   INT          DEFAULT 200,
  cost_ms  INT          DEFAULT 0,
  detail   VARCHAR(500) DEFAULT ''
) ENGINE=InnoDB COMMENT='请求日志表';

-- =====================================================================
-- 演示数据
-- =====================================================================
-- 管理员账号(演示): admin / admin123
INSERT INTO admin_user (username, password, name) VALUES
  ('admin', 'admin123', '系统管理员');

-- 两名学生(登录: 学号 + 姓名)
INSERT INTO student (stu_no, name, dept, card_no) VALUES
  ('2023001', '张三', '计科2201', 'A1B2C3D4'),
  ('2023002', '李四', '计科2202', 'E5F60708');

-- 两条已发布活动
INSERT INTO activity (title, content, location, start_time, end_time, hours, capacity, publisher, status) VALUES
  ('ACM 算法训练营', '由 ACM 实验室组织的算法集训，涵盖图论与动态规划专题。', '教学楼 A-301', '2026-11-05 19:00:00', '2026-11-05 21:00:00', 2.0, 60, '管理员', 1),
  ('嵌入式开发分享会', 'STM32 与鸿蒙开发实战经验分享。', '实验楼 B-102', '2026-11-12 14:00:00', '2026-11-12 16:30:00', 2.5, 40, '管理员', 1);

-- 一名学生已报名(待审核, 用于演示审核流程)
INSERT INTO signup (client_id, activity_id, stu_no, name, status) VALUES
  ('demo-signup-2023001-1', 1, '2023001', '张三', 0);
