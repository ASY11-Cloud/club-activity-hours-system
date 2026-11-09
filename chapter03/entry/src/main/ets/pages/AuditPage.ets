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
  ActivityInfo, parseActivities, totalOf, hasMoreOf, categoryText,
  AppealInfo, parseAppeals
} from '../common/Models';
import { Theme } from '../common/Theme';
import { TimeFmt } from '../common/TimeFmt';

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
  // 注册审批时可补绑 RFID 卡号(按 student.id 索引; 注册时没填卡号就在这里补)
  @State regCard: Record<string, string> = {};
  @State msg: string = '';
  @State msgError: boolean = false;   // msg 是否为失败提示(染红显示, 成功为灰色)
  @State busy: boolean = false;
  @State blocked: boolean = false;
  // 驳回理由: 内联填写(不可用 AlertDialog, 弹窗放不下输入框)
  @State rejectId: number = -1;
  @State rejectInput: string = '';
  @State pendingCount: number = 0;   // 待审报名总数, 用于"全部通过(N)"
  @State batchBusy: boolean = false;
  // ---- v4.0 学时申诉 ----
  @State appeals: AppealInfo[] = [];
  @State appealTotal: number = 0;
  @State appealPending: number = 0;
  @State appealFilter: number = 0;      // 默认只看待处理
  @State appealBusy: boolean = false;
  @State apPanelId: number = -1;        // 正在处理(展开输入)的申诉 id
  @State apPanelAction: string = '';    // pass | reject
  @State apReply: string = '';
  @State apHours: string = '';
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
      this.loadPendingCount();
      this.loadAppeals();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    if (!this.blocked) {
      this.load(true);
      this.loadRegs();
      this.loadPendingCount();
      this.loadAppeals();
    }
  }

  /** 待审报名总数(角标与批量通过按钮用) */
  async loadPendingCount(): Promise<void> {
    const resp = await ApiClient.get('/api/stats/pending');
    if (resp['code'] !== 0) return;
    const d = resp['data'] as Record<string, Object>;
    this.pendingCount = Number(d['signup_pending']);
  }

  // ==================== v4.0 学时申诉 ====================

  async loadAppeals(): Promise<void> {
    let q = '/api/appeal/list?page=1&size=50';
    if (this.appealFilter >= 0) q += '&status=' + this.appealFilter.toString();
    const resp = await ApiClient.get(q);
    if (resp['code'] === 0) {
      this.appeals = parseAppeals(resp);
      this.appealTotal = totalOf(resp);
    }
    const p = await ApiClient.get('/api/appeal/list?status=0&page=1&size=1');
    if (p['code'] === 0) this.appealPending = totalOf(p);
  }

  pendingAppeals(): number {
    let n = 0;
    for (const a of this.appeals) if (a.status === 0) n++;
    return n;
  }

  startAppealAudit(a: AppealInfo, action: string): void {
    this.apPanelId = a.id;
    this.apPanelAction = action;
    this.apReply = '';
    this.apHours = a.signup_hours.toString();
    this.msg = '';
    this.msgError = false;
  }

  async submitAppealAudit(a: AppealInfo): Promise<void> {
    if (this.appealBusy) return;
    if (this.apPanelAction === 'reject' && this.apReply.trim().length < 2) {
      this.msg = '驳回需填写原因(至少 2 个字), 学生端会看到';
      this.msgError = true;
      return;
    }
    const hours = Number(this.apHours);
    if (this.apPanelAction === 'pass') {
      if (isNaN(hours) || hours < 0 || hours > a.activity_hours) {
        this.msg = '调整学时应在 0 ~ ' + a.activity_hours.toString() + ' 之间';
        this.msgError = true;
        return;
      }
    }
    this.appealBusy = true;
    const body: Record<string, Object> = {
      'appeal_id': a.id,
      'action': this.apPanelAction,
      'reply': this.apReply.trim()
    };
    if (this.apPanelAction === 'pass') body['hours'] = hours;
    const resp = await ApiClient.post('/api/appeal/audit', body);
    this.appealBusy = false;
    if (resp['code'] === 0) {
      const d = resp['data'] as Record<string, Object>;
      const after = Number(d['hours_after']);
      this.msg = this.apPanelAction === 'pass'
        ? '申诉已通过, 认定学时调整为 ' + after + ' 学时'
        : '申诉已驳回';
      this.msgError = false;
      this.apPanelId = -1;
      this.apReply = '';
      await this.loadAppeals();
      await this.load(false);   // 学时变化同步刷新报名列表
    } else {
      this.msg = '处理失败: ' + (resp['msg'] as string);
      this.msgError = true;
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
      this.msgError = false;
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
      this.msgError = true;
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

  /** 通过确认弹窗(不可逆操作, 防误触); 驳回走内联填理由, 不用弹窗 */
  confirmPass(s: SignupInfo): void {
    AlertDialog.show({
      title: '通过该报名?',
      message: s.name + ' 报名「' + s.activity_title + '」\n通过后将自动累计 ' + this.passHours(s) + ' 学时',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '通过',
        fontColor: Theme.success,
        action: () => this.audit(s, 'pass', '管理员审核通过')
      }
    });
  }

  /** 展开驳回理由输入(内联, 不用弹窗: 弹窗放不下输入框) */
  startReject(s: SignupInfo): void {
    this.rejectId = s.id;
    this.rejectInput = '';
  }

  cancelReject(): void {
    this.rejectId = -1;
    this.rejectInput = '';
  }

  /** 提交驳回: 理由必填, 成员端会原样看到 */
  async submitReject(s: SignupInfo): Promise<void> {
    const r = this.rejectInput.trim();
    if (r.length < 2) {
      this.msg = '请填写驳回理由(至少 2 个字), 成员会看到这条理由';
      return;
    }
    await this.audit(s, 'reject', r);
  }

  /** 审核: 通过 -> 服务器自动累计学时; 驳回 -> 理由写入 remark */
  async audit(s: SignupInfo, action: string, remark: string): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const body: Record<string, Object> = {
        'signup_id': s.id,
        'action': action,
        'remark': remark
      };
      const resp = await ApiClient.post('/api/signup/audit', body);
      if (resp['code'] === 0) {
        const data = resp['data'] as Record<string, Object>;
        const capped: boolean = data['hours_capped'] === true;
        this.msg = action === 'pass'
          ? '已通过 ' + s.name + ', 自动累计学时 ' + (data['hours'] as number) +
            (capped ? '(超出' + categoryText(s.category) + '类别上限, 已按规则折算)' : '')
          : '已驳回 ' + s.name + ', 理由已同步给成员';
        this.msgError = false;
        this.rejectId = -1;
        this.rejectInput = '';
      } else {
        // 典型场景: 学生在管理员点通过前撤销了报名 —— 服务端 404 的中文原因
        // 经 ApiClient 透传到这里, 弹 toast + 染红提示, 并刷新列表让该行消失
        this.msg = '审核失败: ' + (resp['msg'] as string);
        this.msgError = true;
      }
      await this.reloadCurrent();
      await this.loadPendingCount();
    } finally {
      this.busy = false;
    }
  }

  /** 批量通过: 逐条调用审核接口(服务端仍逐条校验事务与幂等, 不是绕过审核) */
  confirmPassAll(): void {
    if (this.pendingCount <= 0) return;
    const n: number = this.pendingCount > 100 ? 100 : this.pendingCount;
    AlertDialog.show({
      title: '全部通过?',
      message: '将一次性通过约 ' + n + ' 条待审核报名, 并按各活动学时自动累计。\n该操作不可撤销, 建议先确认名单。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '全部通过',
        fontColor: Theme.success,
        action: () => this.passAll()
      }
    });
  }

  async passAll(): Promise<void> {
    if (this.batchBusy) return;
    this.batchBusy = true;
    this.msg = '正在批量通过...';
    let ok = 0;
    let fail = 0;
    try {
      // 每轮都取"第 1 页待审", 通过的记录不再命中, 因此不会重复处理同一条
      for (let round = 0; round < 5; round++) {
        const resp = await ApiClient.get('/api/signup/list?status=0&size=20&page=1');
        if (resp['code'] !== 0) {
          this.msg = '批量通过失败: ' + (resp['msg'] as string);
          this.msgError = true;
          return;
        }
        const list: SignupInfo[] = parseSignups(resp);
        if (list.length === 0) break;
        let roundOk = 0;
        for (const s of list) {
          const body: Record<string, Object> = {
            'signup_id': s.id, 'action': 'pass', 'remark': '管理员批量通过'
          };
          // silent: 批量逐条调用, 失败由下方汇总统计展示, 不逐条弹 toast 刷屏
          const r = await ApiClient.post('/api/signup/audit', body, true);
          if (r['code'] === 0) {
            ok++;
            roundOk++;
          } else {
            fail++;
          }
        }
        // 本轮一条都没成功说明有系统性失败, 继续只会空转
        if (roundOk === 0) break;
      }
      this.msg = '批量通过完成: 成功 ' + ok + ' 条' + (fail > 0 ? ', 失败 ' + fail + ' 条' : '');
      this.msgError = fail > 0;
      await this.load(true);
      await this.loadPendingCount();
    } finally {
      this.batchBusy = false;
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
        fontColor: action === 'pass' ? Theme.success : Theme.danger,
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
      const typed = this.regCard[r.id.toString()];
      const card = (typed === undefined || typed === null) ? '' : typed.trim().toUpperCase();
      if (action === 'pass' && card !== '') {
        body['card_no'] = card;   // 仅在通过时绑定, 拒绝不写卡号
      }
      const resp = await ApiClient.post('/api/student/audit', body);
      if (resp['code'] === 0) {
        this.msg = action === 'pass'
          ? '已同意 ' + r.name + ' 的注册申请, 现在可以登录了'
          : '已拒绝 ' + r.name + ' 的注册申请';
        this.msgError = false;
      } else {
        // 该申请可能刚被其他管理员处理过 —— 服务端原因透传展示
        this.msg = '审批失败: ' + (resp['msg'] as string);
        this.msgError = true;
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
          Text(s.stu_no).fontSize(12).fontColor(Theme.textTertiary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(statusText(s.status))
          .fontSize(12)
          .fontColor(s.status === 1 ? Theme.success : (s.status === 2 ? Theme.danger : Theme.warning))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(s.status === 1 ? Theme.successBg : (s.status === 2 ? Theme.dangerBg : Theme.warningBg))
          .borderRadius(8)
      }.width('100%')

      Text('活动: ' + s.activity_title).fontSize(Theme.fsBody).fontColor(Theme.textBody)
        .width('100%').margin({ top: 6 })
      Row({ space: 6 }) {
        Text(categoryText(s.category))
          .fontSize(Theme.fsCaption).fontColor(Theme.report)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor(Theme.reportBg).borderRadius(Theme.radiusSm)
        // 待审核记录 hours 仍为 0, 展示活动原学时; 通过后服务端可能按类别上限裁剪
        Text('活动学时 ' + s.activity_hours + (s.status === 1 ? ' · 认定 ' + s.hours : ''))
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }.width('100%').margin({ top: 4 })
      Row({ space: 10 }) {
        Text('报名: ' + TimeFmt.short(s.created_at)).fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
        if (s.checkin === 1) {
          Text(s.checkin_at === '' ? '已刷卡签到' : '已刷卡 ' + TimeFmt.short(s.checkin_at))
            .fontSize(Theme.fsCaption).fontColor(Theme.signin)
        }
      }.width('100%').margin({ top: 4 })

      if (s.status === 0) {
        if (this.rejectId === s.id) {
          // 驳回理由内联填写: 弹窗放不下输入框, 且这理由要展示给成员
          Column({ space: 8 }) {
            TextInput({ text: this.rejectInput, placeholder: '驳回理由(必填, 成员会看到)' })
              .height(38).fontSize(Theme.fsSmall).width('100%')
              .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusSm)
              .onChange((v: string) => this.rejectInput = v)
            Row({ space: 10 }) {
              Button('取消').layoutWeight(1).height(34).fontSize(Theme.fsSmall)
                .backgroundColor(Theme.bgNeutral).fontColor(Theme.textSecondary)
                .onClick(() => this.cancelReject())
              Button('确认驳回').layoutWeight(1).height(34).fontSize(Theme.fsSmall)
                .backgroundColor(Theme.danger)
                .onClick(() => this.submitReject(s))
            }.width('100%')
          }
          .width('100%').margin({ top: 8 }).padding(10)
          .backgroundColor(Theme.dangerBg).borderRadius(Theme.radiusSm)
        } else {
          Row({ space: 10 }) {
            Button('通过(+' + this.passHours(s) + '学时)')
              .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
              .backgroundColor(Theme.success)
              .onClick(() => this.confirmPass(s))
            Button('驳回')
              .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
              .backgroundColor(Theme.dangerBg).fontColor(Theme.danger)
              .onClick(() => this.startReject(s))
          }.width('100%').margin({ top: 8 })
        }
      } else {
        Column({ space: 3 }) {
          Text(s.status === 1 ? '认定学时: ' + s.hours : '驳回理由: ' + (s.remark === '' ? '—' : s.remark))
            .fontSize(Theme.fsSmall)
            .fontColor(s.status === 1 ? Theme.success : Theme.danger)
            .width('100%')
          if (s.audited_at !== '') {
            Text('审核时间: ' + TimeFmt.short(s.audited_at))
              .fontSize(Theme.fsCaption).fontColor(Theme.textDisabled).width('100%')
          }
        }.width('100%').margin({ top: 6 })
      }
    }
    .width('100%').padding(12).backgroundColor(Theme.bgCard).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  regItem(r: StudentRequest) {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(r.name).fontSize(15).fontWeight(FontWeight.Medium)
          Text(r.stu_no).fontSize(12).fontColor(Theme.textTertiary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('待审批')
          .fontSize(12).fontColor(Theme.warning)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(Theme.warningBg).borderRadius(8)
      }.width('100%')

      Row() {
        Text('班级: ' + (r.dept === '' ? '—' : r.dept)).fontSize(13).fontColor(Theme.textBody)
      }.width('100%').margin({ top: 6 })
      Row() {
        Text('申请时间: ' + r.created_at).fontSize(11).fontColor(Theme.textDisabled)
        Text(r.card_no !== '' ? ' 已绑定RFID卡' : '').fontSize(11).fontColor(Theme.primary)
      }.width('100%').margin({ top: 4 })

      // 补绑卡号: 注册时未填卡号的成员, 在这里填了才能刷卡签到
      if (r.card_no === '') {
        Row({ space: 8 }) {
          Text('卡号').fontSize(12).fontColor(Theme.textSecondary)
          TextInput({ text: this.regCard[r.id.toString()] ?? '', placeholder: '选填: 审核通过时绑定 RFID 卡' })
            .layoutWeight(1).height(34).fontSize(12).maxLength(32)
            .onChange((v: string) => {
              this.regCard[r.id.toString()] = v;
            })
        }.width('100%').margin({ top: 8 })
      }

      Row({ space: 10 }) {
        Button('同意').layoutWeight(1).height(32).fontSize(13).backgroundColor(Theme.success)
          .onClick(() => this.confirmReg(r, 'pass'))
        Button('拒绝').layoutWeight(1).height(32).fontSize(13).backgroundColor(Theme.danger)
          .onClick(() => this.confirmReg(r, 'reject'))
      }.width('100%').margin({ top: 8 })
    }
    .width('100%').padding(12).backgroundColor(Theme.bgCard).borderRadius(12).margin({ bottom: 8 })
  }

  appealStatusText(s: number): string {
    if (s === 1) return '已通过';
    if (s === 2) return '已驳回';
    return '待处理';
  }

  appealColor(s: number): ResourceColor {
    if (s === 1) return Theme.success;
    if (s === 2) return Theme.danger;
    return Theme.warning;
  }

  appealBg(s: number): ResourceColor {
    if (s === 1) return Theme.successBg;
    if (s === 2) return Theme.dangerBg;
    return Theme.warningBg;
  }

  @Builder
  appealItem(a: AppealInfo) {
    Column({ space: 6 }) {
      Row() {
        Column({ space: 2 }) {
          Text(a.name).fontSize(15).fontWeight(FontWeight.Medium)
          Text(a.stu_no).fontSize(12).fontColor(Theme.textTertiary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.appealStatusText(a.status))
          .fontSize(12).fontColor(this.appealColor(a.status))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(this.appealBg(a.status)).borderRadius(8)
      }.width('100%')

      Text('活动: ' + a.activity_title).fontSize(Theme.fsBody).fontColor(Theme.textBody)
        .width('100%').margin({ top: 4 })
      Text('申诉前认定 ' + a.hours_before + ' 学时 · 活动学时 ' + a.activity_hours)
        .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary).width('100%')
      Text('理由: ' + a.reason).fontSize(Theme.fsSmall).fontColor(Theme.textSecondary)
        .width('100%').padding(8).backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusSm)

      if (a.status === 0) {
        if (this.apPanelId === a.id) {
          Column({ space: 8 }) {
            if (this.apPanelAction === 'pass') {
              Row({ space: 8 }) {
                Text('认定学时').fontSize(12).fontColor(Theme.textSecondary)
                TextInput({ text: this.apHours, placeholder: '0 ~ ' + a.activity_hours.toString() })
                  .type(InputType.NUMBER_DECIMAL).layoutWeight(1).height(36).fontSize(13)
                  .onChange((v: string) => this.apHours = v)
              }.width('100%')
            }
            TextInput({ text: this.apReply,
              placeholder: this.apPanelAction === 'pass' ? '答复(选填)' : '驳回原因(必填, 学生可见)' })
              .height(36).fontSize(13).width('100%')
              .onChange((v: string) => this.apReply = v)
            Row({ space: 10 }) {
              Button('取消').layoutWeight(1).height(34).fontSize(Theme.fsSmall)
                .backgroundColor(Theme.bgNeutral).fontColor(Theme.textSecondary)
                .onClick(() => { this.apPanelId = -1; this.apReply = ''; })
              Button(this.appealBusy ? '提交中...' : (this.apPanelAction === 'pass' ? '确认通过' : '确认驳回'))
                .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
                .backgroundColor(this.apPanelAction === 'pass' ? Theme.success : Theme.danger)
                .enabled(!this.appealBusy)
                .onClick(() => this.submitAppealAudit(a))
            }.width('100%')
          }
          .width('100%').padding(10).margin({ top: 4 })
          .backgroundColor(Theme.primaryBg).borderRadius(Theme.radiusSm)
        } else {
          Row({ space: 10 }) {
            Button('通过并调整学时')
              .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
              .backgroundColor(Theme.success)
              .onClick(() => this.startAppealAudit(a, 'pass'))
            Button('驳回')
              .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
              .backgroundColor(Theme.dangerBg).fontColor(Theme.danger)
              .onClick(() => this.startAppealAudit(a, 'reject'))
          }.width('100%').margin({ top: 6 })
        }
      } else {
        Column({ space: 3 }) {
          Text(a.status === 1
            ? '复核结果: ' + a.hours_after + ' 学时'
            : '驳回原因: ' + (a.reply === '' ? '—' : a.reply))
            .fontSize(Theme.fsSmall)
            .fontColor(a.status === 1 ? Theme.success : Theme.danger).width('100%')
          Text('处理: ' + a.handler + ' · ' + TimeFmt.short(a.handled_at))
            .fontSize(Theme.fsCaption).fontColor(Theme.textDisabled).width('100%')
        }.width('100%').margin({ top: 4 })
      }
    }
    .width('100%').padding(12).backgroundColor(Theme.bgCard).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    AdminGuardView({ tip: '审核中心仅限管理员, 请以管理员身份登录后访问' })
  }

  @Builder
  modeBtn(label: string, m: number) {
    Column({ space: 3 }) {
      Text(label).fontSize(13).fontWeight(FontWeight.Bold)
        .fontColor(this.mode === m ? Theme.textOnPrimary : Theme.textBody)
      if (m === 1 && this.regs.length > 0) {
        Text(this.regs.length + ' 条待审批').fontSize(9)
          .fontColor(this.mode === m ? 'rgba(255,255,255,0.85)' : Theme.admin)
      }
      if (m === 2 && this.appealPending > 0) {
        Text(this.appealPending + ' 条待处理').fontSize(9)
          .fontColor(this.mode === m ? 'rgba(255,255,255,0.85)' : Theme.warning)
      }
    }
    .layoutWeight(1)
    .padding({ top: 9, bottom: 9 })
    .backgroundColor(this.mode === m ? Theme.primary : Theme.bgNeutral)
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
      .fontColor(this.filter === f ? Theme.textOnPrimary : Theme.textBody)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.filter === f ? Theme.primary : Theme.bgNeutral)
      .borderRadius(14)
      .onClick(() => {
        if (this.filter === f) return;
        this.filter = f;
        this.load(true);   // 状态筛选在服务端执行, 切换后回到第 1 页
      })
  }

  @Builder
  appealFilterBtn(label: string, f: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.appealFilter === f ? Theme.textOnPrimary : Theme.textBody)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.appealFilter === f ? Theme.primary : Theme.bgNeutral)
      .borderRadius(14)
      .onClick(() => {
        if (this.appealFilter === f) return;
        this.appealFilter = f;
        this.apPanelId = -1;
        this.loadAppeals();
      })
  }

  @Builder
  pager() {
    Row({ space: 10 }) {
      Button('‹ 上一页').fontSize(12).height(30).layoutWeight(1)
        .backgroundColor(this.page > 1 ? Theme.bgNeutral : Theme.bgSubtle)
        .fontColor(this.page > 1 ? Theme.textBody : Theme.textDisabled)
        .enabled(this.page > 1)
        .onClick(() => this.prevPage())
      Text('第 ' + this.page + ' 页 · 共 ' + this.total + ' 条')
        .fontSize(11).fontColor(Theme.textTertiary)
      Button('下一页 ›').fontSize(12).height(30).layoutWeight(1)
        .backgroundColor(this.hasMore ? Theme.bgNeutral : Theme.bgSubtle)
        .fontColor(this.hasMore ? Theme.textBody : Theme.textDisabled)
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
          Text('‹ 返回').fontSize(14).fontColor(Theme.primary)
            .padding({ right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('审核中心').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('刷新').fontSize(13).height(30).backgroundColor(Theme.primary)
            .onClick(() => {
              this.load(true);
              this.loadRegs();
              this.loadAppeals();
            })
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        // 模式切换: 报名审核 / 注册申请
        Row({ space: 10 }) {
          this.modeBtn('报名审核', 0)
          this.modeBtn('注册申请', 1)
          this.modeBtn('学时申诉', 2)
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
            Button('搜索').fontSize(12).height(34).backgroundColor(Theme.primary)
              .onClick(() => {
                this.kw = this.kwInput;
                this.load(true);
              })
            if (this.kw !== '') {
              Button('清除').fontSize(12).height(34).backgroundColor(Theme.textTertiary)
                .onClick(() => {
                  this.kwInput = '';
                  this.kw = '';
                  this.load(true);
                })
            }
          }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

          Row({ space: 8 }) {
            Text('活动:').fontSize(12).fontColor(Theme.textSecondary)
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

          Row() {
            Text(this.msg).fontSize(Theme.fsSmall)
              .fontColor(this.msgError ? Theme.danger : Theme.textTertiary)
              .fontWeight(this.msgError ? FontWeight.Medium : FontWeight.Normal)
              .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.pendingCount > 0) {
              Text(this.batchBusy ? '批量处理中...' : '全部通过(' + this.pendingCount + ')')
                .fontSize(Theme.fsSmall).fontColor(Theme.success)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(Theme.successBg).borderRadius(Theme.radiusPill)
                .margin({ left: 8 })
                .onClick(() => {
                  if (!this.batchBusy) this.confirmPassAll();
                })
            }
          }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

          if (this.rows.length === 0) {
            Column({ space: 6 }) {
              Text(this.loading ? '加载中...' : '没有符合条件的记录').fontSize(14).fontColor(Theme.textTertiary)
              if (!this.loading) {
                Text('可切换状态/活动筛选, 或清除搜索关键词').fontSize(11).fontColor(Theme.textDisabled)
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
            .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
          }

          this.pager()
        } else if (this.mode === 1) {
          // ---- 注册申请 ----
          Text(this.regs.length === 0 ? '暂无待审批的注册申请' : '共 ' + this.regs.length + ' 条注册申请待审批')
            .fontSize(12).fontColor(Theme.textTertiary).width('100%').padding({ left: 14, bottom: 6 })

          if (this.regs.length === 0) {
            Column() {
              Text('暂无记录').fontSize(14).fontColor(Theme.textTertiary)
              Text('新成员在 App 提交注册后会出现在这里').fontSize(11).fontColor(Theme.textDisabled).margin({ top: 6 })
            }.width('100%').margin({ top: 60 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.regs, (r: StudentRequest) => {
                  this.regItem(r)
                }, (r: StudentRequest) => r.id.toString() + '-' + r.stu_no)
              }.padding(14)
            }
            .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
          }
        } else {
          // ---- 学时申诉(v4.0): 学生在"我的报名"发起, 管理员在这里复核 ----
          Row({ space: 8 }) {
            this.appealFilterBtn('待处理', 0)
            this.appealFilterBtn('已通过', 1)
            this.appealFilterBtn('已驳回', 2)
            this.appealFilterBtn('全部', -1)
          }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

          Text('共 ' + this.appealTotal + ' 条申诉' +
            (this.appealPending > 0 ? ' · 待处理 ' + this.appealPending + ' 条' : ''))
            .fontSize(12).fontColor(Theme.textTertiary).width('100%').padding({ left: 14, bottom: 6 })

          if (this.appeals.length === 0) {
            Column({ space: 6 }) {
              Text('暂无符合条件的申诉').fontSize(14).fontColor(Theme.textTertiary)
              Text('成员在「我的报名」对已通过记录点「学时申诉」后会出现在这里')
                .fontSize(11).fontColor(Theme.textDisabled)
            }.width('100%').margin({ top: 50 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.appeals, (a: AppealInfo) => {
                  this.appealItem(a)
                }, (a: AppealInfo) => a.id.toString() + '-' + a.status.toString() + '-' + a.hours_after.toString())
              }.padding({ left: 14, right: 14 })
            }
            .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
          }
        }
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
