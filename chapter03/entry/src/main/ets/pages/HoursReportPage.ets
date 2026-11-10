/**
 * 社团活动报名与学时认定系统 —— 学时统计报表(服务器 MySQL 排行 + 本地 SQLite 统计)
 * 普通成员: 排行 + 本人认定明细; 管理员: 全量明细 + 达标线设置 + CSV 导出。
 * 服务端按角色返回, 并下发学时达标线 required_hours 与达标人数。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { LoginGuardView } from '../common/GuardViews';
import {
  HoursRow, HoursDetail, CategoryStat, WarningRow, parseHoursReport, parseHoursDetail,
  parseCategoryStats, parseWarningList, parseSignups, dataOf, numOf, csvCell, categoryText,
  AnomalyBurst, AnomalyNotOut, AnomalyExceed, ClubStats, parseClubStats,
  parseAnomalyBurst, parseAnomalyNotOut, parseAnomalyExceed
} from '../common/Models';
import { Theme } from '../common/Theme';

@Entry
@Component
struct HoursReportPage {
  @State report: HoursRow[] = [];
  @State detail: HoursDetail[] = [];
  @State categoryStats: CategoryStat[] = [];   // 分类学时汇总(条形图)
  @State warnList: WarningRow[] = [];          // 学分预警名单(管理员)
  // v4.0 签到异常检测(管理员)
  @State burst: AnomalyBurst[] = [];
  @State notOut: AnomalyNotOut[] = [];
  @State exceed: AnomalyExceed[] = [];
  @State localHours: number = 0;
  @State localCount: number = 0;
  @State serverTotal: number = 0;      // 服务端合计学时(管理员=全量, 成员=本人排行行求和等价)
  @State requiredHours: number = 0;    // 学时达标线(0 表示未设置)
  @State achievedCount: number = 0;    // 达标人数
  @State requiredInput: string = '';   // 管理员编辑达标线的输入框
  @State msg: string = '';
  @State tab: number = 0; // 0 排行 1 明细 2 预警(管理员)
  @State notLoggedIn: boolean = false;
  @State exporting: boolean = false;
  @State calibrating: boolean = false;
  // v5.0 社团维度统计(仅社团账号): 内部/公开活动数 + 公开活动带来的外社团参与
  @State csInternal: number = 0;
  @State csPublic: number = 0;
  @State csOutsider: number = 0;
  @State csOutsiderJoin: number = 0;
  @State csPassRate: number = 0;
  @State csLoaded: boolean = false;

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
      this.categoryStats = parseCategoryStats(resp);
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
    // 学分预警名单(仅管理员): 未达标学生 + 缺口学时, 可直接导出
    if (AppConfig.isAdmin) {
      // 社团账号额外拉一条社团维度统计(平台管理员没有"本社团", 不展示)
      if (AppConfig.isClubAccount) {
        const cs = await ApiClient.get('/api/stats/club');
        const st: ClubStats | null = cs['code'] === 0 ? parseClubStats(cs) : null;
        if (st !== null) {
          this.csInternal = st.internal_count;
          this.csPublic = st.public_count;
          this.csOutsider = st.outsider_count;
          this.csOutsiderJoin = st.outsider_join_count;
          this.csPassRate = st.pass_rate;
          this.csLoaded = true;
        } else {
          this.csLoaded = false;
        }
      } else {
        this.csLoaded = false;
      }
      const w = await ApiClient.get('/api/report/warning');
      this.warnList = w['code'] === 0 ? parseWarningList(w) : [];
      // 签到异常检测(v4.0): 批量签到 / 长期未签退 / 学时超限
      const an = await ApiClient.get('/api/report/anomaly');
      if (an['code'] === 0) {
        this.burst = parseAnomalyBurst(an);
        this.notOut = parseAnomalyNotOut(an);
        this.exceed = parseAnomalyExceed(an);
      } else {
        this.burst = [];
        this.notOut = [];
        this.exceed = [];
      }
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
    } else if (this.tab === 2) {
      lines.push('学号,姓名,班级,已认定学时,通过次数,缺口学时,最近认定');
      for (const w of this.warnList) {
        lines.push([w.stu_no, w.name, w.dept, w.total_hours.toString(), w.sign_count.toString(),
          w.gap.toString(), w.last_activity_at].map((s: string) => csvCell(s)).join(','));
      }
    } else if (this.tab === 3) {
      lines.push('类型,活动,学号,姓名,数量/学时,时间');
      for (const b of this.burst) {
        lines.push(['批量签到', b.activity_title, '', '', b.count.toString(), b.window_start]
          .map((s: string) => csvCell(s)).join(','));
      }
      for (const n of this.notOut) {
        lines.push(['签到未签退', n.activity_title, n.stu_no, n.name,
          n.hours.toString(), n.checked_at].map((s: string) => csvCell(s)).join(','));
      }
      for (const e of this.exceed) {
        lines.push(['学时超限', e.activity_title, e.stu_no, e.name,
          e.hours.toString(), ''].map((s: string) => csvCell(s)).join(','));
      }
    } else {
      lines.push('学号,姓名,活动,类别,认定学时,认定时间');
      for (const d of this.detail) {
        lines.push([d.stu_no, d.name, d.activity, categoryText(d.category), d.hours.toString(), d.audited_at]
          .map((s: string) => csvCell(s)).join(','));
      }
    }
    return lines.join('\n');
  }

  stamp(): string {
    const now = new Date();
    const pad = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString());
    return now.getFullYear().toString() + pad(now.getMonth() + 1) + pad(now.getDate()) +
      '_' + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
  }

  /**
   * 导出当前标签页为 CSV。
   * 首选系统「保存到…」选择器(DocumentViewPicker): 用户自己选下载/文档目录,
   * 导出后能真的在文件管理里找到; 选择器不可用或用户取消时回退到
   * 「写沙箱 + 复制到剪贴板」, 保证离线/受限环境也能拿到数据。
   */
  async exportCsv(): Promise<void> {
    if (this.exporting) return;
    let rows = 0;
    if (this.tab === 0) rows = this.report.length;
    else if (this.tab === 1) rows = this.detail.length;
    else if (this.tab === 2) rows = this.warnList.length;
    else rows = this.burst.length + this.notOut.length + this.exceed.length;
    if (rows === 0) {
      this.msg = '当前页没有数据可导出';
      return;
    }
    this.exporting = true;
    // UTF-8 BOM: 不加的话 Excel 双击打开中文全是乱码(Excel 只认带 BOM 的 UTF-8)
    const text = '\uFEFF' + this.buildCsv();
    const prefix = this.tab === 0 ? 'hours_rank_' : (this.tab === 1 ? 'hours_detail_' : 'hours_warning_');
    const name = prefix + this.stamp() + '.csv';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [name];
      const saveUri = await new picker.DocumentViewPicker(ctx).save(opts);
      if (saveUri.length === 0) {
        this.msg = '已取消保存';
        return;
      }
      const file = fileIo.openSync(saveUri[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      this.msg = '已保存 ' + rows + ' 行 CSV: ' + name;
    } catch (e) {
      await this.fallbackExport(text, name, rows, (e as Error).message);
    } finally {
      this.exporting = false;
    }
  }

  /** 选择器不可用时的兜底: 写应用沙箱 + 提供复制到剪贴板 */
  async fallbackExport(text: string, name: string, rows: number, reason: string): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path = ctx.filesDir + '/' + name;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      this.msg = '已导出到应用沙箱(选择器不可用: ' + reason + ')';
      AlertDialog.show({
        title: 'CSV 已导出',
        message: '文件: ' + name + '\n路径: ' + path + '\n\n也可复制内容粘贴到 Excel/WPS。',
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
    } catch (e2) {
      this.msg = '导出失败: ' + (e2 as Error).message;
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
            Text('达标').fontSize(9).fontColor(Theme.textOnPrimary)
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
    .width('100%').padding(12).backgroundColor(Theme.bgCard).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  categoryBar(c: CategoryStat) {
    Row({ space: 8 }) {
      Text(categoryText(c.category)).fontSize(10).fontColor(Theme.textSecondary).width(56)
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width(this.barPct(c.hours).toString() + '%')
          .height(8).backgroundColor(Theme.primary).borderRadius(4)
      }.layoutWeight(1).height(8).backgroundColor(Theme.bgNeutral).borderRadius(4)
      Text(c.hours.toString() + 'h').fontSize(10).fontColor(Theme.textTertiary)
        .width(40).textAlign(TextAlign.End)
    }.width('100%')
  }

  @Builder
  warnRow(w: WarningRow) {
    Row() {
      Column({ space: 2 }) {
        Text(w.name + '  ' + w.stu_no).fontSize(13).fontWeight(FontWeight.Medium)
        Text(w.dept + ' · 已认定 ' + w.total_hours + ' 学时 · 通过 ' + w.sign_count + ' 次' +
          (w.last_activity_at === '' ? ' · 从未认定' : ''))
          .fontSize(11).fontColor(Theme.textTertiary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('缺 ' + w.gap).fontSize(13).fontWeight(FontWeight.Bold).fontColor(Theme.danger)
    }
    .width('100%').padding(12).backgroundColor(Theme.bgCard).borderRadius(12).margin({ bottom: 8 })
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
    .width('100%').padding(12).backgroundColor(Theme.bgCard).borderRadius(12).margin({ bottom: 8 })
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
          // 社团账号看到的是"本社团活动产生的学时"(按 signup.club_id 口径), 不是平台全量
          Text(AppConfig.isClubAccount ? '社团·本社团活动口径'
            : (AppConfig.isAdmin ? '管理员·全量' : '成员·本人明细'))
            .fontSize(10).fontColor(Theme.textOnPrimary)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(AppConfig.isAdmin ? Theme.admin : Theme.success)
            .borderRadius(8)
          Button('刷新').fontSize(13).height(30).backgroundColor(Theme.primary)
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        // 页签固定在页头下方(仅一行): 排行/明细/预警/异常随时可切, 不用滚回顶部
        Row({ space: 8 }) {
          this.tabBtn('学时排行', 0)
          this.tabBtn('认定明细', 1)
          if (AppConfig.isAdmin) {
            this.tabBtn('学分预警', 2)
            this.tabBtn('异常检测', 3)
          }
        }.width('100%').padding({ left: 14, right: 14, bottom: 8 })

        // 概览与图表全部进滚动区: 之前七八块统计钉在顶部占掉 2/3 屏, 列表只剩一条缝
        Scroll() {
          Column() {
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
                  Text(AppConfig.isClubAccount
                    ? '学时归属「活动所属社团」: 公开活动带来的外社团参与也计入本社团'
                    : '汇总由服务端审核事务自动累计, 可一键重算修复历史漂移')
                    .fontSize(10).fontColor(Theme.textTertiary).layoutWeight(1)
                  Button('重算学时').fontSize(11).height(26).backgroundColor(Theme.admin)
                    .onClick(() => this.rebuild())
                }.width('100%')
              }
              .width('100%').padding(12).margin({ bottom: 8 })
              .backgroundColor(Theme.bgCard).borderRadius(12)
            }

            // CSV 导出: 导出当前标签页(排行 / 明细), 便于交作业或表格留档
            Row({ space: 8 }) {
              Text(this.requiredHours > 0 && !AppConfig.isAdmin
                ? '达标线 ' + this.requiredHours + ' 学时 · 已达标 ' + this.achievedCount + ' 人'
                : (this.tab === 0 ? '当前: 学时排行' : '当前: 认定明细'))
                .fontSize(10).fontColor(Theme.textTertiary).layoutWeight(1)
              Button(this.exporting ? '导出中...' : '导出CSV').fontSize(11).height(26).backgroundColor(Theme.report)
                .enabled(!this.exporting).onClick(() => this.exportCsv())
            }.width('100%').padding({ bottom: 6 })

            // 本地 vs 服务器 双端对比卡
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(AppConfig.isAdmin ? '本地 SQLite 全量' : '本地 SQLite 统计')
                  .fontSize(11).fontColor(Theme.textTertiary)
                Text(this.localHours + '').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.primary)
                Text('通过 ' + this.localCount + ' 条').fontSize(11).fontColor(Theme.textTertiary)
              }.layoutWeight(1).padding(12).backgroundColor(Theme.primaryBg).borderRadius(12)

              Column({ space: 3 }) {
                Text(AppConfig.isAdmin ? '服务器全量学时' : '我的服务器学时')
                  .fontSize(11).fontColor(Theme.textTertiary)
                Text((AppConfig.isAdmin ? this.serverTotal : this.serverHours()) + '')
                  .fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.success)
                Text(this.serverSubText()).fontSize(11).fontColor(Theme.textTertiary)
              }.layoutWeight(1).padding(12).backgroundColor(Theme.successBg).borderRadius(12)
            }.width('100%').padding({ bottom: 8 })

            // v5.0 社团维度统计卡(仅社团账号): 参与范围分布 + 公开活动的外部参与
            if (this.csLoaded) {
              Column({ space: 8 }) {
                Row({ space: 6 }) {
                  Text('社团维度统计').fontSize(13).fontWeight(FontWeight.Medium).fontColor(Theme.textPrimary)
                    .layoutWeight(1)
                  Text('按活动所属社团归集').fontSize(10).fontColor(Theme.textTertiary)
                }.width('100%')

                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Text('仅本社团活动').fontSize(11).fontColor(Theme.textTertiary)
                    Text(this.csInternal.toString()).fontSize(18).fontWeight(FontWeight.Bold)
                      .fontColor(Theme.primary)
                  }.layoutWeight(1).padding(10).backgroundColor(Theme.primaryBg).borderRadius(Theme.radiusSm)

                  Column({ space: 3 }) {
                    Text('全校开放活动').fontSize(11).fontColor(Theme.textTertiary)
                    Text(this.csPublic.toString()).fontSize(18).fontWeight(FontWeight.Bold)
                      .fontColor(Theme.success)
                  }.layoutWeight(1).padding(10).backgroundColor(Theme.successBg).borderRadius(Theme.radiusSm)

                  Column({ space: 3 }) {
                    Text('通过率').fontSize(11).fontColor(Theme.textTertiary)
                    Text((Math.round(this.csPassRate * 10) / 10).toString() + '%')
                      .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Theme.report)
                  }.layoutWeight(1).padding(10).backgroundColor(Theme.reportBg).borderRadius(Theme.radiusSm)
                }.width('100%')

                Row({ space: 6 }) {
                  Text('外社团参与').fontSize(11).fontColor(Theme.textSecondary)
                  Text(this.csOutsider.toString() + ' 人 / ' + this.csOutsiderJoin.toString() + ' 次')
                    .fontSize(12).fontWeight(FontWeight.Medium).fontColor(Theme.warning)
                  Text('（仅全校开放活动可产生）').fontSize(10)
                    .fontColor(Theme.textTertiary).layoutWeight(1)
                }.width('100%')
              }
              .width('100%').padding(12).margin({ bottom: 8 })
              .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusMd).alignItems(HorizontalAlign.Start)
            }

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
            }.width('100%').padding({ bottom: 8 })

            // 可视化: 达标率环形图 + 分类学时条形图(纯布局实现, 不引第三方图表库)
            if (this.report.length > 0) {
              Column({ space: 10 }) {
                Row({ space: 12 }) {
                  Stack() {
                    Progress({ value: this.achievePct(), total: 100, type: ProgressType.Ring })
                      .width(64).height(64).color(Theme.success).backgroundColor(Theme.bgNeutral)
                    Column({ space: 0 }) {
                      Text(this.achievePct().toString() + '%')
                        .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Theme.textPrimary)
                      Text('达标率').fontSize(9).fontColor(Theme.textTertiary)
                    }
                  }

                  Column({ space: 4 }) {
                    Text('已达标 ' + this.achievedCount + ' / ' + this.report.length + ' 人')
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Theme.textPrimary)
                    Text(this.requiredHours > 0 ? '达标线 ' + this.requiredHours + ' 学时' : '未设置达标线')
                      .fontSize(11).fontColor(Theme.textTertiary)
                    Text('合计 ' + this.serverTotal + ' 学时 · 分类 ' + this.categoryStats.length + ' 类')
                      .fontSize(11).fontColor(Theme.textTertiary)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%')

                if (this.categoryStats.length > 0) {
                  ForEach(this.categoryStats, (c: CategoryStat) => {
                    this.categoryBar(c)
                  }, (c: CategoryStat) => c.category + '-' + c.hours.toString())
                }
              }
              .width('100%').padding(12).margin({ bottom: 8 })
              .backgroundColor(Theme.bgCard).borderRadius(12)
            }

            Text(this.msg).fontSize(12).fontColor(Theme.textTertiary).width('100%').padding({ bottom: 6 })

            if (this.tab === 0) {
              if (this.report.length === 0) {
                Text('暂无学时记录, 审核通过报名后自动累计').fontSize(13).fontColor(Theme.textDisabled).margin({ top: 40 })
              } else {
                ForEach(this.report, (r: HoursRow) => {
                  this.rankRow(r)
                }, (r: HoursRow) => r.stu_no + '-' + r.total_hours.toString())
              }
            } else if (this.tab === 2) {
              if (this.warnList.length === 0) {
                Text('全员均已达标, 暂无需预警').fontSize(13).fontColor(Theme.textDisabled).margin({ top: 40 })
              } else {
                ForEach(this.warnList, (w: WarningRow) => {
                  this.warnRow(w)
                }, (w: WarningRow) => w.stu_no + '-' + w.gap.toString())
              }
            } else if (this.tab === 3) {
              Text('只读检测: 批量签到(同活动 10 分钟内 ≥5 人) / 签到超 24 小时未签退 / 认定学时大于活动学时')
                .fontSize(11).fontColor(Theme.textTertiary).width('100%').lineHeight(17).margin({ bottom: 8 })
              Row({ space: 8 }) {
                this.anomalyChip('批量签到', this.burst.length, Theme.danger)
                this.anomalyChip('未签退', this.notOut.length, Theme.warning)
                this.anomalyChip('学时超限', this.exceed.length, Theme.report)
              }.width('100%').margin({ bottom: 10 })

              if (this.burst.length + this.notOut.length + this.exceed.length === 0) {
                Text('暂未发现异常').fontSize(13).fontColor(Theme.textDisabled).margin({ top: 30 })
              } else {
                if (this.burst.length > 0) {
                  Text('① 批量签到').fontSize(13).fontWeight(FontWeight.Medium).width('100%').margin({ bottom: 4 })
                  ForEach(this.burst, (b: AnomalyBurst) => {
                    this.anomalyLine(b.activity_title + ' · ' + b.window_start,
                      '涉及 ' + b.students + '（' + b.count + ' 条）', b.count.toString() + ' 条', Theme.danger)
                  }, (b: AnomalyBurst) => b.activity_id.toString() + b.window_start)
                }
                if (this.notOut.length > 0) {
                  Text('② 签到后长期未签退(学时按全额认定)').fontSize(13).fontWeight(FontWeight.Medium)
                    .width('100%').margin({ top: 8, bottom: 4 })
                  ForEach(this.notOut, (n: AnomalyNotOut) => {
                    this.anomalyLine(n.name + ' · ' + n.activity_title,
                      '签到 ' + n.checked_at + ' · 已等待 ' + n.hours_waiting + ' 小时',
                      '暂记 ' + n.hours + ' 学时', Theme.warning)
                  }, (n: AnomalyNotOut) => n.signup_id.toString())
                }
                if (this.exceed.length > 0) {
                  Text('③ 认定学时大于活动学时').fontSize(13).fontWeight(FontWeight.Medium)
                    .width('100%').margin({ top: 8, bottom: 4 })
                  ForEach(this.exceed, (e: AnomalyExceed) => {
                    this.anomalyLine(e.name + ' · ' + e.activity_title,
                      '活动 ' + e.activity_hours + ' 学时, 认定 ' + e.hours + ' 学时',
                      '超 ' + (e.hours - e.activity_hours).toFixed(1), Theme.report)
                  }, (e: AnomalyExceed) => e.signup_id.toString())
                }
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

  /** 达标率(0~100): 未设达标线时按"有学时即达标"口径展示 0 */
  achievePct(): number {
    if (this.report.length === 0 || this.requiredHours <= 0) return 0;
    return Math.round(this.achievedCount * 100 / this.report.length);
  }

  /** 分类条形长度: 相对最大值取百分比, 最小 2% 保证极小值也可见 */
  barPct(hours: number): number {
    let max = 0;
    for (const c of this.categoryStats) if (c.hours > max) max = c.hours;
    if (max <= 0) return 0;
    return Math.max(2, Math.round(hours * 100 / max));
  }

  serverHours(): number {
    if (AppConfig.isAdmin) {
      // 管理员视角: 展示全量累计学时
      let total = 0;
      for (const r of this.report) total += r.total_hours;
      return total;
    }
    for (const r of this.report) {
      // 本人行有 is_me 标记(学生视图下他人学号已脱敏, 不能再靠学号全等匹配)
      if (r.is_me || r.stu_no === AppConfig.stuNo) return r.total_hours;
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
  anomalyChip(label: string, n: number, color: ResourceColor) {
    Column({ space: 2 }) {
      Text(n.toString()).fontSize(16).fontWeight(FontWeight.Bold).fontColor(color)
      Text(label).fontSize(10).fontColor(Theme.textTertiary)
    }
    .layoutWeight(1).padding(8).backgroundColor(Theme.bgCard)
    .borderRadius(Theme.radiusSm).alignItems(HorizontalAlign.Center)
  }

  @Builder
  anomalyLine(title: string, sub: string, tag: string, color: ResourceColor) {
    Column({ space: 3 }) {
      Row({ space: 6 }) {
        Text(title).fontSize(13).fontColor(Theme.textBody).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(tag).fontSize(11).fontColor(color)
      }.width('100%')
      Text(sub).fontSize(11).fontColor(Theme.textTertiary).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%').padding(10).backgroundColor(Theme.bgCard)
    .borderRadius(Theme.radiusSm).margin({ bottom: 6 })
  }

  @Builder
  tabBtn(label: string, t: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.tab === t ? Theme.textOnPrimary : Theme.textBody)
      .padding({ left: 14, right: 14, top: 5, bottom: 5 })
      .backgroundColor(this.tab === t ? Theme.primary : Theme.bgNeutral)
      .borderRadius(14)
      .onClick(() => this.tab = t)
  }
}
