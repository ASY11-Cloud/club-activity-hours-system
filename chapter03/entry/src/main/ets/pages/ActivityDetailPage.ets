/**
 * 社团活动报名与学时认定系统 —— 活动详情 + 报名(普通成员可报名: 本地落库 + 同步服务器)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { ActivityInfo, SignupInfo, parseActivities, parseSignups, statusText } from '../common/Models';
import { LoginGuardView } from '../common/GuardViews';

@Entry
@Component
struct ActivityDetailPage {
  @State activity: ActivityInfo | null = null;
  @State signed: boolean = false;
  @State signing: boolean = false;
  @State msg: string = '';
  @State myStatus: string = '';
  @State notLoggedIn: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true; // 未登录: 引导登录
        return;
      }
      this.loadActivity();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    // 从登录页返回且已登录: 解除未登录守卫并加载
    if (this.notLoggedIn && AppConfig.isLoggedIn) {
      this.notLoggedIn = false;
      this.loadActivity();
      return;
    }
    // 从其他页面返回: 名额/报名状态可能已变化(审核通过、撤销报名、他人报名), 重新拉取
    if (this.activity !== null) this.loadActivity();
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
      this.msg = '缺少活动参数, 请从活动列表进入';
      return;
    }
    // 管理员带 all=1 拉全量(含已下线), 以便下线后仍能查看/恢复
    const path = AppConfig.isAdmin ? '/api/activity/list?all=1' : '/api/activity/list';
    const resp = await ApiClient.get(path);
    const list = parseActivities(resp);
    for (const a of list) {
      if (a.id === aid) {
        this.activity = a;
        break;
      }
    }
    if (this.activity !== null) {
      await this.checkSigned();
    } else {
      this.msg = '活动不存在或已下线';
    }
  }

  /**
   * 报名状态判定: 以服务器为事实来源(审核结果在服务器) —— 服务器有记录则覆盖本地,
   * 服务器没有但本地有(离线报名未同步)则保留本地并提示未同步。
   */
  async checkSigned(): Promise<void> {
    const a = this.activity;
    if (a === null) return;
    if (AppConfig.stuNo === '' || AppConfig.isAdmin) {
      // 管理员无报名概念; 未登录/未填写学号时不做判定
      this.signed = false;
      return;
    }
    // 1) 先查服务器(权威): 审核通过/驳回后无需手动"同步"即可看到最新状态
    const resp = await ApiClient.get('/api/signup/list?activity_id=' + a.id);
    const srv = parseSignups(resp);
    for (const s of srv) {
      if (s.activity_id === a.id && s.stu_no === AppConfig.stuNo) {
        this.signed = true;
        // 先清掉本地同一活动的旧记录(可能是不同 client_id 的离线/刷卡记录),
        // 再按服务器记录重建, 保证同一活动本地只有一条且状态与服务器一致
        await DbHelper.deleteSignupByActivity(a.id, AppConfig.stuNo);
        await DbHelper.upsertSignupFromServer(s.client_id, s.activity_id, a.title,
          s.stu_no, s.name, s.status, s.checkin, s.hours, s.remark, s.created_at);
        await DbHelper.markSignupSynced(s.client_id);
        const signTag: string = s.checkin === 1 ? ' · 已刷卡签到' : '';
        if (s.status === 1) this.myStatus = '已通过(' + s.hours + ' 学时)' + signTag;
        else if (s.status === 2) this.myStatus = '已驳回: ' + s.remark;
        else this.myStatus = '待审核(已同步)' + signTag;
        return;
      }
    }
    // 2) 服务器没有: 检查本地(离线报名/网络失败暂存), 提示未同步
    const local = await DbHelper.getSignups(AppConfig.stuNo);
    for (const s of local) {
      if (s.activity_id === a.id) {
        this.signed = true;
        this.myStatus = s.synced === 1 ? statusText(s.status) : '待审核(未同步)';
        return;
      }
    }
  }

  async doSignup(): Promise<void> {
    const a = this.activity;
    // 防重复: 已报名(非驳回)或处理中直接返回; 驳回后允许重新报名
    if (a === null || this.signing) return;
    if (this.signed && !this.myStatus.startsWith('已驳回')) return;
    // 名额/时间窗校验(与服务端同口径: 有效报名数不含已驳回)
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
      if (this.myStatus.startsWith('已驳回')) {
        await DbHelper.deleteSignupByActivity(a.id, AppConfig.stuNo);
      }
      // 1) 本地落库(离线可查; 驳回后重新报名生成新 client_id, 服务器将原驳回记录重置为待审核)
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
        // 服务器返回真实状态(可能是审核/刷卡已通过的重复报名)
        const d = resp['data'] as Record<string, Object>;
        const st = d['status'] as number;
        const ck = (d['checkin'] === undefined || d['checkin'] === null) ? 0 : Number(d['checkin']);
        if (st === 1) {
          const h = d['hours'] as number;
          this.msg = '该报名已通过(' + h + ' 学时), 学时已累计';
          await DbHelper.updateSignupStatus(clientId, 1, h, '', ck);
        } else {
          this.msg = '报名成功, 已同步服务器(待管理员审核)';
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

  /** 管理员上下线活动(软删除: 下线后不出现在活动广场, 历史报名与学时保留) */
  confirmOffline(): void {
    const a = this.activity;
    if (a === null) return;
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
        fontColor: offline ? '#E84026' : '#07C160',
        action: () => { this.offlineActivity(offline ? 0 : 1); }
      }
    });
  }

  async offlineActivity(targetStatus: number): Promise<void> {
    const a = this.activity;
    if (a === null) return;
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

  @Builder
  deniedView() {
    LoginGuardView({ tip: '活动详情与报名需要登录, 普通成员可报名' })
  }

  /** 顶部返回栏: 二级页面统一提供可见返回入口(不依赖系统返回手势) */
  @Builder
  navBar(title: string) {
    Row({ space: 6 }) {
      Text('‹ 返回').fontSize(14).fontColor('#1E6FFF')
        .padding({ right: 10, top: 2, bottom: 2 })
        .onClick(() => router.back())
      Text(title).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#333333').layoutWeight(1)
    }
    .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })
    .backgroundColor('#F5F7FA')
  }

  build() {
    Column() {
      this.navBar('活动详情')
      if (this.notLoggedIn) {
        this.deniedView()
      } else if (this.activity === null) {
        this.loadingView()
      } else {
        this.detailView(this.activity as ActivityInfo)
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }

  @Builder
  loadingView() {
    Column({ space: 12 }) {
      LoadingProgress().width(40).height(40).color('#1E6FFF')
      Text(this.msg === '' ? '加载中...' : this.msg).fontSize(14).fontColor('#999999')
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  detailView(a: ActivityInfo) {
    Scroll() {
      Column() {
        // 标题卡
        Column() {
          Text(a.title).fontSize(20).fontWeight(FontWeight.Bold).width('100%')
          Row({ space: 10 }) {
            Text(a.hours + ' 学时').fontSize(12).fontColor('#1E6FFF')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 }).backgroundColor('#EAF1FF').borderRadius(8)
            if (a.capacity > 0) {
              Text('限 ' + a.capacity + ' 人').fontSize(12).fontColor('#B25E00')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 }).backgroundColor('#FFF3E0').borderRadius(8)
            }
            if (a.expired) {
              Text('已结束').fontSize(12).fontColor('#E84026')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 }).backgroundColor('#FDECEA').borderRadius(8)
            }
          }.width('100%').margin({ top: 8 })
        }
        .width('100%').padding(16).backgroundColor(Color.White).borderRadius(14)

        // 信息
        Column({ space: 8 }) {
          this.infoRow('🕐 开始', a.start_time === '' ? '待定' : a.start_time)
          this.infoRow('🕐 结束', a.end_time === '' ? '待定' : a.end_time)
          this.infoRow('📍 地点', a.location === '' ? '待定' : a.location)
          this.infoRow('👤 发布人', a.publisher === '' ? '—' : a.publisher)
          this.infoRow('📊 报名', a.capacity > 0
            ? a.valid_count + ' 人已报名 / 上限 ' + a.capacity + ' 人 · 剩余 ' + a.remaining + ' 名额'
            : a.valid_count + ' 人已报名 · 不限人数')
        }
        .width('100%').padding(16).backgroundColor(Color.White).borderRadius(14).margin({ top: 10 })

        // 描述
        Column() {
          Text('活动内容').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
          Text(a.content === '' ? '暂无描述' : a.content)
            .fontSize(13).fontColor('#555555').width('100%').margin({ top: 8 })
            .lineHeight(22)
        }
        .width('100%').padding(16).backgroundColor(Color.White).borderRadius(14).margin({ top: 10 })

        // 报名区
        Column({ space: 8 }) {
          if (AppConfig.isAdmin) {
            Row({ space: 8 }) {
              Text(a.status === 0 ? '该活动已下线, 成员端不可见' : '管理员账号无需报名, 请到「审核中心」处理成员报名')
                .fontSize(13).fontColor('#B25E00').layoutWeight(1)
            }.width('100%')
            Row({ space: 10 }) {
              Button('编辑活动')
                .layoutWeight(1).height(38).fontSize(14).backgroundColor('#1E6FFF')
                .onClick(() => router.pushUrl({
                  url: 'pages/ActivityEditPage',
                  params: { 'activity_id': a.id }
                }))
              Button(a.status === 0 ? '恢复上线' : '下线该活动')
                .layoutWeight(1).height(38).fontSize(14)
                .backgroundColor(a.status === 0 ? '#07C160' : '#E84026')
                .onClick(() => this.confirmOffline())
            }.width('100%')
          } else if (this.signed && this.myStatus.startsWith('已驳回')) {
            Row({ space: 8 }) {
              Text('已驳回' + (this.myStatus.length > 4 ? ' · ' + this.myStatus : ''))
                .fontSize(13).fontColor('#E84026').layoutWeight(1)
              Button(this.signing ? '处理中...' : '重新报名')
                .height(36).fontSize(14).backgroundColor('#1E6FFF')
                .enabled(!this.signing)
                .onClick(() => this.doSignup())
            }.width('100%')
          } else if (this.signed) {
            Text('你已报名 · ' + this.myStatus).fontSize(14).fontColor('#07C160')
          } else if (a.expired) {
            Text('活动已结束(' + a.end_time + '), 不可报名').fontSize(13).fontColor('#999999')
          } else if (a.remaining === 0) {
            Text('名额已满(' + a.valid_count + '/' + a.capacity + ' 人), 无法报名')
              .fontSize(13).fontColor('#B25E00')
          } else {
            Button(this.signing ? '处理中...' : '立即报名')
              .width('100%').height(44).fontSize(16).backgroundColor('#1E6FFF')
              .enabled(!this.signing)
              .onClick(() => this.doSignup())
          }
          if (this.msg !== '') {
            Text(this.msg).fontSize(12).fontColor('#B25E00').textAlign(TextAlign.Center).width('100%')
          }
        }
        .width('100%').padding(16).backgroundColor(Color.White).borderRadius(14).margin({ top: 10 })
      }
      .padding(14)
    }
    .layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor('#999999').width(70)
      Text(value).fontSize(13).fontColor('#333333').layoutWeight(1)
    }.width('100%')
  }
}
