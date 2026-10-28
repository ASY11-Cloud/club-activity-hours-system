/**
 * 社团活动报名与学时认定系统 —— 用户管理(仅管理员)
 * 查看全系统所有用户的注册状态 + 学时汇总 + 报名统计, 支持分组查找与关键字搜索。
 * 分组: 全部 / 待审核 / 已通过 / 已驳回 / 已达标 / 未达标(全部服务端过滤, total 一致)。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { AdminGuardView } from '../common/GuardViews';
import {
  StudentInfo, StudentGroupCounts, parseStudentList, parseStudentGroupCounts,
  dataOf, numOf, studentStatusText
} from '../common/Models';
import { Theme } from '../common/Theme';
import { StateView } from '../components/StateView';

interface GroupDef {
  key: string;    // 服务端 group 参数
  label: string;  // 展示名
  count: number;  // 分组计数
}

@Entry
@Component
struct UserManagePage {
  @State students: StudentInfo[] = [];
  @State groups: GroupDef[] = [];
  @State currentGroup: string = 'all';
  @State kw: string = '';
  @State total: number = 0;
  @State requiredHours: number = 0;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State notAdmin: boolean = false;
  @State expandedSearch: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isAdmin) {
        this.notAdmin = true;
        return;
      }
      this.load();
    }).catch((e: Error) => {
      this.loadError = '初始化失败: ' + e.message;
      this.loading = false;
    });
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    // 分组计数与列表一次拉取(服务端同时下发 group_counts / list / total / required_hours)
    const qs: string = (this.kw !== '' ? '&kw=' + encodeURIComponent(this.kw) : '');
    const resp = await ApiClient.get('/api/student/list?group=' + this.currentGroup + qs);
    if (resp['code'] === 0) {
      this.students = parseStudentList(resp);
      const d = dataOf(resp);
      if (d !== null) {
        this.total = numOf(d, 'total');
        this.requiredHours = numOf(d, 'required_hours');
      }
      const gc: StudentGroupCounts = parseStudentGroupCounts(resp);
      this.groups = [
        { key: 'all', label: '全部', count: gc.all },
        { key: 'pending', label: '待审核', count: gc.pending },
        { key: 'approved', label: '已通过', count: gc.approved },
        { key: 'rejected', label: '已驳回', count: gc.rejected },
        { key: 'achieved', label: '已达标', count: gc.achieved },
        { key: 'unachieved', label: '未达标', count: gc.unachieved }
      ];
      this.loadError = '';
    } else {
      this.loadError = resp['msg'] as string;
    }
    this.loading = false;
  }

  switchGroup(key: string): void {
    if (this.currentGroup === key) return;
    this.currentGroup = key;
    this.load();
  }

  // 状态色: 已通过=绿 待审核=橙 已驳回=红
  statusColor(status: number): string {
    if (status === 1) return Theme.success;
    if (status === 2) return Theme.danger;
    return Theme.warning;
  }

  statusBg(status: number): string {
    if (status === 1) return Theme.successBg;
    if (status === 2) return Theme.dangerBg;
    return Theme.warningBg;
  }

  // ==================== UI 构建 ====================

  @Builder
  groupChips() {
    // 两行三列网格: 6 个分组全部一眼可见, 无需横向滑动(避免末尾分组被右缘裁切)
    Grid() {
      ForEach(this.groups, (g: GroupDef) => {
        GridItem() {
          Text(g.label + ' ' + g.count)
            .fontSize(Theme.fsSmall)
            .fontColor(this.currentGroup === g.key ? Theme.primary : Theme.textSecondary)
            .fontWeight(this.currentGroup === g.key ? FontWeight.Medium : FontWeight.Normal)
            .width('100%').height(34)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.currentGroup === g.key ? Theme.primaryBg : Theme.bgCard)
            .borderRadius(Theme.radiusSm)
            .border({
              width: 1,
              color: this.currentGroup === g.key ? Theme.primary : Theme.divider
            })
            .onClick(() => this.switchGroup(g.key))
        }
      }, (g: GroupDef) => g.key)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .columnsGap(8).rowsGap(8)
    .height(76)
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4 })
  }

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      TextInput({ text: this.kw, placeholder: '按学号 / 姓名 / 班级查找' })
        .layoutWeight(1).height(36).fontSize(Theme.fsSmall)
        .backgroundColor(Theme.bgCard)
        .borderRadius(Theme.radiusSm)
        .onChange((v: string) => this.kw = v)
        .onSubmit(() => this.load())
      Button('搜索').fontSize(Theme.fsSmall).height(36).backgroundColor(Theme.primary)
        .onClick(() => this.load())
    }
    .width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 8 })
  }

  @Builder
  userCard(s: StudentInfo) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(s.name.substring(0, 1))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
          .textAlign(TextAlign.Center).width(40).height(40)
          .backgroundColor(this.statusColor(s.status)).borderRadius(12)
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(s.name).fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold).fontColor(Theme.textBody)
            Text(studentStatusText(s.status))
              .fontSize(10)
              .fontColor(this.statusColor(s.status))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor(this.statusBg(s.status))
              .borderRadius(6)
          }.alignItems(VerticalAlign.Center)
          Text(s.stu_no + (s.dept !== '' ? ' · ' + s.dept : ''))
            .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)

        // 右侧学时摘要(固定宽度, 避免被姓名列挤压溢出)
        Column({ space: 2 }) {
          Row({ space: 3 }) {
            Text(s.total_hours.toString())
              .fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold).fontColor(Theme.primary)
            Text('学时').fontSize(10).fontColor(Theme.textTertiary)
          }.alignItems(VerticalAlign.Bottom).justifyContent(FlexAlign.End)
          Text('通过 ' + s.sign_count + ' 次')
            .fontSize(10).fontColor(Theme.textTertiary)
        }.width(76).alignItems(HorizontalAlign.End)
      }.width('100%')

      // 达标进度条(仅已通过的学生展示, 直观呈现距达标线的差距)
      if (s.status === 1) {
        Column({ space: 4 }) {
          Row() {
            Text(this.requiredHours > 0
              ? (s.achieved ? '已达标' : '还差 ' + Math.max(0, this.requiredHours - s.total_hours).toFixed(1) + ' 学时')
              : '未设达标线')
              .fontSize(10).fontColor(s.achieved ? Theme.success : Theme.textTertiary)
              .layoutWeight(1)
            Text(this.requiredHours > 0 ? '达标线 ' + this.requiredHours.toString() + ' 学时' : '')
              .fontSize(10).fontColor(Theme.textTertiary)
          }.width('100%')

          Progress({ value: this.requiredHours > 0
            ? Math.min(100, s.total_hours / this.requiredHours * 100) : 0,
            total: 100, type: ProgressType.Linear })
            .width('100%').height(6)
            .color(s.achieved ? Theme.success : Theme.primary)
            .backgroundColor(Theme.bgNeutral)
        }.width('100%')
      }

      // 附加信息: RFID 卡号 / 注册日期(仅到日, 避免长串溢出)
      Row() {
        Text(s.card_no !== '' ? '卡号 ' + s.card_no : '未绑卡')
          .fontSize(10).fontColor(Theme.textTertiary)
        Blank()
        Text('注册 ' + s.created_at.substring(0, 10))
          .fontSize(10).fontColor(Theme.textDisabled)
      }.width('100%')
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
    .border({ width: { left: 3 }, color: this.statusColor(s.status) })
  }

  build() {
    Column() {
      if (this.notAdmin) {
        AdminGuardView({ tip: '用户管理功能仅限管理员使用' })
      } else {
        // 页头
        Row() {
          Text('‹ 返回').fontSize(14).fontColor(Theme.primary)
            .padding({ right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('用户管理').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text('共 ' + this.total + ' 人').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
          Button('刷新').fontSize(13).height(30).backgroundColor(Theme.primary)
            .onClick(() => this.load())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 6 })

        // 分组查找
        this.groupChips()
        this.searchBar()

        // 达标线提示
        if (this.requiredHours > 0) {
          Text('学时达标线 ' + this.requiredHours + ' 学时')
            .fontSize(10).fontColor(Theme.textTertiary)
            .width('100%')
            .padding({ left: Theme.pagePadding, top: 8 })
        }

        // 列表 / 状态视图
        if (this.loading) {
          StateView({ kind: 'loading', title: '加载用户中', desc: '正在从服务器拉取全量学生信息' })
        } else if (this.loadError !== '') {
          StateView({ kind: 'error', title: '加载失败', desc: this.loadError, retryText: '重试', onRetry: () => this.load() })
        } else if (this.students.length === 0) {
          StateView({ kind: 'empty', title: '没有匹配的用户', desc: '换个分组或关键字试试' })
        } else {
          List({ space: 10 }) {
            ForEach(this.students, (s: StudentInfo) => {
              ListItem() {
                this.userCard(s)
              }
            }, (s: StudentInfo) => s.stu_no + '_' + s.id.toString())
          }
          .layoutWeight(1).width('100%')
          .scrollBar(BarState.Off)
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 16 })
        }
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
