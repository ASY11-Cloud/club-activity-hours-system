/**
 * 社团主页(v5.0) —— 认证主体是社团, 不是个人
 *
 * 四个区块(需求原文):
 *  1) 社团信息展示区: 名称/账号/挂靠单位/简介 + 成员/活动/报名/学时统计
 *  2) 社长姓名修改入口: 需当前社团账号密码验证 + 二次确认 + 分支错误文案
 *  3) 历任社长记录: 时间轴, 在任标记, 变更方式/操作人/备注
 *  4) 账号权限继承机制说明: 常驻文案, 讲清"权限随岗位不随人"
 *
 * 关键语义: 换届只改 club.leader_* 三个字段 + 追加一条历史,
 * 不换账号、不换密码、不重建 Token —— 新社长用同一账号登录即继承全部社团权限。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { AdminGuardView } from '../common/GuardViews';
import { ClubInfo, LeaderRecord, parseClubInfo, parseLeaders, changeTypeText } from '../common/Models';
import { Theme } from '../common/Theme';
import { StateView } from '../components/StateView';

@Entry
@Component
struct ClubProfilePage {
  @State info: ClubInfo | null = null;
  @State leaders: LeaderRecord[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State notAdmin: boolean = false;
  @State notClub: boolean = false;

  // ---- 换届表单(内联展开, 与设置页注销面板同风格) ----
  @State editing: boolean = false;
  @State newName: string = '';
  @State newStu: string = '';
  @State confirmPwd: string = '';
  @State reason: string = '';
  @State formErr: string = '';
  @State formMsg: string = '';
  @State busy: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isAdmin) {
        this.notAdmin = true;
        this.loading = false;
        return;
      }
      // 平台管理员(club_id=0)没有"本社团", 换届入口对它没有意义
      if (!AppConfig.isClubAccount) {
        this.notClub = true;
        this.loading = false;
        return;
      }
      this.load();
    }).catch((e: Error) => {
      this.loadError = '初始化失败: ' + e.message;
      this.loading = false;
    });
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    const infoResp = await ApiClient.get('/api/club/info');
    if (infoResp['code'] !== 0) {
      this.loadError = infoResp['msg'] as string;
      this.loading = false;
      return;
    }
    this.info = parseClubInfo(infoResp);
    const ldResp = await ApiClient.get('/api/club/leaders?page=1&size=30');
    if (ldResp['code'] === 0) {
      this.leaders = parseLeaders(ldResp);
    }
    this.loading = false;
  }

  openEditor(): void {
    this.editing = true;
    this.formErr = '';
    this.formMsg = '';
    this.confirmPwd = '';
    this.reason = '';
    // 预填现任社长, 用户只改需要改的字(降低误改成别字的概率)
    this.newName = this.info !== null ? this.info.leader_name : '';
    this.newStu = this.info !== null ? this.info.leader_stu_no : '';
  }

  closeEditor(): void {
    this.editing = false;
    this.formErr = '';
    this.confirmPwd = '';
  }

  /** 二次确认: 换届是"账号不变但责任人变了"的动作, 必须让用户看清前后姓名 */
  confirmAndSubmit(): void {
    if (this.newName.trim() === '') {
      this.formErr = '请填写新社长姓名';
      return;
    }
    if (this.confirmPwd === '') {
      this.formErr = '请输入当前社团账号密码以确认';
      return;
    }
    const oldName = this.info !== null ? this.info.leader_name : '';
    AlertDialog.show({
      title: '确认换届',
      message: '确认将社长由「' + oldName + '」变更为「' + this.newName.trim() +
        '」？\n变更立即生效并记入历任社长记录；账号与密码不变。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '确认换届',
        action: () => {
          this.doSubmit();
        }
      }
    });
  }

  async doSubmit(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.formErr = '';
    this.formMsg = '';
    const body: Record<string, Object> = {
      'new_name': this.newName.trim(),
      'new_stu_no': this.newStu.trim(),
      'confirm_pwd': this.confirmPwd,
      'reason': this.reason.trim(),
      'expect_leader': this.info !== null ? this.info.leader_name : ''
    };
    const resp = await ApiClient.post('/api/club/leader', body, true);
    if (resp['code'] === 0) {
      this.formMsg = resp['msg'] as string;
      this.editing = false;
      this.confirmPwd = '';
      await this.load();
    } else {
      // 403 密码错 / 409 已被他人变更 / 429 节流, 服务端文案可直接展示
      this.formErr = resp['msg'] as string;
    }
    this.busy = false;
  }

  // ==================== 视图 ====================

  @Builder
  header() {
    Row({ space: 8 }) {
      Text('‹').fontSize(24).fontColor(Theme.textBody)
        .width(32).height(32).textAlign(TextAlign.Center)
        .onClick(() => router.back())
      Text('社团主页').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody).layoutWeight(1)
      Text('刷新').fontSize(Theme.fsSmall).fontColor(Theme.primary)
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .onClick(() => this.load())
    }
    .width('100%')
    .padding({ left: 10, right: Theme.pagePadding, top: 12, bottom: 8 })
  }

  @Builder
  statItem(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value).fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
      Text(label).fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  infoCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(this.info !== null && this.info.club_name !== ''
          ? this.info.club_name.substring(0, 1) : '社')
          .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
          .width(56).height(56).textAlign(TextAlign.Center)
          .backgroundColor(Theme.primary).borderRadius(18)
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(this.info !== null ? this.info.club_name : '')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
            Text(this.info !== null && this.info.status === 1 ? '正常' : '停用')
              .fontSize(Theme.fsCaption)
              .fontColor(this.info !== null && this.info.status === 1 ? Theme.success : Theme.danger)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor(this.info !== null && this.info.status === 1
                ? Theme.successBg : Theme.dangerBg)
              .borderRadius(Theme.radiusPill)
          }
          Text('登录账号 ' + (this.info !== null ? this.info.account : '') + ' · 账号长期不变')
            .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
          Text('挂靠 ' + (this.info !== null ? this.info.dept : ''))
            .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      if (this.info !== null && this.info.intro !== '') {
        Text(this.info.intro)
          .fontSize(Theme.fsSmall).fontColor(Theme.textSecondary).lineHeight(19)
          .width('100%')
      }

      Divider().color(Theme.divider)

      // 现任社长: 换届只改这三行数据
      Column({ space: 6 }) {
        Row() {
          Text('现任社长').fontSize(Theme.fsSmall).fontColor(Theme.textTertiary).layoutWeight(1)
          Text((this.info !== null ? this.info.leader_name : '') +
            (this.info !== null && this.info.leader_stu_no !== ''
              ? '（' + this.info.leader_stu_no + '）' : ''))
            .fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium).fontColor(Theme.textBody)
        }
        .width('100%')
        Row() {
          Text('本任开始').fontSize(Theme.fsSmall).fontColor(Theme.textTertiary).layoutWeight(1)
          Text((this.info !== null ? this.info.leader_since : '') +
            (this.info !== null ? ' · 在任 ' + this.info.leader_days.toString() + ' 天' : ''))
            .fontSize(Theme.fsSmall).fontColor(Theme.textSecondary)
        }
        .width('100%')
      }

      Divider().color(Theme.divider)

      Row() {
        this.statItem('成员', this.info !== null ? this.info.member_count.toString() : '0')
        this.statItem('活动', this.info !== null ? this.info.activity_count.toString() : '0')
        this.statItem('报名', this.info !== null ? this.info.signup_count.toString() : '0')
        this.statItem('学时', this.info !== null ? this.info.hours_sum.toFixed(1) : '0.0')
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('内部活动 ' + (this.info !== null ? this.info.internal_count.toString() : '0'))
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        Text('·').fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
        Text('全校开放 ' + (this.info !== null ? this.info.public_count.toString() : '0'))
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        Text('·').fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
        Text('待审报名 ' + (this.info !== null ? this.info.pending_signup.toString() : '0'))
          .fontSize(Theme.fsCaption).fontColor(Theme.warning)
      }
      .width('100%')
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  fieldLabel(text: string) {
    Text(text).fontSize(Theme.fsSmall).fontColor(Theme.textSecondary)
      .width('100%').margin({ bottom: 4 })
  }

  @Builder
  leaderCard() {
    Column({ space: 10 }) {
      Row() {
        Text('社长换届').fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
          .fontColor(Theme.textBody).layoutWeight(1)
        Text('需密码验证').fontSize(Theme.fsCaption).fontColor(Theme.admin)
      }
      .width('100%')

      Text('换届只修改社长姓名与社团内岗位，登录账号、密码、历史活动、报名与学时全部保留。')
        .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary).lineHeight(18)
        .width('100%')

      if (!this.editing) {
        Button('修改社长姓名')
          .width('100%').height(42).fontSize(Theme.fsBody)
          .fontColor(Theme.textOnPrimary).backgroundColor(Theme.primary)
          .onClick(() => this.openEditor())
      } else {
        Column({ space: 10 }) {
          this.fieldLabel('新社长姓名')
          TextInput({ text: this.newName, placeholder: '如 王俊' })
            .width('100%').onChange((v: string) => this.newName = v)

          this.fieldLabel('新社长学号（选填，留空沿用上一任）')
          TextInput({ text: this.newStu, placeholder: '如 2023003' })
            .width('100%').onChange((v: string) => this.newStu = v)

          this.fieldLabel('变更原因 / 备注（选填）')
          TextInput({ text: this.reason, placeholder: '如 换届选举' })
            .width('100%').onChange((v: string) => this.reason = v)

          this.fieldLabel('当前社团账号密码（必填，用于权限验证）')
          TextInput({ text: this.confirmPwd, placeholder: '输入登录密码以确认换届' })
            .type(InputType.Password)
            .width('100%').onChange((v: string) => this.confirmPwd = v)

          Row({ space: 10 }) {
            Button('取消')
              .layoutWeight(1).height(40).fontSize(Theme.fsBody)
              .fontColor(Theme.textBody).backgroundColor(Theme.bgNeutral)
              .onClick(() => this.closeEditor())
            Button(this.busy ? '提交中...' : '确认换届')
              .layoutWeight(1).height(40).fontSize(Theme.fsBody)
              .fontColor(Theme.textOnPrimary).backgroundColor(Theme.primary)
              .enabled(!this.busy && this.confirmPwd.length >= 6)
              .onClick(() => this.confirmAndSubmit())
          }
          .width('100%').margin({ top: 2 })

          if (this.formErr !== '') {
            Text(this.formErr).fontSize(Theme.fsSmall).fontColor(Theme.danger)
              .fontWeight(FontWeight.Medium).lineHeight(18).width('100%')
          }
        }
        .width('100%').alignItems(HorizontalAlign.Start)
      }

      if (this.formMsg !== '') {
        Text(this.formMsg).fontSize(Theme.fsSmall).fontColor(Theme.success)
          .fontWeight(FontWeight.Medium).width('100%')
      }
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  leaderRow(item: LeaderRecord) {
    Row({ space: 10 }) {
      // 时间轴: 竖线 + 圆点(在任用主色)
      Column() {
        Circle({ width: item.is_current ? 10 : 8, height: item.is_current ? 10 : 8 })
          .fill(item.is_current ? Theme.primary : Theme.textDisabled)
        Rect().width(1).layoutWeight(1).fill(Theme.divider)
      }
      .width(12).alignItems(HorizontalAlign.Center)

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(item.leader_name).fontSize(Theme.fsBody).fontWeight(FontWeight.Medium)
            .fontColor(Theme.textBody)
          if (item.is_current) {
            Text('在任').fontSize(Theme.fsCaption).fontColor(Theme.success)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor(Theme.successBg).borderRadius(Theme.radiusPill)
          }
          Text(changeTypeText(item.change_type)).fontSize(Theme.fsCaption)
            .fontColor(Theme.textTertiary)
        }
        .width('100%')

        Text((item.leader_stu_no !== '' ? item.leader_stu_no + ' · ' : '') +
          item.start_at + ' ~ ' + (item.is_current ? '至今' : item.end_at))
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)

        if (item.reason !== '') {
          Text((item.operator !== '' ? item.operator + '：' : '') + item.reason)
            .fontSize(Theme.fsCaption).fontColor(Theme.textSecondary)
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      .padding({ bottom: 14 })
    }
    .width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  historyCard() {
    Column({ space: 10 }) {
      Row() {
        Text('历任社长').fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
          .fontColor(Theme.textBody).layoutWeight(1)
        Text('共 ' + this.leaders.length.toString() + ' 任')
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }
      .width('100%')

      if (this.leaders.length === 0) {
        StateView({ kind: 'empty', title: '暂无历任记录', desc: '完成一次换届后会在此留痕' })
      } else {
        Column() {
          ForEach(this.leaders, (item: LeaderRecord) => {
            this.leaderRow(item)
          }, (item: LeaderRecord) => item.id.toString() + '-' + item.end_at)
        }
        .width('100%')
      }
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  inheritCard() {
    Column({ space: 8 }) {
      Row() {
        Text('账号权限继承机制').fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
          .fontColor(Theme.textBody).layoutWeight(1)
        Text('重要说明').fontSize(Theme.fsCaption).fontColor(Theme.primary)
      }
      .width('100%')

      this.inheritLine('1', '账号属于社团，不属于任何个人。社长换届不换账号、不重新注册。')
      this.inheritLine('2', '权限绑定的是社团内的「社长」岗位，不是上一任社长的个人权限。')
      this.inheritLine('3', '换届只改社长字段，历史活动、报名、学时、公告全部保留。')
      this.inheritLine('4', '每次换届都写入历任记录并可查操作日志，不可静默篡改。')
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.primaryBg).borderRadius(Theme.radiusLg)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  inheritLine(no: string, text: string) {
    Row({ space: 8 }) {
      Text(no).fontSize(Theme.fsCaption).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textOnPrimary).textAlign(TextAlign.Center)
        .width(18).height(18).backgroundColor(Theme.primary).borderRadius(9)
      Text(text).fontSize(Theme.fsSmall).fontColor(Theme.textSecondary)
        .lineHeight(18).layoutWeight(1)
    }
    .width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  clubOnlyView() {
    Column({ space: 10 }) {
      Text('社团账号专属').fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody)
      Text('当前是平台管理员账号，没有所属社团。\n请在登录页选择「社团账号」并输入 club / club123。')
        .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
        .textAlign(TextAlign.Center).lineHeight(20)
      Button('返回').fontSize(Theme.fsBody).height(38).width(140)
        .backgroundColor(Theme.primary).fontColor(Theme.textOnPrimary)
        .onClick(() => router.back())
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    .padding({ left: 30, right: 30 })
  }

  build() {
    Column() {
      this.header()
      if (this.notAdmin) {
        AdminGuardView({ tip: '社团主页仅管理员可见' })
      } else if (this.notClub) {
        this.clubOnlyView()
      } else if (this.loading) {
        StateView({ kind: 'loading' })
      } else if (this.loadError !== '') {
        StateView({
          kind: 'error', title: '社团信息加载失败', desc: this.loadError,
          onRetry: () => {
            this.load();
          }
        })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            this.infoCard()
            this.leaderCard()
            this.historyCard()
            this.inheritCard()
          }
          .width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 20 })
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
