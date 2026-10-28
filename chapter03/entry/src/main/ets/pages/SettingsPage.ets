/**
 * 社团活动报名与学时认定系统 —— 设置(服务器地址 / 当前账号 / 退出登录)
 * 账号信息由登录页签发, 此处只读展示。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';

@Entry
@Component
struct SettingsPage {
  @State host: string = '';
  @State port: string = '';
  @State msg: string = '';
  @State testing: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.host = AppConfig.serverHost;
      this.port = AppConfig.serverPort;
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  async save(): Promise<void> {
    await AppConfig.saveServer(this.host, this.port);
    this.msg = '已保存';
  }

  async testConn(): Promise<void> {
    this.testing = true;
    this.msg = '正在连接 ' + AppConfig.serverBase + ' ...';
    const ok = await ApiClient.ping();
    this.msg = ok ? '连接成功! 服务器在线(MySQL 已连接)' : '连接失败, 请检查地址/端口/防火墙';
    this.testing = false;
  }

  async doLogout(): Promise<void> {
    await AppConfig.logout();
    this.msg = '已退出登录';
    setTimeout(() => {
      router.back();
    }, 400);
  }

  build() {
    Column() {
      Row() {
        Text('设置').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('测试连接').fontSize(12).height(30).backgroundColor('#1E6FFF')
          .enabled(!this.testing)
          .onClick(() => this.testConn())
      }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

      Scroll() {
        Column() {
          // 服务器连接
          Column({ space: 10 }) {
            Text('服务器连接(自主 C++ Web 服务器 + MySQL)').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            Text('模拟器/真机访问宿主机: 填宿主机局域网 IPv4, 例如 10.15.85.109; 模拟器也可用 10.0.2.2; 服务器 bind 0.0.0.0')
              .fontSize(11).fontColor('#888888').width('100%').lineHeight(17)
            Row({ space: 10 }) {
              TextInput({ text: this.host, placeholder: '服务器 IP' })
                .layoutWeight(1).onChange((v: string) => this.host = v)
              TextInput({ text: this.port, placeholder: '端口' })
                .type(InputType.NUMBER_DECIMAL).width(90).onChange((v: string) => this.port = v)
            }
            Button('保存服务器地址').width('100%').height(38).fontSize(14).backgroundColor('#1E6FFF')
              .onClick(() => this.save())
          }
          .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14)

          // 当前账号(只读)
          Column({ space: 8 }) {
            Text('当前账号').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            if (AppConfig.isLoggedIn) {
              Row({ space: 10 }) {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(AppConfig.stuName).fontSize(15).fontWeight(FontWeight.Bold)
                    Text(AppConfig.roleText)
                      .fontSize(10).fontColor(Color.White)
                      .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                      .backgroundColor(AppConfig.isAdmin ? '#F5652F' : '#07C160')
                      .borderRadius(8)
                  }
                  Text(AppConfig.isAdmin ? '管理员账号: ' + AppConfig.stuNo : '学号: ' + AppConfig.stuNo)
                    .fontSize(11).fontColor('#666666')
                  Text('身份由服务端校验(admin_user / student 表), 不可手动伪造')
                    .fontSize(10).fontColor('#BBBBBB')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }
              Button('退出登录').width('100%').height(38).fontSize(14)
                .backgroundColor('#E84026')
                .onClick(() => this.doLogout())
            } else {
              Column({ space: 8 }) {
                Text('当前未登录').fontSize(13).fontColor('#666666')
                Button('去登录').width('100%').height(38).fontSize(14).backgroundColor('#1E6FFF')
                  .onClick(() => router.pushUrl({ url: 'pages/LoginPage' }))
              }.width('100%')
            }
          }
          .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14).margin({ top: 10 })

          if (this.msg !== '') {
            Text(this.msg).fontSize(12).fontColor('#1E6FFF').textAlign(TextAlign.Center).width('100%').margin({ top: 8 })
          }

          // 演示账号说明
          Column({ space: 5 }) {
            Text('演示账号').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('普通成员: 2023001 张三 / 2023002 李四(登录: 学号+姓名)')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('管理员: admin / admin123(登录: 账号+密码)')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('RFID 签到卡: 张三 A1B2C3D4 / 李四 E5F60708(嵌入式扩展项)')
              .fontSize(11).fontColor('#666666').width('100%')
          }
          .width('100%').padding(14).margin({ top: 10 })
          .backgroundColor('#F2F4F8').borderRadius(12)
          .alignItems(HorizontalAlign.Start)
        }
        .padding(14)
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
