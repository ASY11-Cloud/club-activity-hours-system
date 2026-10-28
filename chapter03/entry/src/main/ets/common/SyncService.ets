/**
 * 双端同步服务
 * 之前"从服务器拉报名状态并写回本地 SQLite"这段逻辑在详情页、我的报名、
 * 学时报表各写了一遍(实现细节还略有差异)。收敛到这里后:
 *  - 页面只负责展示与交互, 不再关心同步细节;
 *  - 以后加字段(例如刷卡时间、驳回理由)只改一处。
 */
import { ApiClient } from './ApiClient';
import { DbHelper } from './DbHelper';
import { AppConfig } from './AppConfig';
import { LocalSignup, SignupInfo, parseSignups, hasMoreOf } from './Models';

/** 同步结果: ok=false 时 msg 为可直接展示的失败原因 */
export class SyncResult {
  ok: boolean;
  count: number;
  msg: string;

  constructor(ok: boolean, count: number, msg: string) {
    this.ok = ok;
    this.count = count;
    this.msg = msg;
  }
}

export class SyncService {
  /**
   * 全量同步本人报名(分页拉取服务器记录 -> 写回本地)
   * 服务器有而本地没有的(另一台设备报名 / RFID 刷卡自动建档)会被补全,
   * 本地有而服务器没有的保留(离线报名尚未补传), 由 synced 字段标记。
   */
  static async syncMySignups(maxPages: number): Promise<SyncResult> {
    if (!AppConfig.isLoggedIn || AppConfig.stuNo === '') {
      return new SyncResult(false, 0, '未登录, 无法同步');
    }
    let page = 1;
    let count = 0;
    const serverIds: string[] = [];      // 服务器上确有的 client_id
    while (page <= maxPages) {
      const resp = await ApiClient.get('/api/signup/list?size=200&page=' + page.toString());
      if (resp['code'] !== 0) {
        // 部分成功也要如实反馈: 已经写回多少条
        return new SyncResult(false, count, '同步失败: ' + (resp['msg'] as string));
      }
      const list: SignupInfo[] = parseSignups(resp);
      for (const s of list) {
        await DbHelper.upsertSignupFromServer(s.client_id, s.activity_id, s.activity_title,
          s.stu_no, s.name, s.status, s.checkin, s.hours, s.remark, s.created_at);
        await DbHelper.markSignupSynced(s.client_id);
        serverIds.push(s.client_id);
        count++;
      }
      const more: boolean = hasMoreOf(resp);
      if (!more || list.length === 0) break;
      page++;
    }
    // 以服务器为准清理陈旧记录: 本地标着"已同步"但服务器上没有的(被撤销/被删除/旧测试残留)要删掉;
    // 未同步的(synced=0)保留 —— 那是离线报名, 还没补传到服务器。
    let pruned = 0;
    const local: LocalSignup[] = await DbHelper.getSignups(AppConfig.stuNo);
    for (const l of local) {
      if (l.synced === 1 && serverIds.indexOf(l.client_id) < 0) {
        await DbHelper.deleteSignupByClientId(l.client_id);
        pruned++;
      }
    }
    const tail: string = pruned > 0 ? ', 清理陈旧 ' + pruned.toString() + ' 条' : '';
    return new SyncResult(true, count, '同步完成: 更新/补全 ' + count.toString() + ' 条' + tail);
  }

  /**
   * 同步某个活动下本人的报名(详情页用): 以服务器为准覆盖本地
   * @returns 服务器上本人该活动的报名记录; 没有则返回 null(可能是离线未同步)
   */
  static async syncByActivity(activityId: number, activityTitle: string): Promise<SignupInfo | null> {
    const resp = await ApiClient.get('/api/signup/list?size=50&activity_id=' + activityId.toString());
    if (resp['code'] !== 0) return null;   // 请求失败: 交给调用方回退到本地(离线可查)
    const list: SignupInfo[] = parseSignups(resp);
    for (const s of list) {
      if (s.stu_no !== AppConfig.stuNo) continue;
      if (s.activity_id !== activityId) continue;   // 双保险: 只认本活动的记录
      // 同一活动本地可能残留不同 client_id 的旧记录, 先清再按服务器记录重建
      await DbHelper.deleteSignupByActivity(activityId, AppConfig.stuNo);
      const title: string = s.activity_title === '' ? activityTitle : s.activity_title;
      await DbHelper.upsertSignupFromServer(s.client_id, s.activity_id, title,
        s.stu_no, s.name, s.status, s.checkin, s.hours, s.remark, s.created_at);
      await DbHelper.markSignupSynced(s.client_id);
      return s;
    }
    // 服务器确认本人没有报名这个活动: 本地"已同步"的旧记录是被撤销/驳回后删掉的残留, 清掉
    const local: LocalSignup[] = await DbHelper.getSignups(AppConfig.stuNo);
    for (const l of local) {
      if (l.activity_id === activityId && l.synced === 1) {
        await DbHelper.deleteSignupByClientId(l.client_id);
      }
    }
    return null;
  }
}
