# -*- coding: utf-8 -*-
"""
P1 并发/权限 + P2 状态机边界 专项验收(豆包测试清单的可自动化子集)
自建数据、自清理, 不动演示基线(8 活动/19 报名/5 人/20.5 学时)。
覆盖:
  P1  越权矩阵 / 伪造 stu_no / 满员竞态 / 并发重复审核 / 刷卡重复累计
      Token 生命周期 / 登录节流 429
  P2  已通过不可撤销 / 驳回后重报 / 已结束与已下线拒绝报名
      容量 0 不限 / 时间校验 / 达标线边界 / 分页 total 一致
用法: python test_p1p2.py   (服务端需在 127.0.0.1:8000 运行)
"""
import json, threading, urllib.request, subprocess, sys
from datetime import datetime, timedelta

BASE = 'http://127.0.0.1:8000'
MYSQL = ['mysql', '-u', 'root', '-p123456', '--default-character-set=utf8mb4', '-N', '-B', 'club_system', '-e']
ok = 0
bad = 0


def check(name, cond, extra=''):
    global ok, bad
    if cond:
        ok += 1
        print('[PASS]', name, extra)
    else:
        bad += 1
        print('[FAIL]', name, extra)


def api(path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method='POST' if data else 'GET',
                                 headers={'Content-Type': 'application/json',
                                          **({'Authorization': 'Bearer ' + token} if token else {})})
    try:
        r = urllib.request.urlopen(req, timeout=8)
        return r.getcode(), json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except Exception:
            return e.code, {'code': e.code, 'msg': 'non-json'}
    except Exception as e:
        return 0, {'code': -1, 'msg': str(e)}


def sql(q):
    p = subprocess.run(MYSQL + [q], capture_output=True)
    return p.stdout.decode('utf-8', 'ignore').strip()


def dt(days=0, minutes=0):
    return (datetime.now() + timedelta(days=days, minutes=minutes)).strftime('%Y-%m-%d %H:%M')


def add_act(admin, title, start, end, hours=2.0, capacity=0):
    _, r = api('/api/activity/add', {
        'title': title, 'content': 'P1P2 测试', 'location': '测试场地',
        'start_time': start, 'end_time': end, 'hours': hours, 'capacity': capacity,
        'publisher': '系统管理员'}, token=admin)
    return r['data']['id'] if r.get('code') == 0 else None


# ---------- 准备: 管理员 + 3 个测试学生 ----------
_, r = api('/api/login', {'type': 'admin', 'account': 'admin', 'secret': 'admin123'})
assert r['code'] == 0, 'admin login failed'
at = r['data']['token']

STU = [('2029101', '并发甲', 'CARD-9101'), ('2029102', '并发乙', 'CARD-9102'),
       ('2029103', '并发丙', 'CARD-9103')]
stu_tokens = {}
for no, name, card in STU:
    api('/api/register', {'stu_no': no, 'name': name, 'dept': '测试班', 'card_no': card}, token=at)
_, r = api('/api/student/list?group=pending', token=at)
pid = {s['stu_no']: s['id'] for s in r['data']['list'] if s['stu_no'] in dict((x[0], x[1]) for x in STU)}
for no, name, card in STU:
    api('/api/student/audit', {'student_id': pid[no], 'action': 'pass'}, token=at)
    _, r = api('/api/login', {'type': 'student', 'account': no, 'secret': name})
    assert r['code'] == 0, no + ' login failed'
    stu_tokens[no] = r['data']['token']
tA, tB, tC = stu_tokens['2029101'], stu_tokens['2029102'], stu_tokens['2029103']

# 测试活动: A1 容量1 / A2 不限 / A3 将改为已结束 / A4 进行中(刷卡) / A5 仅验证时间校验
now = datetime.now()
a1 = add_act(at, 'P1满员竞态', dt(minutes=5), dt(days=2), capacity=1)
a2 = add_act(at, 'P1容量不限', dt(minutes=5), dt(days=2), capacity=0)
a3 = add_act(at, 'P2已结束', dt(minutes=5), dt(days=2), capacity=10)
a4 = add_act(at, 'P1刷卡重复', dt(minutes=1), dt(days=2), capacity=10)
check('setup activities created', None not in (a1, a2, a3, a4))
# A3 通过"编辑"改为过去时间段(编辑允许历史时间, 发布不允许 —— 本身就是一条 P2 用例)
_, r = api('/api/activity/update', {'activity_id': a3, 'title': 'P2已结束', 'content': '',
                                    'location': '测试场地', 'start_time': dt(days=-3),
                                    'end_time': dt(days=-2), 'hours': 2.0,
                                    'capacity': 10, 'publisher': '系统管理员'}, token=at)
check('edit allows past time (P2)', r['code'] == 0, r.get('msg', ''))

try:
    # ================= P1 =================
    print('---- P1 并发与权限 ----')
    # 1) 越权矩阵: 学生 token 打管理接口
    admin_only = [('/api/signup/audit', {'signup_id': 1, 'action': 'pass'}),
                  ('/api/student/list', None),
                  ('/api/hours/rebuild', {}),
                  ('/api/activity/add', {'title': 'x'}),
                  ('/api/student/audit', {'student_id': 1, 'action': 'pass'}),
                  ('/api/activity/status', {'activity_id': a1, 'status': 0}),
                  ('/api/config/set', {'required_hours': 20})]
    vio = []
    for p, b in admin_only:
        st, r = api(p, b, token=tA)
        # 服务端约定: 业务错误也走 HTTP 200, 判断 body 里的 code
        if r.get('code') != 403:
            vio.append('%s->%s/%s' % (p, st, r.get('code')))
    check('privilege: all admin APIs 403 for student', not vio, str(vio))

    # 2) 伪造 stu_no: body 塞别人学号, 应被忽略并归属登录者本人
    _, r = api('/api/signup/add', {'client_id': 'fake-1', 'activity_id': a2,
                                   'stu_no': '2029102', 'name': '并发乙'}, token=tA)
    check('forged stu_no: signup ok', r['code'] == 0, r.get('msg', ''))
    row = sql("SELECT stu_no FROM signup WHERE client_id='fake-1'")
    check('forged stu_no: owner is login user', row == '2029101', row)

    # 3) 容量 0 不限: 甲乙都成功
    _, r = api('/api/signup/add', {'client_id': 'cap0-b', 'activity_id': a2}, token=tB)
    check('capacity 0 allows many', r['code'] == 0, r.get('msg', ''))

    # 4) 满员竞态: 容量 1, 甲乙并发报名
    results = []

    def fire_signup(tok, cid):
        results.append(api('/api/signup/add', {'client_id': cid, 'activity_id': a1}, token=tok))

    ths = [threading.Thread(target=fire_signup, args=(tA, 'race-a')),
           threading.Thread(target=fire_signup, args=(tB, 'race-b'))]
    [t.start() for t in ths]
    [t.join() for t in ths]
    succ = [1 for st, r in results if st == 200 and r['code'] == 0]
    denied = [m['msg'] for st, m in results if not (st == 200 and m['code'] == 0)]
    check('capacity race: exactly 1 of 2 succeeds', len(succ) == 1,
          'denied=%s' % denied)
    valid = int(sql("SELECT COUNT(*) FROM signup WHERE activity_id=%d AND status<>2" % a1))
    check('capacity race: valid_count <= 1', valid <= 1, 'valid=%d' % valid)

    # 5) 并发重复审核: 乙在 a2 的待审记录, 两路并发通过 -> 学时只加一次
    rowid = int(sql("SELECT id FROM signup WHERE activity_id=%d AND stu_no='2029102'" % a2))
    before = float(sql("SELECT COALESCE(total_hours,0) FROM hours_total WHERE stu_no='2029102'") or 0)
    audit_results = []

    def fire_audit():
        audit_results.append(api('/api/signup/audit',
                                 {'signup_id': rowid, 'action': 'pass', 'remark': '并发审核测试'}, token=at))

    ths = [threading.Thread(target=fire_audit), threading.Thread(target=fire_audit)]
    [t.start() for t in ths]
    [t.join() for t in ths]
    n_ok = sum(1 for st, r in audit_results if st == 200 and r['code'] == 0)
    after = float(sql("SELECT COALESCE(total_hours,0) FROM hours_total WHERE stu_no='2029102'") or 0)
    check('concurrent audit: exactly 1 success', n_ok == 1,
          'results=%s' % [(st, m.get('msg', '')) for st, m in audit_results])
    check('concurrent audit: hours counted once', abs((after - before) - 2.0) < 1e-6,
          'delta=%.2f' % (after - before))

    # 6) 已通过不可撤销
    _, r = api('/api/signup/cancel', {'activity_id': a2}, token=tB)
    check('passed signup cannot be cancelled', r['code'] != 0 and '仅待审核' in r['msg'], r.get('msg', ''))

    # 7) 刷卡重复累计: 丙(未报名)同卡连刷 5 次 a4 -> 学时只加一次
    # 注册接口不绑卡(卡片在刷卡时落 signup.card_no), 学生表绑卡用 SQL 模拟"已绑卡成员"
    sql("UPDATE student SET card_no='CARD-9103' WHERE stu_no='2029103'")
    for i in range(5):
        st, r = api('/api/signin', {'card_no': 'CARD-9103', 'activity_id': a4})
    c_hours = float(sql("SELECT total_hours FROM hours_total WHERE stu_no='2029103'") or 0)
    c_passed = int(sql("SELECT COUNT(*) FROM signup WHERE stu_no='2029103' AND status=1 AND checkin=1"))
    check('5x card swipe: hours counted once', abs(c_hours - 2.0) < 1e-6, 'hours=%.2f' % c_hours)
    check('5x card swipe: single passed record', c_passed == 1, 'records=%d' % c_passed)
    st, r = api('/api/signin', {'card_no': 'CARD-9999', 'activity_id': a4})
    check('unbound card -> 404', r['code'] == 404 and '未绑定' in r['msg'], r.get('msg', ''))

    # 8) Token 生命周期: 登出后旧 token 失效
    _, r = api('/api/login', {'type': 'student', 'account': '2029102', 'secret': '并发乙'})
    tok_b2 = r['data']['token']
    api('/api/logout', {}, token=tok_b2)
    st, r = api('/api/signup/list', token=tok_b2)
    check('old token after logout -> 401', st == 401 or r['code'] == 401, 'st=%s' % st)
    st, r = api('/api/signup/list', token='deadbeef' * 4)
    check('random token -> 401', st == 401 or r['code'] == 401, 'st=%s' % st)

    # ================= P2 =================
    print('---- P2 状态机与边界 ----')
    # 9) 已结束活动拒绝报名
    _, r = api('/api/signup/add', {'client_id': 'p2-end', 'activity_id': a3}, token=tA)
    check('ended activity rejects signup', r['code'] == 400 and '结束' in r['msg'], r.get('msg', ''))
    # 10) 已下线活动拒绝报名
    api('/api/activity/status', {'activity_id': a4, 'status': 0}, token=at)
    _, r = api('/api/signup/add', {'client_id': 'p2-off', 'activity_id': a4}, token=tC)
    check('offline activity rejects signup', r['code'] == 400 and '未开放' in r['msg'], r.get('msg', ''))
    api('/api/activity/status', {'activity_id': a4, 'status': 1}, token=at)
    # 11) 时间校验: 结束早于开始
    _, r = api('/api/activity/add', {'title': '坏时间', 'start_time': dt(days=3),
                                     'end_time': dt(days=1), 'hours': 1.0, 'capacity': 0,
                                     'publisher': '系统管理员'}, token=at)
    check('end<=start rejected on publish', r['code'] == 400, r.get('msg', ''))
    _, r = api('/api/activity/add', {'title': '坏时间2', 'start_time': dt(days=1),
                                     'end_time': dt(days=1), 'hours': 1.0, 'capacity': 0,
                                     'publisher': '系统管理员'}, token=at)
    check('end==start rejected on publish', r['code'] == 400, r.get('msg', ''))
    # 12) 驳回后重报: 状态复位待审 + 旧备注清空
    _, r = api('/api/signup/add', {'client_id': 'rej-1', 'activity_id': a1}, token=tB)
    rid = int(sql("SELECT id FROM signup WHERE activity_id=%d AND stu_no='2029102'" % a1))
    api('/api/signup/audit', {'signup_id': rid, 'action': 'reject', 'remark': '理由不充分测试'}, token=at)
    rmk = sql("SELECT remark FROM signup WHERE id=%d" % rid)
    check('reject stores remark', '不充分' in rmk, rmk)
    _, r = api('/api/signup/add', {'client_id': 'rej-2', 'activity_id': a1}, token=tB)
    check('re-signup after reject ok', r['code'] == 0, r.get('msg', ''))
    # 重报后复位待审; remark 清空(mysql CLI 对行尾空列可能不输出, 空串/NULL 均视为已清)
    parts = sql("SELECT status,remark FROM signup WHERE id=%d" % rid).split('\t')
    st2 = parts[0] if parts else '?'
    rmk2 = parts[1] if len(parts) > 1 else ''
    check('re-signup resets to pending & clears remark',
          st2 == '0' and rmk2 in ('', 'NULL'), 'status=%s remark=%r' % (st2, rmk2))
    # 13) 达标线边界: 999 全员未达标 -> 恢复 0
    api('/api/config/set', {'required_hours': 999}, token=at)
    _, r = api('/api/hours/report', token=at)
    d = r['data']
    check('threshold 999: nobody achieved', int(d.get('achieved_count', 0)) == 0,
          'achieved=%s' % d.get('achieved_count'))
    api('/api/config/set', {'required_hours': 0}, token=at)
    _, r = api('/api/hours/report', token=at)
    check('threshold 0: no line', int(r['data'].get('achieved_count', -1)) == 0, '')
    # 14) 分页 total 一致: 待审筛选 total == 待审行数
    _, r = api('/api/signup/list?status=0&size=20&page=1', token=at)
    total = int(r['data']['total'])
    rows = len(r['data']['list'])
    check('filtered total matches rows (<=size)', total >= rows and rows <= 20,
          'total=%d rows=%d' % (total, rows))
finally:
    # ---------- 清理: 删学生(级联删报名/学时) + 删测试活动 ----------
    for no, name, card in STU:
        api('/api/student/delete', {'stu_no': no, 'confirm_stu_no': no}, token=at)
    ids = ','.join(str(x) for x in (a1, a2, a3, a4) if x)
    sql("DELETE FROM activity WHERE id IN (%s)" % ids)
    sql("DELETE FROM sys_config WHERE 1=0")  # no-op, 保持连接习惯
    left = sql("SELECT COUNT(*) FROM student WHERE stu_no LIKE '20291%'")
    print('[CLEANUP] test students left=%s (expect 0)' % left)

print('result: %d passed, %d failed' % (ok, bad))
sys.exit(1 if bad else 0)
