/**
 * 通知公告(v5.0)
 *
 * 可见性由服务端判定:
 *  - 学生: 本校团(status=1)的公告, 带未读标记, 点开即标记已读
 *  - 社团账号: 本社团全部公告(含已撤回), 可发布 / 撤回 / 恢复 / 置顶
 *  - 平台管理员: 可跨社团查看(club_id 过滤), 发布时默认落到默认社团
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { AnnouncementInfo, parseAnnouncements, unreadAnnouncements } from '../common/Models';
import { Theme } from '../common/Theme';
import { StateView } from '../components/StateView';

@Entry
@Component
struct AnnouncementPage {
  @State list: AnnouncementInfo[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State page: number = 1;
  @State hasMore: boolean = false;
  @State total: number = 0;
  @State unread: number = 0;
  @State expandedId: number = -1;

  // 发布面板(管理员)
  @State showForm: boolean = false;
  @State title: string = '';
  @State content: string = '';
  @State topFlag: boolean = false;
  @State busy: boolean = false;
  @State msg: string = '';
  @State msgErr: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.load(true);
    }).catch((e: Error) => {
      this.loadError = '初始化失败: ' + e.message;
      this.loading = false;
    });
  }

  async load(reset: boolean): Promise<void> {
    if (reset) {
      this.page = 1;
      this.loading = true;
      this.loadError = '';
    }
    const resp = await ApiClient.get('/api/announcement/list?page=' + this.page.toString() + '&size=20');
    if (resp['code'] !== 0) {
      this.loadError = resp['msg'] as string;
      this.loading = false;
      return;
    }
    const rows = parseAnnouncements(resp);
    this.list = reset ? rows : this.list.concat(rows);
    this.unread = unreadAnnouncements(resp);
    this.total = Number(resp['data'] !== undefined
      ? (resp['data'] as Record<string, Object>)['total'] : 0);
    this.hasMore = resp['data'] !== undefined
      ? (resp['data'] as Record<string, Object>)['has_more'] === true : false;
    this.loading = false;
  }

  async loadMore(): Promise<void> {
    if (!this.hasMore || this.busy) return;
    this.page = this.page + 1;
    await this.load(false);
  }

  /** 点开正文: 学生首次展开时标记已读(服务端幂等, 重复展开不会重复计数) */
  async toggle(a: AnnouncementInfo): Promise<void> {
    this.expandedId = this.expandedId === a.id ? -1 : a.id;
    if (this.expandedId !== a.id) return;
    if (!AppConfig.isAdmin && !a.is_read) {
      const resp = await ApiClient.post('/api/announcement/read', { 'ann_id': a.id }, true);
      if (resp['code'] === 0) {
        for (let i = 0; i < this.list.length; i++) {
          if (this.list[i].id === a.id) {
            const cur = this.list[i];
            this.list[i] = {
              id: cur.id, title: cur.title, content: cur.content, publisher: cur.publisher,
              top_flag: cur.top_flag, status: cur.status, created_at: cur.created_at,
              club_name: cur.club_name, is_read: true
            };
            break;
          }
        }
        if (this.unread > 0) this.unread = this.unread - 1;
      }
    }
  }

  async publish(): Promise<void> {
    if (this.busy) return;
    if (this.title.trim() === '') {
      this.msg = '请填写公告标题';
      this.msgErr = true;
      return;
    }
    this.busy = true;
    this.msg = '';
    const body: Record<string, Object> = {
      'title': this.title.trim(),
      'content': this.content.trim(),
      'top_flag': this.topFlag ? 1 : 0
    };
    const resp = await ApiClient.post('/api/announcement/add', body, true);
    if (resp['code'] === 0) {
      this.msg = '公告已发布';
      this.msgErr = false;
      this.title = '';
      this.content = '';
      this.topFlag = false;
      this.showForm = false;
      await this.load(true);
    } else {
      this.msg = resp['msg'] as string;
      this.msgErr = true;
    }
    this.busy = false;
  }

  confirmStatus(a: AnnouncementInfo): void {
    const toRecall = a.status === 1;
    AlertDialog.show({
      title: toRecall ? '撤回该公告?' : '恢复该公告?',
      message: toRecall
        ? '「' + a.title + '」撤回后成员将看不到, 已读记录保留'
        : '「' + a.title + '」将重新对成员可见',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: toRecall ? '撤回' : '恢复',
        fontColor: toRecall ? Theme.danger : Theme.success,
        action: () => {
          this.changeStatus(a, toRecall ? 0 : 1);
        }
      }
    });
  }

  async changeStatus(a: AnnouncementInfo, status: number): Promise<void> {
    const resp = await ApiClient.post('/api/announcement/status',
      { 'ann_id': a.id, 'status': status }, true);
    if (resp['code'] === 0) {
      this.msg = status === 1 ? '公告已恢复' : '公告已撤回';
      this.msgErr = false;
      await this.load(true);
    } else {
      this.msg = resp['msg'] as string;
      this.msgErr = true;
    }
  }

  @Builder
  header() {
    Row({ space: 8 }) {
      Text('‹').fontSize(24).fontColor(Theme.textBody)
        .width(32).height(32).textAlign(TextAlign.Center)
        .onClick(() => router.back())
      Text('通知公告').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody).layoutWeight(1)
      if (this.unread > 0) {
        Text(this.unread.toString() + ' 条未读')
          .fontSize(Theme.fsCaption).fontColor(Theme.danger)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(Theme.dangerBg).borderRadius(Theme.radiusPill)
      }
      if (AppConfig.isAdmin) {
        Text(this.showForm ? '收起' : '发布')
          .fontSize(Theme.fsSmall).fontColor(Theme.primary)
          .padding({ left: 8, right: 4, top: 6, bottom: 6 })
          .onClick(() => this.showForm = !this.showForm)
      }
    }
    .width('100%')
    .padding({ left: 10, right: Theme.pagePadding, top: 12, bottom: 8 })
  }

  @Builder
  publishPanel() {
    Column({ space: 8 }) {
      TextInput({ text: this.title, placeholder: '公告标题(必填)' })
        .width('100%').onChange((v: string) => this.title = v)
      TextArea({ text: this.content, placeholder: '公告内容' })
        .width('100%').height(90).fontSize(Theme.fsBody)
        .onChange((v: string) => this.content = v)
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.topFlag })
          .width(20).height(20)
          .onChange((on: boolean) => this.topFlag = on)
        Text('置顶显示').fontSize(Theme.fsSmall).fontColor(Theme.textSecondary).layoutWeight(1)
        Button(this.busy ? '发布中' : '发布公告')
          .height(36).fontSize(Theme.fsSmall)
          .backgroundColor(Theme.primary).fontColor(Theme.textOnPrimary)
          .enabled(!this.busy).onClick(() => this.publish())
      }.width('100%')
      if (this.msg !== '') {
        Text(this.msg).fontSize(Theme.fsSmall)
          .fontColor(this.msgErr ? Theme.danger : Theme.success).width('100%')
      }
    }
    .width('100%').padding(12)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  annCard(a: AnnouncementInfo) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        if (a.top_flag === 1) {
          Text('置顶').fontSize(10).fontColor(Theme.danger)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.dangerBg).borderRadius(4)
        }
        Text(a.title).fontSize(Theme.fsBody).fontWeight(FontWeight.Medium)
          .fontColor(a.status === 0 ? Theme.textDisabled : Theme.textBody)
          .layoutWeight(1).maxLines(2)
        if (!AppConfig.isAdmin && !a.is_read) {
          Circle({ width: 7, height: 7 }).fill(Theme.danger)
        }
      }
      .width('100%').alignItems(VerticalAlign.Top)

      Text(a.publisher + ' · ' + a.created_at + (a.club_name !== '' ? ' · ' + a.club_name : ''))
        .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary).width('100%')

      if (this.expandedId === a.id) {
        Text(a.content === '' ? '(无正文)' : a.content)
          .fontSize(Theme.fsSmall).fontColor(Theme.textSecondary).lineHeight(20)
          .width('100%')
      }

      if (AppConfig.isAdmin) {
        Row({ space: 10 }) {
          if (a.status === 0) {
            Text('已撤回').fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
          }
          Blank()
          Text(a.status === 1 ? '撤回' : '恢复')
            .fontSize(Theme.fsCaption)
            .fontColor(a.status === 1 ? Theme.danger : Theme.success)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .onClick(() => this.confirmStatus(a))
        }.width('100%')
      }
    }
    .width('100%').padding(12)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd)
    .opacity(a.status === 0 ? 0.6 : 1)
    .onClick(() => this.toggle(a))
  }

  build() {
    Column() {
      this.header()
      if (this.showForm && AppConfig.isAdmin) {
        Column() { this.publishPanel() }
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })
      }
      if (this.loading) {
        StateView({ kind: 'loading' })
      } else if (this.loadError !== '') {
        StateView({
          kind: 'error', title: '公告加载失败', desc: this.loadError,
          onRetry: () => {
            this.load(true);
          }
        })
      } else if (this.list.length === 0) {
        StateView({
          kind: 'empty', title: '暂无公告',
          desc: AppConfig.isAdmin ? '点右上角「发布」写第一条公告' : '社团发布公告后会出现在这里'
        })
      } else {
        List({ space: 8 }) {
          ForEach(this.list, (a: AnnouncementInfo) => {
            ListItem() {
              this.annCard(a)
            }
          }, (a: AnnouncementInfo) => 'ann' + a.id.toString() + '-' + a.status.toString() +
            '-' + (a.is_read ? '1' : '0') + '-' + (this.expandedId === a.id ? '1' : '0'))

          ListItem() {
            Row() {
              if (this.hasMore) {
                Text(this.busy ? '加载中...' : '加载更多')
                  .fontSize(Theme.fsSmall).fontColor(Theme.primary)
                  .onClick(() => this.loadMore())
              } else {
                Text('共 ' + this.total.toString() + ' 条')
                  .fontSize(Theme.fsCaption).fontColor(Theme.textDisabled)
              }
            }.width('100%').justifyContent(FlexAlign.Center).padding(10)
          }
        }
        .layoutWeight(1).scrollBar(BarState.Off)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 12 })
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
