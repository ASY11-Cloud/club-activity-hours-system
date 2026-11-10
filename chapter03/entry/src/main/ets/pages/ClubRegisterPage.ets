/**
 * 社团注册 (v5.0 重构)
 *
 * 社团像成员一样注册: 自设登录账号 + 社团名 + 密码(+ 挂靠单位/简介/首任社长),
 * 提交后进入待审核状态, 由平台管理员审核通过后才获得独立编号并可登录。
 */
import { router, promptAction } from '@kit.ArkUI';
import { ApiClient } from '../common/ApiClient';
import { Theme } from '../common/Theme';

@Entry
@Component
struct ClubRegisterPage {
  @State account: string = '';
  @State clubName: string = '';
  @State pwd: string = '';
  @State pwd2: string = '';
  @State dept: string = '';
  @State intro: string = '';
  @State leaderName: string = '';
  @State leaderStu: string = '';
  @State submitting: boolean = false;
  @State msg: string = '';

  async submit(): Promise<void> {
    if (this.account.trim() === '' || this.clubName.trim() === '') {
      this.msg = '登录账号与社团名称必填';
      return;
    }
    if (this.pwd.length < 6 || this.pwd.length > 64) {
      this.msg = '密码长度需 6~64 位';
      return;
    }
    if (this.pwd !== this.pwd2) {
      this.msg = '两次输入的密码不一致';
      return;
    }
    this.submitting = true;
    this.msg = '';
    const resp = await ApiClient.post('/api/club/register', {
      'account': this.account.trim(),
      'club_name': this.clubName.trim(),
      'pwd': this.pwd,
      'dept': this.dept.trim(),
      'intro': this.intro.trim(),
      'leader_name': this.leaderName.trim(),
      'leader_stu_no': this.leaderStu.trim()
    });
    this.submitting = false;
    this.msg = (resp['msg'] as string) || '';
    if (resp['code'] === 0) {
      promptAction.showToast({ message: '注册申请已提交, 请等待平台管理员审核' });
      setTimeout(() => router.back(), 1200);
    }
  }

  @Builder
  header() {
    Row() {
      Text('‹ 返回').fontSize(Theme.fsBody).fontColor(Theme.primary)
        .onClick(() => router.back())
      Text('社团注册').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody).layoutWeight(1).textAlign(TextAlign.Center)
      Text('').fontSize(Theme.fsBody).width(52)
    }
    .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 10 })
  }

  @Builder
  fieldLabel(label: string) {
    Text(label).fontSize(Theme.fsSmall).fontColor(Theme.textSecondary).width('100%')
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 6 }) {
            Text('注册即提交审核申请').fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
              .fontColor(Theme.textBody)
            Text('审核通过前无法登录; 通过后由系统分配社团独立编号, 登录账号长期不变。')
              .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
          }.width('100%').alignItems(HorizontalAlign.Start)

          Column({ space: 4 }) {
            this.fieldLabel('登录账号 *')
            TextInput({ placeholder: '自设账号, 注册后不可改', text: this.account })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .onChange((v: string) => { this.account = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('社团名称 *')
            TextInput({ placeholder: '社团全称(不可与已有社团重名)', text: this.clubName })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .onChange((v: string) => { this.clubName = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('登录密码 *')
            TextInput({ placeholder: '6~64 位', text: this.pwd })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .type(InputType.Password)
              .onChange((v: string) => { this.pwd = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('确认密码 *')
            TextInput({ placeholder: '再次输入密码', text: this.pwd2 })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .type(InputType.Password)
              .onChange((v: string) => { this.pwd2 = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('挂靠单位')
            TextInput({ placeholder: '院系/单位(选填)', text: this.dept })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .onChange((v: string) => { this.dept = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('社团简介')
            TextInput({ placeholder: '一句话介绍(选填)', text: this.intro })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .onChange((v: string) => { this.intro = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('首任社长姓名')
            TextInput({ placeholder: '注册人姓名(选填, 留痕用)', text: this.leaderName })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .onChange((v: string) => { this.leaderName = v; })
          }.width('100%')

          Column({ space: 4 }) {
            this.fieldLabel('首任社长学号')
            TextInput({ placeholder: '与姓名配套(选填)', text: this.leaderStu })
              .fontSize(Theme.fsBody).height(42).width('100%')
              .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
              .onChange((v: string) => { this.leaderStu = v; })
          }.width('100%')

          Button(this.submitting ? '提交中...' : '提交注册申请')
            .width('100%').height(44).fontSize(16)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.primary)
            .enabled(!this.submitting)
            .onClick(() => this.submit())

          if (this.msg !== '') {
            Text(this.msg)
              .fontSize(Theme.fsSmall)
              .fontColor(this.msg.includes('已提交') ? Theme.success : Theme.onColorDanger)
              .width('100%').textAlign(TextAlign.Center)
          }

          Text('提示: 社团名称唯一; 登录账号唯一(含待审核中的申请)。')
            .fontSize(10).fontColor(Theme.textTertiary).width('100%')
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1).align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
