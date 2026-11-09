/**
 * 社团活动报名与学时认定系统 —— 我的报名(v2.5)
 * 本地 SQLite 可查 + 与服务器审核状态双向同步。
 *
 * 本轮改进:
 *  - 顶部给出本机记录概览(条数 / 待审 / 已通过 / 认定学时), 一眼看懂自己的状态;
 *  - 驳回理由单独用红色块展示 —— 之前只写在"备注"里, 成员不知道要改什么;
 *  - 同步逻辑收敛到 SyncService, 页面不再重复实现;
 *  - 空态/错误态统一, 并提供"去活动广场"的出口。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { LocalSignup, statusText, AppealInfo, parseAppeals, parseSignups, SignupInfo } from '../common/Models';
import { LoginGuardView } from '../common/GuardViews';
import { SyncService, SyncResult } from '../common/SyncService';
import { Theme } from '../common/Theme';
import { TimeFmt } from '../common/TimeFmt';
import { StateView } from '../components/StateView';

@Entry
@Component
struct MySignupPage {
  @State signups: LocalSignup[] = [];
  @State msg: string = '';
  @State syncing: boolean = false;
  @State notLoggedIn: boolean = false;
  @State unsynced: number = 0;
  @State loaded: boolean = false;
  // ---- v4.0 学时申诉 ----
  @State appeals: AppealInfo[] = [];
  @State appealFor: number = 0;        // 正在填理由的活动 id(0 = 未展开)
  @State appealReason: string = '';
  @State appealBusy: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true;
        return;
      }
      // 进页面先补传未同步记录, 再静默拉一次审核状态:
      // 成员不必手点"同步"才能看到审核结果。
      this.retryUnsynced(true).then(() => this.syncFromServer(true));
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
      this.loaded = true;
    });
  }

  onPageShow(): void {
    if (this.notLoggedIn && AppConfig.isLoggedIn) this.notLoggedIn = false;
    this.refreshLocal();
  }

  async refreshLocal(): Promise<void> {
    if (AppConfig.stuNo === '') {
      this.msg = '请先在「设置」填写学号与姓名';
      this.loaded = true;
      return;
    }
    this.signups = await DbHelper.getSignups(AppConfig.stuNo);
    this.unsynced = (await DbHelper.getUnsyncedSignups(AppConfig.stuNo)).length;
    await this.loadAppeals();
    this.loaded = true;
    if (this.signups.length === 0) {
      this.msg = '暂无本地报名记录';
    } else if (this.msg === '暂无本地报名记录') {
      // 静默同步把记录补进来后, 清掉进页面时那句空态提示
      this.msg = '';
    }
  }

  // ---- 概览数字 ----
  countBy(status: number): number {
    let n = 0;
    for (const s of this.signups) {
      if (s.status === status) n++;
    }
    return n;
  }

  totalHours(): number {
    let h = 0;
    for (const s of this.signups) {
      if (s.status === 1) h += s.hours;
    }
    // 一位小数, 避免 5.499999 这类浮点噪声
    return Math.round(h * 10) / 10;
  }

  /**
   * 补传未同步的本地报名(离线报名/服务器暂时不可达时的重试通道)。
   * 服务端按 client_id 幂等, 重复重试不会产生重复报名。
   */
  async retryUnsynced(silent: boolean): Promise<void> {
    if (this.syncing) return;
    const pending = await DbHelper.getUnsyncedSignups(AppConfig.stuNo);
    if (pending.length === 0) {
      await this.refreshLocal();
      return;
    }
    this.syncing = true;
    let ok = 0;
    let fail = 0;
    let rejected = 0;
    for (const s of pending) {
      const body: Record<string, Object> = {
        'client_id': s.client_id,
        'activity_id': s.activity_id,
        'stu_no': AppConfig.stuNo,
        'name': AppConfig.stuName
      };
      // 批量补传用 silent: 逐条弹 toast 会刷屏, 结果统一在末尾汇总
      const resp = await ApiClient.post('/api/signup/add', body, true);
      if (resp['code'] === 0) {
        const d = resp['data'] as Record<string, Object>;
        // 服务器可能命中已有报名并保留原 client_id, 以服务端为准校正本地, 避免双端不一致
        let cid = s.client_id;
        const scid = (d['client_id'] === undefined || d['client_id'] === null) ? '' : String(d['client_id']);
        if (scid !== '' && scid !== cid) {
          await DbHelper.replaceSignupClientId(cid, scid);
          cid = scid;
        }
        await DbHelper.markSignupSynced(cid);
        const st = Number(d['status']);
        const ck = (d['checkin'] === undefined || d['checkin'] === null) ? 0 : Number(d['checkin']);
        if (st === 1) {
          await DbHelper.updateSignupStatus(cid, 1, Number(d['hours']), '', ck);
        }
        ok++;
      } else if (ApiClient.isRejected(resp)) {
        // 服务端明确拒绝(名额已满/活动已结束/已下线): 永远传不上去, 直接清理避免无限重试
        await DbHelper.deleteSignupByClientId(s.client_id);
        rejected++;
      } else {
        fail++;
      }
    }
    this.syncing = false;
    await this.refreshLocal();
    if (!silent || fail > 0 || rejected > 0) {
      const parts: string[] = [];
      if (ok > 0) parts.push('成功 ' + ok.toString() + ' 条');
      if (rejected > 0) parts.push('已失效 ' + rejected.toString() + ' 条(服务器拒绝, 已清理)');
      if (fail > 0) parts.push('失败 ' + fail.toString() + ' 条(请检查服务器连接)');
      this.msg = '补传完成: ' + parts.join(', ');
    }
  }

  /** 从服务器拉取审核状态并写回本地(服务器有而本地无的记录自动补全) */
  async syncFromServer(silent: boolean): Promise<void> {
    if (this.syncing) return;
    this.syncing = true;
    if (!silent) this.msg = '正在同步服务器审核状态...';
    try {
      const r: SyncResult = await SyncService.syncMySignups(5);
      if (!silent) this.msg = r.msg;
      await this.refreshLocal();
    } finally {
      this.syncing = false;
    }
  }

  /** 撤销待审核报名(本地 + 服务器): 释放名额, 已通过/已驳回不可撤销 */
  confirmCancel(s: LocalSignup): void {
    AlertDialog.show({
      title: '撤销报名?',
      message: '将删除「' + s.activity_title + '」的待审核报名并释放名额',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '撤销报名',
        fontColor: Theme.danger,
        action: () => { this.cancelSignup(s); }
      }
    });
  }

  async cancelSignup(s: LocalSignup): Promise<void> {
    const body: Record<string, Object> = { 'activity_id': s.activity_id };
    const resp = await ApiClient.post('/api/signup/cancel', body);
    if (resp['code'] === 0) {
      await DbHelper.deleteSignupByActivity(s.activity_id, AppConfig.stuNo);
      this.msg = '已撤销「' + s.activity_title + '」的报名';
      await this.refreshLocal();
    } else {
      this.msg = '撤销失败: ' + (resp['msg'] as string);
    }
  }

  statusColor(s: number): ResourceColor {
    if (s === 1) return Theme.success;
    if (s === 2) return Theme.danger;
    return Theme.warning;
  }

  statusBg(s: number): ResourceColor {
    if (s === 1) return Theme.successBg;
    if (s === 2) return Theme.dangerBg;
    return Theme.warningBg;
  }

  // ==================== v4.0 学时申诉 ====================

  async loadAppeals(): Promise<void> {
    const resp = await ApiClient.get('/api/appeal/list?size=200');
    if (resp['code'] === 0) this.appeals = parseAppeals(resp);
  }

  /** 按活动找本人的申诉记录(本地只缓存 activity_id, 不存服务端 signup id) */
  appealOf(activityId: number): AppealInfo | null {
    for (const a of this.appeals) {
      if (a.activity_id === activityId) return a;
    }
    return null;
  }

  appealStatus(activityId: number): number {
    const a = this.appealOf(activityId);
    return a === null ? -1 : a.status;
  }

  appealKey(activityId: number): string {
    const a = this.appealOf(activityId);
    return a === null ? 'none' : a.status.toString() + '-' + a.hours_after.toString();
  }

  appealText(activityId: number): string {
    const a = this.appealOf(activityId);
    if (a === null) return '';
    if (a.status === 0) return '申诉处理中, 请等待管理员复核';
    if (a.status === 1) {
      const h = a.hours_after >= 0 ? a.hours_after : a.signup_hours;
      return '申诉已通过: 认定学时调整为 ' + h + ' 学时';
    }
    return '申诉已驳回' + (a.reply === '' ? '' : ': ' + a.reply);
  }

  openAppeal(s: LocalSignup): void {
    this.appealFor = s.activity_id;
    this.appealReason = '';
    this.msg = '';
  }

  async submitAppeal(s: LocalSignup): Promise<void> {
    const reason = this.appealReason.trim();
    if (reason.length < 5) {
      this.msg = '请填写申诉理由(至少 5 个字), 管理员会看到';
      return;
    }
    if (this.appealBusy) return;
    this.appealBusy = true;
    try {
      // 本地表只有活动 id, 申诉要服务端 signup.id: 先按活动查本人已通过记录
      const lr = await ApiClient.get('/api/signup/list?activity_id=' + s.activity_id.toString() + '&size=10');
      let sid = 0;
      if (lr['code'] === 0) {
        const rows: SignupInfo[] = parseSignups(lr);
        for (const r of rows) {
          if (r.stu_no === AppConfig.stuNo && r.status === 1) sid = r.id;
        }
      }
      if (sid <= 0) {
        this.msg = '未找到服务器上的已通过记录, 请先同步';
        return;
      }
      const resp = await ApiClient.post('/api/appeal/add', {
        'signup_id': sid,
        'reason': reason
      });
      if (resp['code'] === 0) {
        this.msg = '申诉已提交, 管理员复核后会通知结果';
        this.appealFor = 0;
        this.appealReason = '';
        await this.loadAppeals();
      } else {
        this.msg = '申诉失败: ' + (resp['msg'] as string);
      }
    } finally {
      this.appealBusy = false;
    }
  }

  // ==================== 视图 ====================

  @Builder
  item(s: LocalSignup) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(s.activity_title).fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium)
          .fontColor(Theme.textBody).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(statusText(s.status))
          .fontSize(Theme.fsCaption).fontColor(this.statusColor(s.status))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(this.statusBg(s.status)).borderRadius(Theme.radiusSm)
      }.width('100%')

      Row({ space: 10 }) {
        Text(s.status === 1 ? '认定 ' + s.hours + ' 学时' : '学时 ' + s.hours)
          .fontSize(Theme.fsSmall)
          .fontColor(s.status === 1 ? Theme.success : Theme.textTertiary)
        if (s.checkin === 1) {
          Text('已刷卡签到').fontSize(Theme.fsCaption).fontColor(Theme.signin)
        }
        Text(s.synced === 1 ? '已同步' : '仅本地')
          .fontSize(Theme.fsCaption)
          .fontColor(s.synced === 1 ? Theme.textTertiary : Theme.danger)
      }.width('100%')

      // 驳回理由: 这是成员最需要看到的信息, 单独成块而不是塞在"备注"里
      if (s.status === 2) {
        Text(s.remark === '' ? '管理员未填写驳回理由' : '驳回理由: ' + s.remark)
          .fontSize(Theme.fsSmall).fontColor(Theme.danger)
          .width('100%').padding(8)
          .backgroundColor(Theme.dangerBg).borderRadius(Theme.radiusSm)
      }

      // 学时申诉(v4.0): 仅已通过记录可申诉; 已提交则回显状态, 不再重复入口
      if (s.status === 1) {
        if (this.appealOf(s.activity_id) !== null) {
          Text(this.appealText(s.activity_id))
            .fontSize(Theme.fsCaption)
            .fontColor(this.appealStatus(s.activity_id) === 1 ? Theme.success : Theme.textTertiary)
            .width('100%')
        } else if (this.appealFor === s.activity_id) {
          Column({ space: 8 }) {
            TextInput({ text: this.appealReason, placeholder: '申诉理由(至少 5 个字), 如签到时长被少算' })
              .height(38).fontSize(Theme.fsSmall).width('100%')
              .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusSm)
              .onChange((v: string) => this.appealReason = v)
            Row({ space: 10 }) {
              Button('取消').layoutWeight(1).height(32).fontSize(Theme.fsCaption)
                .backgroundColor(Theme.bgNeutral).fontColor(Theme.textSecondary)
                .onClick(() => { this.appealFor = 0; this.appealReason = ''; })
              Button(this.appealBusy ? '提交中...' : '提交申诉')
                .layoutWeight(1).height(32).fontSize(Theme.fsCaption)
                .backgroundColor(Theme.primary).enabled(!this.appealBusy)
                .onClick(() => this.submitAppeal(s))
            }.width('100%')
          }
          .width('100%').padding(8).margin({ top: 4 })
          .backgroundColor(Theme.primaryBg).borderRadius(Theme.radiusSm)
        } else {
          Button('学时申诉')
            .fontSize(Theme.fsCaption).height(26)
            .fontColor(Theme.primary).backgroundColor(Theme.primaryBg)
            .borderRadius(13).margin({ top: 2 })
            .onClick(() => this.openAppeal(s))
        }
      }

      Row() {
        Text('报名时间: ' + TimeFmt.short(s.created_at))
          .fontSize(Theme.fsCaption).fontColor(Theme.textDisabled).layoutWeight(1)
        if (s.status === 0) {
          Button('撤销报名')
            .fontSize(Theme.fsCaption).height(26).fontColor(Theme.danger)
            .backgroundColor(Theme.dangerBg).borderRadius(13)
            .onClick(() => this.confirmCancel(s))
        }
      }.width('100%')
    }
    .width('100%').padding(12)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)
    .border({ width: { left: 3 }, color: this.statusColor(s.status) })
    .margin({ bottom: Theme.gapSm })
  }

  @Builder
  deniedView() {
    LoginGuardView({ tip: '我的报名仅普通成员可见, 登录后按学号记录本地 SQLite 与服务器状态' })
  }

  @Builder
  overview() {
    Row() {
      Column({ space: 2 }) {
        Text(this.signups.length.toString()).fontSize(Theme.fsDisplay).fontWeight(FontWeight.Bold)
          .fontColor(Theme.textBody)
        Text('本地记录').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }.layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.countBy(0).toString()).fontSize(Theme.fsDisplay).fontWeight(FontWeight.Bold)
          .fontColor(Theme.warning)
        Text('待审核').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }.layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.countBy(1).toString()).fontSize(Theme.fsDisplay).fontWeight(FontWeight.Bold)
          .fontColor(Theme.success)
        Text('已通过').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }.layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.totalHours().toString()).fontSize(Theme.fsDisplay).fontWeight(FontWeight.Bold)
          .fontColor(Theme.primary)
        Text('认定学时').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }.layoutWeight(1)
    }
    .width('100%').padding({ top: 14, bottom: 14 })
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)
  }

  build() {
    Column() {
      if (this.notLoggedIn) {
        this.deniedView()
      } else {
        Row({ space: 6 }) {
          Text('‹ 返回').fontSize(Theme.fsBody).fontColor(Theme.primary)
            .padding({ right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('我的报名').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
            .fontColor(Theme.textBody).layoutWeight(1)
          Text(this.syncing ? '同步中...' : '同步')
            .fontSize(Theme.fsBody).fontColor(this.syncing ? Theme.textDisabled : Theme.primary)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              if (!this.syncing) this.syncFromServer(false);
            })
        }.width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12, bottom: 8 })

        Column({ space: 8 }) {
          this.overview()

          // 未同步提醒 + 手动补传(离线报名/上次网络失败的恢复入口)
          if (this.unsynced > 0) {
            Row({ space: 8 }) {
              Text('有 ' + this.unsynced + ' 条报名仅存本地, 未同步服务器')
                .fontSize(Theme.fsCaption).fontColor(Theme.danger).layoutWeight(1)
              Button(this.syncing ? '处理中...' : '立即补传')
                .fontSize(Theme.fsCaption).height(28).backgroundColor(Theme.danger)
                .enabled(!this.syncing)
                .onClick(() => this.retryUnsynced(false))
            }
            .width('100%').padding(10)
            .backgroundColor(Theme.dangerBg).borderRadius(Theme.radiusSm)
          }

          if (this.msg !== '' && this.signups.length > 0) {
            Text(this.msg).fontSize(Theme.fsCaption).fontColor(Theme.textTertiary).width('100%')
          }
        }
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })

        if (!this.loaded) {
          StateView({ kind: 'loading', title: '正在读取本地报名...' })
        } else if (this.signups.length === 0) {
          Column() {
            StateView({
              kind: 'empty',
              title: AppConfig.isAdmin ? '管理员账号无报名记录' : '还没有报名记录',
              desc: AppConfig.isAdmin
                ? '成员报名与审核请前往「审核中心」'
                : '报名成功后记录会保存在本机 SQLite, 即使离线也能查看'
            })
            if (!AppConfig.isAdmin) {
              Button('去活动广场看看')
                .height(40).fontSize(Theme.fsBody)
                .backgroundColor(Theme.primary)
                .padding({ left: 24, right: 24 })
                .onClick(() => router.back())
            }
          }.width('100%')
        } else {
          Scroll() {
            Column() {
              ForEach(this.signups, (s: LocalSignup) => {
                this.item(s)
              }, (s: LocalSignup) => s.client_id + '-' + s.status.toString() + '-' + s.checkin.toString() +
                '-' + s.hours.toString() + '-' + s.synced.toString() + '-' + s.remark + '-' + s.created_at +
                '-' + this.appealKey(s.activity_id))
            }.padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 14 })
          }
          .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        }
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
