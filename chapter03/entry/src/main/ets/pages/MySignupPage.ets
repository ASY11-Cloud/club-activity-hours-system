/**
 * 社团活动报名与学时认定系统 —— 我的报名(普通成员, 本地 SQLite 可查, 与服务器状态同步)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { LocalSignup, parseSignups, statusText } from '../common/Models';
import { LoginGuardView } from '../common/GuardViews';

@Entry
@Component
struct MySignupPage {
  @State signups: LocalSignup[] = [];
  @State msg: string = '';
  @State syncing: boolean = false;
  @State notLoggedIn: boolean = false;
  @State unsynced: number = 0;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true; // 未登录: 引导登录
        return;
      }
      // 进页面先补传未同步记录(离线报名/上次网络失败), 再静默拉取服务器审核状态,
      // 保证"服务端审核 → 本机就能看到学时/签到"不需要用户手动点同步。
      this.retryUnsynced(true).then(() => this.syncFromServer(true));
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    // 从登录页返回且已登录: 解除未登录守卫
    if (this.notLoggedIn && AppConfig.isLoggedIn) this.notLoggedIn = false;
    this.refreshLocal();
  }

  async refreshLocal(): Promise<void> {
    if (AppConfig.stuNo === '') {
      this.msg = '请先在「设置」填写学号与姓名';
      return;
    }
    this.signups = await DbHelper.getSignups(AppConfig.stuNo);
    this.unsynced = (await DbHelper.getUnsyncedSignups(AppConfig.stuNo)).length;
    if (this.signups.length === 0) {
      this.msg = '暂无本地报名记录';
    } else if (this.msg === '暂无本地报名记录') {
      // 静默同步把记录补进来后, 清掉进页面时那句"暂无本地报名记录", 否则列表有数据却顶着空态提示
      this.msg = '';
    }
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
        const st = d['status'] as number;
        const ck = (d['checkin'] === undefined || d['checkin'] === null) ? 0 : Number(d['checkin']);
        if (st === 1) {
          await DbHelper.updateSignupStatus(s.client_id, 1, d['hours'] as number, '', ck);
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

  /** 从服务器拉取审核状态并更新本地(服务器有而本地无的记录自动补全, 保证双端一致) */
  async syncFromServer(silent: boolean = false): Promise<void> {
    if (this.syncing) return;
    this.syncing = true;
    if (!silent) this.msg = '正在同步服务器审核状态...';
    try {
      const resp = await ApiClient.get('/api/signup/list?size=200&stu_no=' + encodeURIComponent(AppConfig.stuNo));
      if (resp['code'] !== 0) {
        if (!silent) this.msg = '同步失败: ' + (resp['msg'] as string);
        return;
      }
      const serverList = parseSignups(resp);
      let updated = 0;
      for (const s of serverList) {
        // 本地存在 -> 更新状态; 本地不存在(跨设备/RFID自动创建) -> 补全插入
        await DbHelper.upsertSignupFromServer(s.client_id, s.activity_id, s.activity_title,
          s.stu_no, s.name, s.status, s.checkin, s.hours, s.remark, s.created_at);
        await DbHelper.markSignupSynced(s.client_id);
        updated++;
      }
      if (!silent) this.msg = '同步完成: 更新/补全 ' + updated + ' 条记录';
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
        fontColor: '#E84026',
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

  @Builder
  item(s: LocalSignup) {
    Column() {
      Row() {
        Text(s.activity_title).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(statusText(s.status))
          .fontSize(12)
          .fontColor(s.status === 1 ? '#07C160' : (s.status === 2 ? '#E84026' : '#B25E00'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(s.status === 1 ? '#E8F8EF' : (s.status === 2 ? '#FDECEA' : '#FFF3E0'))
          .borderRadius(8)
      }.width('100%')

      Row({ space: 14 }) {
        Text('学时: ' + s.hours).fontSize(12).fontColor('#888888')
        if (s.checkin === 1) {
          Text('已刷卡签到').fontSize(11).fontColor('#1E6FFF')
        }
        Text(s.synced === 1 ? '已同步服务器' : '仅本地(未同步)')
          .fontSize(12).fontColor(s.synced === 1 ? '#07C160' : '#E84026')
      }.width('100%').margin({ top: 6 })

      Text('报名时间: ' + s.created_at).fontSize(11).fontColor('#BBBBBB').width('100%').margin({ top: 4 })

      // 待审核报名可撤销(释放名额); 已通过/已驳回不提供撤销
      if (s.status === 0) {
        Row() {
          Button('撤销报名')
            .fontSize(12).height(28).fontColor('#E84026').backgroundColor('#FDECEA')
            .onClick(() => this.confirmCancel(s))
        }.width('100%').justifyContent(FlexAlign.End).margin({ top: 6 })
      }
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    LoginGuardView({ tip: '我的报名仅普通成员可见, 登录后按学号记录本地 SQLite 与服务器状态' })
  }

  build() {
    Column() {
      if (this.notLoggedIn) {
        this.deniedView()
      } else {
        Row() {
          Text('‹ 返回').fontSize(14).fontColor('#1E6FFF')
            .padding({ right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('我的报名').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button(this.syncing ? '同步中...' : '同步服务器状态')
            .fontSize(12).height(30).backgroundColor('#1E6FFF')
            .enabled(!this.syncing)
            .onClick(() => this.syncFromServer())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        // 未同步提醒 + 手动补传(离线报名/上次网络失败的恢复入口)
        if (this.unsynced > 0) {
          Row({ space: 8 }) {
            Text('有 ' + this.unsynced + ' 条报名仅存本地, 未同步服务器')
              .fontSize(11).fontColor('#E84026').layoutWeight(1)
            Button(this.syncing ? '处理中...' : '立即补传')
              .fontSize(11).height(26).backgroundColor('#E84026')
              .enabled(!this.syncing)
              .onClick(() => this.retryUnsynced(false))
          }.width('100%').padding({ left: 14, right: 14, bottom: 8 })
        }

        if (this.msg !== '' && this.signups.length > 0) {
          Text(this.msg).fontSize(11).fontColor('#999999').width('100%')
            .padding({ left: 14, right: 14, bottom: 6 })
        }

        if (this.signups.length === 0) {
          Column({ space: 10 }) {
            Text(AppConfig.isAdmin ? '管理员账号无报名记录'
              : (this.msg === '' ? '加载中...' : this.msg)).fontSize(14).fontColor('#999999')
            Text(AppConfig.isAdmin ? '成员报名与审核请前往「审核中心」'
              : '报名成功后记录会保存在本机 SQLite, 即使离线也能查看')
              .fontSize(12).fontColor('#BBBBBB').textAlign(TextAlign.Center)
          }.width('100%').margin({ top: 60 }).padding({ left: 30, right: 30 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.signups, (s: LocalSignup) => {
                this.item(s)
              }, (s: LocalSignup) => s.client_id + '-' + s.status.toString() + '-' + s.checkin.toString() +
                '-' + s.hours.toString() + '-' + s.created_at)
            }.padding(14)
          }
          .layoutWeight(1).scrollBar(BarState.Off)
        }
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
