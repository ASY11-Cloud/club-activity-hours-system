/**
 * 社团活动报名与学时认定系统 —— 主界面(v2.5)
 * 普通成员: 活动 / 我的
 * 管理员:   活动 / 管理 / 我的
 *
 * 本轮重做的是"信息与操作的优先级":
 *  - 学生进首页先看到"我还差多少学时", 而不是先看活动列表;
 *  - 管理员进首页先看到"有 N 条待办", 并在 Tab 上有角标;
 *  - 活动卡带时间状态色条与相对时间, 一眼分辨进行中/已结束/名额已满;
 *  - 列表支持服务端筛选与关键词搜索(与分页一致, 不在前端过滤);
 *  - 加载/空/错误三态统一, 失败给原因和重试入口。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';
import {
  ActivityInfo, HoursRow, SignupInfo, parseActivities, parseHoursReport, parseSignups,
  totalOf, hasMoreOf
} from '../common/Models';
import { Nav } from '../common/Nav';
import { Theme } from '../common/Theme';
import { TimeFmt } from '../common/TimeFmt';
import { StateView } from '../components/StateView';

const PAGE_SIZE = 10;

@Entry
@Component
struct MainPage {
  @State currentTab: number = 0;
  @State loggedIn: boolean = AppConfig.isLoggedIn;
  @State isAdmin: boolean = AppConfig.isAdmin;
  @State name: string = AppConfig.stuName;
  @State stuNo: string = AppConfig.stuNo;

  // ---- 活动列表 ----
  @State activities: ActivityInfo[] = [];
  @State actMsg: string = '';
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State actPage: number = 1;
  @State actTotal: number = 0;
  @State hasMore: boolean = false;
  @State reachedEnd: boolean = false;
  @State loadFailed: boolean = false;

  // ---- 筛选 / 搜索(全部在服务端生效) ----
  @State scope: string = 'all';
  @State kw: string = '';
  @State kwInput: string = '';
  @State searchOpen: boolean = false;

  // ---- 学生: 学时进度与已报名活动 ----
  @State myHours: number = 0;
  @State requiredHours: number = 0;
  @State mySignupActs: number[] = [];

  // ---- 管理员: 待办 ----
  @State pendingSignup: number = 0;
  @State pendingReg: number = 0;

  private tabsController: TabsController = new TabsController();

  get tabCount(): number {
    return this.isAdmin ? 3 : 2;
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.syncLogin();
      this.resetAndLoad();
      this.loadAside();
    }).catch((e: Error) => {
      this.actMsg = '初始化失败: ' + e.message;
      this.loadFailed = true;
    });
  }

  onPageShow(): void {
    this.syncLogin();
    if (!AppConfig.isLoggedIn) {
      Nav.resetTo('pages/LandingPage');
      return;
    }
    this.resetAndLoad();
    this.loadAside();
  }

  syncLogin(): void {
    this.loggedIn = AppConfig.isLoggedIn;
    this.isAdmin = AppConfig.isAdmin;
    this.name = AppConfig.stuName;
    this.stuNo = AppConfig.stuNo;
  }

  /** 与列表无关的附加数据: 学生看学时/已报名, 管理员看待办 */
  loadAside(): void {
    if (this.isAdmin) {
      this.loadPending();
    } else {
      this.loadProgress();
      this.loadMySignups();
    }
  }

  // ==================== 数据 ====================

  buildPath(page: number): string {
    let q = '/api/activity/list?page=' + page.toString() + '&size=' + PAGE_SIZE.toString();
    if (this.scope !== 'all') q += '&scope=' + this.scope;
    if (this.scope === 'mine' && this.stuNo !== '') q += '&stu_no=' + encodeURIComponent(this.stuNo);
    if (this.kw !== '') q += '&kw=' + encodeURIComponent(this.kw);
    return q;
  }

  resetAndLoad(): void {
    this.actPage = 1;
    this.reachedEnd = false;
    this.hasMore = false;
    this.loadActivities(true);
  }

  /**
   * 分页拉取活动列表
   * 页码只在请求成功后推进: 失败时停留在原页, 下次触底重试同一页, 不会跳过整页数据。
   */
  async loadActivities(reset: boolean, page: number = 0): Promise<void> {
    if (this.loading) {
      this.refreshing = false;
      return;
    }
    const target = page > 0 ? page : this.actPage;
    this.loading = true;
    this.loadFailed = false;
    try {
      const resp = await ApiClient.get(this.buildPath(target));
      if (resp['code'] === 0) {
        const list: ActivityInfo[] = parseActivities(resp);
        this.actTotal = totalOf(resp);
        this.hasMore = hasMoreOf(resp);
        this.activities = reset ? list : this.activities.concat(list);
        this.actPage = target;
        if (!this.hasMore) this.reachedEnd = true;
        this.actMsg = '';
      } else {
        this.loadFailed = true;
        this.actMsg = (resp['msg'] as string);
        if (reset) this.activities = [];
      }
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  loadMore(): void {
    if (this.loading || this.reachedEnd) return;
    this.loadActivities(false, this.actPage + 1);
  }

  onRefresh(): void {
    this.refreshing = true;
    this.resetAndLoad();
    this.loadAside();
  }

  /** 学生学时进度: 已认定 / 达标线 */
  async loadProgress(): Promise<void> {
    const resp = await ApiClient.get('/api/hours/report');
    if (resp['code'] !== 0) return;
    const data = resp['data'] as Record<string, Object>;
    this.requiredHours = Number(data['required_hours']);
    const rows: HoursRow[] = parseHoursReport(resp);
    for (const r of rows) {
      if (r.stu_no === this.stuNo) {
        this.myHours = r.total_hours;
        break;
      }
    }
  }

  /** 我已报名的活动 id 集合: 列表卡上直接标"已报名", 不用点进去才知道 */
  async loadMySignups(): Promise<void> {
    if (this.stuNo === '') return;
    const resp = await ApiClient.get('/api/signup/list?size=200');
    if (resp['code'] !== 0) return;
    const list: SignupInfo[] = parseSignups(resp);
    const ids: number[] = [];
    for (const s of list) {
      if (s.status !== 2 && ids.indexOf(s.activity_id) < 0) ids.push(s.activity_id);
    }
    this.mySignupActs = ids;
  }

  /** 管理员待办: 待审报名 / 待批注册 */
  async loadPending(): Promise<void> {
    const resp = await ApiClient.get('/api/stats/pending');
    if (resp['code'] !== 0) return;
    const d = resp['data'] as Record<string, Object>;
    this.pendingSignup = Number(d['signup_pending']);
    this.pendingReg = Number(d['register_pending']);
  }

  // ==================== 展示辅助 ====================

  /** 学时完成度 0~100 */
  pct(): number {
    if (this.requiredHours <= 0) return 0;
    const v = Math.round(this.myHours / this.requiredHours * 100);
    if (v < 0) return 0;
    return v > 100 ? 100 : v;
  }

  /** 活动状态色: 已结束灰 / 名额满橙 / 进行中绿 / 未开始蓝 */
  actColor(a: ActivityInfo): string {
    if (a.expired) return Theme.textDisabled;
    if (a.remaining === 0) return Theme.warning;
    if (TimeFmt.stage(a.start_time, a.end_time) === '进行中') return Theme.success;
    return Theme.primary;
  }

  isMine(a: ActivityInfo): boolean {
    return this.mySignupActs.indexOf(a.id) >= 0;
  }

  go(url: string): void {
    router.pushUrl({ url: url });
  }

  setScope(s: string): void {
    if (this.scope === s) return;
    this.scope = s;
    this.resetAndLoad();
  }

  applySearch(): void {
    this.kw = this.kwInput.trim();
    this.resetAndLoad();
  }

  clearSearch(): void {
    this.kwInput = '';
    this.kw = '';
    this.searchOpen = false;
    this.resetAndLoad();
  }

  logout(): void {
    AlertDialog.show({
      title: '退出登录?',
      message: '退出后需重新登录才能使用完整功能',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: Theme.danger,
        action: async () => {
          await ApiClient.post('/api/logout', {});
          await AppConfig.logout();
          Nav.resetTo('pages/LandingPage');
        }
      }
    });
  }

  // ==================== 底部导航 ====================
  // 不用 Tabs 的 tabBar 构建器: 它是 CustomBuilder, @State(待办数) 变化后不会重建,
  // 角标永远是首次构建的值。改为自绘导航, 状态变化必定刷新。

  /** 角标数字: 同样在 builder 内部按 kind 读状态, 避免"按值传参不刷新" */
  badgeOf(kind: string): number {
    if (kind === 'audit') return this.pendingSignup + this.pendingReg;
    return 0;
  }

  badgeTxt(kind: string): string {
    const n = this.badgeOf(kind);
    if (n <= 0) return '';
    return n > 99 ? '99+' : n.toString();
  }

  tabColor(idx: number): string {
    return this.currentTab === idx ? Theme.primary : Theme.textTertiary;
  }

  /**
   * 图标: 用基础图形拼, 不用 emoji/字符码位。
   * emoji 在部分字体下会被渲染成彩色位图或空心方块, 字符码位(☰ ▦ ◉)粗细也不可控,
   * 几何图元在任何设备上都一致, 选中态只是换个填充色。
   */
  @Builder
  navIcon(kind: string, idx: number) {
    if (kind === 'list') {
      Column({ space: 3 }) {
        Row().width(16).height(2).backgroundColor(this.tabColor(idx)).borderRadius(1)
        Row().width(16).height(2).backgroundColor(this.tabColor(idx)).borderRadius(1)
        Row().width(10).height(2).backgroundColor(this.tabColor(idx)).borderRadius(1)
      }.alignItems(HorizontalAlign.Start).height(19).justifyContent(FlexAlign.Center)
    } else if (kind === 'grid') {
      Column({ space: 3 }) {
        Row({ space: 3 }) {
          Row().width(6).height(6).backgroundColor(this.tabColor(idx)).borderRadius(1.5)
          Row().width(6).height(6).backgroundColor(this.tabColor(idx)).borderRadius(1.5)
        }

        Row({ space: 3 }) {
          Row().width(6).height(6).backgroundColor(this.tabColor(idx)).borderRadius(1.5)
          Row().width(6).height(6).backgroundColor(this.tabColor(idx)).borderRadius(1.5)
        }
      }.height(19).justifyContent(FlexAlign.Center)
    } else {
      // 人形: 一个圆(头) + 一个圆角矩形(肩)
      Column({ space: 2 }) {
        Circle().width(7).height(7).fill(this.tabColor(idx))
        Row().width(13).height(6).backgroundColor(this.tabColor(idx))
          .borderRadius({ topLeft: 6, topRight: 6, bottomLeft: 2, bottomRight: 2 })
      }.height(19).justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  navItem(title: string, icon: string, idx: number, kind: string) {
    Column({ space: 2 }) {
      Row() {
        this.navIcon(icon, idx)
        if (this.badgeTxt(kind) !== '') {
          Text(this.badgeTxt(kind))
            .fontSize(9).fontColor(Theme.textOnPrimary)
            .padding({ left: 3, right: 3 })
            .backgroundColor(Theme.danger)
            .borderRadius(7)
            .margin({ left: 2, top: -8 })
        }
      }.height(19).alignItems(VerticalAlign.Center)

      Text(title).fontSize(10)
        .fontColor(this.tabColor(idx))
        .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1).height(56).justifyContent(FlexAlign.Center)
    .onClick(() => this.switchTab(idx))
  }

  @Builder
  bottomNav() {
    Row() {
      this.navItem('活动', 'list', 0, '')
      if (this.isAdmin) {
        this.navItem('管理', 'grid', 1, 'audit')
      }
      this.navItem('我的', 'user', this.tabCount - 1, '')
    }
    .width('100%').height(56)
    .backgroundColor(Theme.bgCard)
    .border({ width: { top: 0.5 }, color: Theme.divider })
  }

  switchTab(idx: number): void {
    if (this.currentTab === idx) return;
    this.currentTab = idx;
    // 切 Tab 不重置列表(会丢分页与滚动位置); 切到管理时补一次待办, 保证角标新鲜
    if (idx === 0 && this.activities.length === 0) this.resetAndLoad();
    if (this.isAdmin) this.loadPending();
  }

  // ==================== 顶部区 ====================

  /**
   * 标题栏。
   * 注意: @Builder 的参数是"按值传递", 状态变量变了不会刷新 builder 内部。
   * 所以"共 N 个"必须在这里直接读 this.actTotal, 不能从外面传字符串进来。
   */
  @Builder
  header(title: string, showSearch: boolean) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(title).fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text(this.kw === '' ? '共 ' + this.actTotal + ' 个' : '找到 ' + this.actTotal + ' 个')
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        if (showSearch) {
          Text(this.searchOpen ? '收起' : '搜索')
            .fontSize(Theme.fsBody).fontColor(Theme.primary)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.searchOpen = !this.searchOpen;
              if (!this.searchOpen && this.kw !== '') this.clearSearch();
            })
        }
        Text('刷新')
          .fontSize(Theme.fsBody).fontColor(Theme.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => this.onRefresh())
      }.width('100%')

      if (showSearch && this.searchOpen) {
        Row({ space: 8 }) {
          TextInput({ text: this.kwInput, placeholder: '搜索活动名称或地点' })
            .layoutWeight(1).height(36).fontSize(Theme.fsBody)
            .backgroundColor(Theme.bgSubtle).borderRadius(18)
            .padding({ left: 12 })
            .onChange((v: string) => this.kwInput = v)
            .onSubmit(() => this.applySearch())
          Button('搜索').height(36).fontSize(Theme.fsSmall)
            .backgroundColor(Theme.primary).borderRadius(18)
            .onClick(() => this.applySearch())
        }.width('100%')
      }
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12, bottom: 8 })
  }

  /** 学生学时进度卡: 学时认定的核心指标常驻首页 */
  @Builder
  progressCard() {
    Column({ space: 8 }) {
      Row() {
        Text('本学期学时认定').fontSize(Theme.fsCaption).fontColor(Theme.textSecondary)
        Blank()
        Text(this.myHours.toString() + ' / ' + this.requiredHours + ' 学时')
          .fontSize(Theme.fsBody).fontWeight(FontWeight.Medium).fontColor(Theme.primary)
      }.width('100%')

      Row() {
        Row()
          .height(7)
          .width(this.pct().toString() + '%')
          .backgroundColor(this.pct() >= 100 ? Theme.success : Theme.primary)
          .borderRadius(4)
      }
      .width('100%').height(7)
      .backgroundColor(Theme.bgNeutral)
      .borderRadius(4)

      Row() {
        Text(this.pct() >= 100 ? '已达标, 继续保持' : '再认定 ' +
          (this.requiredHours - this.myHours > 0 ? (this.requiredHours - this.myHours) : 0) + ' 学时即可达标')
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        Blank()
        Text('查看明细 ›').fontSize(Theme.fsCaption).fontColor(Theme.primary)
      }.width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.bgCard)
    .borderRadius(Theme.radiusMd)
    .onClick(() => this.go('pages/HoursReportPage'))
  }

  /** 管理员待办卡: 审核是核心动作, 不能让管理员靠"点进去看"才发现有活 */
  @Builder
  pendingCard() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(this.pendingSignup + this.pendingReg > 0 ? '有 ' +
          (this.pendingSignup + this.pendingReg) + ' 条待办' : '暂无待办')
          .fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
          .fontColor(this.pendingSignup + this.pendingReg > 0 ? Theme.warning : Theme.success)
        Text(this.pendingSignup + ' 条报名待审核 · ' + this.pendingReg + ' 条注册待审批')
          .fontSize(Theme.fsCaption).fontColor(Theme.textSecondary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Text(this.pendingSignup + this.pendingReg > 0 ? '去处理 ›' : '查看 ›')
        .fontSize(Theme.fsSmall).fontColor(Theme.primary)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.pendingSignup + this.pendingReg > 0 ? Theme.warningBg : Theme.successBg)
    .borderRadius(Theme.radiusMd)
    .onClick(() => this.go('pages/AuditPage'))
  }

  @Builder
  scopeChip(label: string, key: string) {
    Text(label)
      .fontSize(Theme.fsSmall)
      .fontColor(this.scope === key ? Theme.textOnPrimary : Theme.textSecondary)
      .fontWeight(this.scope === key ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.scope === key ? Theme.primary : Theme.bgNeutral)
      .borderRadius(Theme.radiusPill)
      .onClick(() => this.setScope(key))
  }

  @Builder
  scopeBar() {
    Row({ space: 8 }) {
      this.scopeChip('全部', 'all')
      this.scopeChip('可报名', 'available')
      if (!this.isAdmin) {
        this.scopeChip('我报名的', 'mine')
      }
      this.scopeChip('已结束', 'expired')
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })
  }

  // ==================== 活动卡 ====================

  @Builder
  actItem(a: ActivityInfo) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(a.title)
          .fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium)
          .fontColor(a.expired ? Theme.textTertiary : Theme.textBody)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.isMine(a)) {
          Text('已报名').fontSize(Theme.fsCaption).fontColor(Theme.success)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(Theme.successBg).borderRadius(Theme.radiusSm)
        }
        Text(a.hours.toString() + ' 学时')
          .fontSize(Theme.fsCaption).fontColor(Theme.primary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(Theme.primaryBg).borderRadius(Theme.radiusSm)
      }.width('100%')

      Row({ space: 6 }) {
        Text(TimeFmt.stage(a.start_time, a.end_time))
          .fontSize(Theme.fsCaption).fontColor(this.actColor(a))
        Text('·').fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
        Text(TimeFmt.short(a.start_time)).fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
      }.width('100%')

      Row({ space: 6 }) {
        Text(a.location === '' ? '地点待定' : a.location)
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')

      Row({ space: 8 }) {
        if (a.capacity > 0) {
          Row() {
            Row()
              .height(4)
              .width(Math.round(a.valid_count * 100 / a.capacity).toString() + '%')
              .backgroundColor(a.remaining === 0 ? Theme.warning : Theme.primary)
              .borderRadius(2)
          }
          .width(64).height(4).backgroundColor(Theme.bgNeutral).borderRadius(2)

          Text(a.valid_count + ' / ' + a.capacity + ' 人')
            .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        } else {
          Text(a.valid_count + ' 人已报名 · 不限人数')
            .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        }
        Blank()
        if (a.expired) {
          Text('已结束').fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
        } else if (a.remaining === 0) {
          Text('名额已满').fontSize(Theme.fsCaption).fontColor(Theme.warning)
        } else if (a.remaining > 0) {
          Text('剩 ' + a.remaining + ' 个名额').fontSize(Theme.fsCaption).fontColor(Theme.success)
        }
      }.width('100%')
    }
    .width('100%').padding(12)
    .backgroundColor(Theme.bgCard)
    .borderRadius(Theme.radiusMd)
    .border({ width: { left: 3 }, color: this.actColor(a) })
    .margin({ bottom: Theme.gapSm })
    .onClick(() => router.pushUrl({ url: 'pages/ActivityDetailPage', params: { 'activity_id': a.id } }))
  }

  // ==================== 活动视图 ====================

  @Builder
  activityView() {
    Column() {
      this.header('活动广场', true)

      Column({ space: 8 }) {
        if (this.isAdmin) {
          this.pendingCard()
        } else {
          this.progressCard()
        }
      }.width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 10 })

      this.scopeBar()

      if (this.loadFailed) {
        StateView({
          kind: 'error',
          title: '活动列表加载失败',
          desc: this.actMsg + '\n请检查服务器地址与网络后重试',
          retryText: '重新加载',
          onRetry: () => this.resetAndLoad()
        })
      } else if (this.activities.length === 0 && this.loading) {
        StateView({ kind: 'loading', title: '正在加载活动...' })
      } else if (this.activities.length === 0) {
        StateView({
          kind: 'empty',
          title: this.kw !== '' ? '没有匹配的活动' : (this.scope === 'mine' ? '还没有报名过活动' : '暂无活动'),
          desc: this.kw !== ''
            ? '换个关键词, 或点右上角「收起」清空搜索'
            : (this.isAdmin ? '到「管理 → 发布活动」创建活动' : '有新活动时会展示在这里, 下拉可刷新')
        })
      } else {
        Refresh({ refreshing: this.refreshing }) {
          List({ space: 0 }) {
            ForEach(this.activities, (a: ActivityInfo) => {
              ListItem() {
                this.actItem(a)
              }
            }, (a: ActivityInfo) => 'act' + a.id.toString() + '-' + a.valid_count.toString() +
              '-' + a.hours.toString() + '-' + a.status.toString() + '-' + (a.expired ? '1' : '0') +
              '-' + (this.isMine(a) ? '1' : '0') + '-' + a.title)

            ListItem() {
              Row() {
                if (this.loading) {
                  Text('加载中...').fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
                } else if (this.hasMore) {
                  Text('上拉加载更多').fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
                } else {
                  Text('已全部加载 (' + this.activities.length + ' 个)')
                    .fontSize(Theme.fsSmall).fontColor(Theme.textDisabled)
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 10, bottom: 16 })
            }
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
          .onReachEnd(() => this.loadMore())
          .edgeEffect(EdgeEffect.Spring)
        }
        .layoutWeight(1)
        .onRefreshing(() => this.onRefresh())
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }

  // ==================== 管理视图(仅管理员) ====================

  @Builder
  adminView() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Text('管理面板').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text('管理员专属').fontSize(Theme.fsCaption).fontColor(Theme.admin)
        }.width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 14, bottom: 4 })

        this.bigCard('审核中心', '报名审核 + 注册审批, 通过自动累计学时',
          Theme.success, 'pages/AuditPage', 'audit')
        this.bigCard('用户管理', '全量学生信息 + 分组查找(注册状态/学时达标)',
          Theme.admin, 'pages/UserManagePage', '')
        this.bigCard('发布活动', '表单 + 本地草稿箱, 同步发布到服务器',
          Theme.primary, 'pages/ActivityPublishPage', '')
        this.bigCard('服务器日志', '实时请求日志(内存 + MySQL request_log)',
          Theme.signin, 'pages/ServerLogPage', '')
        this.bigCard('学时报表', '全量学时排行 + 明细(双端一致)',
          Theme.report, 'pages/HoursReportPage', '')
      }
      .width('100%').padding({ bottom: 16 })
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
    .scrollBar(BarState.Off).align(Alignment.Top)
  }

  @Builder
  bigCard(title: string, desc: string, color: string, url: string, kind: string) {
    Row({ space: 12 }) {
      Text(title.substring(0, 1))
        .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
        .width(44).height(44).textAlign(TextAlign.Center)
        .backgroundColor(color).borderRadius(12)
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(title).fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
          if (this.badgeOf(kind) > 0) {
            Text(this.badgeOf(kind).toString()).fontSize(10).fontColor(Theme.textOnPrimary)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.danger).borderRadius(8)
          }
        }

        Text(desc).fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(20).fontColor(Theme.textDisabled)
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
    .margin({ left: Theme.pagePadding, right: Theme.pagePadding })
    .onClick(() => this.go(url))
  }

  // ==================== 我的视图 ====================

  @Builder
  profileView() {
    Scroll() {
      Column() {
        // 与「活动广场 / 管理面板」保持一致的页头
        Row() {
          Text('我的').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
            .fontColor(Theme.textBody).layoutWeight(1)
          Text(this.isAdmin ? '管理员' : '普通成员')
            .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        }
        .width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 14, bottom: 4 })

        Column({ space: 8 }) {
          Text(this.name === '' ? '访' : this.name.substring(0, 1))
            .fontSize(28).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
            .textAlign(TextAlign.Center)
            .width(72).height(72)
            .backgroundColor(this.isAdmin ? Theme.admin : Theme.success)
            .borderRadius(36)
          Text(this.name).fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
          Text(this.isAdmin ? '管理员 · 可发布活动与审核' : '普通成员 · 学号 ' + this.stuNo)
            .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
          // 学生再补一行学时进度: 「我的」也要能一眼看到认定情况
          if (!this.isAdmin && this.requiredHours > 0) {
            Text('本学期已认定 ' + this.myHours + ' / ' + this.requiredHours + ' 学时')
              .fontSize(Theme.fsCaption).fontColor(Theme.primary)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(Theme.primaryBg).borderRadius(Theme.radiusPill)
              .margin({ top: 4 })
          }
        }
        .width('100%').padding({ top: 24, bottom: 20 })
        .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
        .margin({ top: 8, left: Theme.pagePadding, right: Theme.pagePadding })

        Column({ space: 0 }) {
          if (!this.isAdmin) {
            this.rowItem('我的报名', '本地记录 + 服务器状态同步', 'pages/MySignupPage')
          }
          this.rowItem('学时报表', '排行榜 + 个人明细', 'pages/HoursReportPage')
          this.dividerLine()
          this.rowItem('设置', '服务器地址 / 登录会话 / 刷卡调试', 'pages/SettingsPage')
          this.dividerLine()
          this.rowItem('系统介绍', '功能一览 / 验收流程 / 服务器状态', 'pages/LandingPage')
        }
        .width('100%').padding({ left: 14, right: 14 }).margin({ top: 12 })
        .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)

        Column({ space: 5 }) {
          Text('验收流程').fontSize(Theme.fsSmall).fontWeight(FontWeight.Medium)
            .fontColor(Theme.textBody).width('100%')
          Text('注册审批 → 登录 → 报名 → 同步 → 服务端审核 → 学时累计(双端一致)')
            .fontSize(Theme.fsCaption).fontColor(Theme.textSecondary).width('100%')
          Text('本地 SQLite 离线记录; 服务器 MySQL 可查; request_log 实时日志; RFID 刷卡签到')
            .fontSize(10).fontColor(Theme.textTertiary).width('100%').lineHeight(15)
        }
        .width('100%').padding(14).margin({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12 })
        .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
        .alignItems(HorizontalAlign.Start)

        Button('退出登录')
          .width('92%').height(44).fontSize(Theme.fsTitle).fontColor(Theme.danger)
          .margin({ top: 16 })
          .backgroundColor(Theme.bgCard).borderRadius(22)
          .onClick(() => this.logout())

        Text('社团活动报名与学时认定系统 · 课程设计 v2.5')
          .fontSize(10).fontColor(Theme.textDisabled).margin({ top: 12, bottom: 16 })
      }
      .width('100%')
    }
    .scrollBar(BarState.Off).align(Alignment.Top)
  }

  @Builder
  rowItem(title: string, desc: string, url: string) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium).fontColor(Theme.textBody)
        Text(desc).fontSize(10).fontColor(Theme.textTertiary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(18).fontColor(Theme.textDisabled)
    }
    .width('100%').padding({ top: 14, bottom: 14 })
    .onClick(() => this.go(url))
  }

  @Builder
  dividerLine() {
    Row().width('100%').height(0.5).backgroundColor(Theme.divider)
  }

  // ==================== 主结构 ====================

  build() {
    Column() {
      Stack() {
        if (this.currentTab === 0) {
          this.activityView()
        } else if (this.currentTab === 1 && this.isAdmin) {
          this.adminView()
        } else {
          this.profileView()
        }
      }
      .layoutWeight(1).width('100%').alignContent(Alignment.TopStart)

      this.bottomNav()
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
