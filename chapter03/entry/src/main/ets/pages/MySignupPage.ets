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
import { LocalSignup, statusText } from '../common/Models';
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
    for (const s of pending) {
      const body: Record<string, Object> = {
        'client_id': s.client_id,
        'activity_id': s.activity_id,
        'stu_no': AppConfig.stuNo,
        'name': AppConfig.stuName
      };
      const resp = await ApiClient.post('/api/signup/add', body);
      if (resp['code'] === 0) {
        await DbHelper.markSignupSynced(s.client_id);
        const d = resp['data'] as Record<string, Object>;
        const st = Number(d['status']);
        const ck = (d['checkin'] === undefined || d['checkin'] === null) ? 0 : Number(d['checkin']);
        if (st === 1) {
          await DbHelper.updateSignupStatus(s.client_id, 1, Number(d['hours']), '', ck);
        }
        ok++;
      } else {
        fail++;
      }
    }
    this.syncing = false;
    await this.refreshLocal();
    if (!silent || fail > 0) {
      this.msg = fail === 0
        ? '补传成功: ' + ok + ' 条记录已同步服务器'
        : '补传完成: 成功 ' + ok + ' 条, 失败 ' + fail + ' 条(请检查服务器连接)';
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

  statusColor(s: number): string {
    if (s === 1) return Theme.success;
    if (s === 2) return Theme.danger;
    return Theme.warning;
  }

  statusBg(s: number): string {
    if (s === 1) return Theme.successBg;
    if (s === 2) return Theme.dangerBg;
    return Theme.warningBg;
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
                '-' + s.hours.toString() + '-' + s.synced.toString() + '-' + s.remark + '-' + s.created_at)
            }.padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 14 })
          }
          .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        }
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
