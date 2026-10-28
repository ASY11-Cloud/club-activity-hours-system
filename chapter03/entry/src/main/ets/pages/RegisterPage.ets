/**
 * 社团活动报名与学时认定系统 —— 注册页(v2.0)
 * 新成员提交注册申请: 学号 + 姓名 + 班级/院系
 * 提交后写入服务器 student 表(status=0), 由管理员在审核中心审批,
 * 审核通过后即可登录(学号+姓名)。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';

@Entry
@Component
struct RegisterPage {
  @State stuNo: string = '';
  @State name: string = '';
  @State dept: string = '';
  @State msg: string = '';
  @State busy: boolean = false;
  @State done: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  async submit(): Promise<void> {
    if (this.busy || this.done) return;
    const s = this.stuNo.trim();
    const n = this.name.trim();
    const d = this.dept.trim();
    if (s === '' || n === '') {
      this.msg = '学号与姓名必填';
      return;
    }
    if (!/^[0-9A-Za-z-]{4,20}$/.test(s)) {
      this.msg = '学号格式不正确(4~20位数字/字母)';
      return;
    }
    if (n.length > 50) {
      this.msg = '姓名过长';
      return;
    }
    this.busy = true;
    this.msg = '正在提交注册申请...';
    try {
      const body: Record<string, Object> = { 'stu_no': s, 'name': n, 'dept': d };
      const resp = await ApiClient.post('/api/register', body);
      if (resp['code'] === 0) {
        this.done = true;
        this.msg = '请等待管理员在审核中心审批, 通过后即可登录。';
      } else {
        this.msg = '提交失败: ' + (resp['msg'] as string);
      }
    } finally {
      this.busy = false;
    }
  }

  reset(): void {
    this.done = false;
    this.stuNo = '';
    this.name = '';
    this.dept = '';
    this.msg = '';
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          // 头部
          Column({ space: 6 }) {
            Text('📝').fontSize(44)
            Text('成员注册').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White)
            Text('提交后由管理员审核, 通过方可登录系统')
              .fontSize(12).fontColor('rgba(255,255,255,0.88)')
          }
          .width('100%').padding({ top: 46, bottom: 36 })
          .linearGradient({
            angle: 135,
            colors: [['#4B8DFF', 0], ['#1E6FFF', 1]]
          })
          .borderRadius({ bottomLeft: 24, bottomRight: 24 })
          .alignItems(HorizontalAlign.Center)

          // 表单
          Column({ space: 12 }) {
            Row({ space: 10 }) {
              Text('学号').fontSize(14).fontColor('#333333').width(60)
              TextInput({ text: this.stuNo, placeholder: '如 2023005' })
                .layoutWeight(1).type(InputType.Number).maxLength(20)
                .enabled(!this.done)
                .onChange((v: string) => this.stuNo = v)
            }
            Row({ space: 10 }) {
              Text('姓名').fontSize(14).fontColor('#333333').width(60)
              TextInput({ text: this.name, placeholder: '真实姓名(登录用)' })
                .layoutWeight(1).maxLength(50)
                .enabled(!this.done)
                .onChange((v: string) => this.name = v)
            }
            Row({ space: 10 }) {
              Text('班级').fontSize(14).fontColor('#333333').width(60)
              TextInput({ text: this.dept, placeholder: '班级/院系, 如 计科2205' })
                .layoutWeight(1).maxLength(100)
                .enabled(!this.done)
                .onChange((v: string) => this.dept = v)
            }

            if (this.done) {
              // 提交成功: 显示提示 + 去登录
              Column({ space: 8 }) {
                Text('✅').fontSize(36)
                Text('注册申请已提交!').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#07C160')
                Text(this.msg).fontSize(12).fontColor('#666666').textAlign(TextAlign.Center)
                Row({ space: 10 }) {
                  Button('去登录').layoutWeight(1).height(40).fontSize(14).backgroundColor('#1E6FFF')
                    .onClick(() => router.replaceUrl({ url: 'pages/LoginPage' }))
                  Button('再注册一个').layoutWeight(1).height(40).fontSize(14).backgroundColor('#666666')
                    .onClick(() => this.reset())
                }.width('100%').margin({ top: 6 })
              }
              .width('100%').padding(14)
              .backgroundColor('#F0FAF4').borderRadius(12)
            } else {
              Button(this.busy ? '提交中...' : '提交注册申请')
                .width('100%').height(44).fontSize(16).fontColor(Color.White)
                .backgroundColor('#1E6FFF')
                .enabled(!this.busy)
                .margin({ top: 6 })
                .onClick(() => this.submit())
            }

            if (this.msg !== '' && !this.done) {
              Text(this.msg).fontSize(12)
                .fontColor(this.msg.includes('成功') ? '#07C160' : '#E84026')
                .textAlign(TextAlign.Center).width('100%')
            }
          }
          .width('100%').padding(16)
          .backgroundColor(Color.White).borderRadius(16)
          .margin({ top: -16, left: 14, right: 14 })
          .shadow({ radius: 12, color: 'rgba(0,0,0,0.08)', offsetY: 4 })

          // 说明
          Column({ space: 4 }) {
            Text('注册说明').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('1. 学号必须为真实学号, 登录时使用学号+姓名')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('2. 提交后状态为「待审核」, 无法登录')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('3. 管理员在「审核中心 → 注册申请」中同意/拒绝')
              .fontSize(11).fontColor('#666666').width('100%')
            Text('4. 审核通过后即可登录使用系统')
              .fontSize(11).fontColor('#666666').width('100%')
          }
          .width('100%').padding(14).margin({ left: 14, right: 14, top: 12 })
          .backgroundColor('#F2F4F8').borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Button('返回').fontSize(14).height(38).fontColor('#666666')
            .backgroundColor('transparent').margin({ top: 10 })
            .onClick(() => router.back())
        }
        .width('100%')
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
