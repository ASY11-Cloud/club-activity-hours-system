/**
 * 社团活动报名与学时认定系统 —— 我的报名(普通成员, 本地 SQLite 可查, 与服务器状态同步)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { LocalSignup, parseSignups, statusText } from '../common/Models';

@Entry
@Component
struct MySignupPage {
  @State signups: LocalSignup[] = [];
  @State msg: string = '';
  @State syncing: boolean = false;
  @State notLoggedIn: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true; // 未登录: 引导登录
        return;
      }
      this.refreshLocal();
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
    if (this.signups.length === 0) {
      this.msg = '暂无本地报名记录';
    }
  }

  /** 从服务器拉取审核状态并更新本地(服务器有而本地无的记录自动补全, 保证双端一致) */
  async syncFromServer(): Promise<void> {
    if (this.syncing) return;
    this.syncing = true;
    this.msg = '正在同步服务器审核状态...';
    try {
      const resp = await ApiClient.get('/api/signup/list?stu_no=' + encodeURIComponent(AppConfig.stuNo));
      if (resp['code'] !== 0) {
        this.msg = '同步失败: ' + (resp['msg'] as string);
        return;
      }
      const serverList = parseSignups(resp);
      let updated = 0;
      for (const s of serverList) {
        // 本地存在 -> 更新状态; 本地不存在(跨设备/RFID自动创建) -> 补全插入
        await DbHelper.upsertSignupFromServer(s.client_id, s.activity_id, s.activity_title,
          s.stu_no, s.name, s.status, s.hours, s.remark);
        await DbHelper.markSignupSynced(s.client_id);
        updated++;
      }
      this.msg = '同步完成: 更新/补全 ' + updated + ' 条记录';
      await this.refreshLocal();
    } finally {
      this.syncing = false;
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
        Text(s.synced === 1 ? '已同步服务器' : '仅本地(未同步)')
          .fontSize(12).fontColor(s.synced === 1 ? '#07C160' : '#E84026')
      }.width('100%').margin({ top: 6 })

      Text('报名时间: ' + s.created_at).fontSize(11).fontColor('#BBBBBB').width('100%').margin({ top: 4 })
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔑').fontSize(40)
      Text('请先登录').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('我的报名仅普通成员可见, 登录后按学号记录本地 SQLite 与服务器状态')
        .fontSize(12).fontColor('#999999').textAlign(TextAlign.Center)
      Button('去登录').fontSize(14).height(38).backgroundColor('#1E6FFF')
        .onClick(() => router.pushUrl({ url: 'pages/LoginPage' }))
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }

  build() {
    Column() {
      if (this.notLoggedIn) {
        this.deniedView()
      } else {
        Row() {
          Text('我的报名').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button(this.syncing ? '同步中...' : '同步服务器状态')
            .fontSize(12).height(30).backgroundColor('#1E6FFF')
            .enabled(!this.syncing)
            .onClick(() => this.syncFromServer())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        if (this.signups.length === 0) {
          Column({ space: 10 }) {
            Text(this.msg === '' ? '加载中...' : this.msg).fontSize(14).fontColor('#999999')
            Text('报名成功后记录会保存在本机 SQLite, 即使离线也能查看')
              .fontSize(12).fontColor('#BBBBBB').textAlign(TextAlign.Center)
          }.width('100%').margin({ top: 60 }).padding({ left: 30, right: 30 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.signups, (s: LocalSignup) => {
                this.item(s)
              }, (s: LocalSignup) => s.client_id)
            }.padding(14)
          }
          .layoutWeight(1).scrollBar(BarState.Off)
        }
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
