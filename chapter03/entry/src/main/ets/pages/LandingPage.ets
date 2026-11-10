/**
 * 社团活动报名与学时认定系统 —— 启动页(引导 + 登录合一, v5.1)
 * 冷启动第一屏: 渐变头 + 服务器状态; 未登录直接内联身份登录卡(三身份), 已登录显示会话条一键进主页。
 * 注册入口跟随所选身份显示在登录卡内: 成员 -> RegisterPage, 社团 -> ClubRegisterPage, 管理员不显示。
 * 「我的 -> 系统介绍」也会 push 到本页, 此时展示功能一览与演示账号。
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
  @State isClub: boolean = false;   // v5.0: 社团账号(认证主体是社团, 与平台管理员区分显示)
  @State name: string = '';
  @State serverOk: boolean = false;
  @State checking: boolean = false;
  @State role: string = 'student';   // student | club | admin
  @State account: string = '';       // 学号 / 社团账号 / 管理员账号
  @State secret: string = '';        // 密码
  @State msg: string = '';
  @State busy: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.syncLogin();
      if (!this.loggedIn) this.prefillDemo();
      this.ping();
    }).catch((e: Error) => {
      console.error('LandingPage init failed: ' + e.message);
    });
  }

  onPageShow(): void {
    // 设置/注册返回时同步登录态
    this.syncLogin();
    if (this.loggedIn) this.msg = '';
    if (!this.checking) this.ping();
  }

  syncLogin(): void {
    this.loggedIn = AppConfig.isLoggedIn;
    this.isAdmin = AppConfig.isAdmin;
    this.isClub = AppConfig.isClubAccount;
    this.name = AppConfig.stuName;
  }

  prefillDemo(): void {
    // 预填演示账号, 便于验收演示
    if (AppConfig.role === '') {
      this.switchRole('student');
    }
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

  enterMain(): void {
    // 本页可能是冷启动根页, 也可能是「我的 → 系统介绍」push 进来的二级页;
    // 根级切换统一清栈, 避免栈里出现两个 MainPage
    Nav.resetTo('pages/MainPage');
  }

  switchRole(r: string): void {
    this.role = r;
    this.msg = '';
    if (r === 'student') {
      this.account = '2023001';
      this.secret = '123456';
    } else if (r === 'club') {
      // 社团账号: 认证主体是社团, 社长换届不换账号, 因此这里永远是同一个登录名
      this.account = 'club';
      this.secret = 'club123';
    } else {
      this.account = 'admin';
      this.secret = 'admin123';
    }
  }

  async doLogin(): Promise<void> {
    if (this.busy) return;
    if (this.account.trim() === '' || this.secret.trim() === '') {
      this.msg = this.role === 'student' ? '请填写学号与密码'
        : (this.role === 'club' ? '请填写社团账号与密码' : '请填写管理员账号与密码');
      return;
    }
    this.busy = true;
    this.msg = '正在登录...';
    try {
      const body: Record<string, Object> = {
        'type': this.role,
        'account': this.account.trim(),
        'secret': this.secret.trim()
      };
      const resp = await ApiClient.post('/api/login', body);
      if (resp['code'] !== 0) {
        this.msg = '登录失败: ' + (resp['msg'] as string);
        return;
      }
      const data = resp['data'] as Record<string, Object>;
      const role = data['role'] as string;
      const name = data['name'] as string;
      const stuNo = data['stu_no'] as string;
      const token = data['token'] as string;
      // 社团会话: club_id>0 表示社团账号, 后续页面按它显示社团信息与换届入口
      const clubId = data['club_id'] !== undefined ? Number(data['club_id']) : 0;
      const clubName = data['club_name'] !== undefined ? (data['club_name'] as string) : '';
      const accountType = data['account_type'] !== undefined ? (data['account_type'] as string) : '';
      await AppConfig.saveLogin(role, name, stuNo, token, clubId, clubName, accountType);
      this.syncLogin();
      this.msg = '';
      // 登录成功直接进入底部 TabBar 主界面(reset: 返回时不再回到本页)
      setTimeout(() => {
        this.enterMain();
      }, 300);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  roleTab(label: string, r: string, hint: string) {
    Column({ space: 3 }) {
      Text(label).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(this.role === r ? Theme.textOnPrimary : Theme.textBody)
      Text(hint).fontSize(10)
        .fontColor(this.role === r ? 'rgba(255,255,255,0.85)' : Theme.textTertiary)
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor(this.role === r ? Theme.primary : Theme.bgNeutral)
    .borderRadius(12)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => this.switchRole(r))
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          // ---- 渐变头部 ----
          Column() {
            Text('社')
              .fontSize(30).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
              .textAlign(TextAlign.Center)
              .width(64).height(64)
              .backgroundColor('rgba(255,255,255,0.22)')
              .borderRadius(22)
            Text('社团活动报名与学时认定系统')
              .fontSize(21).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary).margin({ top: 10 })
            Text('报名 · 审核 · 学时认定 · RFID 刷卡签到')
              .fontSize(12).fontColor('rgba(255,255,255,0.88)').margin({ top: 6 })
            // 服务器状态
            Row({ space: 6 }) {
              Text(this.checking ? '检测中...' : (this.serverOk ? '● 服务器在线' : '● 服务器未连接'))
                .fontSize(11).fontColor(this.serverOk ? Theme.onColorSuccess : Theme.onColorDanger)
              if (!this.checking) {
                Text('点此重试').fontSize(10).fontColor(Theme.textOnPrimary)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .backgroundColor('rgba(255,255,255,0.25)').borderRadius(6)
              }
            }
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .backgroundColor('rgba(255,255,255,0.18)')
            .borderRadius(12)
            .margin({ top: 12 })
            .onClick(() => {
              if (!this.checking) this.ping();
            })
          }
          .width('100%').padding({ top: 44, bottom: 46 })
          .linearGradient({
            angle: 135,
            colors: [[Theme.gradientStart, 0], [Theme.primary, 1]]
          })
          .borderRadius({ bottomLeft: 28, bottomRight: 28 })

          // ---- 已登录: 会话条(一键进主页); 未登录: 内联登录卡 ----
          if (this.loggedIn) {
            Column() {
              Row({ space: 10 }) {
                Text(this.name.substring(0, 1))
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary).textAlign(TextAlign.Center)
                  .width(40).height(40)
                  .backgroundColor(this.isAdmin ? Theme.admin : Theme.success)
                  .borderRadius(20)
                Column({ space: 2 }) {
                  Text('已登录: ' + this.name)
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
                  Text(this.isAdmin ? (this.isClub ? '社团账号 · ' + AppConfig.clubName : '平台管理员') : '普通成员')
                    .fontSize(11).fontColor(Theme.textTertiary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }
              .width('100%')

              Button(this.busy ? '正在进入...' : '进入主界面 ›')
                .width('100%').height(44).fontSize(15).fontColor(Theme.textOnPrimary)
                .margin({ top: 14 })
                .linearGradient({
                  angle: 90,
                  colors: [[Theme.gradientStart, 0], [Theme.primary, 1]]
                })
                .borderRadius(22)
                .onClick(() => this.enterMain())

              Text('切换账号请到「设置 → 退出登录」')
                .fontSize(10).fontColor(Theme.textTertiary).margin({ top: 8 })
            }
            .width('100%').padding(16)
            .backgroundColor(Theme.bgCard).borderRadius(16)
            .margin({ top: -20, left: 14, right: 14 })
            .shadow({ radius: 12, color: 'rgba(0,0,0,0.08)', offsetY: 4 })
          } else {
            Column() {
              Text('身份登录').fontSize(17).fontWeight(FontWeight.Bold).width('100%')
              Text('不同身份进入不同的功能(权限由服务端校验)')
                .fontSize(11).fontColor(Theme.textTertiary).width('100%').margin({ top: 4, bottom: 12 })

              // 角色切换: 普通成员 / 社团账号 / 平台管理员
              Row({ space: 8 }) {
                this.roleTab('普通成员', 'student', '学号+密码')
                this.roleTab('社团账号', 'club', '社团+密码')
                this.roleTab('管理员', 'admin', '账号+密码')
              }.width('100%')

              // 表单
              Column({ space: 12 }) {
                Row({ space: 10 }) {
                  Text(this.role === 'student' ? '学号' : (this.role === 'club' ? '社团账号' : '账号'))
                    .fontSize(14).fontColor(Theme.textBody).width(60)
                  TextInput({
                    text: this.account,
                    placeholder: this.role === 'student' ? '如 2023001' : (this.role === 'club' ? '如 club' : '如 admin')
                  })
                    .layoutWeight(1)
                    .onChange((v: string) => this.account = v)
                }
                Row({ space: 10 }) {
                  Text('密码')
                    .fontSize(14).fontColor(Theme.textBody).width(60)
                  TextInput({
                    text: this.secret,
                    placeholder: this.role === 'student' ? '成员登录密码'
                      : (this.role === 'club' ? '社团账号密码' : '管理员密码')
                  })
                    .type(InputType.Password)
                    .layoutWeight(1)
                    .onChange((v: string) => this.secret = v)
                }

                Button(this.busy ? '登录中...' : '登 录')
                  .width('100%').height(44).fontSize(16).fontColor(Theme.textOnPrimary)
                  .backgroundColor(Theme.primary)
                  .enabled(!this.busy)
                  .margin({ top: 6 })
                  .onClick(() => this.doLogin())

                if (this.msg !== '') {
                  Text(this.msg).fontSize(12)
                    .fontColor(this.msg.includes('成功') ? Theme.success : Theme.danger)
                    .textAlign(TextAlign.Center).width('100%')
                }

                // 注册入口跟随当前身份: 成员 -> 成员注册; 社团账号 -> 社团注册; 管理员 -> 不显示
                if (this.role === 'student') {
                  Row({ space: 2 }) {
                    Text('还没有成员账号?').fontSize(12).fontColor(Theme.textTertiary)
                    Text('去注册').fontSize(12).fontColor(Theme.primary)
                      .onClick(() => this.go('pages/RegisterPage'))
                  }
                  .width('100%').justifyContent(FlexAlign.Center)
                } else if (this.role === 'club') {
                  Row({ space: 2 }) {
                    Text('社团尚未注册?').fontSize(12).fontColor(Theme.textTertiary)
                    Text('注册社团(提交管理员审核)').fontSize(12).fontColor(Theme.primary)
                      .onClick(() => this.go('pages/ClubRegisterPage'))
                  }
                  .width('100%').justifyContent(FlexAlign.Center)
                }
              }
              .width('100%').margin({ top: 16 })
            }
            .width('100%').padding(16)
            .backgroundColor(Theme.bgCard).borderRadius(16)
            .margin({ top: -20, left: 14, right: 14 })
            .shadow({ radius: 12, color: 'rgba(0,0,0,0.08)', offsetY: 4 })
          }

          // ---- 服务器设置入口(连不上服务器时的出口, 登录前后均可见) ----
          Row({ space: 4 }) {
            Text('服务器未连通? ').fontSize(12).fontColor(Theme.textSecondary)
            Text('前往服务器设置').fontSize(12).fontColor(Theme.primary)
              .onClick(() => this.go('pages/SettingsPage'))
          }
          .width('100%').justifyContent(FlexAlign.Center)
          .padding({ top: 14 })

          // ---- 演示账号 + 功能一览 ----
          Column({ space: 5 }) {
            Text('演示账号').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('普通成员: 2023001(张三) / 2023002(李铭), 密码 123456')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('社团账号: club / club123 (认证主体是社团, 换届不换账号)')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('管理员: admin / admin123')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('服务器: 请先到「设置」填写宿主机局域网 IPv4:8000')
              .fontSize(11).fontColor(Theme.warning).width('100%')

            Divider().margin({ top: 8, bottom: 4 })

            Text('功能一览').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('普通成员: 浏览活动 · 在线报名 · 我的报名 · 学时报表')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('社团账号: 发布活动 · 报名审核 · 入社退社审批 · 成员/公告/报表')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('平台管理员: 社团注册审核 · 用户管理 · 学时统计 · 实时日志')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('嵌入式扩展: ESP32 + RFID 读卡终端刷卡签到')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
          }
          .width('100%').padding(14).margin({ left: 14, right: 14, top: 12 })
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
