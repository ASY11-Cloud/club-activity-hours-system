/**
 * 社团活动报名与学时认定系统 —— 活动广场(登录后从服务器拉取活动列表)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { ActivityInfo, parseActivities } from '../common/Models';

@Entry
@Component
struct ActivityListPage {
  @State activities: ActivityInfo[] = [];
  @State loading: boolean = false;
  @State error: string = '';
  @State notLoggedIn: boolean = false;
  @State refreshing: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true; // 未登录: 引导登录
        return;
      }
      this.load();
    }).catch((e: Error) => {
      this.error = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    // 从登录页返回且已登录: 解除未登录守卫
    if (this.notLoggedIn && AppConfig.isLoggedIn) this.notLoggedIn = false;
    if (!this.notLoggedIn) this.load();
  }

  /** 下拉刷新回调 */
  onRefresh(): void {
    this.refreshing = true;
    this.load().then(() => {
      this.refreshing = false;
    }).catch(() => {
      this.refreshing = false;
    });
  }

  async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    const resp = await ApiClient.get('/api/activity/list');
    if (resp['code'] === 0) {
      this.activities = parseActivities(resp);
      if (this.activities.length === 0) {
        this.error = '暂无活动, 可前往「发布活动」创建';
      }
    } else {
      this.error = resp['msg'] as string;
    }
    this.loading = false;
  }

  @Builder
  card(a: ActivityInfo) {
    Column() {
      Row() {
        Text(a.title).fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text(a.hours + ' 学时').fontSize(13).fontColor('#1E6FFF')
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .backgroundColor('#EAF1FF').borderRadius(10)
      }.width('100%')

      Text(a.content === '' ? '暂无描述' : a.content)
        .fontSize(13).fontColor('#555555')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').margin({ top: 8 })

      Row({ space: 16 }) {
        Text('📍 ' + (a.location === '' ? '待定' : a.location))
          .fontSize(12).fontColor('#888888')
        Text('⏱ ' + a.start_time).fontSize(12).fontColor('#888888')
      }.width('100%').margin({ top: 8 })

      Row() {
        Text('已报名 ' + a.signed_count + (a.capacity > 0 ? ' / ' + a.capacity : '') + ' 人')
          .fontSize(12).fontColor('#888888')
        Text('发布人: ' + (a.publisher === '' ? '—' : a.publisher))
          .fontSize(12).fontColor('#888888')
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 6 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .margin({ bottom: 10 })
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.05)', offsetY: 2 })
    .onClick(() => {
      router.pushUrl({ url: 'pages/ActivityDetailPage', params: { 'activity_id': a.id } });
    })
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔑').fontSize(40)
      Text('请先登录').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('活动广场需要登录后访问(普通成员/管理员均可)')
        .fontSize(12).fontColor('#999999').textAlign(TextAlign.Center)
      Button('去登录').fontSize(14).height(38).backgroundColor('#1E6FFF')
        .onClick(() => router.pushUrl({ url: 'pages/LoginPage' }))
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }

  build() {
    Column() {
      if (this.notLoggedIn) {
        this.deniedView()
      } else {
        Row() {
          Text('活动广场').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('刷新').fontSize(13).height(30).backgroundColor('#1E6FFF')
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        if (this.loading) {
          LoadingProgress().width(40).height(40).color('#1E6FFF').margin({ top: 60 })
        } else if (this.error !== '') {
          Column({ space: 10 }) {
            Text(this.error).fontSize(14).fontColor('#999999').textAlign(TextAlign.Center)
            Text('请检查「设置」中的服务器地址(宿主机局域网 IPv4:8000)')
              .fontSize(12).fontColor('#BBBBBB').textAlign(TextAlign.Center)
          }.width('100%').margin({ top: 60 }).padding({ left: 30, right: 30 })
        } else {
          Refresh({ refreshing: this.refreshing }) {
            Scroll() {
              Column() {
                ForEach(this.activities, (a: ActivityInfo) => {
                  this.card(a)
                }, (a: ActivityInfo) => a.id.toString() + '-' + a.signed_count.toString())
              }.padding(14)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
          }
          .onRefreshing(() => this.onRefresh())
        }
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
