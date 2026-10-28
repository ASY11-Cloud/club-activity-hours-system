# -*- coding: utf-8 -*-
"""
社团活动报名与学时认定系统 - 演示数据接口验证脚本
验证补充数据后 App 视角所见: 登录(通过/待审核/驳回)、活动列表、报名列表、学时报表
用法: python verify_demo_data.py
"""
import json
import urllib.request

BASE = "http://127.0.0.1:8000"


def req(method, path, body=None, token=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


def main():
    passed, failed = 0, 0

    def check(name, cond, extra=""):
        nonlocal passed, failed
        mark = "PASS" if cond else "FAIL"
        if cond:
            passed += 1
        else:
            failed += 1
        print("[%s] %s %s" % (mark, name, extra))

    # 1. 已通过学生可登录
    st, r = req("POST", "/api/login", {"type": "student", "account": "2023005", "secret": "孙洋"})
    check("孙洋(已通过)登录", st == 200 and r.get("code") == 0, "st=%d msg=%s" % (st, r.get("msg")))

    # 2. 待审核学生登录被拒(业务拒绝: code!=0)
    st, r = req("POST", "/api/login", {"type": "student", "account": "2023007", "secret": "吴桐"})
    check("吴桐(待审核)登录被拒", r.get("code") != 0 and "审核" in (r.get("msg") or ""), "st=%d msg=%s" % (st, r.get("msg")))

    # 3. 已驳回学生登录被拒(业务拒绝: code!=0)
    st, r = req("POST", "/api/login", {"type": "student", "account": "2023009", "secret": "冯婷"})
    check("冯婷(已驳回)登录被拒", r.get("code") != 0 and "驳回" in (r.get("msg") or ""), "st=%d msg=%s" % (st, r.get("msg")))

    # 4. 管理员登录拿 token
    st, r = req("POST", "/api/login", {"type": "admin", "account": "admin", "secret": "admin123"})
    check("管理员登录", st == 200 and r.get("code") == 0, "st=%d msg=%s" % (st, r.get("msg")))
    token = r["data"]["token"] if r.get("data") else ""

    # 5. 活动列表(已发布 8 个, 不含下线的迎新晚会)
    st, r = req("GET", "/api/activity/list", token=token)
    n = len(r["data"]["list"]) if r.get("data") else 0
    check("活动列表 = 8 个已发布", st == 200 and r.get("code") == 0 and n == 8, "count=%d" % n)

    # 6. 报名列表 19 条(状态全覆盖)
    st, r = req("GET", "/api/signup/list", token=token)
    n = len(r["data"]["list"]) if r.get("data") else 0
    check("报名列表 = 19 条", st == 200 and r.get("code") == 0 and n == 19, "count=%d" % n)

    # 7. 学时报表 5 人, 冠军李铭 5.5h
    st, r = req("GET", "/api/hours/report", token=token)
    rows = r["data"]["report"] if r.get("data") else []
    top = rows[0] if rows else {}
    check("学时报表 5 人, 榜首李铭 5.5", st == 200 and r.get("code") == 0 and len(rows) == 5
          and top.get("name") == "李铭" and float(top.get("total_hours")) == 5.5,
          "count=%d top=%s %.1fh" % (len(rows), top.get("name"), float(top.get("total_hours") or 0)))

    # 8. 注册申请列表(王俊/吴桐/郑雪 = 3 条待审批)
    st, r = req("GET", "/api/student/requests", token=token)
    n = len(r["data"]["list"]) if r.get("data") else 0
    check("注册申请待审批 = 3 条", st == 200 and r.get("code") == 0 and n == 3, "count=%d" % n)

    print("\n结果: %d 通过, %d 失败" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
