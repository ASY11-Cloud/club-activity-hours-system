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
    st, r = req("POST", "/api/login", {"type": "student", "account": "2023005", "secret": "123456"})
    check("孙洋(已通过)登录", st == 200 and r.get("code") == 0, "st=%d msg=%s" % (st, r.get("msg")))

    # 2. 待审核学生登录被拒(业务拒绝: code!=0)
    st, r = req("POST", "/api/login", {"type": "student", "account": "2023007", "secret": "123456"})
    check("吴桐(待审核)登录被拒", r.get("code") != 0 and "审核" in (r.get("msg") or ""), "st=%d msg=%s" % (st, r.get("msg")))

    # 3. 已驳回学生登录被拒(业务拒绝: code!=0)
    st, r = req("POST", "/api/login", {"type": "student", "account": "2023009", "secret": "123456"})
    check("冯婷(已驳回)登录被拒", r.get("code") != 0 and "驳回" in (r.get("msg") or ""), "st=%d msg=%s" % (st, r.get("msg")))

    # 4. 管理员登录拿 token
    st, r = req("POST", "/api/login", {"type": "admin", "account": "admin", "secret": "admin123"})
    check("管理员登录", st == 200 and r.get("code") == 0, "st=%d msg=%s" % (st, r.get("msg")))
    token = r["data"]["token"] if r.get("data") else ""

    # 5. 活动列表(已发布 8 个, 不含下线的迎新晚会)
    st, r = req("GET", "/api/activity/list", token=token)
    acts = r["data"]["list"] if r.get("data") else []
    n = len(acts)
    check("活动列表 = 8 个已发布", st == 200 and r.get("code") == 0 and n == 8, "count=%d" % n)

    # 6. 报名列表 19 条(状态全覆盖: 通过9 + 待审8 + 驳回演示2)
    st, r = req("GET", "/api/signup/list", token=token)
    signups = (r["data"]["list"] if r.get("data") else [])
    n = len(signups)
    check("报名列表 = 19 条", st == 200 and r.get("code") == 0 and n == 19, "count=%d" % n)

    # 7. 学时报表 5 人, 冠军李铭 5.5h
    st, r = req("GET", "/api/hours/report", token=token)
    rows = r["data"]["report"] if r.get("data") else []
    top = rows[0] if rows else {}
    check("学时报表 5 人, 榜首李铭 5.5", st == 200 and r.get("code") == 0 and len(rows) == 5
          and top.get("name") == "李铭" and float(top.get("total_hours")) == 5.5,
          "count=%d top=%s %.1fh" % (len(rows), top.get("name"), float(top.get("total_hours") or 0)))

    # 7.1 分类与名额计数(v3.2): 活动都带七大类之一, taken 与有效报名数自洽
    cats = ("thought", "practice", "volunteer", "innovation", "sports", "social", "skill")
    bad_cat = [a.get("title") for a in acts if a.get("category") not in cats]
    check("活动均带合法类别", len(bad_cat) == 0, "bad=%s" % bad_cat[:3])
    bad_taken = ["%s(taken=%s,valid=%s)" % (a.get("title"), a.get("taken"), a.get("valid_count"))
                 for a in acts if int(a.get("taken", -1)) != int(a.get("valid_count", -2))]
    check("每个活动 taken == valid_count", len(bad_taken) == 0, "bad=%s" % bad_taken[:3])
    sum_taken = sum(int(a.get("taken") or 0) for a in acts)
    # 有效报名 = 通过 + 待审(驳回演示不占名额): 种子数据 19 条中 2 条为驳回展示
    valid_n = len([s for s in signups if s.get("status") is not None and int(s["status"]) in (0, 1)])
    check("taken 合计 = 有效报名数(通过+待审)", sum_taken == valid_n,
          "sum=%d valid=%d(总%d, 驳回%d)" % (sum_taken, valid_n, n, n - valid_n))

    # 7.2 分类学时汇总(报表图表数据源): 合计应等于 20.5 学时
    by_cat = (r.get("data") or {}).get("by_category") or []
    check("报表下发 by_category", len(by_cat) > 0, "n=%d" % len(by_cat))
    cat_hours = sum(float(c.get("hours") or 0) for c in by_cat)
    check("分类学时合计 = 20.5", abs(cat_hours - 20.5) < 0.05, "sum=%.1f" % cat_hours)

    # 8. 注册申请列表(王俊/吴桐/郑雪 = 3 条待审批)
    st, r = req("GET", "/api/student/requests", token=token)
    n = len(r["data"]["list"]) if r.get("data") else 0
    check("注册申请待审批 = 3 条", st == 200 and r.get("code") == 0 and n == 3, "count=%d" % n)

    print("\n结果: %d 通过, %d 失败" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
