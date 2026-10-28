/**
 * 社团活动报名与学时认定系统 —— 登录页(双角色: 普通成员 / 管理员)
 * 普通成员: 学号 + 姓名(与 MySQL student 表校验)
 * 管理员:   账号 + 密码(与 MySQL admin_user 表校验)
 * 登录成功签发 Token, 后续请求自动携带。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';

@Entry
@Component
struct LoginPage {
  @State role: string = 'student';   // student | admin
  @State account: string = '';       // 学号 / 管理员账号
  @State secret: string = '';        // 姓名 / 密码
  @State msg: string = '';
  @State busy: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      // 预填演示账号, 便于验收演示
      if (AppConfig.role === '') {
        this.account = '2023001';
        this.secret = '张三';
      }
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  switchRole(r: string): void {
    this.role = r;
    this.msg = '';
    if (r === 'student') {
      this.account = '2023001';
      this.secret = '张三';
    } else {
      this.account = 'admin';
      this.secret = 'admin123';
    }
  }

  async doLogin(): Promise<void> {
    if (this.busy) return;
    if (this.account.trim() === '' || this.secret.trim() === '') {
      this.msg = this.role === 'student' ? '请填写学号与姓名' : '请填写管理员账号与密码';
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
      await AppConfig.saveLogin(role, name, stuNo, token);
      this.msg = '登录成功! 身份: ' + (role === 'admin' ? '管理员' : '普通成员') + ' ' + name;
      // 延迟返回首页(首页刷新用户信息与权限)
      setTimeout(() => {
        router.back();
      }, 600);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  roleTab(label: string, r: string, hint: string) {
    Column({ space: 3 }) {
      Text(label).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(this.role === r ? Color.White : '#333333')
      Text(hint).fontSize(10)
        .fontColor(this.role === r ? 'rgba(255,255,255,0.85)' : '#999999')
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor(this.role === r ? '#1E6FFF' : '#E9ECF3')
    .borderRadius(12)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => this.switchRole(r))
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          // 头部
          Column({ space: 6 }) {
            Text('社团活动报名与学时认定系统')
              .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White)
            Text('HarmonyOS + SQLite 本地库 · 服务端 MySQL · 双端同步')
              .fontSize(12).fontColor('rgba(255,255,255,0.85)')
          }
          .width('100%').padding({ top: 46, bottom: 34 })
          .backgroundColor('#1E6FFF')
          .borderRadius({ bottomLeft: 24, bottomRight: 24 })
          .alignItems(HorizontalAlign.Center)

          // 登录卡
          Column() {
            Text('身份登录').fontSize(17).fontWeight(FontWeight.Bold).width('100%')
            Text('不同身份进入不同的功能(权限由服务端校验)')
              .fontSize(11).fontColor('#999999').width('100%').margin({ top: 4, bottom: 12 })

            // 角色切换
            Row({ space: 10 }) {
              this.roleTab('普通成员', 'student', '学号 + 姓名')
              this.roleTab('管理员', 'admin', '账号 + 密码')
            }.width('100%')

            // 表单
            Column({ space: 12 }) {
              Row({ space: 10 }) {
                Text(this.role === 'student' ? '学号' : '账号')
                  .fontSize(14).fontColor('#333333').width(52)
                TextInput({ text: this.account, placeholder: this.role === 'student' ? '如 2023001' : '如 admin' })
                  .layoutWeight(1)
                  .onChange((v: string) => this.account = v)
              }
              Row({ space: 10 }) {
                Text(this.role === 'student' ? '姓名' : '密码')
                  .fontSize(14).fontColor('#333333').width(52)
                TextInput({ text: this.secret, placeholder: this.role === 'student' ? '如 张三' : '管理员密码' })
                  .type(this.role === 'admin' ? InputType.Password : InputType.Normal)
                  .layoutWeight(1)
                  .onChange((v: string) => this.secret = v)
              }

              Button(this.busy ? '登录中...' : '登 录')
                .width('100%').height(44).fontSize(16).fontColor(Color.White)
                .backgroundColor('#1E6FFF')
                .enabled(!this.busy)
                .margin({ top: 6 })
                .onClick(() => this.doLogin())

              if (this.msg !== '') {
                Text(this.msg).fontSize(12)
                  .fontColor(this.msg.includes('成功') ? '#07C160' : '#E84026')
                  .textAlign(TextAlign.Center).width('100%')
              }
            }
            .width('100%').margin({ top: 16 })
          }
          .width('100%').padding(16)
          .backgroundColor(Color.White).borderRadius(16)
          .margin({ top: -16, left: 14, right: 14 })
          .shadow({ radius: 12, color: 'rgba(0,0,0,0.08)', offsetY: 4 })

          // 演示账号提示
          Column({ space: 5 }) {
            Text('演示账号').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('普通成员: 2023001 张三 / 2023002 李四')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('管理员: admin / admin123')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('服务器: 请先到「设置」填写宿主机局域网 IPv4:8000')
              .fontSize(11).fontColor('#B25E00').width('100%')
          }
          .width('100%').padding(14).margin({ left: 14, right: 14, top: 12 })
          .backgroundColor('#F2F4F8').borderRadius(12)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
