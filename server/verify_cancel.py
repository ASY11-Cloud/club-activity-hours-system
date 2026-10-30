# -*- coding: utf-8 -*-
"""
注销后数据一致性校验(只读, 不改任何数据)
把"注销后数据是否合理"变成 4 条可执行的标准:
  1. 无孤儿: signup / hours_total 里不存在 student 表没有的 stu_no
  2. 汇总自洽: hours_total.total_hours == 该生 status=1 报名学时之和, sign_count == 条数
  3. 学时总额一致: 所有学生学时之和 == 所有已通过报名的学时之和
  4. 演示基线未漂移: 8 活动 / 19 报名 / 5 人 / 20.5 学时(可选, 测试后应恢复)

用法: python verify_cancel.py
"""
import subprocess
import sys

MYSQL = ["mysql", "-u", "root", "-p123456", "--default-character-set=utf8mb4",
         "-N", "-B", "club_system", "-e"]


def q(sql):
    p = subprocess.run(MYSQL + [sql], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", "ignore"))
    out = p.stdout.decode("utf-8", "ignore").strip()
    return [] if out == "" else [line.split("\t") for line in out.splitlines()]


ok = 0
bad = 0


def check(name, cond, extra=""):
    global ok, bad
    if cond:
        ok += 1
        print("[PASS] %s %s" % (name, extra))
    else:
        bad += 1
        print("[FAIL] %s %s" % (name, extra))


# 1. 无孤儿
orphan_signup = q("SELECT s.stu_no FROM signup s LEFT JOIN student t ON s.stu_no=t.stu_no "
                  "WHERE t.stu_no IS NULL")
check("signup 无孤儿记录(全部能对上 student)", len(orphan_signup) == 0,
      "orphans=%s" % [r[0] for r in orphan_signup][:5])

orphan_hours = q("SELECT h.stu_no FROM hours_total h LEFT JOIN student t ON h.stu_no=t.stu_no "
                 "WHERE t.stu_no IS NULL")
check("hours_total 无孤儿记录", len(orphan_hours) == 0,
      "orphans=%s" % [r[0] for r in orphan_hours][:5])

# 2. 汇总自洽(逐人比对)
rows = q("""
SELECT t.stu_no,
       COALESCE(h.total_hours,0),
       COALESCE((SELECT SUM(s.hours) FROM signup s WHERE s.stu_no=t.stu_no AND s.status=1),0),
       COALESCE(h.sign_count,0),
       COALESCE((SELECT COUNT(*) FROM signup s WHERE s.stu_no=t.stu_no AND s.status=1),0)
FROM student t LEFT JOIN hours_total h ON h.stu_no=t.stu_no
""")
drift = []
for r in rows:
    no, ht, hs, hc, sc = r[0], float(r[1]), float(r[2]), int(r[3]), int(r[4])
    if abs(ht - hs) > 0.05 or hc != sc:
        drift.append("%s hours_total=%.1f 明细=%.1f count=%d/%d" % (no, ht, hs, hc, sc))
check("每人学时汇总与明细一致", len(drift) == 0, "; ".join(drift[:3]))

# 3. 总额一致
t1 = q("SELECT COALESCE(SUM(total_hours),0) FROM hours_total")[0][0]
t2 = q("SELECT COALESCE(SUM(hours),0) FROM signup WHERE status=1")[0][0]
check("学时总额 == 已通过报名学时之和", abs(float(t1) - float(t2)) < 0.05,
      "total=%s detail=%s" % (t1, t2))

# 4. 演示基线
act = int(q("SELECT COUNT(*) FROM activity WHERE status=1")[0][0])
sg = int(q("SELECT COUNT(*) FROM signup")[0][0])
stu = int(q("SELECT COUNT(*) FROM student WHERE status=1")[0][0])
hours = float(q("SELECT COALESCE(SUM(total_hours),0) FROM hours_total")[0][0])
print("[INFO] 基线: 活动 %d / 报名 %d / 已通过学生 %d / 学时 %.1f" % (act, sg, stu, hours))

print("\nresult: %d passed, %d failed" % (ok, bad))
sys.exit(1 if bad else 0)
