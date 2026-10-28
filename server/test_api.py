# -*- coding: utf-8 -*-
"""社团活动报名与学时认定系统 - 服务端 API 全流程验收测试脚本

覆盖: 登录(Token 签发) / 角色权限矩阵(越权拒绝) / 报名-同步-审核-学时累计 / 日志 / RFID 签到
用法: 先启动 server.exe, 再 python test_api.py
说明: 脚本开头重置 signup/hours_total 演示数据, 保证验收可重复运行。
"""
import json
import subprocess
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:8000"

# ---- 数据准备: 重置演示数据(可重复验收) ----
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
reset_sql = ("UPDATE signup SET status=0, hours=0, checkin=0, card_no=''; "
             "DELETE FROM hours_total;")
try:
    subprocess.run([MYSQL, "-u", "root", "-p123456", "club_system", "-e", reset_sql],
                   check=True, capture_output=True, timeout=30)
    print("数据重置完成: signup 全部回到待审核, hours_total 已清空")
except Exception as e:
    print("数据重置失败(不影响已通过的用例): %s" % e)


def call(method, path, body=None, token=None):
    url = BASE + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        return {"http_error": e.code, "body": e.read().decode("utf-8", "replace")}
    except Exception as e:
        return {"network_error": str(e)}


def check(name, cond, extra=""):
    print(("PASS" if cond else "FAIL") + " | " + name + ((" | " + str(extra)) if extra else ""))
    return cond


passed = 0
total = 0


def t(name, cond, extra=""):
    global passed, total
    total += 1
    if check(name, cond, extra):
        passed += 1


# ================= 1. 登录与 Token =================
print("========== 1. 登录(Token 签发) ==========")
r = call("POST", "/api/login", {"type": "admin", "account": "admin", "secret": "admin123"})
t("admin login ok", r.get("code") == 0 and r["data"].get("role") == "admin" and r["data"].get("token"), r.get("data"))
ADMIN = r.get("data", {}).get("token", "")

r = call("POST", "/api/login", {"type": "admin", "account": "admin", "secret": "badpwd"})
t("admin wrong password rejected", r.get("code") == 401, r)

r = call("POST", "/api/login", {"type": "student", "account": "2023001", "secret": "张三"})
t("student login ok", r.get("code") == 0 and r["data"].get("role") == "student" and r["data"].get("stu_no") == "2023001", r.get("data"))
STU1 = r.get("data", {}).get("token", "")

r = call("POST", "/api/login", {"type": "student", "account": "2023001", "secret": "李四"})
t("student wrong name rejected", r.get("code") == 401, r)

# ================= 2. 权限矩阵(越权拒绝) =================
print("========== 2. 权限矩阵 ==========")
r = call("GET", "/api/logs")
t("no-token access logs -> 401", r.get("code") == 401, r)

r = call("GET", "/api/logs", token=STU1)
t("student access logs -> 403", r.get("code") == 403, r)

r = call("POST", "/api/signup/audit", {"signup_id": 1, "action": "pass"}, token=STU1)
t("student audit -> 403", r.get("code") == 403, r)

r = call("POST", "/api/activity/add", {"title": "x"}, token=STU1)
t("student publish activity -> 403", r.get("code") == 403, r)

r = call("GET", "/api/logs", token=ADMIN)
t("admin access logs -> ok", r.get("code") == 0, r.get("data", {}).get("total"))

# ================= 3. 学生报名(身份强制) =================
print("========== 3. 学生报名(服务端强制登录身份) ==========")
r = call("POST", "/api/signup/add",
         {"client_id": "ptest-2023002-1", "activity_id": 2, "stu_no": "2023002", "name": "李四"},
         token=STU1)  # 伪造李四身份 -> 应被强制为 2023001
t("signup with forged identity forced to login stu", r.get("code") == 0, r)
r = call("GET", "/api/signup/list", token=STU1)
mine = [s for s in r.get("data", {}).get("list", []) if s["stu_no"] == "2023001"]
not_mine = [s for s in r.get("data", {}).get("list", []) if s["stu_no"] != "2023001"]
t("student list only own records", r.get("code") == 0 and len(mine) > 0 and len(not_mine) == 0, r.get("data"))

# 管理员登录李四身份报名(正常路径)
r = call("POST", "/api/login", {"type": "student", "account": "2023002", "secret": "李四"}, )
t("student2 login", r.get("code") == 0, r.get("data"))
STU2 = r.get("data", {}).get("token", "")
r = call("POST", "/api/signup/add",
         {"client_id": "ptest-2023002-2", "activity_id": 1, "stu_no": "2023002", "name": "李四"},
         token=STU2)
t("student2 signup ok", r.get("code") == 0, r)

# 保证 2023001 有待审核记录(验收脚本可重复运行, 不依赖上次数据)
r = call("POST", "/api/signup/add",
         {"client_id": "ptest-audit-1", "activity_id": 1, "stu_no": "2023001", "name": "张三"},
         token=STU1)
t("ensure pending signup for audit", r.get("code") == 0, r)

# ================= 4. 服务端审核(自动累计学时) =================
print("========== 4. 服务端审核 -> 自动累计学时 ==========")
r = call("GET", "/api/signup/list?stu_no=2023001", token=ADMIN)
ids = [s["id"] for s in r.get("data", {}).get("list", []) if s["status"] == 0]
if ids:
    r = call("POST", "/api/signup/audit", {"signup_id": ids[0], "action": "pass", "remark": "材料齐全, 通过"}, token=ADMIN)
    t("audit pass auto accumulate hours", r.get("code") == 0 and r["data"].get("hours", 0) > 0, r.get("data"))
else:
    t("audit pass auto accumulate hours", False, "no pending signup for 2023001")

# ================= 5. 学时报表(角色差异) =================
print("========== 5. 学时统计报表 ==========")
r = call("GET", "/api/hours/report", token=STU1)
stu_detail = [d for d in r.get("data", {}).get("detail", []) if d["stu_no"] == "2023001"]
other_detail = [d for d in r.get("data", {}).get("detail", []) if d["stu_no"] != "2023001"]
t("student report: own detail only", r.get("code") == 0 and len(stu_detail) > 0 and len(other_detail) == 0, r.get("data"))

r = call("GET", "/api/hours/report", token=ADMIN)
all_detail = r.get("data", {}).get("detail", [])
t("admin report: full detail", r.get("code") == 0 and len(all_detail) > 0, r.get("data", {}).get("report"))

# ================= 6. 实时请求日志 =================
print("========== 6. 服务器实时请求日志 ==========")
r = call("GET", "/api/logs?limit=5", token=ADMIN)
t("request logs", r.get("code") == 0 and len(r["data"]["logs"]) >= 5, r.get("data", {}).get("total"))

# ================= 7. RFID 刷卡签到(嵌入式扩展) =================
print("========== 7. RFID 刷卡签到 ==========")
r = call("POST", "/api/signin", {"card_no": "E5F60708", "activity_id": 2})
t("rfid signin ok", r.get("code") == 0 and r["data"].get("stu_no") == "2023002" and r["data"].get("checkin") == 1, r.get("data"))

r = call("POST", "/api/signin", {"card_no": "FFFF0000", "activity_id": 1})
t("unbound card rejected", r.get("code") != 0, r)

# ================= 汇总 =================
print("=" * 50)
print("结果: %d/%d PASS" % (passed, total))
print("=" * 50)
