# -*- coding: utf-8 -*-
"""
注销功能接口级验收脚本(可重复执行, 结束后不留残留数据)
覆盖: 影响面预览 / 确认密码校验(学号不再作为凭据) / 注销失败节流 /
      事务级联删除 / 旧 token 失效 / 无孤儿数据 / 学号可重新注册 / 管理员注销
用法: python test_cancel_api.py
"""
import json
import urllib.request

BASE = "http://127.0.0.1:8000"
TEST_NO = "2029999"
TEST_NAME = "TESTSUT"


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:                                    # noqa: BLE001
        return {"code": -1, "msg": "request failed: %s" % e, "data": None}


ok_count = 0
fail_count = 0


def check(name, cond, extra=""):
    global ok_count, fail_count
    if cond:
        ok_count += 1
        print("[PASS] %s %s" % (name, extra))
    else:
        fail_count += 1
        print("[FAIL] %s %s" % (name, extra))


def login(kind, account, secret):
    r = call("POST", "/api/login", {"type": kind, "account": account, "secret": secret})
    return r["data"]["token"] if r.get("code") == 0 else None


admin = login("admin", "admin", "admin123")
check("admin login", admin is not None)

# ---- 0. 清理上一次可能残留的测试账号 ----
call("POST", "/api/student/delete", {"stu_no": TEST_NO, "confirm_stu_no": TEST_NO}, admin)

# ---- 1. 造一个真实的测试学生: 注册 -> 管理员通过 ----
r = call("POST", "/api/register", {"stu_no": TEST_NO, "name": TEST_NAME, "dept": "TEST", "pwd": "123456"})
check("register test student", r.get("code") == 0, r.get("msg", ""))

reqs = call("GET", "/api/student/requests", None, admin)
sid = None
for it in (reqs.get("data") or {}).get("list", []) or []:
    if it["stu_no"] == TEST_NO:
        sid = it["id"]
check("find pending registration", sid is not None)
r = call("POST", "/api/student/audit", {"student_id": sid, "action": "pass"}, admin)
check("approve test student", r.get("code") == 0, r.get("msg", ""))

stu = login("student", TEST_NO, "123456")
check("test student login", stu is not None)

# ---- 2. 让该学生产生报名数据(活动 1) ----
r = call("POST", "/api/signup/add", {"activity_id": 1, "client_id": "test-cancel-1"}, stu)
check("test student signup", r.get("code") == 0, r.get("msg", ""))

# ---- 3. 影响面预览 ----
r = call("GET", "/api/student/impact", None, stu)
d = r.get("data") or {}
check("impact: signup_total=1", d.get("signup_total") == 1, "got %s" % d.get("signup_total"))
check("impact: name matches", d.get("name") == TEST_NAME, "got %s" % d.get("name"))

# 管理员也能查任意学号
r = call("GET", "/api/student/impact?stu_no=" + TEST_NO, None, admin)
check("admin impact query", r.get("code") == 0 and (r.get("data") or {}).get("stu_no") == TEST_NO)

# ---- 4. 确认密码错误必须被拒(学号是公开信息, 不能当凭据) ----
r = call("POST", "/api/student/cancel", {"confirm_pwd": "wrongpwd"}, stu)
check("cancel rejects wrong password", r.get("code") == 403, "code=%s" % r.get("code"))

# ---- 5. 管理员不能走自助注销通道 ----
r = call("POST", "/api/student/cancel", {"confirm_pwd": "admin123"}, admin)
check("admin cannot use self-cancel", r.get("code") == 403, "code=%s" % r.get("code"))

# ---- 6. 学生不能走管理员注销通道 ----
r = call("POST", "/api/student/delete", {"stu_no": TEST_NO, "confirm_stu_no": TEST_NO}, stu)
check("student cannot use admin delete", r.get("code") == 403, "code=%s" % r.get("code"))

# ---- 7. 正常自助注销(密码正确) ----
r = call("POST", "/api/student/cancel", {"confirm_pwd": "123456"}, stu)
dd = r.get("data") or {}
check("self cancel ok", r.get("code") == 0, r.get("msg", ""))
check("cancel reports 1 signup deleted", dd.get("signup_deleted") == 1, "got %s" % dd.get("signup_deleted"))
check("cancel reports token revoked>=1", (dd.get("token_revoked") or 0) >= 1, "got %s" % dd.get("token_revoked"))

# ---- 8. 旧 token 必须立即失效 ----
r = call("GET", "/api/signup/list", None, stu)
check("old token rejected after cancel", r.get("code") == 401, "code=%s" % r.get("code"))

# ---- 9. 数据必须彻底消失(无孤儿) ----
r = call("GET", "/api/student/impact?stu_no=" + TEST_NO, None, admin)
check("student row gone", r.get("code") == 404, "code=%s" % r.get("code"))

signups = call("GET", "/api/signup/list?size=200&kw=" + TEST_NO, None, admin)
total = (signups.get("data") or {}).get("total")
check("no orphan signup left", total == 0, "left %s" % total)

# ---- 10. 学号可以重新注册(注销后不占用) ----
r = call("POST", "/api/register", {"stu_no": TEST_NO, "name": TEST_NAME, "dept": "TEST", "pwd": "123456"})
check("stu_no reusable after cancel", r.get("code") == 0, r.get("msg", ""))

# ---- 11. 管理员注销(收拾现场) ----
reqs = call("GET", "/api/student/requests", None, admin)
sid2 = None
for it in (reqs.get("data") or {}).get("list", []) or []:
    if it["stu_no"] == TEST_NO:
        sid2 = it["id"]
r = call("POST", "/api/student/delete", {"stu_no": TEST_NO, "confirm_stu_no": "9999999"}, admin)
check("admin delete rejects wrong confirm", r.get("code") == 400, "code=%s" % r.get("code"))
r = call("POST", "/api/student/delete", {"stu_no": TEST_NO, "confirm_stu_no": TEST_NO}, admin)
check("admin delete pending student ok", r.get("code") == 0, r.get("msg", ""))

r = call("GET", "/api/student/impact?stu_no=" + TEST_NO, None, admin)
check("cleanup verified (404)", r.get("code") == 404, "code=%s" % r.get("code"))

# ---- 12. 注销失败节流: 持 Token 者不能反复猜密码后毁号 ----
LOCK_NO = "2029998"
call("POST", "/api/student/delete", {"stu_no": LOCK_NO, "confirm_stu_no": LOCK_NO}, admin)
r = call("POST", "/api/register", {"stu_no": LOCK_NO, "name": "LOCKTEST", "dept": "TEST", "pwd": "123456"})
check("lockout: register test student", r.get("code") == 0, r.get("msg", ""))
reqs = call("GET", "/api/student/requests", None, admin)
lid = None
for it in (reqs.get("data") or {}).get("list", []) or []:
    if it["stu_no"] == LOCK_NO:
        lid = it["id"]
r = call("POST", "/api/student/audit", {"student_id": lid, "action": "pass"}, admin)
check("lockout: approve test student", r.get("code") == 0, r.get("msg", ""))
ltok = login("student", LOCK_NO, "123456")
codes = []
for _ in range(5):
    r = call("POST", "/api/student/cancel", {"confirm_pwd": "badpwd"}, ltok)
    codes.append(r.get("code"))
check("lockout: 5 wrong attempts -> 403", codes == [403, 403, 403, 403, 403], "codes=%s" % codes)
r = call("POST", "/api/student/cancel", {"confirm_pwd": "123456"}, ltok)
check("lockout: 6th attempt -> 429", r.get("code") == 429, "code=%s" % r.get("code"))
r = call("POST", "/api/student/delete", {"stu_no": LOCK_NO, "confirm_stu_no": LOCK_NO}, admin)
check("lockout: cleanup by admin ok", r.get("code") == 0, r.get("msg", ""))

print("\nresult: %d passed, %d failed" % (ok_count, fail_count))
