/**
 * 社团活动报名与学时认定系统 —— 审核中心(仅管理员)
 * 两个模式:
 *  - 报名审核: 服务端筛选(状态/活动/关键词) + 分页, 通过自动累计学时
 *  - 注册申请: 审批新成员注册申请(同意/拒绝)
 * 筛选与分页都在服务端执行, 避免把全量报名拉到本地再过滤。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { AdminGuardView } from '../common/GuardViews';
import {
  SignupInfo, parseSignups, statusText, StudentRequest, parseStudentRequests,
  ActivityInfo, parseActivities, totalOf, hasMoreOf
} from '../common/Models';

@Entry
@Component
struct AuditPage {
  @State mode: number = 0;         // 0 报名审核 | 1 注册申请
  @State rows: SignupInfo[] = [];  // 当前页报名记录(服务端过滤 + 分页)
  @State filter: number = -1;      // -1 全部 0 待审核 1 通过 2 驳回
  @State kw: string = '';          // 已生效的搜索词(服务端 LIKE 姓名/学号/活动名)
  @State kwInput: string = '';     // 输入框内容(点搜索后才生效)
  @State actIndex: number = 0;     // 活动筛选下标(0 = 全部活动)
  @State actNames: string[] = ['全部活动'];
  @State actIds: number[] = [0];
  @State actOptions: SelectOption[] = [{ value: '全部活动' }];
  @State page: number = 1;
  @State total: number = 0;
  @State hasMore: boolean = false;
  @State loading: boolean = false;
  @State regs: StudentRequest[] = [];
  @State msg: string = '';
  @State busy: boolean = false;
  @State blocked: boolean = false;
  private readonly PAGE_SIZE: number = 20;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isAdmin) {
        this.blocked = true; // 无权限: 仅管理员可审核
        return;
      }
      this.loadActOptions();
      this.load(true);
      this.loadRegs();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    if (!this.blocked) {
      this.load(true);
      this.loadRegs();
    }
  }

  /** 活动下拉选项(含已下线, 便于筛选历史活动的报名) */
  async loadActOptions(): Promise<void> {
    const resp = await ApiClient.get('/api/activity/list?all=1');
    if (resp['code'] !== 0) return;
    const list: ActivityInfo[] = parseActivities(resp);
    const names: string[] = ['全部活动'];
    const ids: number[] = [0];
    const opts: SelectOption[] = [{ value: '全部活动' }];
    for (const a of list) {
      names.push(a.title);
      ids.push(a.id);
      const o: SelectOption = { value: a.title };
      opts.push(o);
    }
    this.actNames = names;
    this.actIds = ids;
    this.actOptions = opts;
    if (this.actIndex >= names.length) this.actIndex = 0;
  }

  /** 组装服务端查询串(状态/活动/关键词/分页) */
  buildPath(): string {
    let q = '/api/signup/list?page=' + this.page.toString() + '&size=' + this.PAGE_SIZE.toString();
    if (this.filter >= 0) q += '&status=' + this.filter.toString();
    const k = this.kw.trim();
    if (k !== '') q += '&kw=' + encodeURIComponent(k);
    const aid = this.actIndex < this.actIds.length ? this.actIds[this.actIndex] : 0;
    if (aid > 0) q += '&activity_id=' + aid.toString();
    return q;
  }

  /** 拉取报名列表: reset=true 回到第 1 页 */
  async load(reset: boolean): Promise<void> {
    if (this.loading) return;
    if (reset) this.page = 1;
    this.loading = true;
    const resp = await ApiClient.get(this.buildPath());
    if (resp['code'] === 0) {
      this.rows = parseSignups(resp);
      this.total = totalOf(resp);
      this.hasMore = hasMoreOf(resp);
      this.msg = '共 ' + this.total + ' 条记录(服务端筛选, 第 ' + this.page + ' 页)';
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
    }
    this.loading = false;
  }

  /** 审核完成/翻页后重载当前页(当前页为空且不是第 1 页时回退一页) */
  async reloadCurrent(): Promise<void> {
    await this.load(false);
    if (this.rows.length === 0 && this.page > 1) {
      this.page = this.page - 1;
      await this.load(false);
    }
  }

  prevPage(): void {
    if (this.page <= 1) return;
    this.page = this.page - 1;
    this.load(false);
  }

  nextPage(): void {
    if (!this.hasMore) return;
    this.page = this.page + 1;
    this.load(false);
  }

  async loadRegs(): Promise<void> {
    const resp = await ApiClient.get('/api/student/requests');
    if (resp['code'] === 0) {
      this.regs = parseStudentRequests(resp);
    } else {
      // 注册申请拉取失败不打断报名审核主流程
      console.error('loadRegs failed: ' + (resp['msg'] as string));
    }
  }

  /** 该报名通过后实际累计的学时: 优先取活动学时(服务端按活动学时累计), 旧响应回退记录学时 */
  passHours(s: SignupInfo): number {
    return s.activity_hours > 0 ? s.activity_hours : s.hours;
  }

  /** 报名审核确认弹窗(通过/驳回均不可逆, 防止误触) */
  confirmAudit(s: SignupInfo, action: string): void {
    AlertDialog.show({
      title: action === 'pass' ? '通过该报名?' : '驳回该报名?',
      message: action === 'pass'
        ? s.name + ' 报名「' + s.activity_title + '」\n通过后将自动累计 ' + this.passHours(s) + ' 学时'
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
      await this.reloadCurrent();
    } finally {
      this.busy = false;
    }
  }

  /** 注册申请审批确认弹窗 */
  confirmReg(r: StudentRequest, action: string): void {
    AlertDialog.show({
      title: action === 'pass' ? '同意该注册申请?' : '拒绝该注册申请?',
      message: r.name + ' (' + r.stu_no + ', ' + r.dept + ')\n' +
        (action === 'pass' ? '同意后该成员即可登录系统' : '拒绝后该成员无法登录, 需联系管理员'),
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
        action: () => this.auditReg(r, action)
      }
    });
  }

  /** 审批注册申请: 同意(status=1 可登录) / 拒绝(status=2) */
  async auditReg(r: StudentRequest, action: string): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const body: Record<string, Object> = {
        'student_id': r.id,
        'action': action
      };
      const resp = await ApiClient.post('/api/student/audit', body);
      if (resp['code'] === 0) {
        this.msg = action === 'pass'
          ? '已同意 ' + r.name + ' 的注册申请, 现在可以登录了'
          : '已拒绝 ' + r.name + ' 的注册申请';
      } else {
        this.msg = '审批失败: ' + (resp['msg'] as string);
      }
      await this.loadRegs();
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
          Button('通过(累计' + this.passHours(s) + '学时)').layoutWeight(1).height(32).fontSize(13).backgroundColor('#07C160')
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
  regItem(r: StudentRequest) {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(r.name).fontSize(15).fontWeight(FontWeight.Medium)
          Text(r.stu_no).fontSize(12).fontColor('#999999')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('待审批')
          .fontSize(12).fontColor('#B25E00')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor('#FFF3E0').borderRadius(8)
      }.width('100%')

      Row() {
        Text('班级: ' + (r.dept === '' ? '—' : r.dept)).fontSize(13).fontColor('#333333')
      }.width('100%').margin({ top: 6 })
      Row() {
        Text('申请时间: ' + r.created_at).fontSize(11).fontColor('#BBBBBB')
        Text(r.card_no !== '' ? ' 已绑定RFID卡' : '').fontSize(11).fontColor('#1E6FFF')
      }.width('100%').margin({ top: 4 })

      Row({ space: 10 }) {
        Button('同意').layoutWeight(1).height(32).fontSize(13).backgroundColor('#07C160')
          .onClick(() => this.confirmReg(r, 'pass'))
        Button('拒绝').layoutWeight(1).height(32).fontSize(13).backgroundColor('#E84026')
          .onClick(() => this.confirmReg(r, 'reject'))
      }.width('100%').margin({ top: 8 })
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    AdminGuardView({ tip: '审核中心仅限管理员, 请以管理员身份登录后访问' })
  }

  @Builder
  modeBtn(label: string, m: number) {
    Column({ space: 3 }) {
      Text(label).fontSize(13).fontWeight(FontWeight.Bold)
        .fontColor(this.mode === m ? Color.White : '#333333')
      if (m === 1 && this.regs.length > 0) {
        Text(this.regs.length + ' 条待审批').fontSize(9)
          .fontColor(this.mode === m ? 'rgba(255,255,255,0.85)' : '#F5652F')
      }
    }
    .layoutWeight(1)
    .padding({ top: 9, bottom: 9 })
    .backgroundColor(this.mode === m ? '#1E6FFF' : '#E9ECF3')
    .borderRadius(12)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.mode = m;
    })
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
        if (this.filter === f) return;
        this.filter = f;
        this.load(true);   // 状态筛选在服务端执行, 切换后回到第 1 页
      })
  }

  @Builder
  pager() {
    Row({ space: 10 }) {
      Button('‹ 上一页').fontSize(12).height(30).layoutWeight(1)
        .backgroundColor(this.page > 1 ? '#E9ECF3' : '#F3F4F6')
        .fontColor(this.page > 1 ? '#333333' : '#BBBBBB')
        .enabled(this.page > 1)
        .onClick(() => this.prevPage())
      Text('第 ' + this.page + ' 页 · 共 ' + this.total + ' 条')
        .fontSize(11).fontColor('#999999')
      Button('下一页 ›').fontSize(12).height(30).layoutWeight(1)
        .backgroundColor(this.hasMore ? '#E9ECF3' : '#F3F4F6')
        .fontColor(this.hasMore ? '#333333' : '#BBBBBB')
        .enabled(this.hasMore)
        .onClick(() => this.nextPage())
    }.width('100%').padding({ left: 14, right: 14, top: 6, bottom: 8 })
  }

  build() {
    Column() {
      if (this.blocked) {
        this.deniedView()
      } else {
        Row() {
          Text('‹ 返回').fontSize(14).fontColor('#1E6FFF')
            .padding({ right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('审核中心').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('刷新').fontSize(13).height(30).backgroundColor('#1E6FFF')
            .onClick(() => {
              this.load(true);
              this.loadRegs();
            })
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        // 模式切换: 报名审核 / 注册申请
        Row({ space: 10 }) {
          this.modeBtn('报名审核', 0)
          this.modeBtn('注册申请', 1)
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        if (this.mode === 0) {
          // ---- 报名审核: 活动下拉 + 关键词搜索(均在服务端生效) ----
          Row({ space: 8 }) {
            TextInput({ text: this.kwInput, placeholder: '搜索姓名 / 学号 / 活动名' })
              .layoutWeight(1).height(34).fontSize(13)
              .onChange((v: string) => this.kwInput = v)
              .onSubmit(() => {
                this.kw = this.kwInput;
                this.load(true);
              })
            Button('搜索').fontSize(12).height(34).backgroundColor('#1E6FFF')
              .onClick(() => {
                this.kw = this.kwInput;
                this.load(true);
              })
            if (this.kw !== '') {
              Button('清除').fontSize(12).height(34).backgroundColor('#999999')
                .onClick(() => {
                  this.kwInput = '';
                  this.kw = '';
                  this.load(true);
                })
            }
          }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

          Row({ space: 8 }) {
            Text('活动:').fontSize(12).fontColor('#666666')
            Select(this.actOptions)
              .selected(this.actIndex)
              .value(this.actIndex < this.actNames.length ? this.actNames[this.actIndex] : '全部活动')
              .font({ size: 12 })
              .layoutWeight(1)
              .onSelect((index: number) => {
                this.actIndex = index;
                this.load(true);
              })
          }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

          Row({ space: 8 }) {
            this.filterBtn('全部', -1)
            this.filterBtn('待审核', 0)
            this.filterBtn('已通过', 1)
            this.filterBtn('已驳回', 2)
          }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

          Text(this.msg).fontSize(12).fontColor('#999999').width('100%').padding({ left: 14, bottom: 6 })

          if (this.rows.length === 0) {
            Column({ space: 6 }) {
              Text(this.loading ? '加载中...' : '没有符合条件的记录').fontSize(14).fontColor('#999999')
              if (!this.loading) {
                Text('可切换状态/活动筛选, 或清除搜索关键词').fontSize(11).fontColor('#BBBBBB')
              }
            }.width('100%').margin({ top: 60 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.rows, (s: SignupInfo) => {
                  this.item(s)
                }, (s: SignupInfo) => s.id.toString() + '-' + s.status.toString() + '-' + s.checkin.toString())
              }.padding({ left: 14, right: 14 })
            }
            .layoutWeight(1).scrollBar(BarState.Off)
          }

          this.pager()
        } else {
          // ---- 注册申请 ----
          Text(this.regs.length === 0 ? '暂无待审批的注册申请' : '共 ' + this.regs.length + ' 条注册申请待审批')
            .fontSize(12).fontColor('#999999').width('100%').padding({ left: 14, bottom: 6 })

          if (this.regs.length === 0) {
            Column() {
              Text('暂无记录').fontSize(14).fontColor('#999999')
              Text('新成员在 App 提交注册后会出现在这里').fontSize(11).fontColor('#BBBBBB').margin({ top: 6 })
            }.width('100%').margin({ top: 60 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.regs, (r: StudentRequest) => {
                  this.regItem(r)
                }, (r: StudentRequest) => r.id.toString() + '-' + r.stu_no)
              }.padding(14)
            }
            .layoutWeight(1).scrollBar(BarState.Off)
          }
        }
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
