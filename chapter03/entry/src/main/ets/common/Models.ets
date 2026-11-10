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
  category: string;       // 七大类 key: thought/practice/volunteer/innovation/sports/social/skill
  taken: number;          // 服务端名额计数缓存(status<>2), 与 valid_count 应一致
  join_scope: string;     // v5.0 参与范围: 'club'=仅本社团成员 / 'all'=全校开放
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
  checkin_at: string;      // 刷卡/输码签到时间(未签到为空)
  category: string;        // 报名时的活动类别快照
  signout_at: string;      // 签退时间(空 = 未签退)
  is_outsider: boolean;    // v5.0 报名人是否不属于活动所属社团(公开活动的外部参与者)
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
  is_me: boolean;      // 是否本人(学生视图下他人姓名/学号已脱敏, 只能靠该标记定位自己)
}

// 学时明细
export interface HoursDetail {
  stu_no: string;
  name: string;
  activity: string;
  hours: number;
  audited_at: string;
  category: string;
}

// 分类学时汇总(图表用)
export interface CategoryStat {
  category: string;
  hours: number;
  count: number;
}

// 学分预警行(未达标名单)
export interface WarningRow {
  stu_no: string;
  name: string;
  dept: string;
  total_hours: number;
  sign_count: number;
  gap: number;              // 距离达标线还差的学时
  last_activity_at: string; // 最近一次认定时间(空 = 从未认定)
}

// 学时申诉(v4.0)
export interface AppealInfo {
  id: number;
  stu_no: string;
  name: string;
  signup_id: number;
  activity_id: number;
  activity_title: string;
  activity_hours: number;
  signup_hours: number;
  reason: string;
  status: number;        // 0待处理 1已通过 2已驳回
  reply: string;
  hours_before: number;
  hours_after: number;   // -1 表示未调整(驳回)
  created_at: string;
  handled_at: string;
  handler: string;
}

// 签到异常(v4.0): 同一活动短时间批量签到
export interface AnomalyBurst {
  activity_id: number;
  activity_title: string;
  window_start: string;
  count: number;
  students: string;
}

// 签到异常: 签到后长期未签退
export interface AnomalyNotOut {
  signup_id: number;
  stu_no: string;
  name: string;
  activity_title: string;
  checked_at: string;
  hours_waiting: number;
  hours: number;
}

// 签到异常: 认定学时大于活动学时
export interface AnomalyExceed {
  signup_id: number;
  stu_no: string;
  name: string;
  activity_title: string;
  hours: number;
  activity_hours: number;
}

// ---------- 活动类别(七大类) ----------
export const CATEGORY_KEYS: string[] = ['thought', 'practice', 'volunteer', 'innovation', 'sports', 'social', 'skill'];
export const CATEGORY_LABELS: string[] = ['思想成长', '实践实习', '志愿公益', '创新创业', '文体活动', '社会工作', '技能特长'];

/** 类别 key -> 中文名(未知值按文体活动处理, 与服务端回落口径一致) */
export function categoryText(key: string): string {
  const i = CATEGORY_KEYS.indexOf(key);
  return i >= 0 ? CATEGORY_LABELS[i] : CATEGORY_LABELS[4];
}

/** 类别 key -> 在列表中的下标(用于选择器默认值) */
export function categoryIndex(key: string): number {
  const i = CATEGORY_KEYS.indexOf(key);
  return i >= 0 ? i : 4;
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
  category: string;    // 七大类 key, 发布时随活动一起提交
  join_scope: string;  // v5.0 参与范围: club=仅本社团 / all=全校开放
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
      status: numOf(item, 'status', 1),
      category: strOf(item, 'category', 'sports'),
      taken: numOf(item, 'taken', numOf(item, 'valid_count')),
      join_scope: strOf(item, 'join_scope', 'all')
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
      checkin_at: strOf(item, 'checkin_at'),
      category: strOf(item, 'category', 'sports'),
      signout_at: strOf(item, 'signout_at'),
      is_outsider: boolOf(item, 'is_outsider')
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
      achieved: boolOf(item, 'achieved'),
      is_me: boolOf(item, 'is_me')
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
      audited_at: strOf(item, 'audited_at'),
      category: strOf(item, 'category', 'sports')
    });
  }
  return out;
}

/** 解析分类学时汇总 */
export function parseCategoryStats(resp: Record<string, Object>): CategoryStat[] {
  const out: CategoryStat[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['by_category'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      category: strOf(item, 'category', 'sports'),
      hours: numOf(item, 'hours'),
      count: numOf(item, 'count')
    });
  }
  return out;
}

/** 解析学分预警名单 */
export function parseWarningList(resp: Record<string, Object>): WarningRow[] {
  const out: WarningRow[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      dept: strOf(item, 'dept'),
      total_hours: numOf(item, 'total_hours'),
      sign_count: numOf(item, 'sign_count'),
      gap: numOf(item, 'gap'),
      last_activity_at: strOf(item, 'last_activity_at')
    });
  }
  return out;
}

/** 解析学时申诉列表(v4.0) */
export function parseAppeals(resp: Record<string, Object>): AppealInfo[] {
  const out: AppealInfo[] = [];
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
      signup_id: numOf(item, 'signup_id'),
      activity_id: numOf(item, 'activity_id'),
      activity_title: strOf(item, 'activity_title'),
      activity_hours: numOf(item, 'activity_hours'),
      signup_hours: numOf(item, 'signup_hours'),
      reason: strOf(item, 'reason'),
      status: numOf(item, 'status'),
      reply: strOf(item, 'reply'),
      hours_before: numOf(item, 'hours_before'),
      hours_after: numOf(item, 'hours_after', -1),
      created_at: strOf(item, 'created_at'),
      handled_at: strOf(item, 'handled_at'),
      handler: strOf(item, 'handler')
    });
  }
  return out;
}

/** 解析签到异常上报(v4.0): 三个数组分别解析 */
export function parseAnomalyBurst(resp: Record<string, Object>): AnomalyBurst[] {
  const out: AnomalyBurst[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['burst'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      activity_id: numOf(item, 'activity_id'),
      activity_title: strOf(item, 'activity_title'),
      window_start: strOf(item, 'window_start'),
      count: numOf(item, 'count'),
      students: strOf(item, 'students')
    });
  }
  return out;
}

export function parseAnomalyNotOut(resp: Record<string, Object>): AnomalyNotOut[] {
  const out: AnomalyNotOut[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['not_signed_out'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      signup_id: numOf(item, 'signup_id'),
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      activity_title: strOf(item, 'activity_title'),
      checked_at: strOf(item, 'checked_at'),
      hours_waiting: numOf(item, 'hours_waiting'),
      hours: numOf(item, 'hours')
    });
  }
  return out;
}

export function parseAnomalyExceed(resp: Record<string, Object>): AnomalyExceed[] {
  const out: AnomalyExceed[] = [];
  if (resp['code'] !== 0) return out;
  const data = resp['data'] as Record<string, Object> | null;
  if (!data || typeof data !== 'object') return out;
  const list = data['hours_exceed'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      signup_id: numOf(item, 'signup_id'),
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      activity_title: strOf(item, 'activity_title'),
      hours: numOf(item, 'hours'),
      activity_hours: numOf(item, 'activity_hours')
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

/** 注销影响面: 供二次确认弹窗如实告知"将删除什么", 而不是只问一句"确定吗" */
export interface CancelImpact {
  stu_no: string;
  name: string;
  dept: string;
  reg_status: number;     // 0待审核 1已通过 2已驳回
  signup_total: number;   // 报名总条数
  signup_passed: number;  // 其中已通过
  signup_pending: number;
  signup_rejected: number;
  hours_sum: number;      // 由报名明细汇总的学时
  hours_total: number;    // hours_total 表记录值
}

/** 解析注销影响面; 失败返回 null(学号不存在时服务端返回 404) */
export function parseCancelImpact(resp: Record<string, Object>): CancelImpact | null {
  const d = dataOf(resp);
  if (d === null) return null;
  return {
    stu_no: strOf(d, 'stu_no'),
    name: strOf(d, 'name'),
    dept: strOf(d, 'dept'),
    reg_status: numOf(d, 'reg_status'),
    signup_total: numOf(d, 'signup_total'),
    signup_passed: numOf(d, 'signup_passed'),
    signup_pending: numOf(d, 'signup_pending'),
    signup_rejected: numOf(d, 'signup_rejected'),
    hours_sum: numOf(d, 'hours_sum'),
    hours_total: numOf(d, 'hours_total')
  };
}

// ==================== v5.0 社团账号(认证主体=社团) ====================

/** 社团信息 + 现任社长 + 社团维度统计 */
export interface ClubInfo {
  id: number;
  account: string;          // 社团登录账号(长期不变)
  club_name: string;
  intro: string;
  dept: string;             // 挂靠单位
  leader_name: string;      // 现任社长(换届只改这个字段)
  leader_stu_no: string;
  leader_since: string;
  leader_days: number;      // 在任天数
  status: number;           // 1 正常 / 0 停用
  created_at: string;
  member_count: number;
  activity_count: number;
  signup_count: number;
  hours_sum: number;        // 本社团活动已认定学时合计
  pending_signup: number;   // 待审核报名数
  internal_count: number;   // 仅本社团活动数
  public_count: number;     // 全校开放活动数
}

export function parseClubInfo(resp: Record<string, Object>): ClubInfo | null {
  const d = dataOf(resp);
  if (d === null) return null;
  return {
    id: numOf(d, 'id'),
    account: strOf(d, 'account'),
    club_name: strOf(d, 'club_name'),
    intro: strOf(d, 'intro'),
    dept: strOf(d, 'dept'),
    leader_name: strOf(d, 'leader_name'),
    leader_stu_no: strOf(d, 'leader_stu_no'),
    leader_since: strOf(d, 'leader_since'),
    leader_days: numOf(d, 'leader_days'),
    status: numOf(d, 'status', 1),
    created_at: strOf(d, 'created_at'),
    member_count: numOf(d, 'member_count'),
    activity_count: numOf(d, 'activity_count'),
    signup_count: numOf(d, 'signup_count'),
    hours_sum: numOf(d, 'hours_sum'),
    pending_signup: numOf(d, 'pending_signup'),
    internal_count: numOf(d, 'internal_count'),
    public_count: numOf(d, 'public_count')
  };
}

/** 历任社长记录(时间轴) */
export interface LeaderRecord {
  id: number;
  leader_name: string;
  leader_stu_no: string;
  start_at: string;
  end_at: string;          // 空 = 在任
  is_current: boolean;
  change_type: number;     // 1 换届 / 2 更正 / 3 初始化
  operator: string;
  reason: string;
}

export function parseLeaders(resp: Record<string, Object>): LeaderRecord[] {
  const out: LeaderRecord[] = [];
  const d = dataOf(resp);
  if (d === null) return out;
  const list = d['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      id: numOf(item, 'id'),
      leader_name: strOf(item, 'leader_name'),
      leader_stu_no: strOf(item, 'leader_stu_no'),
      start_at: strOf(item, 'start_at'),
      end_at: strOf(item, 'end_at'),
      is_current: boolOf(item, 'is_current'),
      change_type: numOf(item, 'change_type'),
      operator: strOf(item, 'operator'),
      reason: strOf(item, 'reason')
    });
  }
  return out;
}

export function changeTypeText(t: number): string {
  if (t === 1) return '换届';
  if (t === 2) return '更正';
  return '初始化';
}

/** 参与范围展示文案: 内部活动用"仅本社团", 公开活动用"全校开放" */
export function joinScopeText(scope: string): string {
  return scope === 'club' ? '仅本社团' : '全校开放';
}

// ==================== v5.0 社团成员 / 通知公告 ====================

/** 社团成员(成员管理页) */
export interface ClubMember {
  stu_no: string;
  name: string;
  dept: string;
  role: string;            // leader | minister | member
  status: number;          // 1 在册 / 0 已退出
  joined_at: string;
  quit_at: string;
  student_status: number;  // 学生账号状态: 1 正常 / 0 待审核 / 2 拒绝 / -1 账号已注销
}

export function parseClubMembers(resp: Record<string, Object>): ClubMember[] {
  const out: ClubMember[] = [];
  const d = dataOf(resp);
  if (d === null) return out;
  const list = d['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      stu_no: strOf(item, 'stu_no'),
      name: strOf(item, 'name'),
      dept: strOf(item, 'dept'),
      role: strOf(item, 'role', 'member'),
      status: numOf(item, 'status', 1),
      joined_at: strOf(item, 'joined_at'),
      quit_at: strOf(item, 'quit_at'),
      student_status: numOf(item, 'student_status', -1)
    });
  }
  return out;
}

export function memberRoleText(role: string): string {
  if (role === 'leader') return '社长';
  if (role === 'minister') return '部长';
  return '成员';
}

/** 通知公告 */
export interface AnnouncementInfo {
  id: number;
  title: string;
  content: string;
  publisher: string;
  top_flag: number;      // 1 置顶
  status: number;        // 1 已发布 / 0 已撤回
  created_at: string;
  club_name: string;
  is_read: boolean;
}

export function parseAnnouncements(resp: Record<string, Object>): AnnouncementInfo[] {
  const out: AnnouncementInfo[] = [];
  const d = dataOf(resp);
  if (d === null) return out;
  const list = d['list'] as Array<Record<string, Object>> | null;
  if (!list) return out;
  for (const item of list) {
    out.push({
      id: numOf(item, 'id'),
      title: strOf(item, 'title'),
      content: strOf(item, 'content'),
      publisher: strOf(item, 'publisher'),
      top_flag: numOf(item, 'top_flag'),
      status: numOf(item, 'status', 1),
      created_at: strOf(item, 'created_at'),
      club_name: strOf(item, 'club_name'),
      is_read: boolOf(item, 'is_read')
    });
  }
  return out;
}

/** 公告未读数(学生端角标用) */
export function unreadAnnouncements(resp: Record<string, Object>): number {
  const d = dataOf(resp);
  return d === null ? 0 : numOf(d, 'unread_count');
}

// ==================== v5.0 社团维度统计 (/api/stats/club) ====================

/**
 * 社团维度统计。口径: 一切按 signup.club_id(报名时快照的活动所属社团)聚合,
 * 因此"公开活动引来的外社团报名"也计入本社团, 但用 outsider_* 单独标出。
 */
export interface ClubStats {
  club_id: number;
  member_count: number;      // 在册成员数
  activity_count: number;    // 社团活动总数
  internal_count: number;    // 仅本社团活动数
  public_count: number;      // 全校开放活动数
  signup_count: number;      // 报名总数(含待审/拒绝)
  passed_count: number;      // 已通过报名数
  hours_sum: number;         // 已认定学时合计
  pass_rate: number;         // 通过率(百分比)
  outsider_count: number;    // 外社团参与人数(去重)
  outsider_join_count: number; // 外社团报名条数
}

export function parseClubStats(resp: Record<string, Object>): ClubStats | null {
  const d = dataOf(resp);
  if (d === null) return null;
  return {
    club_id: numOf(d, 'club_id'),
    member_count: numOf(d, 'member_count'),
    activity_count: numOf(d, 'activity_count'),
    internal_count: numOf(d, 'internal_count'),
    public_count: numOf(d, 'public_count'),
    signup_count: numOf(d, 'signup_count'),
    passed_count: numOf(d, 'passed_count'),
    hours_sum: numOf(d, 'hours_sum'),
    pass_rate: numOf(d, 'pass_rate'),
    outsider_count: numOf(d, 'outsider_count'),
    outsider_join_count: numOf(d, 'outsider_join_count')
  };
}
