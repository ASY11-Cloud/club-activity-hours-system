/**
 * 社团活动报名与学时认定系统 —— 服务器实时请求日志(仅管理员)
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { LogRow, parseLogs } from '../common/Models';

@Entry
@Component
struct ServerLogPage {
  @State logs: LogRow[] = [];
  @State msg: string = '';
  @State auto: boolean = true;
  @State blocked: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isAdmin) {
        this.blocked = true; // 无权限: 仅管理员可查看服务器日志
        return;
      }
      this.load();
      this.timer = setInterval(() => {
        if (this.auto) this.load();
      }, 3000);
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    // 返回页面时恢复自动刷新: aboutToDisappear 会清掉 timer, 需在重新可见时重启
    if (this.auto && this.timer === -1) {
      this.timer = setInterval(() => {
        if (this.auto) this.load();
      }, 3000);
    }
    if (!this.blocked) this.load();
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  async load(): Promise<void> {
    const resp = await ApiClient.get('/api/logs?limit=50');
    if (resp['code'] === 0) {
      this.logs = parseLogs(resp);
      const data = resp['data'] as Record<string, Object>;
      this.msg = '服务器内存日志 ' + (data['total'] as number) + ' 条, 显示最近 ' + this.logs.length + ' 条';
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
    }
  }

  @Builder
  item(l: LogRow) {
    Row() {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(l.method).fontSize(11).fontColor(Color.White)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(l.method === 'POST' ? '#E84026' : '#1E6FFF').borderRadius(4)
          Text(l.status.toString()).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor(l.status >= 400 ? '#E84026' : '#07C160')
        }
        Text(l.path).fontSize(13).fontColor('#333333')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 3 }) {
        Text(l.time).fontSize(11).fontColor('#999999')
        Text(l.ip + ' · ' + l.cost_ms + 'ms').fontSize(11).fontColor('#999999')
      }.alignItems(HorizontalAlign.End)
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔒').fontSize(40)
      Text('无权限访问').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('服务器实时日志仅限管理员查看, 请以管理员身份登录后访问')
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
          Text('服务器实时日志').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text(this.auto ? '● 自动刷新' : '○ 手动刷新')
            .fontSize(12).fontColor(this.auto ? '#07C160' : '#999999')
            .onClick(() => this.auto = !this.auto)
          Button('刷新').fontSize(13).height(30).backgroundColor('#1E6FFF')
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        Text(this.msg).fontSize(12).fontColor('#999999').width('100%').padding({ left: 14, bottom: 6 })

        if (this.logs.length === 0) {
          Column({ space: 10 }) {
            Text(this.msg === '' ? '加载中...' : '暂无日志')
              .fontSize(14).fontColor('#999999')
            Text('每当 App 请求服务器, 这里会实时显示(同时写入 MySQL request_log)')
              .fontSize(12).fontColor('#BBBBBB').textAlign(TextAlign.Center)
          }.width('100%').margin({ top: 60 }).padding({ left: 30, right: 30 })
        } else {
          List({ space: 0 }) {
            ForEach(this.logs, (l: LogRow) => {
              ListItem() {
                this.item(l)
              }
            }, (l: LogRow) => l.time + l.method + l.path + l.ip + l.cost_ms)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: 14, right: 14 })
        }
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
