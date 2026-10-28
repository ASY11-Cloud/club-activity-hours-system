/**
 * 社团活动报名与学时认定系统 —— 启动引导页(v2.2 新架构)
 * 冷启动第一屏: 登录 / 注册 / 设置 三个入口。
 * 已登录用户返回本页时显示「进入主界面」, 一键直达 TabBar 主页。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';
import { Nav } from '../common/Nav';
import { Theme } from '../common/Theme';

@Entry
@Component
struct LandingPage {
  @State loggedIn: boolean = false;
  @State isAdmin: boolean = false;
  @State name: string = '';
  @State serverOk: boolean = false;
  @State checking: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.syncLogin();
      this.ping();
    }).catch((e: Error) => {
      console.error('LandingPage init failed: ' + e.message);
    });
  }

  onPageShow(): void {
    // 登录/注册/设置返回时同步登录态
    this.syncLogin();
    if (!this.checking) this.ping();
  }

  syncLogin(): void {
    this.loggedIn = AppConfig.isLoggedIn;
    this.isAdmin = AppConfig.isAdmin;
    this.name = AppConfig.stuName;
  }

  ping(): void {
    this.checking = true;
    ApiClient.ping().then((ok: boolean) => {
      this.serverOk = ok;
      this.checking = false;
    });
  }

  go(url: string): void {
    router.pushUrl({ url: url });
  }

  enter(): void {
    // 已登录 -> 主页(TabBar); 未登录 -> 登录页
    if (this.loggedIn) {
      // 本页可能是冷启动根页, 也可能是「我的 → 系统介绍」push 进来的二级页;
      // 根级切换统一清栈, 避免栈里出现两个 MainPage
      Nav.resetTo('pages/MainPage');
    } else {
      router.pushUrl({ url: 'pages/LoginPage' });
    }
  }

  /**
   * 入口卡: 图标改用"字符方块"而不是 emoji。
   * 原因: emoji 在不同设备/字体下会被渲染成彩色位图或方块(📍 就渲染成了红点),
   * 这里统一成圆角方块 + 单字, 任何字体下都稳定, 也与主界面的管理卡一致。
   */
  @Builder
  entryCard(icon: string, title: string, desc: string, color: string, bg: string, url: string) {
    Column() {
      Text(icon)
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(color)
        .textAlign(TextAlign.Center)
        .width(44).height(44).backgroundColor(bg).borderRadius(14)
      Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.textBody).margin({ top: 10 })
      Text(desc).fontSize(11).fontColor(Theme.textTertiary).margin({ top: 4 })
    }
    .width('31%').padding({ top: 18, bottom: 18 })
    .backgroundColor(Color.White)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.06)', offsetY: 3 })
    .onClick(() => this.go(url))
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          // ---- 渐变头部 ----
          Column() {
            Text('社')
              .fontSize(30).fontWeight(FontWeight.Bold).fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .width(72).height(72)
              .backgroundColor('rgba(255,255,255,0.22)')
              .borderRadius(24)
            Text('社团活动报名与学时认定系统')
              .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White).margin({ top: 10 })
            Text('报名 · 审核 · 学时认定 · RFID 刷卡签到')
              .fontSize(13).fontColor('rgba(255,255,255,0.88)').margin({ top: 8 })
            // 服务器状态
            Row({ space: 6 }) {
              Text(this.checking ? '检测中...' : (this.serverOk ? '● 服务器在线' : '● 服务器未连接'))
                .fontSize(11).fontColor(this.serverOk ? Theme.onColorSuccess : Theme.onColorDanger)
              if (!this.checking) {
                Text('点此重试').fontSize(10).fontColor(Color.White)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .backgroundColor('rgba(255,255,255,0.25)').borderRadius(6)
              }
            }
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .backgroundColor('rgba(255,255,255,0.18)')
            .borderRadius(12)
            .margin({ top: 16 })
            .onClick(() => {
              if (!this.checking) this.ping();
            })
          }
          .width('100%').padding({ top: 56, bottom: 44 })
          .linearGradient({
            angle: 135,
            colors: [['#4B8DFF', 0], [Theme.primary, 1]]
          })
          .borderRadius({ bottomLeft: 28, bottomRight: 28 })

          // ---- 已登录状态条 ----
          if (this.loggedIn) {
            Row({ space: 10 }) {
              Text(this.name.substring(0, 1))
                .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Color.White).textAlign(TextAlign.Center)
                .width(40).height(40)
                .backgroundColor(this.isAdmin ? Theme.admin : Theme.success)
                .borderRadius(20)
              Column({ space: 2 }) {
                Text('已登录: ' + this.name)
                  .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
                Text(this.isAdmin ? '管理员' : '普通成员')
                  .fontSize(11).fontColor(Theme.textTertiary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Button('进入主界面').fontSize(13).height(32).backgroundColor(Theme.primary)
                .onClick(() => this.enter())
            }
            .width('100%').padding(14).margin({ top: 14, left: 14, right: 14 })
            .backgroundColor(Color.White).borderRadius(16)
            .shadow({ radius: 8, color: 'rgba(0,0,0,0.05)', offsetY: 2 })
          }

          // ---- 三入口 ----
          Column() {
            Text('欢迎使用').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
            Text('未注册成员请先注册, 经管理员审核通过后即可登录')
              .fontSize(11).fontColor(Theme.textTertiary).width('100%').margin({ top: 4, bottom: 14 })
            Row({ space: 10 }) {
              this.entryCard('登', '登录', '已有账号直接登录', Theme.primary, Theme.primaryBg, 'pages/LoginPage')
              this.entryCard('注', '注册', '新成员申请注册', Theme.success, Theme.successBg, 'pages/RegisterPage')
              this.entryCard('设', '设置', '服务器地址配置', Theme.signin, Theme.signinBg, 'pages/SettingsPage')
            }.width('100%')
          }
          .width('100%').padding(14).margin({ left: 14, right: 14, top: 14 })
          .backgroundColor(Color.White).borderRadius(16)

          // ---- 主登录按钮 ----
          Button(this.loggedIn ? '进入主界面 ›' : '登 录 ›')
            .width('92%').height(46).fontSize(16).fontColor(Color.White)
            .margin({ top: 18 })
            .linearGradient({
              angle: 90,
              colors: [['#4B8DFF', 0], [Theme.primary, 1]]
            })
            .borderRadius(23)
            .onClick(() => this.enter())

          // ---- 角色说明 ----
          Column({ space: 5 }) {
            Text('功能一览').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('普通成员: 浏览活动 · 在线报名 · 我的报名 · 学时报表')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('管理员: 发布活动 · 审核报名 · 注册审批 · 学时统计 · 实时日志')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('嵌入式扩展: ESP32 + RFID 读卡终端刷卡签到')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
          }
          .width('100%').padding(14).margin({ left: 14, right: 14, top: 14 })
          .backgroundColor(Theme.bgSubtle).borderRadius(12)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%').padding({ bottom: 24 })
      }
      .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
