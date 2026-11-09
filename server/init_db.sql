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
  password   VARCHAR(100) NOT NULL COMMENT '口令摘要: "sha256i:<hex>", 迭代加盐; 旧格式 sha256:/明文会在登录或启动时自动升级',
  name       VARCHAR(50)  NOT NULL DEFAULT '' COMMENT '管理员姓名',
  created_at DATETIME     DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='管理员账号表(口令不存明文)';

-- ---------------------------------------------------------------------
-- 1. 学生表
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS appeal;
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
  -- 卡号允许 NULL(未绑卡); 唯一索引保证一张卡只能绑一个学号, 否则刷卡会记到别人头上
  card_no    VARCHAR(32)  NULL DEFAULT NULL COMMENT 'RFID卡号(刷卡签到绑定, 唯一)',
  pwd_hash   VARCHAR(100) NOT NULL DEFAULT '' COMMENT '登录口令: sha256i:<hex>(空=未设置, 服务启动时初始化为默认密码 123456)',
  status     TINYINT      NOT NULL DEFAULT 1 COMMENT '注册审核: 1=已通过(可登录) 0=待审核 2=已驳回',
  created_at DATETIME     DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_card (card_no)
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
  -- 七大类: thought 思想成长 / practice 实践实习 / volunteer 志愿公益 / innovation 创新创业
  --         sports 文体活动 / social 社会工作 / skill 技能特长(非法值由服务端回落 sports)
  category   VARCHAR(20)   NOT NULL DEFAULT 'sports' COMMENT '活动类别(七大类之一)',
  -- 有效报名数缓存(status<>2): 报名用条件 UPDATE 原子扣减, 启动时按真实行数对账
  taken      INT           NOT NULL DEFAULT 0 COMMENT '有效报名数缓存',
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
  -- 报名时的活动类别快照: 报表按类别汇总不再依赖 JOIN, 活动改类别也不影响历史认定
  category    VARCHAR(20)  NOT NULL DEFAULT '' COMMENT '活动类别快照',
  checkin     TINYINT      NOT NULL DEFAULT 0 COMMENT '0=未签到 1=已刷卡/输码签到',
  checked_at  DATETIME     NULL COMMENT '签到时间(刷卡或签到码)',
  signout_at  DATETIME     NULL COMMENT '签退时间(动态签到码签到后可用, 用于按在场时长折算)',
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
-- 4.5 学时申诉表 (v4.0): 学生对已通过认定发起申诉, 管理员复核并调整学时
--     同一报名同时只允许一条待处理申诉(由学生行锁串行化 + 业务校验保证)
-- ---------------------------------------------------------------------
CREATE TABLE appeal (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  stu_no       VARCHAR(20)  NOT NULL COMMENT '申诉人学号',
  signup_id    INT          NOT NULL COMMENT '被申诉的报名记录',
  reason       VARCHAR(500) NOT NULL COMMENT '申诉理由',
  status       TINYINT      NOT NULL DEFAULT 0 COMMENT '0待处理 1已通过 2已驳回',
  reply        VARCHAR(500) NOT NULL DEFAULT '' COMMENT '管理员答复/驳回原因',
  hours_before DECIMAL(5,1) NOT NULL DEFAULT 0 COMMENT '申诉前认定学时',
  hours_after  DECIMAL(5,1) NULL COMMENT '复核后认定学时(驳回为空)',
  created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
  handled_at   DATETIME NULL,
  handler      VARCHAR(50) NOT NULL DEFAULT '' COMMENT '处理人',
  KEY idx_stu (stu_no),
  KEY idx_status (status),
  KEY idx_signup (signup_id),
  CONSTRAINT fk_appeal_signup  FOREIGN KEY (signup_id) REFERENCES signup(id),
  CONSTRAINT fk_appeal_student FOREIGN KEY (stu_no)    REFERENCES student(stu_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='学时申诉表(v4.0)';

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
  detail   VARCHAR(500) DEFAULT '',
  KEY idx_req_time (req_time)          -- 按时间清理历史日志(服务端每小时执行一次)
) ENGINE=InnoDB COMMENT='请求日志表';

-- ---------------------------------------------------------------------
-- 6. 系统配置表 (学时达标线等, 服务端启动时也会自动补建)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_config (
  cfg_key    VARCHAR(50)  PRIMARY KEY,
  cfg_value  VARCHAR(200) NOT NULL DEFAULT '',
  updated_at DATETIME     DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='系统配置';

INSERT INTO sys_config (cfg_key, cfg_value) VALUES
  ('required_hours', '20')
ON DUPLICATE KEY UPDATE cfg_value = cfg_value;

-- 类别学时规则(0 = 不限): max_activity 单活动上限 / max_total 该类别累计上限。
-- 默认全 0, 因此历史数据与演示基线(20.5 学时)不受影响; 需要演示限额时改成非 0 即可。
INSERT IGNORE INTO sys_config (cfg_key, cfg_value) VALUES
  ('rule.thought.max_activity','0'),    ('rule.thought.max_total','0'),
  ('rule.practice.max_activity','0'),   ('rule.practice.max_total','0'),
  ('rule.volunteer.max_activity','0'),  ('rule.volunteer.max_total','0'),
  ('rule.innovation.max_activity','0'), ('rule.innovation.max_total','0'),
  ('rule.sports.max_activity','0'),     ('rule.sports.max_total','0'),
  ('rule.social.max_activity','0'),     ('rule.social.max_total','0'),
  ('rule.skill.max_activity','0'),      ('rule.skill.max_total','0');

-- =====================================================================
-- 演示数据
-- =====================================================================
-- 管理员账号(演示): admin / admin123
-- 只存摘要, 不存明文; 摘要 = SHA256("club-system::" + 明文)
INSERT INTO admin_user (username, password, name) VALUES
  ('admin', 'sha256:de8346faa6a9aa96df9926bb5e7970823d9efb910acf091678f249cff20abe30', '系统管理员');

-- 两名学生(登录: 学号 + 姓名, 均已通过注册审核)
INSERT INTO student (stu_no, name, dept, card_no, status) VALUES
  ('2023001', '张三', '计科2201', 'A1B2C3D4', 1),
  ('2023002', '李铭', '计科2202', 'E5F60708', 1);

-- 一条待审核注册申请(演示: 管理员在审核中心同意/拒绝)
INSERT INTO student (stu_no, name, dept, status) VALUES
  ('2023003', '王俊', '软工2203', 0);

-- 两条已发布活动(类别: skill 技能特长 / practice 实践实习)
INSERT INTO activity (title, content, location, start_time, end_time, hours, capacity, category, publisher, status) VALUES
  ('ACM 算法训练营', '由 ACM 实验室组织的算法集训，涵盖图论与动态规划专题。', '教学楼 A-301', '2026-11-05 19:00:00', '2026-11-05 21:00:00', 2.0, 60, 'skill', '管理员', 1),
  ('嵌入式开发分享会', 'STM32 与鸿蒙开发实战经验分享。', '实验楼 B-102', '2026-11-12 14:00:00', '2026-11-12 16:30:00', 2.5, 40, 'practice', '管理员', 1);

-- 一名学生已报名(待审核, 用于演示审核流程)
INSERT INTO signup (client_id, activity_id, stu_no, name, status, category) VALUES
  ('demo-signup-2023001-1', 1, '2023001', '张三', 0, 'skill');

-- 名额计数缓存回填: taken 必须等于有效报名数(status<>2), 否则容量判断会误判。
-- 服务端每次启动也会做同样的一次对账(dbEnsureSchema), 这里保证纯 SQL 初始化也自洽。
UPDATE activity a
SET a.taken = (SELECT COUNT(*) FROM signup s WHERE s.activity_id = a.id AND s.status <> 2);
