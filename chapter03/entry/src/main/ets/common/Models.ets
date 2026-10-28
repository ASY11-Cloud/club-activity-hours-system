/**
 * 社团活动报名与学时认定系统 —— 数据模型与 JSON 解析工具
 * ArkTS 严格模式: 不使用 any, 所有解析显式进行。
 */

// 活动
export interface ActivityInfo {
  id: number;
  title: string;
  content: string;
  location: string;
  start_time: string;
  end_time: string;
  hours: number;
  capacity: number;
  publisher: string;
  signed_count: number;   // 全部报名数(含已驳回, 仅用于展示)
  passed_count: number;
  valid_count: number;    // 有效报名数(不含已驳回, 与服务端容量口径一致)
  remaining: number;      // 剩余名额; -1 表示不限人数
  expired: boolean;       // 活动是否已结束(结束后不可报名/刷卡)
  status: number;         // 1 已发布 / 0 已下线(仅管理员查询 all=1 时可能出现)
}

// 报名记录
export interface SignupInfo {
  id: number;
  client_id: string;
  activity_id: number;
  stu_no: string;
  name: string;
  status: number;       // 0待审核 1已通过 2已驳回
  checkin: number;      // 0未签到 1已签到
  hours: number;
  remark: string;
  created_at: string;
  audited_at: string;
  activity_title: string;
  activity_hours: number;  // 活动本身的学时(审核通过时服务端按此累计)
  checkin_at: string;      // 刷卡签到时间(未签到为空)
}

// 学时排行
export interface HoursRow {
  rank: number;
  stu_no: string;
  name: string;
  total_hours: number;
  sign_count: number;
  updated_at: string;
  achieved: boolean;   // 是否达到系统设定的学时达标线(未设达标线时恒为 false)
}

// 学时明细
export interface HoursDetail {
  stu_no: string;
  name: string;
  activity: string;
  hours: number;
  audited_at: string;
}

// 请求日志
export interface LogRow {
  time: string;
  method: string;
  path: string;
  ip: string;
  status: number;
  cost_ms: number;
  detail: string;
}

// 本地草稿(活动)
export interface LocalDraft {
  id: number;
  server_id: number;
  title: string;
  content: string;
  location: string;
  start_time: string;
  end_time: string;
  hours: number;
  capacity: number;
  publisher: string;
  synced: number;
  created_at: string;
}

// 本地报名记录
export interface LocalSignup {
  id: number;
  client_id: string;
  activity_id: number;
  activity_title: string;
  stu_no: string;
  name: string;
  status: number;
  checkin: number;     // 0未签到 1已刷卡签到(由服务器同步下发, 本地缓存便于离线查看)
  hours: number;
  synced: number;
  remark: string;
  created_at: string;
}

// 注册申请(待管理员审核)
export interface StudentRequest {
  id: number;
  stu_no: string;
  name: string;
  dept: string;
  card_no: string;
  created_at: string;
}

// 用户管理(全量学生信息: 注册状态 + 学时汇总 + 报名统计)
export interface StudentInfo {
  id: number;
  stu_no: string;
  name: string;
  dept: string;
  card_no: string;
  status: number;       // 0待审核 1已通过 2已驳回
  created_at: string;
  total_hours: number;  // 累计认定学时
  sign_count: number;   // 通过活动次数
  achieved: boolean;    // 是否达标(达到系统学时达标线)
}

// 用户管理分组计数
export interface StudentGroupCounts {
  all: number;
  pending: number;
  approved: number;
  rejected: number;
  achieved: number;
  unachieved: number;
}

// ---------- JSON 安全取值工具 ----------
export function strOf(o: Record<string, Object>, key: string, dflt: string = ''): string {
  const v = o[key];
  if (typeof v === 'string') return v as string;
  if (typeof v === 'number') return String(v as number);
  return dflt;
}

export function numOf(o: Record<string, Object>, key: string, dflt: number = 0): number {
  const v = o[key];
  if (typeof v === 'number') return v as number;
  if (typeof v === 'string') {
    const n = Number(v as string);
    return isNaN(n) ? dflt : n;
  }
  return dflt;
}

export function boolOf(o: Record<string, Object>, key: string, dflt: boolean = false): boolean {
  const v = o[key];
  if (typeof v === 'boolean') return v as boolean;
  if (typeof v === 'number') return (v as number) !== 0;
  return dflt;
}

/** 从服务器响应中解析活动列表 */
export function parseActivities(resp: Record<string, Object>): ActivityInfo[] {
  const out: ActivityInfo[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      id: numOf(item, 'id'),
      title: strOf(item, 'title'),
      content: strOf(item, 'content'),
      location: strOf(item, 'location'),
      start_time: strOf(item, 'start_time'),
      end_time: strOf(item, 'end_time'),
      hours: numOf(item, 'hours'),
      capacity: numOf(item, 'capacity'),
      publisher: strOf(item, 'publisher'),
      signed_count: numOf(item, 'signed_count'),
      passed_count: numOf(item, 'passed_count'),
      valid_count: numOf(item, 'valid_count', numOf(item, 'signed_count')),
      remaining: numOf(item, 'remaining', -1),
      expired: boolOf(item, 'expired'),
      status: numOf(item, 'status', 1)
    });
  }
  return out;
}

/** 解析报名列表 */
export function parseSignups(resp: Record<string, Object>): SignupInfo[] {
  const out: SignupInfo[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      id: numOf(item, 'id'),
      client_id: strOf(item, 'client_id'),
      activity_id: numOf(item, 'activity_id'),
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      status: numOf(item, 'status'),
      checkin: numOf(item, 'checkin'),
      hours: numOf(item, 'hours'),
      remark: strOf(item, 'remark'),
      created_at: strOf(item, 'created_at'),
      audited_at: strOf(item, 'audited_at'),
      activity_title: strOf(item, 'activity_title'),
      activity_hours: numOf(item, 'activity_hours'),
      checkin_at: strOf(item, 'checkin_at')
    });
  }
  return out;
}

/** 解析学时排行 */
export function parseHoursReport(resp: Record<string, Object>): HoursRow[] {
  const out: HoursRow[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['report'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      rank: numOf(item, 'rank'),
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      total_hours: numOf(item, 'total_hours'),
      sign_count: numOf(item, 'sign_count'),
      updated_at: strOf(item, 'updated_at'),
      achieved: boolOf(item, 'achieved')
    });
  }
  return out;
}

/** 解析学时明细 */
export function parseHoursDetail(resp: Record<string, Object>): HoursDetail[] {
  const out: HoursDetail[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['detail'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      activity: strOf(item, 'activity'),
      hours: numOf(item, 'hours'),
      audited_at: strOf(item, 'audited_at')
    });
  }
  return out;
}

/** 解析请求日志 */
export function parseLogs(resp: Record<string, Object>): LogRow[] {
  const out: LogRow[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['logs'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      time: strOf(item, 'time'),
      method: strOf(item, 'method'),
      path: strOf(item, 'path'),
      ip: strOf(item, 'ip'),
      status: numOf(item, 'status'),
      cost_ms: numOf(item, 'cost_ms'),
      detail: strOf(item, 'detail')
    });
  }
  return out;
}

/** 解析注册申请列表 */
export function parseStudentRequests(resp: Record<string, Object>): StudentRequest[] {
  const out: StudentRequest[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      id: numOf(item, 'id'),
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      dept: strOf(item, 'dept'),
      card_no: strOf(item, 'card_no'),
      created_at: strOf(item, 'created_at')
    });
  }
  return out;
}

/** 解析用户管理列表 */
export function parseStudentList(resp: Record<string, Object>): StudentInfo[] {
  const out: StudentInfo[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      id: numOf(item, 'id'),
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      dept: strOf(item, 'dept'),
      card_no: strOf(item, 'card_no'),
      status: numOf(item, 'status'),
      created_at: strOf(item, 'created_at'),
      total_hours: numOf(item, 'total_hours'),
      sign_count: numOf(item, 'sign_count'),
      achieved: boolOf(item, 'achieved')
    });
  }
  return out;
}

/** 解析用户管理分组计数 */
export function parseStudentGroupCounts(resp: Record<string, Object>): StudentGroupCounts {
  const zero: StudentGroupCounts = { all: 0, pending: 0, approved: 0, rejected: 0, achieved: 0, unachieved: 0 };
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return zero;
  const gc = data['group_counts'] as Record<string, Object> | null;
  if (!gc || typeof gc !== 'object') return zero;
  return {
    all: numOf(gc, 'all'),
    pending: numOf(gc, 'pending'),
    approved: numOf(gc, 'approved'),
    rejected: numOf(gc, 'rejected'),
    achieved: numOf(gc, 'achieved'),
    unachieved: numOf(gc, 'unachieved')
  };
}

/** 注册状态文案(学生注册审核) */
export function studentStatusText(status: number): string {
  if (status === 1) return '已通过';
  if (status === 2) return '已驳回';
  return '待审核';
}

/** 活动状态文案 */
export function statusText(status: number): string {
  if (status === 1) return '已通过';
  if (status === 2) return '已驳回';
  return '待审核';
}

// ---------- 分页 / 配置 辅助 ----------

/** 取响应 data 段(结构不符时返回 null) */
export function dataOf(resp: Record<string, Object>): Record<string, Object> | null {
  if (resp['code'] !== 0) return null;
  const d = resp['data'] as Record<string, Object> | null;
  if (!d || typeof d !== 'object') return null;
  return d;
}

/** 列表总条数(服务端分页接口统一下发 total) */
export function totalOf(resp: Record<string, Object>): number {
  const d = dataOf(resp);
  return d === null ? 0 : numOf(d, 'total');
}

/** 是否还有下一页(未分页时服务端返回 has_more=false) */
export function hasMoreOf(resp: Record<string, Object>): boolean {
  const d = dataOf(resp);
  return d === null ? false : boolOf(d, 'has_more');
}

/** "YYYY-MM-DD HH:MM(:SS)" -> Date; 格式非法返回 null(用于草稿/活动载入表单) */
export function toDate(text: string): Date | null {
  const t = text.trim();
  if (t.length < 16) return null;
  const y = Number(t.substring(0, 4));
  const mo = Number(t.substring(5, 7));
  const d = Number(t.substring(8, 10));
  const h = Number(t.substring(11, 13));
  const mi = Number(t.substring(14, 16));
  if (isNaN(y) || isNaN(mo) || isNaN(d) || isNaN(h) || isNaN(mi)) return null;
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return new Date(y, mo - 1, d, h, mi);
}

/** CSV 单元格转义: 含逗号/引号/换行时用双引号包裹并转义内部引号 */
export function csvCell(v: string): string {
  if (v.indexOf(',') >= 0 || v.indexOf('"') >= 0 || v.indexOf('\n') >= 0) {
    return '"' + v.split('"').join('""') + '"';
  }
  return v;
}
