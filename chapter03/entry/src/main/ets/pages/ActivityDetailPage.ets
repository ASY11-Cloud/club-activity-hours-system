/**
 * 社团活动报名与学时认定系统 —— 活动详情 + 报名(普通成员可报名: 本地落库 + 同步服务器)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { ActivityInfo, SignupInfo, parseActivities, parseSignups } from '../common/Models';

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

  async loadActivity(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    const aid = params['activity_id'] as number;
    const resp = await ApiClient.get('/api/activity/list');
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

  async checkSigned(): Promise<void> {
    if (AppConfig.stuNo === '') {
      this.msg = '请先在「设置」填写学号与姓名';
      return;
    }
    const a = this.activity;
    if (a === null) return;
    // 1) 本地已报名
    const list = await DbHelper.getSignups(AppConfig.stuNo);
    for (const s of list) {
      if (s.activity_id === a.id) {
        this.signed = true;
        if (s.status === 1) this.myStatus = '已通过(' + s.hours + ' 学时)';
        else if (s.status === 2) this.myStatus = '已驳回: ' + s.remark;
        else this.myStatus = s.synced === 1 ? '待审核(已同步)' : '待审核(未同步)';
        return;
      }
    }
    // 2) 本地无记录: 查服务器(跨设备/重装场景), 存在则补全本地保证双端一致
    const resp = await ApiClient.get('/api/signup/list?activity_id=' + a.id);
    const srv = parseSignups(resp);
    for (const s of srv) {
      if (s.activity_id === a.id && s.stu_no === AppConfig.stuNo) {
        this.signed = true;
        await DbHelper.addSignup(s.client_id, s.activity_id, a.title, s.stu_no, s.name);
        await DbHelper.updateSignupStatus(s.client_id, s.status, s.hours, s.remark);
        await DbHelper.markSignupSynced(s.client_id);
        if (s.status === 1) this.myStatus = '已通过(' + s.hours + ' 学时)';
        else if (s.status === 2) this.myStatus = '已驳回: ' + s.remark;
        else this.myStatus = '待审核(已同步)';
        return;
      }
    }
  }

  async doSignup(): Promise<void> {
    const a = this.activity;
    // 防重复: 已报名(非驳回)或处理中直接返回; 驳回后允许重新报名
    if (a === null || this.signing) return;
    if (this.signed && !this.myStatus.startsWith('已驳回')) return;
    // 满员校验
    if (a.capacity > 0 && a.signed_count >= a.capacity) {
      this.msg = '名额已满, 无法报名';
      return;
    }
    if (AppConfig.stuNo === '' || AppConfig.stuName === '') {
      this.msg = '请先在「设置」填写学号与姓名';
      return;
    }
    this.signing = true;
    this.msg = '正在报名并写入本地 SQLite...';
    try {
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
        if (st === 1) {
          const h = d['hours'] as number;
          this.msg = '该报名已通过(' + h + ' 学时), 学时已累计';
          await DbHelper.updateSignupStatus(clientId, 1, h, '');
        } else {
          this.msg = '报名成功, 已同步服务器(待管理员审核)';
        }
      } else {
        this.msg = '服务器同步失败: ' + (resp['msg'] as string) + ' (记录已保留在本地, 可稍后重试)';
      }
      this.signed = true;
      await this.checkSigned();
    } finally {
      this.signing = false;
    }
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔑').fontSize(40)
      Text('请先登录').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('活动详情与报名需要登录, 普通成员可报名')
        .fontSize(12).fontColor('#999999').textAlign(TextAlign.Center)
      Button('去登录').fontSize(14).height(38).backgroundColor('#1E6FFF')
        .onClick(() => router.pushUrl({ url: 'pages/LoginPage' }))
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }

  build() {
    Column() {
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
          }.width('100%').margin({ top: 8 })
        }
        .width('100%').padding(16).backgroundColor(Color.White).borderRadius(14)

        // 信息
        Column({ space: 8 }) {
          this.infoRow('🕐 开始', a.start_time === '' ? '待定' : a.start_time)
          this.infoRow('🕐 结束', a.end_time === '' ? '待定' : a.end_time)
          this.infoRow('📍 地点', a.location === '' ? '待定' : a.location)
          this.infoRow('👤 发布人', a.publisher === '' ? '—' : a.publisher)
          this.infoRow('📊 报名', a.signed_count + ' 人已报名' + (a.capacity > 0 ? ' / 共 ' + a.capacity + ' 人' : ''))
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
            Text('管理员账号无需报名, 请到「审核中心」处理成员报名')
              .fontSize(13).fontColor('#B25E00')
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
          } else if (a.capacity > 0 && a.signed_count >= a.capacity) {
            Text('名额已满(' + a.signed_count + '/' + a.capacity + ' 人), 无法报名')
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
