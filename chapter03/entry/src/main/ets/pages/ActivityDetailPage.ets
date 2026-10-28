/**
 * 社团活动报名与学时认定系统 —— 活动详情 + 报名(v2.5)
 *
 * 本轮改的是"操作可见性":
 *  - 报名按钮从滚动区底部改为**固定底栏**, 首屏不用滑动就能报名;
 *  - 顶部分开三种失败: 网络/服务器错误(可重试)、活动不存在、未登录;
 *  - 报名成功后不再只弹一句提示, 而是给出"已提交 → 待审核"的状态卡;
 *  - 待审核的报名可直接在详情页撤销(释放名额), 驳回的显示理由并允许重报。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { ActivityInfo, SignupInfo, parseActivities, statusText } from '../common/Models';
import { LoginGuardView } from '../common/GuardViews';
import { SyncService } from '../common/SyncService';
import { Theme } from '../common/Theme';
import { TimeFmt } from '../common/TimeFmt';
import { StateView } from '../components/StateView';

/** 空白活动对象: 让 act 常驻 @State, 详情视图直接读 this.act 而不是 builder 传参 */
function blankAct(): ActivityInfo {
  return {
    id: 0, title: '', content: '', location: '', start_time: '', end_time: '',
    hours: 0, capacity: 0, publisher: '', signed_count: 0, passed_count: 0,
    valid_count: 0, remaining: 0, expired: false, status: 1
  };
}

@Entry
@Component
struct ActivityDetailPage {
  // 注意: @Builder 的入参是按值传递, 状态变化不会刷新 builder 内部。
  // 所以详情与底栏都改成直接读 this.act / this.found, 报名后名额才会立刻变。
  @State act: ActivityInfo = blankAct();
  @State found: boolean = false;
  @State signed: boolean = false;
  @State signing: boolean = false;
  @State msg: string = '';
  @State myStatus: string = '';
  @State mySignupStatus: number = -1;   // 服务器上本人的报名状态(-1 无记录)
  @State notLoggedIn: boolean = false;
  @State loadError: string = '';        // 网络/服务端错误(与"活动不存在"区分)
  @State loaded: boolean = false;
  @State justSigned: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true;
        return;
      }
      this.loadActivity();
    }).catch((e: Error) => {
      this.loadError = '本地初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    if (this.notLoggedIn && AppConfig.isLoggedIn) {
      this.notLoggedIn = false;
      this.loadActivity();
      return;
    }
    // 从其他页面返回: 名额/报名状态可能已变化, 重新拉取
    if (this.found) this.loadActivity();
  }

  async loadActivity(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    // 兼容两种跳转写法: params:{activity_id} 与 url 查询串 ?id=(值是字符串)
    let aid = 0;
    if (params && params['activity_id'] !== undefined && params['activity_id'] !== null) {
      aid = Number(params['activity_id']);
    } else if (params && params['id'] !== undefined && params['id'] !== null) {
      aid = Number(params['id']);
    }
    if (isNaN(aid) || aid <= 0) {
      this.loadError = '缺少活动参数, 请从活动列表进入';
      this.loaded = true;
      return;
    }
    // 管理员带 all=1 拉全量(含已下线), 以便下线后仍能查看/恢复
    const path = AppConfig.isAdmin ? '/api/activity/list?all=1' : '/api/activity/list';
    const resp = await ApiClient.get(path);
    if (resp['code'] !== 0) {
      // 关键区别: 这里不是"活动不存在", 而是请求本身失败(服务器/网络)
      this.loadError = (resp['msg'] as string);
      this.found = false;
      this.loaded = true;
      return;
    }
    this.loadError = '';
    const list: ActivityInfo[] = parseActivities(resp);
    let found: ActivityInfo | null = null;
    for (const a of list) {
      if (a.id === aid) {
        found = a;
        break;
      }
    }
    if (found !== null) {
      this.act = found;
      this.found = true;
    } else {
      this.act = blankAct();
      this.found = false;
    }
    this.loaded = true;
    if (this.found) {
      await this.checkSigned();
    }
  }

  /**
   * 报名状态判定: 以服务器为事实来源(审核结果在服务器) —— 服务器有记录则覆盖本地,
   * 服务器没有但本地有(离线报名未同步)则保留本地并提示未同步。
   */
  async checkSigned(): Promise<void> {
    if (!this.found) return;
    const a = this.act;
    if (AppConfig.stuNo === '' || AppConfig.isAdmin) {
      this.signed = false;
      this.mySignupStatus = -1;
      return;
    }
    const s: SignupInfo | null = await SyncService.syncByActivity(a.id, a.title);
    if (s !== null) {
      this.signed = true;
      this.mySignupStatus = s.status;
      const signTag: string = s.checkin === 1 ? ' · 已刷卡签到' : '';
      if (s.status === 1) {
        this.myStatus = '已通过(' + s.hours + ' 学时)' + signTag;
      } else if (s.status === 2) {
        this.myStatus = s.remark === '' ? '未填写理由' : s.remark;
      } else {
        this.myStatus = '待审核' + signTag;
      }
      return;
    }
    // 服务器没有: 检查本地(离线报名/网络失败暂存)
    const local = await DbHelper.getSignups(AppConfig.stuNo);
    for (const l of local) {
      if (l.activity_id === a.id) {
        this.signed = true;
        this.mySignupStatus = l.synced === 1 ? l.status : 0;
        this.myStatus = l.synced === 1 ? statusText(l.status) : '待审核(未同步)';
        return;
      }
    }
    this.signed = false;
    this.mySignupStatus = -1;
    this.myStatus = '';
  }

  async doSignup(): Promise<void> {
    if (!this.found || this.signing) return;
    const a = this.act;
    if (this.signed && this.mySignupStatus !== 2) return;
    if (a.expired) {
      this.msg = '活动已结束, 无法报名';
      return;
    }
    if (a.remaining === 0) {
      this.msg = '名额已满(' + a.valid_count + '/' + a.capacity + ' 人), 无法报名';
      return;
    }
    if (AppConfig.stuNo === '' || AppConfig.stuName === '') {
      this.msg = '请先在「设置」填写学号与姓名';
      return;
    }
    this.signing = true;
    this.msg = '正在报名并写入本地 SQLite...';
    try {
      // 驳回后重新报名: 先删除本地旧驳回记录, 保证本地与服务器各一条(双端一致)
      if (this.mySignupStatus === 2) {
        await DbHelper.deleteSignupByActivity(a.id, AppConfig.stuNo);
      }
      // 1) 本地落库(离线可查)
      const clientId = util.generateRandomUUID();
      await DbHelper.addSignup(clientId, a.id, a.title, AppConfig.stuNo, AppConfig.stuName);
      this.msg = '已写入本地库, 正在同步服务器...';
      // 2) 同步服务器(幂等)
      const body: Record<string, Object> = {
        'client_id': clientId,
        'activity_id': a.id,
        'stu_no': AppConfig.stuNo,
        'name': AppConfig.stuName
      };
      const resp = await ApiClient.post('/api/signup/add', body);
      if (resp['code'] === 0) {
        await DbHelper.markSignupSynced(clientId);
        const d = resp['data'] as Record<string, Object>;
        const st = Number(d['status']);
        const ck = (d['checkin'] === undefined || d['checkin'] === null) ? 0 : Number(d['checkin']);
        if (st === 1) {
          const h = Number(d['hours']);
          this.msg = '该报名已通过(' + h + ' 学时), 学时已累计';
          await DbHelper.updateSignupStatus(clientId, 1, h, '', ck);
        } else {
          this.msg = '报名成功, 已同步服务器, 等待管理员审核';
          this.justSigned = true;
        }
      } else {
        this.msg = '服务器同步失败: ' + (resp['msg'] as string) + ' (记录已保留在本地, 可稍后重试)';
      }
      this.signed = true;
      // 重新拉取活动(名额/剩余数已变化)并同步本人状态
      await this.loadActivity();
    } finally {
      this.signing = false;
    }
  }

  /** 撤销本人待审核报名(释放名额; 已通过/已驳回不可撤销) */
  confirmCancel(): void {
    if (!this.found) return;
    const a = this.act;
    AlertDialog.show({
      title: '撤销报名?',
      message: '撤销后名额立即释放, 若仍要参加需重新报名',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: { value: '再想想', action: () => {} },
      secondaryButton: {
        value: '撤销',
        fontColor: Theme.danger,
        action: () => { this.doCancel(); }
      }
    });
  }

  async doCancel(): Promise<void> {
    if (!this.found) return;
    const a = this.act;
    const body: Record<string, Object> = { 'activity_id': a.id };
    const resp = await ApiClient.post('/api/signup/cancel', body);
    if (resp['code'] === 0) {
      await DbHelper.deleteSignupByActivity(a.id, AppConfig.stuNo);
      this.signed = false;
      this.mySignupStatus = -1;
      this.myStatus = '';
      this.justSigned = false;
      this.msg = '已撤销报名, 名额已释放';
      await this.loadActivity();
    } else {
      this.msg = '撤销失败: ' + (resp['msg'] as string);
    }
  }

  /** 管理员上下线活动(软删除: 下线后不出现在活动广场, 历史报名与学时保留) */
  confirmOffline(): void {
    if (!this.found) return;
    const a = this.act;
    const offline = a.status !== 0;
    AlertDialog.show({
      title: offline ? '下线该活动?' : '恢复上线该活动?',
      message: offline
        ? '「' + a.title + '」下线后不再出现在活动广场, 已产生的报名与学时记录保留'
        : '「' + a.title + '」将重新出现在活动广场, 成员可继续报名',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: offline ? '下线' : '恢复上线',
        fontColor: offline ? Theme.danger : Theme.success,
        action: () => { this.offlineActivity(offline ? 0 : 1); }
      }
    });
  }

  async offlineActivity(targetStatus: number): Promise<void> {
    if (!this.found) return;
    const a = this.act;
    const body: Record<string, Object> = { 'activity_id': a.id, 'status': targetStatus };
    const resp = await ApiClient.post('/api/activity/status', body);
    if (resp['code'] === 0) {
      this.msg = targetStatus === 0 ? '活动已下线' : '活动已恢复上线';
      if (targetStatus === 0) {
        setTimeout(() => { router.back(); }, 600);
      } else {
        await this.loadActivity();
      }
    } else {
      this.msg = (targetStatus === 0 ? '下线失败: ' : '上线失败: ') + (resp['msg'] as string);
    }
  }

  // ==================== 视图 ====================

  @Builder
  deniedView() {
    LoginGuardView({ tip: '活动详情与报名需要登录, 普通成员可报名' })
  }

  @Builder
  navBar() {
    Row({ space: 6 }) {
      Text('‹ 返回').fontSize(Theme.fsBody).fontColor(Theme.primary)
        .padding({ right: 10, top: 2, bottom: 2 })
        .onClick(() => router.back())
      Text('活动详情').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody).layoutWeight(1)
    }
    .width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12, bottom: 8 })
    .backgroundColor(Theme.bgPage)
  }

  @Builder
  tag(text: string, color: string, bg: string) {
    Text(text).fontSize(Theme.fsCaption).fontColor(color)
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .backgroundColor(bg).borderRadius(Theme.radiusSm)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(Theme.fsBody).fontColor(Theme.textTertiary).width(64)
      Text(value).fontSize(Theme.fsBody).fontColor(Theme.textBody).layoutWeight(1)
    }.width('100%').padding({ top: 5, bottom: 5 })
  }

  @Builder
  detailView() {
    Scroll() {
      Column({ space: 10 }) {
        // ---- 标题卡 ----
        Column({ space: 10 }) {
          Text(this.act.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.textBody).width('100%')
          Row({ space: 8 }) {
            this.tag(this.act.hours.toString() + ' 学时', Theme.primary, Theme.primaryBg)
            if (this.act.capacity > 0) {
              this.tag('限 ' + this.act.capacity + ' 人', Theme.warning, Theme.warningBg)
            }
            if (this.act.expired) {
              this.tag('已结束', Theme.danger, Theme.dangerBg)
            } else if (this.signed && this.mySignupStatus === 0) {
              this.tag('待审核', Theme.warning, Theme.warningBg)
            } else if (this.signed && this.mySignupStatus === 1) {
              this.tag('已通过', Theme.success, Theme.successBg)
            } else if (this.signed && this.mySignupStatus === 2) {
              this.tag('已驳回', Theme.danger, Theme.dangerBg)
            }
          }.width('100%')

          // 报名进度
          Row({ space: 8 }) {
            Row() {
              Row().height(5)
                .width(this.act.capacity > 0 ? Math.round(this.act.valid_count * 100 / this.act.capacity).toString() + '%' : '0%')
                .backgroundColor(this.act.remaining === 0 ? Theme.warning : Theme.primary)
                .borderRadius(3)
            }
            .layoutWeight(1).height(5).backgroundColor(Theme.bgNeutral).borderRadius(3)

            Text(this.act.capacity > 0
              ? this.act.valid_count + ' / ' + this.act.capacity + ' 人'
              : this.act.valid_count + ' 人已报名')
              .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
          }.width('100%').margin({ top: 2 })
        }
        .width('100%').padding(16).backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)

        // ---- 报名结果卡(报名成功后出现, 把"下一步该等什么"说清楚) ----
        if (this.justSigned && this.signed) {
          Column({ space: 6 }) {
            Text('已提交, 等待管理员审核').fontSize(Theme.fsTitle)
              .fontWeight(FontWeight.Medium).fontColor(Theme.warning)
            Text('报名已写入本地 SQLite 并同步到服务器; 审核通过后学时自动累计, 可在「我的报名」查看进度')
              .fontSize(Theme.fsCaption).fontColor(Theme.textSecondary).lineHeight(19)
          }
          .width('100%').padding(14).alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.warningBg).borderRadius(Theme.radiusMd)
        }

        // ---- 信息卡 ----
        Column() {
          this.infoRow('开始', this.act.start_time === '' ? '待定' : TimeFmt.short(this.act.start_time))
          this.infoRow('结束', this.act.end_time === '' ? '待定' : TimeFmt.short(this.act.end_time))
          this.infoRow('地点', this.act.location === '' ? '待定' : this.act.location)
          this.infoRow('发布人', this.act.publisher === '' ? '—' : this.act.publisher)
          this.infoRow('当前状态', this.act.expired ? '已结束' : TimeFmt.stage(this.act.start_time, this.act.end_time))
        }
        .width('100%').padding(16).backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)

        // ---- 内容 ----
        Column({ space: 8 }) {
          Text('活动内容').fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium)
            .fontColor(Theme.textBody).width('100%')
          Text(this.act.content === '' ? '暂无描述' : this.act.content)
            .fontSize(Theme.fsBody).fontColor(Theme.textSecondary).width('100%').lineHeight(22)
        }
        .width('100%').padding(16).alignItems(HorizontalAlign.Start)
        .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)

        // ---- 已报名状态(成员) ----
        if (!AppConfig.isAdmin && this.signed) {
          Column({ space: 4 }) {
            Text('我的报名').fontSize(Theme.fsSmall).fontColor(Theme.textTertiary).width('100%')
            Text(this.myStatus === '' ? '—' : this.myStatus)
              .fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium)
              .fontColor(this.mySignupStatus === 1 ? Theme.success
                : (this.mySignupStatus === 2 ? Theme.danger : Theme.warning))
              .width('100%')
            if (this.mySignupStatus === 2) {
              Text('可按管理员给出的理由修改后重新报名').fontSize(Theme.fsCaption)
                .fontColor(Theme.textTertiary).width('100%')
            }
          }
          .width('100%').padding(14).alignItems(HorizontalAlign.Start)
          .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)
        }
      }
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 16 })
    }
    .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
    .align(Alignment.Top)
  }

  /** 固定底栏: 主操作永远在首屏可见 */
  @Builder
  bottomBar() {
    Column({ space: 6 }) {
      if (this.msg !== '') {
        Text(this.msg)
          .fontSize(Theme.fsCaption)
          .fontColor(this.msg.indexOf('失败') >= 0 ? Theme.danger : Theme.textSecondary)
          .width('100%').textAlign(TextAlign.Center).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (AppConfig.isAdmin) {
        Text(this.act.status === 0 ? '该活动已下线, 成员端不可见' : '管理员账号无需报名, 请到「审核中心」处理成员报名')
          .fontSize(Theme.fsCaption).fontColor(Theme.warning)
          .width('100%').textAlign(TextAlign.Center).margin({ bottom: 2 })
        Row({ space: 10 }) {
          Button('编辑活动')
            .layoutWeight(1).height(42).fontSize(Theme.fsBody)
            .backgroundColor(Theme.primary)
            .onClick(() => router.pushUrl({
              url: 'pages/ActivityEditPage',
              params: { 'activity_id': this.act.id }
            }))
          Button(this.act.status === 0 ? '恢复上线' : '下线该活动')
            .layoutWeight(1).height(42).fontSize(Theme.fsBody)
            .backgroundColor(this.act.status === 0 ? Theme.success : Theme.danger)
            .onClick(() => this.confirmOffline())
        }.width('100%')
      } else if (this.signed && this.mySignupStatus === 2) {
        Row({ space: 10 }) {
          Text('已驳回').fontSize(Theme.fsBody).fontColor(Theme.danger)
          Button(this.signing ? '处理中...' : '修改后重新报名')
            .layoutWeight(1).height(44).fontSize(Theme.fsTitle)
            .backgroundColor(Theme.primary).enabled(!this.signing)
            .onClick(() => this.doSignup())
        }.width('100%')
      } else if (this.signed) {
        Row({ space: 10 }) {
          Text(this.mySignupStatus === 1 ? '已通过, 学时已累计' :
            (this.mySignupStatus === 0 ? '待管理员审核' : this.myStatus))
            .fontSize(Theme.fsBody)
            .fontColor(this.mySignupStatus === 1 ? Theme.success : Theme.warning)
            .layoutWeight(1)
          if (this.mySignupStatus === 0) {
            Button('撤销报名')
              .height(40).fontSize(Theme.fsBody).fontColor(Theme.danger)
              .backgroundColor(Theme.dangerBg)
              .onClick(() => this.confirmCancel())
          } else if (this.mySignupStatus === 1) {
            Text('学时报表 ›')
              .fontSize(Theme.fsSmall).fontColor(Theme.primary)
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .onClick(() => router.pushUrl({ url: 'pages/HoursReportPage' }))
          }
        }.width('100%')
      } else if (this.act.expired) {
        Text('活动已结束(' + TimeFmt.day(this.act.end_time) + '), 不可报名')
          .fontSize(Theme.fsBody).fontColor(Theme.textTertiary)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 10, bottom: 10 })
      } else if (this.act.remaining === 0) {
        Text('名额已满(' + this.act.valid_count + '/' + this.act.capacity + ' 人), 无法报名')
          .fontSize(Theme.fsBody).fontColor(Theme.warning)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 10, bottom: 10 })
      } else {
        Button(this.signing ? '正在报名...' : '立即报名')
          .width('100%').height(46).fontSize(16)
          .backgroundColor(Theme.primary)
          .enabled(!this.signing)
          .onClick(() => this.doSignup())
      }
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: 14 })
    .backgroundColor(Theme.bgCard)
    .border({ width: { top: 0.5 }, color: Theme.divider })
  }

  build() {
    Column() {
      this.navBar()
      if (this.notLoggedIn) {
        this.deniedView()
      } else if (this.loadError !== '') {
        StateView({
          kind: 'error',
          title: '活动加载失败',
          desc: this.loadError + '\n请确认服务器在线后重试',
          retryText: '重新加载',
          onRetry: () => this.loadActivity()
        })
      } else if (!this.loaded) {
        StateView({ kind: 'loading', title: '正在加载活动...' })
      } else if (!this.found) {
        StateView({
          kind: 'empty',
          title: '活动不存在或已下线',
          desc: '可能已被管理员下线, 请返回列表刷新后重试'
        })
      } else {
        this.detailView()
        this.bottomBar()
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
