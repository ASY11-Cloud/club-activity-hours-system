/**
 * 社团活动报名与学时认定系统 —— 本地 SQLite 数据库封装
 * 使用系统 relationalStore(SQLite):
 *  - local_activity : 活动草稿(发布前本地保存) + 活动缓存
 *  - local_signup   : 报名记录(本地落库, 可离线查看, 再同步服务器)
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LocalDraft, LocalSignup } from './Models';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'club_system.db',
  securityLevel: relationalStore.SecurityLevel.S1
};

export class DbHelper {
  private static rdb: relationalStore.RdbStore | null = null;

  /** 初始化数据库(幂等) */
  static async init(context: common.UIAbilityContext): Promise<void> {
    if (DbHelper.rdb) return;
    const store = await relationalStore.getRdbStore(context, STORE_CONFIG);
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS local_activity (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'server_id INTEGER DEFAULT 0, ' +
      'title TEXT NOT NULL, content TEXT, location TEXT, ' +
      'start_time TEXT, end_time TEXT, ' +
      'hours REAL DEFAULT 1.0, capacity INTEGER DEFAULT 0, ' +
      'publisher TEXT, synced INTEGER DEFAULT 0, ' +
      'created_at TEXT DEFAULT CURRENT_TIMESTAMP)'
    );
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS local_signup (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'client_id TEXT NOT NULL UNIQUE, ' +
      'activity_id INTEGER DEFAULT 0, activity_title TEXT, ' +
      'stu_no TEXT, name TEXT, ' +
      'status INTEGER DEFAULT 0, hours REAL DEFAULT 0, ' +
      'checkin INTEGER DEFAULT 0, ' +
      'synced INTEGER DEFAULT 0, remark TEXT, ' +
      'created_at TEXT DEFAULT CURRENT_TIMESTAMP)'
    );
    // 旧版本库升级: v2.3 及以前没有 checkin 列, 已存在的库 CREATE IF NOT EXISTS 不会补列,
    // 这里补一次(列已存在会抛错, 忽略即可), 保证老设备升级 App 后不丢刷卡签到状态。
    try {
      await store.executeSql('ALTER TABLE local_signup ADD COLUMN checkin INTEGER DEFAULT 0');
    } catch (e) {
      // 列已存在: 正常情况, 无需处理
    }
    DbHelper.rdb = store;
  }

  // ==================== 活动草稿 / 缓存 ====================

  /** 保存活动草稿(本地), 返回草稿 id */
  static async addDraft(title: string, content: string, location: string,
    startTime: string, endTime: string, hours: number, capacity: number,
    publisher: string): Promise<number> {
    const store = DbHelper.rdb;
    if (!store) return 0;
    const vb: relationalStore.ValuesBucket = {
      'title': title,
      'content': content,
      'location': location,
      'start_time': startTime,
      'end_time': endTime,
      'hours': hours,
      'capacity': capacity,
      'publisher': publisher,
      'synced': 0
    };
    return await store.insert('local_activity', vb);
  }

  /** 草稿同步成功后标记 server_id / synced */
  static async markDraftSynced(id: number, serverId: number): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const vb: relationalStore.ValuesBucket = { 'synced': 1, 'server_id': serverId };
    const pred = new relationalStore.RdbPredicates('local_activity');
    pred.equalTo('id', id);
    await store.update(vb, pred);
  }

  /** 查询全部草稿(未同步优先) */
  static async getDrafts(): Promise<LocalDraft[]> {
    const store = DbHelper.rdb;
    const out: LocalDraft[] = [];
    if (!store) return out;
    const pred = new relationalStore.RdbPredicates('local_activity');
    pred.orderByDesc('id');
    const rs = await store.query(pred, DbHelper.DRAFT_COLS);
    while (rs.goToNextRow()) {
      out.push(DbHelper.mapDraft(rs));
    }
    rs.close();
    return out;
  }

  /** 按 id 查询单条草稿(草稿载入表单/编辑用); 不存在返回 null */
  static async getDraft(id: number): Promise<LocalDraft | null> {
    const store = DbHelper.rdb;
    if (!store) return null;
    const pred = new relationalStore.RdbPredicates('local_activity');
    pred.equalTo('id', id);
    const rs = await store.query(pred, DbHelper.DRAFT_COLS);
    let out: LocalDraft | null = null;
    if (rs.goToNextRow()) out = DbHelper.mapDraft(rs);
    rs.close();
    return out;
  }

  /** 更新草稿(表单回填后再次保存, 不新增记录) */
  static async updateDraft(id: number, title: string, content: string, location: string,
    startTime: string, endTime: string, hours: number, capacity: number,
    publisher: string): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const vb: relationalStore.ValuesBucket = {
      'title': title,
      'content': content,
      'location': location,
      'start_time': startTime,
      'end_time': endTime,
      'hours': hours,
      'capacity': capacity,
      'publisher': publisher
    };
    const pred = new relationalStore.RdbPredicates('local_activity');
    pred.equalTo('id', id);
    await store.update(vb, pred);
  }

  /** 草稿字段列表(查询与映射共用, 避免两处字段顺序不一致) */
  private static readonly DRAFT_COLS: string[] = ['id', 'server_id', 'title', 'content', 'location',
    'start_time', 'end_time', 'hours', 'capacity', 'publisher', 'synced', 'created_at'];

  private static mapDraft(rs: relationalStore.ResultSet): LocalDraft {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      server_id: rs.getLong(rs.getColumnIndex('server_id')),
      title: DbHelper.safeStr(rs, 'title'),
      content: DbHelper.safeStr(rs, 'content'),
      location: DbHelper.safeStr(rs, 'location'),
      start_time: DbHelper.safeStr(rs, 'start_time'),
      end_time: DbHelper.safeStr(rs, 'end_time'),
      hours: rs.getDouble(rs.getColumnIndex('hours')),
      capacity: rs.getLong(rs.getColumnIndex('capacity')),
      publisher: DbHelper.safeStr(rs, 'publisher'),
      synced: rs.getLong(rs.getColumnIndex('synced')),
      created_at: DbHelper.safeStr(rs, 'created_at')
    };
  }

  /** 删除草稿 */
  static async deleteDraft(id: number): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const pred = new relationalStore.RdbPredicates('local_activity');
    pred.equalTo('id', id);
    await store.delete(pred);
  }

  // ==================== 本地报名记录 ====================

  /** 报名写入本地库(幂等: client_id 唯一) */
  static async addSignup(clientId: string, activityId: number, title: string,
    stuNo: string, name: string): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const pred = new relationalStore.RdbPredicates('local_signup');
    pred.equalTo('client_id', clientId);
    const rs = await store.query(pred, ['id']);
    const exists = rs.goToNextRow();
    rs.close();
    if (exists) return; // 已存在, 幂等
    const vb: relationalStore.ValuesBucket = {
      'client_id': clientId,
      'activity_id': activityId,
      'activity_title': title,
      'stu_no': stuNo,
      'name': name,
      'status': 0,
      'checkin': 0,
      'synced': 0
    };
    await store.insert('local_signup', vb);
  }

  /** 按 client_id 查本地报名记录(不存在返回 null) */
  static async getSignupByClientId(clientId: string): Promise<LocalSignup | null> {
    const store = DbHelper.rdb;
    if (!store) return null;
    const pred = new relationalStore.RdbPredicates('local_signup');
    pred.equalTo('client_id', clientId);
    const rs = await store.query(pred, ['id', 'client_id', 'activity_id', 'activity_title',
      'stu_no', 'name', 'status', 'checkin', 'hours', 'synced', 'remark', 'created_at']);
    let out: LocalSignup | null = null;
    if (rs.goToNextRow()) {
      out = {
        id: rs.getLong(rs.getColumnIndex('id')),
        client_id: DbHelper.safeStr(rs, 'client_id'),
        activity_id: rs.getLong(rs.getColumnIndex('activity_id')),
        activity_title: DbHelper.safeStr(rs, 'activity_title'),
        stu_no: DbHelper.safeStr(rs, 'stu_no'),
        name: DbHelper.safeStr(rs, 'name'),
        status: rs.getLong(rs.getColumnIndex('status')),
        checkin: rs.getLong(rs.getColumnIndex('checkin')),
        hours: rs.getDouble(rs.getColumnIndex('hours')),
        synced: rs.getLong(rs.getColumnIndex('synced')),
        remark: DbHelper.safeStr(rs, 'remark'),
        created_at: DbHelper.safeStr(rs, 'created_at')
      };
    }
    rs.close();
    return out;
  }

  /** 完整字段补插(服务器记录同步到本地: 不存在则插入, 存在则更新状态) */
  static async upsertSignupFromServer(clientId: string, activityId: number, title: string,
    stuNo: string, name: string, status: number, checkin: number, hours: number, remark: string): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const exist = await DbHelper.getSignupByClientId(clientId);
    if (exist === null) {
      const vb: relationalStore.ValuesBucket = {
        'client_id': clientId,
        'activity_id': activityId,
        'activity_title': title,
        'stu_no': stuNo,
        'name': name,
        'status': status,
        'checkin': checkin,
        'hours': hours,
        'synced': 1,
        'remark': remark
      };
      await store.insert('local_signup', vb);
    } else {
      await DbHelper.updateSignupStatus(clientId, status, hours, remark, checkin);
    }
  }

  /** 查询本地报名(全部/按人) */
  static async getSignups(stuNo: string = ''): Promise<LocalSignup[]> {
    const store = DbHelper.rdb;
    const out: LocalSignup[] = [];
    if (!store) return out;
    const pred = new relationalStore.RdbPredicates('local_signup');
    if (stuNo !== '') pred.equalTo('stu_no', stuNo);
    pred.orderByDesc('id');
    const rs = await store.query(pred, ['id', 'client_id', 'activity_id', 'activity_title',
      'stu_no', 'name', 'status', 'checkin', 'hours', 'synced', 'remark', 'created_at']);
    while (rs.goToNextRow()) {
      out.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        client_id: DbHelper.safeStr(rs, 'client_id'),
        activity_id: rs.getLong(rs.getColumnIndex('activity_id')),
        activity_title: DbHelper.safeStr(rs, 'activity_title'),
        stu_no: DbHelper.safeStr(rs, 'stu_no'),
        name: DbHelper.safeStr(rs, 'name'),
        status: rs.getLong(rs.getColumnIndex('status')),
        checkin: rs.getLong(rs.getColumnIndex('checkin')),
        hours: rs.getDouble(rs.getColumnIndex('hours')),
        synced: rs.getLong(rs.getColumnIndex('synced')),
        remark: DbHelper.safeStr(rs, 'remark'),
        created_at: DbHelper.safeStr(rs, 'created_at')
      });
    }
    rs.close();
    return out;
  }

  /** 报名同步成功后标记 synced=1 */
  static async markSignupSynced(clientId: string): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const vb: relationalStore.ValuesBucket = { 'synced': 1 };
    const pred = new relationalStore.RdbPredicates('local_signup');
    pred.equalTo('client_id', clientId);
    await store.update(vb, pred);
  }

  /** 查询未同步服务器的报名记录(离线/网络失败时落本地, 待重试补传) */
  static async getUnsyncedSignups(stuNo: string = ''): Promise<LocalSignup[]> {
    const all = await DbHelper.getSignups(stuNo);
    const out: LocalSignup[] = [];
    for (const s of all) {
      if (s.synced === 0) out.push(s);
    }
    return out;
  }

  /** 从服务器同步审核状态(按 client_id 更新 status/checkin/hours/remark) */
  static async updateSignupStatus(clientId: string, status: number, hours: number, remark: string,
    checkin: number): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const vb: relationalStore.ValuesBucket = {
      'status': status,
      'checkin': checkin,
      'hours': hours,
      'remark': remark
    };
    const pred = new relationalStore.RdbPredicates('local_signup');
    pred.equalTo('client_id', clientId);
    await store.update(vb, pred);
  }

  /** 删除某活动某人的本地报名记录(驳回后重新报名前清理旧记录, 保证本地与服务器各一条, 双端一致) */
  static async deleteSignupByActivity(activityId: number, stuNo: string): Promise<void> {
    const store = DbHelper.rdb;
    if (!store) return;
    const pred = new relationalStore.RdbPredicates('local_signup');
    pred.equalTo('activity_id', activityId);
    pred.equalTo('stu_no', stuNo);
    await store.delete(pred);
  }

  /** 本地学时统计(通过记录聚合) */
  static async localHours(stuNo: string): Promise<number> {
    const list = await DbHelper.getSignups(stuNo);
    let total = 0;
    for (const s of list) {
      if (s.status === 1) total += s.hours;
    }
    return total;
  }

  /** 本地全量学时统计(管理员视角: 所有成员的通过记录) */
  static async localAllHours(): Promise<number> {
    const list = await DbHelper.getSignups('');
    let total = 0;
    for (const s of list) {
      if (s.status === 1) total += s.hours;
    }
    return total;
  }

  /** 本地通过报名条数(成员视角: 本人 status=1 的记录数, 与学时统计口径一致) */
  static async localPassedCount(stuNo: string): Promise<number> {
    const list = await DbHelper.getSignups(stuNo);
    let n = 0;
    for (const s of list) {
      if (s.status === 1) n++;
    }
    return n;
  }

  /** 本地通过报名条数(管理员视角: 所有成员) */
  static async localAllPassedCount(): Promise<number> {
    return DbHelper.localPassedCount('');
  }

  /** 本地报名记录总数(管理员视角: 所有成员) */
  static async localAllCount(): Promise<number> {
    return (await DbHelper.getSignups('')).length;
  }

  // ==================== 工具 ====================
  private static safeStr(rs: relationalStore.ResultSet, col: string): string {
    const i = rs.getColumnIndex(col);
    if (i < 0 || rs.isColumnNull(i)) return '';
    return rs.getString(i);
  }
}
