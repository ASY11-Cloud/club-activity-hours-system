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
  signed_count: number;
  passed_count: number;
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
}

// 学时排行
export interface HoursRow {
  rank: number;
  stu_no: string;
  name: string;
  total_hours: number;
  sign_count: number;
  updated_at: string;
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
  hours: number;
  synced: number;
  remark: string;
  created_at: string;
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
      passed_count: numOf(item, 'passed_count')
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
      activity_title: strOf(item, 'activity_title')
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
      updated_at: strOf(item, 'updated_at')
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

/** 活动状态文案 */
export function statusText(status: number): string {
  if (status === 1) return '已通过';
  if (status === 2) return '已驳回';
  return '待审核';
}
