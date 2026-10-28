/**
 * 社团活动报名与学时认定系统 —— 服务器实时请求日志(仅管理员)
 * 支持按级别(全部/失败/慢请求)、方法(GET/POST)、路径关键词筛选,
 * 筛选在服务端内存日志上执行(handleLogs), 前端只负责组装查询条件。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { LogRow, parseLogs, dataOf, numOf } from '../common/Models';
import { AdminGuardView } from '../common/GuardViews';
import { Theme } from '../common/Theme';

@Entry
@Component
struct ServerLogPage {
  @State logs: LogRow[] = [];
  @State msg: string = '';
  @State auto: boolean = true;
  @State blocked: boolean = false;
  @State level: string = '';      // '' 全部 | err 失败(>=400) | slow 慢请求(>=500ms)
  @State method: string = '';     // '' 全部 | GET | POST
  @State kw: string = '';         // 已生效的路径关键词
  @State kwInput: string = '';    // 输入框内容
  @State matched: number = 0;     // 命中条数(服务端)
  @State totalAll: number = 0;    // 服务器内存日志总条数
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

  /** 组装日志查询串(级别/方法/关键词在服务端过滤) */
  buildPath(): string {
    let q = '/api/logs?limit=100';
    if (this.level !== '') q += '&level=' + this.level;
    if (this.method !== '') q += '&method=' + this.method;
    if (this.kw !== '') q += '&kw=' + encodeURIComponent(this.kw);
    return q;
  }

  async load(): Promise<void> {
    const resp = await ApiClient.get(this.buildPath());
    if (resp['code'] === 0) {
      this.logs = parseLogs(resp);
      const d = dataOf(resp);
      if (d !== null) {
        this.totalAll = numOf(d, 'total');
        this.matched = numOf(d, 'matched');
      }
      this.msg = '内存日志 ' + this.totalAll + ' 条, 命中 ' + this.matched +
        ' 条, 当前显示 ' + this.logs.length + ' 条';
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
    }
  }

  /** 筛选切换后立即刷新(不等下一次定时) */
  applyFilter(): void {
    this.load();
  }

  @Builder
  chip(label: string, active: boolean, kind: string, val: string) {
    Text(label)
      .fontSize(11)
      .fontColor(active ? Color.White : Theme.textBody)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .backgroundColor(active ? Theme.primary : Theme.bgNeutral)
      .borderRadius(12)
      .onClick(() => {
        if (kind === 'level') {
          this.level = val;
        } else {
          this.method = val;
        }
        this.applyFilter();
      })
  }

  @Builder
  item(l: LogRow) {
    Row() {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(l.method).fontSize(11).fontColor(Color.White)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(l.method === 'POST' ? Theme.danger : Theme.primary).borderRadius(4)
          Text(l.status.toString()).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor(l.status >= 400 ? Theme.danger : Theme.success)
          if (l.cost_ms >= 500) {
            Text('慢').fontSize(9).fontColor(Color.White)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor(Theme.warning).borderRadius(4)
          }
        }
        Text(l.path).fontSize(13).fontColor(Theme.textBody)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 3 }) {
        Text(l.time).fontSize(11).fontColor(Theme.textTertiary)
        Text(l.ip + ' · ' + l.cost_ms + 'ms').fontSize(11).fontColor(Theme.textTertiary)
      }.alignItems(HorizontalAlign.End)
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    AdminGuardView({ tip: '服务器实时日志仅限管理员查看, 请以管理员身份登录后访问' })
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
          Text('服务器实时日志').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text(this.auto ? '● 自动刷新' : '○ 手动刷新')
            .fontSize(12).fontColor(this.auto ? Theme.success : Theme.textTertiary)
            .onClick(() => this.auto = !this.auto)
          Button('刷新').fontSize(13).height(30).backgroundColor(Theme.primary).margin({ left: 8 })
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        // 级别 + 方法筛选
        Row({ space: 6 }) {
          this.chip('全部', this.level === '', 'level', '')
          this.chip('失败', this.level === 'err', 'level', 'err')
          this.chip('慢请求', this.level === 'slow', 'level', 'slow')
          Row().width(1).height(14).backgroundColor(Theme.divider).margin({ left: 2, right: 2 })
          this.chip('ALL', this.method === '', 'method', '')
          this.chip('GET', this.method === 'GET', 'method', 'GET')
          this.chip('POST', this.method === 'POST', 'method', 'POST')
        }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

        // 路径关键词
        Row({ space: 8 }) {
          TextInput({ text: this.kwInput, placeholder: '按路径关键词过滤(如 /api/signup)' })
            .layoutWeight(1).height(32).fontSize(12)
            .onChange((v: string) => this.kwInput = v)
            .onSubmit(() => {
              this.kw = this.kwInput;
              this.applyFilter();
            })
          Button('过滤').fontSize(12).height(32).backgroundColor(Theme.primary)
            .onClick(() => {
              this.kw = this.kwInput;
              this.applyFilter();
            })
          if (this.kw !== '') {
            Button('清除').fontSize(12).height(32).backgroundColor(Theme.textTertiary)
              .onClick(() => {
                this.kwInput = '';
                this.kw = '';
                this.applyFilter();
              })
          }
        }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

        Text(this.msg).fontSize(12).fontColor(Theme.textTertiary).width('100%').padding({ left: 14, bottom: 6 })

        if (this.logs.length === 0) {
          Column({ space: 10 }) {
            Text(this.msg === '' ? '加载中...' : '没有符合条件的日志')
              .fontSize(14).fontColor(Theme.textTertiary)
            Text('每当 App 请求服务器, 这里会实时显示(同时写入 MySQL request_log)')
              .fontSize(12).fontColor(Theme.textDisabled).textAlign(TextAlign.Center)
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
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
