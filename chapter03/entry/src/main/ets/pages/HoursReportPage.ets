/**
 * 社团活动报名与学时认定系统 —— 学时统计报表(服务器 MySQL 排行 + 本地 SQLite 统计)
 * 普通成员: 排行 + 本人认定明细; 管理员: 全量明细 + 达标线设置 + CSV 导出。
 * 服务端按角色返回, 并下发学时达标线 required_hours 与达标人数。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { LoginGuardView } from '../common/GuardViews';
import {
  HoursRow, HoursDetail, parseHoursReport, parseHoursDetail, parseSignups, dataOf, numOf, csvCell
} from '../common/Models';
import { Theme } from '../common/Theme';

@Entry
@Component
struct HoursReportPage {
  @State report: HoursRow[] = [];
  @State detail: HoursDetail[] = [];
  @State localHours: number = 0;
  @State localCount: number = 0;
  @State serverTotal: number = 0;      // 服务端合计学时(管理员=全量, 成员=本人排行行求和等价)
  @State requiredHours: number = 0;    // 学时达标线(0 表示未设置)
  @State achievedCount: number = 0;    // 达标人数
  @State requiredInput: string = '';   // 管理员编辑达标线的输入框
  @State msg: string = '';
  @State tab: number = 0; // 0 排行 1 明细
  @State notLoggedIn: boolean = false;
  @State exporting: boolean = false;
  @State calibrating: boolean = false;

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
    // 从登录页返回且已登录: 解除未登录守卫
    if (this.notLoggedIn && AppConfig.isLoggedIn) this.notLoggedIn = false;
    if (!this.notLoggedIn) this.load();
  }

  async load(): Promise<void> {
    const resp = await ApiClient.get('/api/hours/report');
    if (resp['code'] === 0) {
      this.report = parseHoursReport(resp);
      this.detail = parseHoursDetail(resp);
      const d = dataOf(resp);
      if (d !== null) {
        this.serverTotal = numOf(d, 'total_hours');
        this.requiredHours = numOf(d, 'required_hours');
        this.achievedCount = numOf(d, 'achieved_count');
        if (this.requiredInput === '') this.requiredInput = this.requiredHours.toString();
      }
      this.msg = '服务器学时报表(MySQL hours_total 自动累计)';
    } else {
      this.msg = '拉取失败: ' + (resp['msg'] as string);
    }
    // 本地统计(双端对比): 管理员统计本机全部成员记录, 成员只统计本人
    try {
      if (AppConfig.isAdmin) {
        this.localHours = await DbHelper.localAllHours();
        this.localCount = await DbHelper.localAllPassedCount();
      } else {
        this.localHours = await DbHelper.localHours(AppConfig.stuNo);
        this.localCount = await DbHelper.localPassedCount(AppConfig.stuNo);
      }
    } catch (e) {
      this.localHours = 0;
      this.localCount = 0;
    }
  }

  /** 管理员: 设置学时达标线(0 = 不设线, 报表不再标注达标) */
  async saveRequired(): Promise<void> {
    const v = Number(this.requiredInput);
    if (isNaN(v) || v < 0 || v > 999) {
      this.msg = '达标线应为 0~999 之间的数字(0 表示不设线)';
      return;
    }
    const resp = await ApiClient.post('/api/config/set', { 'required_hours': v });
    if (resp['code'] !== 0) {
      this.msg = '设置失败: ' + (resp['msg'] as string);
      return;
    }
    await this.load();
    this.msg = v > 0 ? '达标线已设为 ' + v + ' 学时' : '已取消学时达标线';
  }

  /** 生成当前标签页的 CSV 文本 */
  buildCsv(): string {
    const lines: string[] = [];
    if (this.tab === 0) {
      lines.push('排名,学号,姓名,总学时,通过次数,是否达标');
      for (const r of this.report) {
        lines.push([r.rank.toString(), r.stu_no, r.name, r.total_hours.toString(),
          r.sign_count.toString(), r.achieved ? '达标' : (this.requiredHours > 0 ? '未达标' : '未设置')]
          .map((s: string) => csvCell(s)).join(','));
      }
    } else {
      lines.push('学号,姓名,活动,认定学时,认定时间');
      for (const d of this.detail) {
        lines.push([d.stu_no, d.name, d.activity, d.hours.toString(), d.audited_at]
          .map((s: string) => csvCell(s)).join(','));
      }
    }
    return lines.join('\n');
  }

  /**
   * 导出当前标签页为 CSV 文件(写入应用沙箱 filesDir)。
   * 鸿蒙应用沙箱文件无法直接被电脑打开, 因此同时提供「复制到剪贴板」便于粘贴到 Excel。
   */
  async exportCsv(): Promise<void> {
    if (this.exporting) return;
    const rows = this.tab === 0 ? this.report.length : this.detail.length;
    if (rows === 0) {
      this.msg = '当前页没有数据可导出';
      return;
    }
    this.exporting = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const now = new Date();
      const pad = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString());
      const stamp = now.getFullYear().toString() + pad(now.getMonth() + 1) + pad(now.getDate()) +
        '_' + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
      const name = (this.tab === 0 ? 'hours_rank_' : 'hours_detail_') + stamp + '.csv';
      const path = ctx.filesDir + '/' + name;
      // UTF-8 BOM: 不加的话 Excel(WPS 不受影响)双击打开中文全是乱码,
      // Excel 只认带 BOM 的 UTF-8, 演示现场用 Excel 打开导出文件会非常尴尬
      const text = '\uFEFF' + this.buildCsv();
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      this.msg = '已导出 ' + rows + ' 行 CSV: ' + path;
      AlertDialog.show({
        title: 'CSV 已导出',
        message: '文件: ' + name + '\n路径: ' + path + '\n\n也可直接复制内容粘贴到 Excel/WPS。',
        autoCancel: true,
        alignment: DialogAlignment.Center,
        primaryButton: { value: '知道了', action: () => {
        } },
        secondaryButton: {
          value: '复制内容',
          fontColor: Theme.primary,
          action: async () => {
            const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
            await pasteboard.getSystemPasteboard().setData(data);
            this.msg = 'CSV 内容已复制到剪贴板(' + rows + ' 行)';
          }
        }
      });
    } catch (e) {
      this.msg = '导出失败: ' + (e as Error).message;
    } finally {
      this.exporting = false;
    }
  }

  /** 管理员: 以 signup(status=1) 为事实来源重建学时汇总, 修复历史漂移 */
  async rebuild(): Promise<void> {
    this.msg = '正在重算学时汇总...';
    const resp = await ApiClient.post('/api/hours/rebuild', {});
    if (resp['code'] !== 0) {
      this.msg = '重算失败: ' + (resp['msg'] as string);
      return;
    }
    const d = resp['data'] as Record<string, Object>;
    await this.load();
    this.msg = '重算完成: ' + (d['students'] as number) + ' 名学生, 合计 ' + (d['total_hours'] as number) + ' 学时';
  }

  @Builder
  rankRow(r: HoursRow) {
    Row() {
      Text(r.rank.toString()).fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(r.rank <= 3 ? Theme.danger : Theme.textTertiary).width(36).textAlign(TextAlign.Center)
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(r.name + '  (' + r.stu_no + ')').fontSize(14).fontWeight(FontWeight.Medium)
          if (r.achieved) {
            Text('达标').fontSize(9).fontColor(Color.White)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Theme.success).borderRadius(6)
          }
        }
        Text('通过 ' + r.sign_count + ' 次活动' +
          (this.requiredHours > 0 ? (r.achieved ? '' : ' · 距达标 ' + (this.requiredHours - r.total_hours) + ' 学时') : ''))
          .fontSize(11).fontColor(Theme.textTertiary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(r.total_hours + ' 学时').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.primary)
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  detailRow(d: HoursDetail) {
    Row() {
      Column({ space: 2 }) {
        Text(d.activity).fontSize(14).fontWeight(FontWeight.Medium)
        Text(d.name + ' · ' + d.audited_at).fontSize(11).fontColor(Theme.textTertiary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('+' + d.hours + ' 学时').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Theme.success)
    }
    .width('100%').padding(12).backgroundColor(Color.White).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  deniedView() {
    LoginGuardView({ tip: '学时报表需要登录, 学生看本人明细, 管理员看全量统计' })
  }

  build() {
    Column() {
      if (this.notLoggedIn) {
        this.deniedView()
      } else {
        Row() {
          Text('‹ 返回').fontSize(14).fontColor(Theme.primary)
            .padding({ right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('学时统计报表').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text(AppConfig.isAdmin ? '管理员·全量' : '成员·本人明细')
            .fontSize(10).fontColor(Color.White)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(AppConfig.isAdmin ? Theme.admin : Theme.success)
            .borderRadius(8)
          Button('刷新').fontSize(13).height(30).backgroundColor(Theme.primary)
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        // 管理员设置(达标线 + 重算), 收纳为一张卡片降低顶部信息密度
        if (AppConfig.isAdmin) {
          Column({ space: 8 }) {
            Row({ space: 6 }) {
              Text('学时达标线').fontSize(11).fontColor(Theme.textSecondary)
              TextInput({ text: this.requiredInput, placeholder: '0 不设线' })
                .type(InputType.NUMBER_DECIMAL).height(28).width(76).fontSize(12)
                .onChange((v: string) => this.requiredInput = v)
              Text('学时').fontSize(11).fontColor(Theme.textSecondary)
              Button('保存').fontSize(11).height(26).backgroundColor(Theme.primary)
                .onClick(() => this.saveRequired())
              Text(this.requiredHours > 0 ? '已达标 ' + this.achievedCount + ' 人' : '未设线')
                .fontSize(11).fontColor(Theme.textTertiary).layoutWeight(1).textAlign(TextAlign.End)
            }.width('100%')

            Row().width('100%').height(0.5).backgroundColor(Theme.divider)

            Row({ space: 6 }) {
              Text('汇总由服务端审核事务自动累计, 可一键重算修复历史漂移')
                .fontSize(10).fontColor(Theme.textTertiary).layoutWeight(1)
              Button('重算学时').fontSize(11).height(26).backgroundColor(Theme.admin)
                .onClick(() => this.rebuild())
            }.width('100%')
          }
          .width('100%').padding(12).margin({ left: 14, right: 14, bottom: 8 })
          .backgroundColor(Color.White).borderRadius(12)
        }

        // CSV 导出: 导出当前标签页(排行 / 明细), 便于交作业或表格留档
        Row({ space: 8 }) {
          Text(this.requiredHours > 0 && !AppConfig.isAdmin
            ? '达标线 ' + this.requiredHours + ' 学时 · 已达标 ' + this.achievedCount + ' 人'
            : (this.tab === 0 ? '当前: 学时排行' : '当前: 认定明细'))
            .fontSize(10).fontColor(Theme.textTertiary).layoutWeight(1)
          Button(this.exporting ? '导出中...' : '导出CSV').fontSize(11).height(26).backgroundColor(Theme.report)
            .enabled(!this.exporting).onClick(() => this.exportCsv())
        }.width('100%').padding({ left: 14, right: 14, bottom: 6 })

        // 本地 vs 服务器 双端对比卡
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(AppConfig.isAdmin ? '本地 SQLite 全量' : '本地 SQLite 统计').fontSize(11).fontColor(Theme.textTertiary)
            Text(this.localHours + '').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.primary)
            Text('通过 ' + this.localCount + ' 条').fontSize(11).fontColor(Theme.textTertiary)
          }.layoutWeight(1).padding(12).backgroundColor(Theme.primaryBg).borderRadius(12)

          Column({ space: 3 }) {
            Text(AppConfig.isAdmin ? '服务器全量学时' : '我的服务器学时').fontSize(11).fontColor(Theme.textTertiary)
            Text((AppConfig.isAdmin ? this.serverTotal : this.serverHours()) + '')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.success)
            Text(this.serverSubText()).fontSize(11).fontColor(Theme.textTertiary)
          }.layoutWeight(1).padding(12).backgroundColor(Theme.successBg).borderRadius(12)
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        // 双端一致判定: 本地缓存相对服务器可能滞后(审核结果在服务器), 一键校准后再比对
        Row({ space: 8 }) {
          Text(this.bothSame()
            ? '双端一致: 学时与记录条数均与服务器相同'
            : '两端不一致: 差 ' +
              (Math.round(Math.abs(this.localHours - this.serverMine()) * 10) / 10) + ' 学时 / ' +
              Math.abs(this.localCount - this.detail.length) + ' 条(服务器审核后本地未刷新)')
            .fontSize(11)
            .fontColor(this.bothSame() ? Theme.success : Theme.warning)
            .layoutWeight(1)
          Button(this.calibrating ? '校准中...' : '校准本地缓存')
            .fontSize(11).height(26).backgroundColor(Theme.primary)
            .enabled(!this.calibrating)
            .onClick(() => this.calibrate())
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        Row({ space: 8 }) {
          this.tabBtn('学时排行', 0)
          this.tabBtn('认定明细', 1)
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        Text(this.msg).fontSize(12).fontColor(Theme.textTertiary).width('100%').padding({ left: 14, bottom: 6 })

        Scroll() {
          Column() {
            if (this.tab === 0) {
              if (this.report.length === 0) {
                Text('暂无学时记录, 审核通过报名后自动累计').fontSize(13).fontColor(Theme.textDisabled).margin({ top: 40 })
              } else {
                ForEach(this.report, (r: HoursRow) => {
                  this.rankRow(r)
                }, (r: HoursRow) => r.stu_no + '-' + r.total_hours.toString())
              }
            } else {
              if (this.detail.length === 0) {
                Text('暂无认定明细').fontSize(13).fontColor(Theme.textDisabled).margin({ top: 40 })
              } else {
                ForEach(this.detail, (d: HoursDetail) => {
                  this.detailRow(d)
                }, (d: HoursDetail) => d.stu_no + d.activity + d.audited_at)
              }
            }
          }.padding(14)
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }

  serverHours(): number {
    if (AppConfig.isAdmin) {
      // 管理员视角: 展示全量累计学时
      let total = 0;
      for (const r of this.report) total += r.total_hours;
      return total;
    }
    for (const r of this.report) {
      if (r.stu_no === AppConfig.stuNo) return r.total_hours;
    }
    return 0;
  }

  /** 服务器端(权威)学时: 管理员=全量合计, 成员=本人排行行 */
  serverMine(): number {
    return AppConfig.isAdmin ? this.serverTotal : this.serverHours();
  }

  /** 双端是否一致: 学时与"已通过记录条数"都对上才算一致(只看学时可能掩盖条数差异) */
  bothSame(): boolean {
    const hoursSame = Math.abs(this.localHours - this.serverMine()) < 0.05;
    return hoursSame && this.localCount === this.detail.length;
  }

  /**
   * 校准本地缓存: 以服务器报名记录为准回填本地 SQLite(含审核状态/学时/刷卡标记)。
   * 管理员拉全量, 成员只拉本人; 服务端学生身份本身也会强制过滤为本人。
   * 用途: 演示"双端一致"时, 避免本地缓存停留在旧状态(如服务器已审核通过, 本地仍待审核)。
   */
  async calibrate(): Promise<void> {
    if (this.calibrating) return;
    this.calibrating = true;
    this.msg = '正在从服务器校准本地缓存...';
    try {
      let page = 1;
      let total = 0;
      while (page <= 10) {
        let path = '/api/signup/list?page=' + page.toString() + '&size=200';
        if (!AppConfig.isAdmin) path += '&stu_no=' + encodeURIComponent(AppConfig.stuNo);
        const resp = await ApiClient.get(path);
        if (resp['code'] !== 0) {
          this.msg = '校准失败: ' + (resp['msg'] as string);
          return;
        }
        const list = parseSignups(resp);
        for (const s of list) {
          await DbHelper.upsertSignupFromServer(s.client_id, s.activity_id, s.activity_title,
            s.stu_no, s.name, s.status, s.checkin, s.hours, s.remark, s.created_at);
          await DbHelper.markSignupSynced(s.client_id);
        }
        total += list.length;
        if (list.length < 200) break;
        page++;
      }
      await this.load();
      this.msg = '本地缓存已按服务器校准: ' + total + ' 条记录';
    } finally {
      this.calibrating = false;
    }
  }

  /** 服务器学时卡副标题: 未设达标线时提示累计口径, 设线后显示达标情况 */
  serverSubText(): string {
    const cnt = this.detail.length;
    if (this.requiredHours <= 0) return '通过 ' + cnt + ' 条';
    if (AppConfig.isAdmin) {
      return '通过 ' + cnt + ' 条 · 达标 ' + this.achievedCount + '/' + this.report.length + ' 人';
    }
    const my = this.serverHours();
    return '通过 ' + cnt + ' 条 · ' +
      (my >= this.requiredHours ? '已达标' : '差 ' + (this.requiredHours - my) + ' 学时');
  }

  @Builder
  tabBtn(label: string, t: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.tab === t ? Color.White : Theme.textBody)
      .padding({ left: 14, right: 14, top: 5, bottom: 5 })
      .backgroundColor(this.tab === t ? Theme.primary : Theme.bgNeutral)
      .borderRadius(14)
      .onClick(() => this.tab = t)
  }
}
