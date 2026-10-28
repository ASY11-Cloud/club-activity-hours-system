/**
 * 社团活动报名与学时认定系统 —— 首页导航(按登录角色显示功能入口)
 * 普通成员: 活动广场 / 我的报名 / 我的学时
 * 管理员:   + 发布活动 / 审核中心 / 服务器日志
 * 未登录:   仅活动广场(浏览需登录, 引导登录)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { DbHelper } from '../common/DbHelper';
import { ApiClient } from '../common/ApiClient';

@Entry
@Component
struct Index {
  @State serverBase: string = '';
  @State serverOk: boolean = false;
  @State checking: boolean = false;
  @State localCount: number = 0;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      DbHelper.init(ctx).then(() => {
        this.refresh();
      }).catch((e: Error) => {
        this.serverOk = false;
        console.error('Index DbHelper.init failed: ' + e.message);
      });
    }).catch((e: Error) => {
      console.error('Index AppConfig.init failed: ' + e.message);
    });
  }

  onPageShow(): void {
    this.refresh();
  }

  refresh(): void {
    this.serverBase = AppConfig.serverBase;
    this.pingServer();
    this.loadLocalCount();
  }

  pingServer(): void {
    this.checking = true;
    ApiClient.ping().then((ok: boolean) => {
      this.serverOk = ok;
      this.checking = false;
    });
  }

  async loadLocalCount(): Promise<void> {
    try {
      const list = await DbHelper.getSignups(AppConfig.stuNo);
      this.localCount = list.length;
    } catch (e) {
      this.localCount = 0;
    }
  }

  go(url: string): void {
    router.pushUrl({ url: url });
  }

  goLogin(): void {
    router.pushUrl({ url: 'pages/LoginPage' });
  }

  /** 功能卡片: icon 色块 + 标题 + 描述 */
  @Builder
  funcCard(title: string, desc: string, icon: string, color: string, url: string) {
    Column() {
      Text(icon).fontSize(22)
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).margin({ top: 8 })
      Text(desc).fontSize(10).fontColor('#999999').margin({ top: 2 })
    }
    .width('31%')
    .padding({ top: 16, bottom: 14 })
    .backgroundColor(Color.White)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Center)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.05)', offsetY: 2 })
    .onClick(() => this.go(url))
  }

  @Builder
  sectionTitle(text: string) {
    Row() {
      Text(text).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#555555')
      if (text.includes('管理员')) {
        Text('专属').fontSize(9).fontColor('#FFFFFF').padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor('#F5652F').borderRadius(6).margin({ left: 6 })
      }
    }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 6 })
  }

  build() {
    Scroll() {
      Column() {
        // 头部
        Column({ space: 5 }) {
          Text('社团活动报名与学时认定系统')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(Color.White)
          Row({ space: 4 }) {
            Text(this.checking ? '检测中...' : (this.serverOk ? '● 服务器在线' : '● 服务器未连接'))
              .fontSize(11).fontColor(this.serverOk ? '#D4F5DD' : '#FFD9D2')
          }
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .backgroundColor('rgba(255,255,255,0.18)')
          .borderRadius(12)
        }
        .width('100%').padding({ top: 24, bottom: 24 })
        .backgroundColor('#1E6FFF')
        .borderRadius({ bottomLeft: 20, bottomRight: 20 })

        // 用户卡
        Row() {
          // 头像
          Text(AppConfig.stuName === '' ? '访' : AppConfig.stuName.substring(0, 1))
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(Color.White)
            .width(46).height(46).textAlign(TextAlign.Center)
            .backgroundColor(AppConfig.isAdmin ? '#F5652F' : (AppConfig.isLoggedIn ? '#07C160' : '#AAB2C0'))
            .borderRadius(23)
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(AppConfig.stuName === '' ? '未登录' : AppConfig.stuName)
                .fontSize(16).fontWeight(FontWeight.Bold)
              Text(AppConfig.roleText)
                .fontSize(10).fontColor(Color.White)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .backgroundColor(AppConfig.isAdmin ? '#F5652F' : (AppConfig.isLoggedIn ? '#07C160' : '#AAB2C0'))
                .borderRadius(8)
            }
            Text(AppConfig.isLoggedIn ? (AppConfig.isAdmin ? '账号: ' + AppConfig.stuNo : '学号: ' + AppConfig.stuNo)
              : '登录后按身份进入对应功能')
              .fontSize(11).fontColor('#666666')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 10 })

          Text(AppConfig.isLoggedIn ? '切换 ›' : '登录 ›')
            .fontSize(13).fontColor('#1E6FFF').fontWeight(FontWeight.Medium)
            .onClick(() => this.goLogin())
        }
        .width('100%').padding(14)
        .backgroundColor(Color.White)
        .borderRadius(14)
        .margin({ top: -14, left: 14, right: 14 })
        .shadow({ radius: 10, color: 'rgba(0,0,0,0.08)', offsetY: 3 })
        .onClick(() => AppConfig.isLoggedIn ? this.go('pages/SettingsPage') : this.goLogin())

        // ---- 未登录提示 ----
        if (!AppConfig.isLoggedIn) {
          Column({ space: 8 }) {
            Text('🔒 请先登录以使用完整功能').fontSize(14).fontWeight(FontWeight.Medium)
            Text('普通成员: 报名活动 / 查看我的报名与学时; 管理员: 发布活动 / 审核认定 / 服务器日志')
              .fontSize(11).fontColor('#666666').lineHeight(17)
          }
          .width('100%').padding(14).margin({ left: 14, right: 14, top: 12 })
          .backgroundColor('#FFF7E6').borderRadius(12)
          .alignItems(HorizontalAlign.Start)
          .onClick(() => this.goLogin())
        }

        // ---- 公共: 活动广场 ----
        this.sectionTitle('活动大厅')
        Row({ space: 10 }) {
          this.funcCard('活动广场', '浏览/报名活动', '📋', '#EAF1FF', 'pages/ActivityListPage')
          if (AppConfig.isLoggedIn) {
            this.funcCard('设置', '服务器地址/账号', '⚙️', '#EDEBFF', 'pages/SettingsPage')
          }
        }

        // ---- 成员功能(普通成员) ----
        if (AppConfig.isLoggedIn && !AppConfig.isAdmin) {
          this.sectionTitle('成员功能')
          Row({ space: 10 }) {
            this.funcCard('我的报名', '本地记录' + (this.localCount > 0 ? ' ' + this.localCount + '条' : ''), '📌', '#E8F8EF', 'pages/MySignupPage')
            this.funcCard('学时报表', '排行+个人明细', '⏱', '#EAF7F2', 'pages/HoursReportPage')
          }
        }

        // ---- 管理员功能 ----
        if (AppConfig.isAdmin) {
          this.sectionTitle('管理员功能')
          Row({ space: 10 }) {
            this.funcCard('发布活动', '草稿+同步发布', '📢', '#FFF1E8', 'pages/ActivityPublishPage')
            this.funcCard('审核中心', '服务端审核认定', '✅', '#E8F8EF', 'pages/AuditPage')
            this.funcCard('学时报表', '双端学时统计', '⏱', '#EAF7F2', 'pages/HoursReportPage')
          }
          Row({ space: 10 }) {
            this.funcCard('服务器日志', '实时请求日志', '🖥', '#EDEBFF', 'pages/ServerLogPage')
          }
        }

        // 说明
        Column({ space: 6 }) {
          Text('验收流程: 登录 → 报名 → 同步 → 服务端审核 → 学时累计(双端一致)')
            .fontSize(12).fontColor('#666666')
          Text('本地 SQLite 可离线记录; 服务器请求日志实时可查; MySQL 数据可查; RFID 刷卡签到(扩展项)')
            .fontSize(11).fontColor('#999999').lineHeight(17)
        }
        .width('100%').padding(14).margin({ left: 14, right: 14, top: 14 })
        .backgroundColor('#F2F4F8').borderRadius(12)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%').padding({ bottom: 20 })
    }
    .backgroundColor('#F5F7FA')
    .scrollBar(BarState.Off)
  }
}
