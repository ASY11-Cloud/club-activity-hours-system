/**
 * 社团活动报名与学时认定系统 —— 审核中心(仅管理员, 服务端审核, 通过自动累计学时)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { SignupInfo, parseSignups, statusText } from '../common/Models';

@Entry
@Component
struct AuditPage {
  @State all: SignupInfo[] = [];
  @State shown: SignupInfo[] = [];
  @State filter: number = -1; // -1 全部 0 待审核 1 通过 2 驳回
  @State msg: string = '';
  @State busy: boolean = false;
  @State blocked: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isAdmin) {
        this.blocked = true; // 无权限: 仅管理员可审核
        return;
      }
      this.load();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    if (!this.blocked) this.load();
  }

  async load(): Promise<void> {
    const resp = await ApiClient.get('/api/signup/list');
    if (resp['code'] === 0) {
      this.all = parseSignups(resp);
      this.msg = '共 ' + this.all.length + ' 条报名记录(来自服务器 MySQL)';
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
    }
    this.applyFilter();
  }

  /** 按状态过滤(结果写入 @State, UI 只读状态) */
  applyFilter(): void {
    if (this.filter === -1) {
      this.shown = this.all;
      return;
    }
    const out: SignupInfo[] = [];
    for (const s of this.all) {
      if (s.status === this.filter) out.push(s);
    }
    this.shown = out;
  }

  /** 审核确认弹窗(通过/驳回均不可逆, 防止误触) */
  confirmAudit(s: SignupInfo, action: string): void {
    AlertDialog.show({
      title: action === 'pass' ? '通过该报名?' : '驳回该报名?',
      message: action === 'pass'
        ? s.name + ' 报名「' + s.activity_title + '」\n通过后将自动累计 ' + s.hours + ' 学时'
        : s.name + ' 报名「' + s.activity_title + '」\n驳回后该成员需重新报名',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '确定',
        fontColor: action === 'pass' ? '#07C160' : '#E84026',
        action: () => this.audit(s, action)
      }
    });
  }

  /** 审核: 通过 -> 服务器自动累计学时 */
  async audit(s: SignupInfo, action: string): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const body: Record<string, Object> = {
        'signup_id': s.id,
        'action': action,
        'remark': action === 'pass' ? '管理员审核通过' : '管理员驳回'
      };
      const resp = await ApiClient.post('/api/signup/audit', body);
      if (resp['code'] === 0) {
        const data = resp['data'] as Record<string, Object>;
        this.msg = action === 'pass'
          ? '已通过, 自动累计学时 ' + (data['hours'] as number) + ' → 学时报表'
          : '已驳回';
      } else {
        this.msg = '审核失败: ' + (resp['msg'] as string);
      }
      await this.load();
    } finally {
      this.busy = false;
    }
  }

  @Builder
  item(s: SignupInfo) {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(s.name).fontSize(15).fontWeight(FontWeight.Medium)
          Text(s.stu_no).fontSize(12).fontColor('#999999')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(statusText(s.status))
          .fontSize(12)
          .fontColor(s.status === 1 ? '#07C160' : (s.status === 2 ? '#E84026' : '#B25E00'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(s.status === 1 ? '#E8F8EF' : (s.status === 2 ? '#FDECEA' : '#FFF3E0'))
          .borderRadius(8)
      }.width('100%')

      Text('活动: ' + s.activity_title).fontSize(13).fontColor('#333333').width('100%').margin({ top: 6 })
      Row() {
        Text('申请时间: ' + s.created_at).fontSize(11).fontColor('#BBBBBB')
        Text(s.checkin === 1 ? ' 已刷卡签到' : '').fontSize(11).fontColor('#1E6FFF')
      }.width('100%').margin({ top: 4 })

      if (s.status === 0) {
        Row({ space: 10 }) {
          Button('通过(累计' + s.hours + '学时)').layoutWeight(1).height(32).fontSize(13).backgroundColor('#07C160')
            .onClick(() => this.confirmAudit(s, 'pass'))
          Button('驳回').layoutWeight(1).height(32).fontSize(13).backgroundColor('#E84026')
            .onClick(() => this.confirmAudit(s, 'reject'))
        }.width('100%').margin({ top: 8 })
      } else {
        Text(s.status === 1 ? '认定学时: ' + s.hours : ('备注: ' + (s.remark === '' ? '—' : s.remark)))
          .fontSize(12).fontColor('#888888').width('100%').margin({ top: 6 })
      }
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔒').fontSize(40)
      Text('无权限访问').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('审核中心仅限管理员, 请以管理员身份登录后访问')
        .fontSize(12).fontColor('#999999').textAlign(TextAlign.Center)
      Button('返回首页').fontSize(14).height(38).backgroundColor('#1E6FFF')
        .onClick(() => router.back())
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }

  build() {
    Column() {
      if (this.blocked) {
        this.deniedView()
      } else {
        Row() {
          Text('审核中心').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('刷新').fontSize(13).height(30).backgroundColor('#1E6FFF')
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        // 筛选
        Row({ space: 8 }) {
          this.filterBtn('全部', -1)
          this.filterBtn('待审核', 0)
          this.filterBtn('已通过', 1)
          this.filterBtn('已驳回', 2)
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        Text(this.msg).fontSize(12).fontColor('#999999').width('100%').padding({ left: 14, bottom: 6 })

        if (this.shown.length === 0) {
          Column() {
            Text('暂无记录').fontSize(14).fontColor('#999999')
          }.width('100%').margin({ top: 60 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.shown, (s: SignupInfo) => {
                this.item(s)
              }, (s: SignupInfo) => s.id.toString())
            }.padding(14)
          }
          .layoutWeight(1).scrollBar(BarState.Off)
        }
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }

  @Builder
  filterBtn(label: string, f: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.filter === f ? Color.White : '#333333')
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.filter === f ? '#1E6FFF' : '#E9ECF3')
      .borderRadius(14)
      .onClick(() => {
        this.filter = f;
        this.applyFilter();
      })
  }
}
