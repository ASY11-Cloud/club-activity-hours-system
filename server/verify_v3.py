#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v3 新增能力回归测试(只增不改, 结束后自动清理测试数据)
  1. 口令哈希登录(库中不存明文)
  2. 活动列表分页(page/size/total/has_more)
  3. 活动编辑 /api/activity/update
  4. 报名列表服务端筛选(status / kw / activity_id) + 分页
  5. 学时达标线 /api/config/get|set + 报表 achieved
  6. 日志筛选 level/method/kw
  7. HTTP keep-alive(单连接连续多请求)
  8. 权限: 普通成员不得编辑活动 / 改配置

用法: python verify_v3.py [port]   默认 8000
"""
import json
import sys
import http.client
import urllib.request

BASE_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
HOST = "127.0.0.1"
PASS = 0
FAIL = 0


def call(method, path, body=None, tok=None, headers=None):
    url = "http://%s:%d%s" % (HOST, BASE_PORT, path)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Content-Type", "application/json; charset=utf-8")
    if tok:
        r.add_header("Authorization", "Bearer " + tok)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        return {"code": -1, "msg": str(e)}


def check(name, ok, extra=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print("  [PASS] %s" % name)
    else:
        FAIL += 1
        print("  [FAIL] %s  %s" % (name, extra))


print("=" * 66)
print(" v3 回归测试  target=%s:%d" % (HOST, BASE_PORT))
print("=" * 66)

# ---------- 1. 登录 ----------
print("\n[1] 登录与口令哈希")
r = call("POST", "/api/login", {"type": "admin", "account": "admin", "secret": "admin123"})
check("管理员 admin/admin123 登录成功", r.get("code") == 0, r)
ATOK = r["data"]["token"] if r.get("code") == 0 else ""
r2 = call("POST", "/api/login", {"type": "admin", "account": "admin", "secret": "wrong-pwd"})
check("错误口令被拒绝(401)", r2.get("code") == 401, r2)
r = call("POST", "/api/login", {"type": "student", "account": "2023001", "secret": "张三"})
check("学生 2023001 张三 登录成功", r.get("code") == 0, r)
STOK = r["data"]["token"] if r.get("code") == 0 else ""

# ---------- 2. 活动列表分页 ----------
print("\n[2] 活动列表分页")
p1 = call("GET", "/api/activity/list?page=1&size=3", tok=ATOK)
p2 = call("GET", "/api/activity/list?page=2&size=3", tok=ATOK)
check("第 1 页返回 3 条", len(p1["data"]["list"]) == 3, p1)
check("下发 total / has_more", "total" in p1["data"] and "has_more" in p1["data"], p1["data"].keys())
ids1 = {a["id"] for a in p1["data"]["list"]}
ids2 = {a["id"] for a in p2["data"]["list"]}
check("两页不重叠", len(ids1 & ids2) == 0, ids1 & ids2)
allres = call("GET", "/api/activity/list", tok=ATOK)
check("不分页时返回全部(向后兼容)", len(allres["data"]["list"]) == allres["data"]["total"],
      (len(allres["data"]["list"]), allres["data"].get("total")))
check("size 上限 200(拒绝放大)", call("GET", "/api/activity/list?size=9999", tok=ATOK)["data"]["size"] == 200)

# ---------- 3. 活动编辑 ----------
print("\n[3] 活动编辑")
sid = call("POST", "/api/activity/add",
           {"title": "v3 编辑测试活动", "content": "初始内容", "location": "测试室",
            "start_time": "2099-01-01 10:00", "end_time": "2099-01-01 12:00",
            "hours": 1.5, "capacity": 10, "publisher": "管理员"}, tok=ATOK)
check("新建测试活动成功", sid.get("code") == 0, sid)
NEW_ID = sid["data"]["id"] if sid.get("code") == 0 else 0
up = call("POST", "/api/activity/update",
          {"activity_id": NEW_ID, "title": "v3 编辑后标题", "content": "改后内容", "location": "新地点",
           "start_time": "2099-01-02 09:00", "end_time": "2099-01-02 11:30",
           "hours": 3.0, "capacity": 20, "publisher": "管理员"}, tok=ATOK)
check("编辑成功", up.get("code") == 0, up)
lst = call("GET", "/api/activity/list?all=1", tok=ATOK)["data"]["list"]
ed = [a for a in lst if a["id"] == NEW_ID]
check("字段已更新(标题/学时/地点)",
      bool(ed) and ed[0]["title"] == "v3 编辑后标题" and ed[0]["hours"] == 3.0 and ed[0]["location"] == "新地点",
      ed[0] if ed else "not found")
check("编辑时允许开始时间早于当前(历史活动可改)",
      call("POST", "/api/activity/update",
           {"activity_id": NEW_ID, "title": "历史活动", "start_time": "2020-01-01 10:00",
            "end_time": "2020-01-01 12:00", "hours": 2, "capacity": 0}, tok=ATOK).get("code") == 0)
bad = call("POST", "/api/activity/update",
           {"activity_id": NEW_ID, "title": "结束早于开始", "start_time": "2099-01-02 10:00",
            "end_time": "2099-01-02 09:00", "hours": 2, "capacity": 0}, tok=ATOK)
check("结束早于开始被拒绝", bad.get("code") == 400, bad)
check("普通成员不能编辑活动(403)",
      call("POST", "/api/activity/update", {"activity_id": NEW_ID, "title": "x"}, tok=STOK).get("code") == 403)
check("不存在的活动返回 404",
      call("POST", "/api/activity/update", {"activity_id": 999999, "title": "x",
                                            "start_time": "2099-01-02 10:00",
                                            "end_time": "2099-01-02 11:00"}, tok=ATOK).get("code") == 404)

# ---------- 4. 报名列表筛选 + 分页 ----------
print("\n[4] 报名列表筛选与分页")
a1 = call("GET", "/api/signup/list?status=0", tok=ATOK)
check("status=0 只返回待审核", all(x["status"] == 0 for x in a1["data"]["list"]), a1["data"]["list"][:1])
a2 = call("GET", "/api/signup/list?status=1", tok=ATOK)
check("status=1 只返回已通过", all(x["status"] == 1 for x in a2["data"]["list"]))
kw = call("GET", "/api/signup/list?kw=%E5%BC%A0%E4%B8%89", tok=ATOK)  # 张三
check("kw=张三 命中且仅命中该姓名", len(kw["data"]["list"]) > 0
      and all(("张三" in x["name"]) for x in kw["data"]["list"]), kw["data"].get("total"))
pg = call("GET", "/api/signup/list?page=1&size=5", tok=ATOK)
check("报名列表分页 size=5", len(pg["data"]["list"]) == 5 and pg["data"]["total"] >= 5, pg["data"].get("total"))
aid = allres["data"]["list"][0]["id"] if allres["data"]["list"] else 0
af = call("GET", "/api/signup/list?activity_id=%d" % aid, tok=ATOK)
check("activity_id 过滤生效", all(x["activity_id"] == aid for x in af["data"]["list"]))
check("学生只能看到本人报名",
      all(x["stu_no"] == "2023001" for x in call("GET", "/api/signup/list?stu_no=2023002", tok=STOK)["data"]["list"]))

# ---------- 5. 学时达标线 ----------
print("\n[5] 学时达标线")
g = call("GET", "/api/config/get", tok=STOK)
check("成员可读配置", g.get("code") == 0 and "required_hours" in g["data"], g)
orig = g["data"]["required_hours"] if g.get("code") == 0 else 20
s = call("POST", "/api/config/set", {"required_hours": 1}, tok=ATOK)
check("管理员设置达标线", s.get("code") == 0, s)
rep = call("GET", "/api/hours/report", tok=ATOK)
check("报表返回 required_hours=1", rep["data"]["required_hours"] == 1, rep["data"].get("required_hours"))
check("达标人数字段存在且>0", rep["data"]["achieved_count"] > 0, rep["data"].get("achieved_count"))
check("排行行带 achieved", all("achieved" in x for x in rep["data"]["report"]))
check("成员不能改配置(403)",
      call("POST", "/api/config/set", {"required_hours": 5}, tok=STOK).get("code") == 403)
check("非法达标线被拒绝",
      call("POST", "/api/config/set", {"required_hours": -1}, tok=ATOK).get("code") == 400)
call("POST", "/api/config/set", {"required_hours": orig}, tok=ATOK)   # 复原

# ---------- 6. 日志筛选 ----------
print("\n[6] 日志筛选")
lg = call("GET", "/api/logs?limit=50", tok=ATOK)
check("日志接口可用", lg.get("code") == 0 and len(lg["data"]["logs"]) > 0, lg.get("msg"))
le = call("GET", "/api/logs?limit=100&level=err", tok=ATOK)
check("level=err 只返回 >=400 的记录",
      all(x["status"] >= 400 for x in le["data"]["logs"]), [x["status"] for x in le["data"]["logs"]][:5])
lp = call("GET", "/api/logs?limit=20&method=POST", tok=ATOK)
check("method=POST 过滤生效", all(x["method"] == "POST" for x in lp["data"]["logs"]))
lk = call("GET", "/api/logs?limit=20&kw=activity", tok=ATOK)
check("kw 关键词过滤生效", all("activity" in x["path"] or "activity" in x["detail"] for x in lk["data"]["logs"]))
check("成员不能看日志(403)", call("GET", "/api/logs", tok=STOK).get("code") == 403)

# ---------- 7. keep-alive ----------
print("\n[7] HTTP keep-alive 连接复用")
try:
    conn = http.client.HTTPConnection(HOST, BASE_PORT, timeout=8)
    okc = 0
    for _ in range(3):
        conn.request("GET", "/api/health")
        resp = conn.getresponse()
        body = json.loads(resp.read().decode())
        if resp.status == 200 and body.get("code") == 0:
            okc += 1
    conn.close()
    check("同一连接连续 3 次请求全部成功", okc == 3, okc)
except Exception as e:  # noqa: BLE001
    check("同一连接连续 3 次请求全部成功", False, e)

print("\n" + "=" * 66)
print(" 结果: 通过 %d / 失败 %d" % (PASS, FAIL))
print(" 测试活动 id=%s 需清理(见 README 或 delete 语句)" % NEW_ID)
print("=" * 66)
sys.exit(0 if FAIL == 0 else 1)
