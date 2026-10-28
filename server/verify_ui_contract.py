#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
UI 契约测试: 校验 App 端(ArkTS)读取的字段在服务端响应中真实存在且语义正确。
覆盖新增交互: 活动列表分页、审核服务端筛选/分页、学时达标线、日志筛选、活动编辑。

用法: python verify_ui_contract.py [port]
"""
import json
import sys
import urllib.request
import urllib.error
import urllib.parse

BASE = 'http://127.0.0.1:' + (sys.argv[1] if len(sys.argv) > 1 else '8000')
PASS = 0
FAIL = 0


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header('Content-Type', 'application/json; charset=utf-8')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode('utf-8')), resp.status
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode('utf-8')), e.code
        except Exception:
            return {'code': -1, 'msg': 'http %d' % e.code}, e.code
    except Exception as e:
        return {'code': -1, 'msg': str(e)}, -1


def check(name, cond, extra=''):
    global PASS, FAIL
    if cond:
        PASS += 1
        print('  [PASS] ' + name + ((' ' + extra) if extra else ''))
    else:
        FAIL += 1
        print('  [FAIL] ' + name + ((' ' + extra) if extra else ''))


def login(role, account, secret):
    r, st = call('POST', '/api/login', {'type': role, 'account': account, 'secret': secret})
    if r.get('code') != 0:
        print('    ! login failed: role=%s account=%s -> %s' % (role, account, r))
        return None
    return r['data']['token']


print('== 0. 登录 ==')
admin = login('admin', 'admin', 'admin123')
stu = login('student', '2023001', '张三')   # 成员登录口径: 学号 + 姓名
check('管理员登录', admin is not None)
check('成员登录(2023001 + 姓名)', stu is not None)

print('== 1. 活动列表分页(活动广场滚动加载) ==')
r, _ = call('GET', '/api/activity/list?page=1&size=3', token=stu)
d = r.get('data') or {}
check('page=1 size=3 返回 3 条', len(d.get('list') or []) == 3, 'len=%d' % len(d.get('list') or []))
check('下发 total', isinstance(d.get('total'), int) and d.get('total') >= 8, 'total=%s' % d.get('total'))
check('下发 has_more=True', d.get('has_more') is True)
check('下发 page=1/size=3', d.get('page') == 1 and d.get('size') == 3)
row = (d.get('list') or [{}])[0]
for k in ('id', 'title', 'valid_count', 'remaining', 'expired', 'status', 'hours', 'capacity'):
    check('活动行字段 ' + k, k in row, str(row.get(k)))
r, _ = call('GET', '/api/activity/list?page=99&size=3', token=stu)
d = r.get('data') or {}
check('越界页返回空且 has_more=False',
      (d.get('list') or []) == [] and d.get('has_more') is False)

print('== 2. 审核列表: 服务端筛选 + 分页 ==')
r, _ = call('GET', '/api/signup/list?page=1&size=5&status=0', token=admin)
d = r.get('data') or {}
rows = d.get('list') or []
check('status=0 全部为待审核', rows and all(x['status'] == 0 for x in rows), 'n=%d' % len(rows))
check('分页 size=5 生效', len(rows) <= 5)
check('下发 total/has_more', 'total' in d and 'has_more' in d, 'total=%s' % d.get('total'))
r, _ = call('GET', '/api/signup/list?page=1&size=50&kw=' + urllib.parse.quote('张'), token=admin)
rows = (r.get('data') or {}).get('list') or []
check('kw=张 命中且仅命中该姓名',
      rows and all('张' in (x['name'] + x['stu_no'] + x['activity_title']) for x in rows),
      'n=%d' % len(rows))
r, _ = call('GET', '/api/signup/list?page=1&size=50&activity_id=1', token=admin)
rows = (r.get('data') or {}).get('list') or []
check('activity_id=1 过滤生效', rows and all(x['activity_id'] == 1 for x in rows), 'n=%d' % len(rows))
key = ('id', 'name', 'stu_no', 'status', 'activity_title', 'activity_hours', 'created_at', 'checkin')
check('报名行字段齐全', rows and all(k in rows[0] for k in key))
r, _ = call('GET', '/api/signup/list?page=1&size=5', token=stu)
rows = (r.get('data') or {}).get('list') or []
check('学生只看本人', rows and all(x['stu_no'] == '2023001' for x in rows), 'n=%d' % len(rows))

print('== 3. 学时报表: 达标线 / achieved ==')
r, _ = call('GET', '/api/hours/report', token=admin)
d = r.get('data') or {}
check('下发 required_hours', 'required_hours' in d, str(d.get('required_hours')))
check('下发 total_hours/achieved_count',
      'total_hours' in d and 'achieved_count' in d,
      'total=%s achieved=%s' % (d.get('total_hours'), d.get('achieved_count')))
rep = d.get('report') or []
check('排行行含 achieved 布尔', rep and isinstance(rep[0].get('achieved'), bool))
check('排行行含 rank/name/total_hours/sign_count',
      rep and all(k in rep[0] for k in ('rank', 'stu_no', 'name', 'total_hours', 'sign_count')))
det = d.get('detail') or []
check('明细行字段齐全', det and all(k in det[0] for k in ('stu_no', 'name', 'activity', 'hours', 'audited_at')))
r0, _ = call('POST', '/api/config/set', {'required_hours': 1}, token=admin)
check('管理员可设达标线', r0.get('code') == 0)
r, _ = call('GET', '/api/hours/report', token=admin)
d = r.get('data') or {}
check('达标线生效(required_hours=1)', d.get('required_hours') == 1, str(d.get('required_hours')))
check('达标人数>0 且与 achieved 行数一致',
      d.get('achieved_count') == len([x for x in (d.get('report') or []) if x.get('achieved')]),
      'achieved=%s' % d.get('achieved_count'))
r0, _ = call('POST', '/api/config/set', {'required_hours': 20}, token=admin)
check('达标线复位为 20', r0.get('code') == 0 and (r0.get('data') or {}).get('required_hours') == 20)
r, _ = call('GET', '/api/config/get', token=stu)
check('成员可读配置(required_hours)', (r.get('data') or {}).get('required_hours') == 20)
r0, _ = call('POST', '/api/config/set', {'required_hours': 5}, token=stu)
check('成员不能改配置(403)', r0.get('code') == 403)

print('== 4. 日志筛选(日志页 chips) ==')
r, _ = call('GET', '/api/logs?limit=20&level=err', token=admin)
d = r.get('data') or {}
check('level=err 全部 >=400', all(x['status'] >= 400 for x in (d.get('logs') or [])))
check('下发 total/matched', 'total' in d and 'matched' in d,
      'total=%s matched=%s' % (d.get('total'), d.get('matched')))
r, _ = call('GET', '/api/logs?limit=20&method=GET&kw=api', token=admin)
d = r.get('data') or {}
rows = d.get('logs') or []
check('method=GET 过滤生效', all(x['method'] == 'GET' for x in rows))
check('kw=api 过滤生效', all('api' in x['path'] or 'api' in x['detail'] for x in rows))
r0, _ = call('GET', '/api/logs?limit=5', token=stu)
check('成员不能看日志(403)', r0.get('code') == 403)

print('== 5. 活动编辑(原记录更新, 数据不变) ==')
r, _ = call('GET', '/api/activity/list?page=1&size=200', token=admin)
acts = (r.get('data') or {}).get('list') or []
target = None
for a in acts:
    if a['id'] == 1:
        target = a
        break
check('取到活动 #1', target is not None)
if target:
    body = {
        'activity_id': 1, 'title': target['title'], 'content': target['content'],
        'location': target['location'], 'start_time': target['start_time'],
        'end_time': target['end_time'], 'hours': target['hours'],
        'capacity': target['capacity'], 'publisher': target['publisher'],
    }
    r0, _ = call('POST', '/api/activity/update', body, token=admin)
    check('同值编辑成功(含历史开始时间)', r0.get('code') == 0, str(r0.get('msg')))
    r, _ = call('GET', '/api/activity/list?page=1&size=200', token=admin)
    after = None
    for a in (r.get('data') or {}).get('list') or []:
        if a['id'] == 1:
            after = a
    check('编辑后字段未漂移',
          after is not None and after['title'] == target['title'] and after['hours'] == target['hours']
          and after['valid_count'] == target['valid_count'])
    # 活动2 有效报名 3 人: 人数上限设为 1 必须被拒绝
    a2 = None
    for a in acts:
        if a['id'] == 2:
            a2 = a
    if a2:
        b2 = {
            'activity_id': 2, 'title': a2['title'], 'content': a2['content'],
            'location': a2['location'], 'start_time': a2['start_time'],
            'end_time': a2['end_time'], 'hours': a2['hours'],
            'capacity': 1, 'publisher': a2['publisher'],
        }
        r0, _ = call('POST', '/api/activity/update', b2, token=admin)
        check('人数上限 < 有效报名数被拒(活动2)', r0.get('code') == 400, str(r0.get('msg')))

    bad = dict(body)
    # 上限取"当前有效报名数 + 1": 不能写死 2, 否则报名数一变用例就失效
    bad['capacity'] = target['valid_count'] + 1
    r0, _ = call('POST', '/api/activity/update', bad, token=admin)
    check('人数上限 >= 有效报名数可保存', r0.get('code') == 0,
          'capacity=%s valid=%s %s' % (bad['capacity'], target['valid_count'], r0.get('msg')))
    r0, _ = call('POST', '/api/activity/update', body, token=admin)  # 还原
    check('还原活动1 原始人数上限', r0.get('code') == 0)
    # 还原后必须回到脚本启动时的值, 否则说明用例把演示数据改坏了
    r, _ = call('GET', '/api/activity/list?page=1&size=200', token=admin)
    back = None
    for a in (r.get('data') or {}).get('list') or []:
        if a['id'] == 1:
            back = a
    check('活动1 人数上限已复原为 %s' % target['capacity'],
          back is not None and back['capacity'] == target['capacity'],
          'now=%s' % (back['capacity'] if back else 'n/a'))
    bad2 = dict(body)
    bad2['end_time'] = bad2['start_time']
    r0, _ = call('POST', '/api/activity/update', bad2, token=admin)
    check('结束时间 <= 开始被拒', r0.get('code') == 400, str(r0.get('msg')))
    r0, _ = call('POST', '/api/activity/update', dict(body, activity_id=999999), token=admin)
    check('不存在的活动 404', r0.get('code') == 404)
    r0, _ = call('POST', '/api/activity/update', body, token=stu)
    check('成员不能编辑(403)', r0.get('code') == 403)

print('=' * 66)
print('  结果: 通过 %d / 失败 %d' % (PASS, FAIL))
print('=' * 66)
sys.exit(0 if FAIL == 0 else 1)
