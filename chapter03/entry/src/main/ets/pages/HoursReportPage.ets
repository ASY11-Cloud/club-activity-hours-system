/**
 * 社团活动报名与学时认定系统 —— 学时统计报表(服务器 MySQL 排行 + 本地 SQLite 统计)
 * 普通成员: 排行 + 本人认定明细; 管理员: 全量明细。服务端按角色返回。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { HoursRow, HoursDetail, parseHoursReport, parseHoursDetail } from '../common/Models';

@Entry
@Component
struct HoursReportPage {
  @State report: HoursRow[] = [];
  @State detail: HoursDetail[] = [];
  @State localHours: number = 0;
  @State localCount: number = 0;
  @State msg: string = '';
  @State tab: number = 0; // 0 排行 1 明细
  @State notLoggedIn: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isLoggedIn) {
        this.notLoggedIn = true; // 未登录: 引导登录
        return;
      }
      this.load();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  onPageShow(): void {
    if (!this.notLoggedIn) this.load();
  }

  async load(): Promise<void> {
    const resp = await ApiClient.get('/api/hours/report');
    if (resp['code'] === 0) {
      this.report = parseHoursReport(resp);
      this.detail = parseHoursDetail(resp);
      this.msg = '服务器学时报表(MySQL hours_total 自动累计)';
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
    }
    // 本地统计(双端对比)
    try {
      this.localHours = await DbHelper.localHours(AppConfig.stuNo);
      this.localCount = (await DbHelper.getSignups(AppConfig.stuNo)).length;
    } catch (e) {
      this.localHours = 0;
      this.localCount = 0;
    }
  }

  @Builder
  rankRow(r: HoursRow) {
    Row() {
      Text(r.rank.toString()).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(r.rank <= 3 ? '#E84026' : '#999999').width(36).textAlign(TextAlign.Center)
      Column({ space: 2 }) {
        Text(r.name + '  (' + r.stu_no + ')').fontSize(14).fontWeight(FontWeight.Medium)
        Text('通过 ' + r.sign_count + ' 次活动').fontSize(11).fontColor('#999999')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(r.total_hours + ' 学时').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1E6FFF')
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  detailRow(d: HoursDetail) {
    Row() {
      Column({ space: 2 }) {
        Text(d.activity).fontSize(14).fontWeight(FontWeight.Medium)
        Text(d.name + ' · ' + d.audited_at).fontSize(11).fontColor('#999999')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('+' + d.hours + ' 学时').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#07C160')
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔑').fontSize(40)
      Text('请先登录').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('学时报表需要登录, 学生看本人明细, 管理员看全量统计')
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
          Text('学时统计报表').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text(AppConfig.isAdmin ? '管理员·全量' : '成员·本人明细')
            .fontSize(10).fontColor(Color.White)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(AppConfig.isAdmin ? '#F5652F' : '#07C160')
            .borderRadius(8)
          Button('刷新').fontSize(13).height(30).backgroundColor('#1E6FFF')
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        // 本地 vs 服务器 双端对比卡
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text('本地 SQLite 统计').fontSize(11).fontColor('#999999')
            Text(this.localHours + '').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1E6FFF')
            Text('通过 ' + this.localCount + ' 条').fontSize(11).fontColor('#999999')
          }.layoutWeight(1).padding(12).backgroundColor('#EAF1FF').borderRadius(12)

          Column({ space: 3 }) {
            Text('我的服务器学时').fontSize(11).fontColor('#999999')
            Text(this.serverHours() + '').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#07C160')
            Text('审核通过自动累计').fontSize(11).fontColor('#999999')
          }.layoutWeight(1).padding(12).backgroundColor('#E8F8EF').borderRadius(12)
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        Row({ space: 8 }) {
          this.tabBtn('学时排行', 0)
          this.tabBtn('认定明细', 1)
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        Text(this.msg).fontSize(12).fontColor('#999999').width('100%').padding({ left: 14, bottom: 6 })

        Scroll() {
          Column() {
            if (this.tab === 0) {
              if (this.report.length === 0) {
                Text('暂无学时记录, 审核通过报名后自动累计').fontSize(13).fontColor('#BBBBBB').margin({ top: 40 })
              } else {
                ForEach(this.report, (r: HoursRow) => {
                  this.rankRow(r)
                }, (r: HoursRow) => r.stu_no)
              }
            } else {
              if (this.detail.length === 0) {
                Text('暂无认定明细').fontSize(13).fontColor('#BBBBBB').margin({ top: 40 })
              } else {
                ForEach(this.detail, (d: HoursDetail) => {
                  this.detailRow(d)
                }, (d: HoursDetail) => d.stu_no + d.activity + d.audited_at)
              }
            }
          }.padding(14)
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }

  serverHours(): number {
    for (const r of this.report) {
      if (r.stu_no === AppConfig.stuNo) return r.total_hours;
    }
    return 0;
  }

  @Builder
  tabBtn(label: string, t: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.tab === t ? Color.White : '#333333')
      .padding({ left: 14, right: 14, top: 5, bottom: 5 })
      .backgroundColor(this.tab === t ? '#1E6FFF' : '#E9ECF3')
      .borderRadius(14)
      .onClick(() => this.tab = t)
  }
}
