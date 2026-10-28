/**
 * 社团活动报名与学时认定系统 —— 主界面(v2.2)
 * 普通成员: 活动 / 我的
 * 管理员:   活动 / 管理 / 我的
 * 冷启动与退出登录统一回引导页 LandingPage(不再有 Index 旧首页);
 * 活动列表内嵌分页 + 下拉刷新(原独立页 ActivityListPage 能力并入, 消除两套实现);
 * 「我的」页不再重复管理员功能(管理 Tab 已覆盖)。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';
import { ActivityInfo, parseActivities, totalOf, hasMoreOf } from '../common/Models';
import { Nav } from '../common/Nav';

const PAGE_SIZE = 10;

@Entry
@Component
struct MainPage {
  @State currentTab: number = 0;
  @State loggedIn: boolean = AppConfig.isLoggedIn;
  @State isAdmin: boolean = AppConfig.isAdmin;
  @State name: string = AppConfig.stuName;
  @State stuNo: string = AppConfig.stuNo;
  @State activities: ActivityInfo[] = [];
  @State actMsg: string = '';
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State actPage: number = 1;
  @State actTotal: number = 0;
  @State hasMore: boolean = false;
  @State reachedEnd: boolean = false;
  private tabsController: TabsController = new TabsController();

  get tabCount(): number {
    return this.isAdmin ? 3 : 2;
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.syncLogin();
      this.resetAndLoad();
    }).catch((e: Error) => {
      console.error('MainPage init failed: ' + e.message);
    });
  }

  onPageShow(): void {
    // 从功能页返回: 同步登录态 + 刷新活动列表(报名后人数变化)
    this.syncLogin();
    // 已退出登录(如在设置页退出): 主界面不再可用, 统一回引导页
    if (!AppConfig.isLoggedIn) {
      Nav.resetTo('pages/LandingPage');
      return;
    }
    this.resetAndLoad();
  }

  syncLogin(): void {
    this.loggedIn = AppConfig.isLoggedIn;
    this.isAdmin = AppConfig.isAdmin;
    this.name = AppConfig.stuName;
    this.stuNo = AppConfig.stuNo;
  }

  /** 重置分页状态并加载第一页 */
  resetAndLoad(): void {
    this.actPage = 1;
    this.reachedEnd = false;
    this.hasMore = false;
    this.loadActivities(true);
  }

  /**
   * 分页拉取活动列表
   * @param reset true=替换列表(第一页) / false=追加下一页
   * @param page  指定要拉的页码; 0 表示用当前 actPage
   * 页码只在请求成功后推进: 失败时停留在原页, 下次触底重试同一页, 不会跳过整页数据。
   */
  async loadActivities(reset: boolean, page: number = 0): Promise<void> {
    if (this.loading) {
      // 并发调用被吞掉时也要收起下拉圈, 否则 Refresh 一直转
      this.refreshing = false;
      return;
    }
    const target = page > 0 ? page : this.actPage;
    this.loading = true;
    try {
      const resp = await ApiClient.get('/api/activity/list?page=' + target + '&size=' + PAGE_SIZE);
      if (resp['code'] === 0) {
        const list = parseActivities(resp);
        this.actTotal = totalOf(resp);
        this.hasMore = hasMoreOf(resp);
        if (reset) {
          this.activities = list;
        } else {
          this.activities = this.activities.concat(list);
        }
        this.actPage = target;
        if (!this.hasMore) {
          this.reachedEnd = true;
        }
        this.actMsg = '';
      } else {
        this.actMsg = '活动拉取失败: ' + (resp['msg'] as string);
      }
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  /** 触底加载下一页(页码由 loadActivities 在成功后推进) */
  loadMore(): void {
    if (this.loading || this.reachedEnd) return;
    this.loadActivities(false, this.actPage + 1);
  }

  /** 下拉刷新(第一页) */
  onRefresh(): void {
    this.refreshing = true;
    this.resetAndLoad();
  }

  go(url: string): void {
    router.pushUrl({ url: url });
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
        fontColor: '#E84026',
        action: async () => {
          // 通知服务端注销 Token, 再清理本地会话, 统一回引导页
          await ApiClient.post('/api/logout', {});
          await AppConfig.logout();
          Nav.resetTo('pages/LandingPage');
        }
      }
    });
  }

  // ==================== TabBar ====================

  @Builder
  tabBar(title: string, icon: string, idx: number) {
    Column({ space: 2 }) {
      Text(icon).fontSize(19)
        .fontColor(this.currentTab === idx ? '#1E6FFF' : '#9AA3B2')
      Text(title).fontSize(10)
        .fontColor(this.currentTab === idx ? '#1E6FFF' : '#9AA3B2')
        .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Normal)
    }
    .width('100%').height(54).justifyContent(FlexAlign.Center)
    .backgroundColor(this.currentTab === idx ? '#EAF1FF' : Color.Transparent)
    .borderRadius(16)
  }

  // ==================== 活动视图 ====================

  @Builder
  actItem(a: ActivityInfo) {
    Column() {
      Row() {
        Text(a.title).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(a.hours.toString() + ' 学时')
          .fontSize(11).fontColor('#1E6FFF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#EAF1FF').borderRadius(6)
      }.width('100%')
      Row({ space: 8 }) {
        Text('🕒 ' + a.start_time).fontSize(11).fontColor('#888888')
        Text('📍 ' + (a.location === '' ? '待定' : a.location)).fontSize(11).fontColor('#888888')
      }.width('100%').margin({ top: 5 })
      Row() {
        Text('已报名 ' + a.valid_count + (a.capacity > 0 ? ' / ' + a.capacity : '') + ' 人')
          .fontSize(11).fontColor('#BBBBBB')
        if (a.expired) {
          Text('已结束').fontSize(11).fontColor('#E84026')
        } else if (a.remaining === 0) {
          Text('名额已满').fontSize(11).fontColor('#B25E00')
        } else {
          Text('详情 ›').fontSize(12).fontColor('#1E6FFF')
        }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 5 })
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12)
    .margin({ bottom: 8 })
    .onClick(() => router.pushUrl({ url: 'pages/ActivityDetailPage', params: { 'activity_id': a.id } }))
  }

  @Builder
  activityView() {
    Column() {
      Row() {
        Text('活动广场').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text('共 ' + this.actTotal + ' 个').fontSize(12).fontColor('#999999').margin({ right: 10 })
        Button('刷新').fontSize(13).height(30).backgroundColor('#1E6FFF')
          .onClick(() => this.resetAndLoad())
      }.width('100%').padding({ left: 14, right: 14, top: 14, bottom: 8 })

      Text(this.actMsg === '' ? '服务器 MySQL 实时数据, 下拉可刷新' : this.actMsg)
        .fontSize(12).fontColor(this.actMsg === '' ? '#999999' : '#E84026')
        .width('100%').padding({ left: 14, bottom: 8 })

      if (this.activities.length === 0) {
        Column({ space: 8 }) {
          Text(this.loading ? '加载中...' : '暂无活动')
            .fontSize(14).fontColor('#999999')
          if (this.isAdmin) {
            Button('去发布活动').fontSize(13).height(34).backgroundColor('#1E6FFF')
              .onClick(() => this.go('pages/ActivityPublishPage'))
          } else {
            Text('有新活动时会展示在这里, 下拉可刷新').fontSize(11).fontColor('#BBBBBB')
          }
        }.width('100%').margin({ top: 60 })
      } else {
        Refresh({ refreshing: this.refreshing }) {
          List({ space: 0 }) {
            ForEach(this.activities, (a: ActivityInfo) => {
              ListItem() {
                this.actItem(a)
              }
            }, (a: ActivityInfo) => 'act' + a.id.toString())

            ListItem() {
              Row() {
                if (this.loading) {
                  Text('加载中...').fontSize(12).fontColor('#999999')
                } else if (this.hasMore) {
                  Text('上拉加载更多').fontSize(12).fontColor('#999999')
                } else {
                  Text('已全部加载 (' + this.activities.length + ' 个)').fontSize(12).fontColor('#BBBBBB')
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 10, bottom: 14 })
            }
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: 14, right: 14 })
          .onReachEnd(() => this.loadMore())
          .edgeEffect(EdgeEffect.Spring)
        }
        .layoutWeight(1)
        .onRefreshing(() => this.onRefresh())
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }

  // ==================== 管理视图(仅管理员) ====================

  @Builder
  adminView() {
    Column({ space: 12 }) {
      Row() {
        Text('管理面板').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text('🛡 管理员专属').fontSize(11).fontColor('#F5652F')
      }.width('100%').padding({ left: 14, right: 14, top: 14, bottom: 4 })

      this.bigCard('✅', '审核中心', '报名审核 + 注册审批, 通过自动累计学时', '#07C160', 'pages/AuditPage')
      this.bigCard('📢', '发布活动', '表单 + 本地草稿箱, 同步发布到服务器', '#1E6FFF', 'pages/ActivityPublishPage')
      this.bigCard('🖥', '服务器日志', '实时请求日志(内存 + MySQL request_log)', '#6C5CE7', 'pages/ServerLogPage')
      this.bigCard('⏱', '学时报表', '全量学时排行 + 明细(双端一致)', '#00A884', 'pages/HoursReportPage')
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }

  @Builder
  bigCard(icon: string, title: string, desc: string, color: string, url: string) {
    Row({ space: 12 }) {
      Text(icon).fontSize(26).width(48).height(48).textAlign(TextAlign.Center)
        .backgroundColor(color).borderRadius(24).fontColor(Color.White)
      Column({ space: 3 }) {
        Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
        Text(desc).fontSize(11).fontColor('#999999')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(20).fontColor('#CCCCCC')
    }
    .width('100%').padding(14)
    .backgroundColor(Color.White).borderRadius(16)
    .margin({ left: 14, right: 14 })
    .onClick(() => this.go(url))
  }

  // ==================== 我的视图 ====================

  @Builder
  profileView() {
    Scroll() {
      Column() {
        // 用户卡
        Column({ space: 8 }) {
          Text(this.name === '' ? '访' : this.name.substring(0, 1))
            .fontSize(28).fontWeight(FontWeight.Bold).fontColor(Color.White).textAlign(TextAlign.Center)
            .width(72).height(72)
            .backgroundColor(this.isAdmin ? '#F5652F' : '#07C160')
            .borderRadius(36)
          Text(this.name).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#333333')
          Text(this.isAdmin ? '管理员' : '普通成员 · 学号 ' + this.stuNo)
            .fontSize(12).fontColor('#888888')
        }
        .width('100%').padding({ top: 28, bottom: 22 })
        .backgroundColor(Color.White).borderRadius(16)
        .margin({ top: 14, left: 14, right: 14 })

        // 成员功能
        Column({ space: 0 }) {
          // 管理员无报名概念, 不显示"我的报名"(进去只会是空列表/提示填写学号)
          if (!this.isAdmin) {
            this.rowItem('📌', '我的报名', '本地记录 + 服务器状态同步', 'pages/MySignupPage')
          }
          this.rowItem('⏱', '学时报表', '排行榜 + 个人明细', 'pages/HoursReportPage')
          this.dividerLine()
          this.rowItem('⚙️', '设置', '服务器地址 / 登录会话', 'pages/SettingsPage')
          this.dividerLine()
          this.rowItem('🎓', '系统介绍', '功能一览 / 验收流程 / 服务器状态', 'pages/LandingPage')
        }
        .width('100%').padding({ left: 14, right: 14 }).margin({ top: 12 })
        .backgroundColor(Color.White).borderRadius(16)

        // 验收流程提示(原主页内容迁移至此)
        Column({ space: 5 }) {
          Text('验收流程').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
          Text('注册审批 → 登录 → 报名 → 同步 → 服务端审核 → 学时累计(双端一致)')
            .fontSize(11).fontColor('#666666').width('100%')
          Text('本地 SQLite 离线记录; 服务器 MySQL 可查; request_log 实时日志; RFID 刷卡签到')
            .fontSize(10).fontColor('#999999').width('100%').lineHeight(15)
        }
        .width('100%').padding(14).margin({ left: 14, right: 14, top: 12 })
        .backgroundColor('#F2F4F8').borderRadius(12)
        .alignItems(HorizontalAlign.Start)

        // 退出登录
        Button('退出登录')
          .width('92%').height(44).fontSize(15).fontColor('#E84026')
          .margin({ top: 16 })
          .backgroundColor(Color.White).borderRadius(22)
          .onClick(() => this.logout())

        Text('社团活动报名与学时认定系统 · 课程设计 v2.2')
          .fontSize(10).fontColor('#BBBBBB').margin({ top: 12, bottom: 16 })
      }
      .width('100%')
    }
    .scrollBar(BarState.Off)
  }

  @Builder
  rowItem(icon: string, title: string, desc: string, url: string) {
    Row({ space: 10 }) {
      Text(icon).fontSize(18).width(30)
      Column({ space: 2 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#333333')
        Text(desc).fontSize(10).fontColor('#999999')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(18).fontColor('#CCCCCC')
    }
    .width('100%').padding({ top: 12, bottom: 12 })
    .onClick(() => this.go(url))
  }

  @Builder
  dividerLine() {
    Row().width('100%').height(0.5).backgroundColor('#EEEEEE')
  }

  // ==================== 主结构 ====================

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentTab, controller: this.tabsController }) {
      TabContent() {
        this.activityView()
      }.tabBar(this.tabBar('活动', '📋', 0))

      if (this.isAdmin) {
        TabContent() {
          this.adminView()
        }.tabBar(this.tabBar('管理', '🛡', 1))
      }

      TabContent() {
        this.profileView()
      }.tabBar(this.tabBar('我的', '👤', this.tabCount - 1))
    }
    .width('100%').height('100%')
    .barHeight(56)
    .backgroundColor(Color.White)
    .onChange((idx: number) => {
      this.currentTab = idx;
      // 切回「活动」Tab 不重置列表: 否则已加载的分页和滚动位置会丢;
      // 数据新鲜度由 onPageShow(从详情/发布等二级页返回)与下拉刷新保证
      if (idx === 0 && this.activities.length === 0) this.resetAndLoad();
    })
    .scrollable(false) // 底部 Tab 不允许滑动切换, 防止误触
  }
}
