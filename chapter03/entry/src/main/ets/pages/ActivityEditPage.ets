/**
 * 社团活动报名与学时认定系统 —— 活动编辑(仅管理员)
 * 在原记录上更新标题/内容/地点/时间/学时/人数上限;
 * 已报名记录与已认定学时不受影响; 人数上限不得小于当前有效报名数(服务端校验)。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { ActivityInfo, parseActivities } from '../common/Models';
import { AdminGuardView } from '../common/GuardViews';
import { Theme } from '../common/Theme';

@Entry
@Component
struct ActivityEditPage {
  @State activityId: number = 0;
  @State title: string = '';
  @State content: string = '';
  @State location: string = '';
  @State startDate: Date = new Date();
  @State endDate: Date = new Date();
  @State hours: string = '1.0';
  @State capacity: string = '0';
  @State publisher: string = '';
  @State validCount: number = 0;     // 当前有效报名数(提示人数上限下限)
  @State status: number = 1;
  @State msg: string = '';
  @State busy: boolean = false;
  @State loaded: boolean = false;
  @State blocked: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      if (!AppConfig.isAdmin) {
        this.blocked = true; // 无权限: 仅管理员可编辑活动
        return;
      }
      this.load();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  /** Date -> "YYYY-MM-DD HH:MM" */
  fmtDate(d: Date): string {
    const pad = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString());
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** 读取活动当前值填充表单 */
  async load(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    let aid = 0;
    if (params && params['activity_id'] !== undefined && params['activity_id'] !== null) {
      aid = Number(params['activity_id']);
    }
    if (isNaN(aid) || aid <= 0) {
      this.msg = '缺少活动参数, 请从「发布活动」的活动管理区进入';
      return;
    }
    this.activityId = aid;
    const resp = await ApiClient.get('/api/activity/list?all=1');
    if (resp['code'] !== 0) {
      this.msg = '加载失败: ' + (resp['msg'] as string);
      return;
    }
    const list: ActivityInfo[] = parseActivities(resp);
    let found: ActivityInfo | null = null;
    for (const a of list) {
      if (a.id === aid) {
        found = a;
        break;
      }
    }
    if (found === null) {
      this.msg = '活动不存在(可能已被删除)';
      return;
    }
    this.title = found.title;
    this.content = found.content;
    this.location = found.location;
    this.hours = found.hours.toString();
    this.capacity = found.capacity.toString();
    this.publisher = found.publisher;
    this.validCount = found.valid_count;
    this.status = found.status;
    const s = this.parseTime(found.start_time);
    const e = this.parseTime(found.end_time);
    const base = new Date();
    base.setDate(base.getDate() + 1);
    this.startDate = s === null ? new Date(base.getFullYear(), base.getMonth(), base.getDate(), 19, 0) : s;
    this.endDate = e === null ? new Date(base.getFullYear(), base.getMonth(), base.getDate(), 21, 0) : e;
    this.loaded = true;
    this.msg = '当前有效报名 ' + this.validCount + ' 人; 人数上限不能小于该值(0 表示不限)';
  }

  parseTime(t: string): Date | null {
    if (t.length < 16) return null;
    const y = Number(t.substring(0, 4));
    const mo = Number(t.substring(5, 7));
    const d = Number(t.substring(8, 10));
    const h = Number(t.substring(11, 13));
    const mi = Number(t.substring(14, 16));
    if (isNaN(y) || isNaN(mo) || isNaN(d) || isNaN(h) || isNaN(mi)) return null;
    return new Date(y, mo - 1, d, h, mi);
  }

  pickStart(): void {
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: this.startDate,
      onDateAccept: (d: Date) => {
        const t = this.startDate;
        this.startDate = new Date(d.getFullYear(), d.getMonth(), d.getDate(), t.getHours(), t.getMinutes());
        TimePickerDialog.show({
          selected: this.startDate,
          useMilitaryTime: true,
          onAccept: (v: TimePickerResult) => {
            this.startDate = new Date(this.startDate.getFullYear(), this.startDate.getMonth(),
              this.startDate.getDate(), v.hour, v.minute);
            if (this.endDate.getTime() <= this.startDate.getTime()) {
              const e = new Date(this.startDate.getTime() + 3600000);
              this.endDate = new Date(e.getFullYear(), e.getMonth(), e.getDate(), e.getHours(), e.getMinutes());
              this.msg = '结束时间已自动调整为开始后 1 小时';
            }
          }
        });
      }
    });
  }

  pickEnd(): void {
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: this.endDate,
      onDateAccept: (d: Date) => {
        const t = this.endDate;
        this.endDate = new Date(d.getFullYear(), d.getMonth(), d.getDate(), t.getHours(), t.getMinutes());
        TimePickerDialog.show({
          selected: this.endDate,
          useMilitaryTime: true,
          onAccept: (v: TimePickerResult) => {
            const nd = new Date(this.endDate.getFullYear(), this.endDate.getMonth(),
              this.endDate.getDate(), v.hour, v.minute);
            if (nd.getTime() <= this.startDate.getTime()) {
              this.msg = '结束时间必须晚于开始时间, 已保留原值';
              return;
            }
            this.endDate = nd;
            this.msg = '';
          }
        });
      }
    });
  }

  /** 保存前本地校验(服务端有同等且更严格的校验) */
  validForm(): boolean {
    if (this.title.trim() === '') {
      this.msg = '活动名称不能为空';
      return false;
    }
    const h = Number(this.hours);
    if (isNaN(h) || h <= 0 || h > 999) {
      this.msg = '学时应为 (0, 999] 之间的数字';
      return false;
    }
    const cap = Number(this.capacity);
    if (isNaN(cap) || cap < 0 || cap > 99999 || Math.floor(cap) !== cap) {
      this.msg = '人数上限应为 0~99999 的整数(0 表示不限)';
      return false;
    }
    if (cap > 0 && cap < this.validCount) {
      this.msg = '人数上限不能小于当前有效报名数(' + this.validCount + ' 人)';
      return false;
    }
    if (this.endDate.getTime() <= this.startDate.getTime()) {
      this.msg = '结束时间必须晚于开始时间';
      return false;
    }
    this.msg = '';
    return true;
  }

  async save(): Promise<void> {
    if (this.busy || !this.validForm()) return;
    this.busy = true;
    this.msg = '正在保存到服务器...';
    try {
      const body: Record<string, Object> = {
        'activity_id': this.activityId,
        'title': this.title.trim(),
        'content': this.content.trim(),
        'location': this.location.trim(),
        'start_time': this.fmtDate(this.startDate),
        'end_time': this.fmtDate(this.endDate),
        'hours': Number(this.hours),
        'capacity': Number(this.capacity),
        'publisher': this.publisher.trim()
      };
      const resp = await ApiClient.post('/api/activity/update', body);
      if (resp['code'] === 0) {
        this.msg = '保存成功, 活动#' + this.activityId + ' 已更新';
      } else {
        this.msg = '保存失败: ' + (resp['msg'] as string);
      }
    } finally {
      this.busy = false;
    }
  }

  @Builder
  deniedView() {
    AdminGuardView({ tip: '活动编辑仅限管理员, 请以管理员身份登录后访问' })
  }

  @Builder
  timeCell(label: string, isStart: boolean) {
    Row() {
      Column() {
        Text(label).fontSize(12).fontColor(Theme.textTertiary)
        Text(isStart ? this.fmtDate(this.startDate) : this.fmtDate(this.endDate))
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.primary).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('滚动选择 ›').fontSize(12).fontColor(Theme.primary)
    }
    .width('100%').padding(12).backgroundColor(Theme.primaryBg).borderRadius(10)
    .onClick(() => {
      if (isStart) this.pickStart(); else this.pickEnd();
    })
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
          Text('编辑活动' + (this.activityId > 0 ? ' #' + this.activityId : ''))
            .fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text(this.status === 0 ? '已下线' : '已发布')
            .fontSize(11).fontColor(Color.White)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(this.status === 0 ? Theme.textTertiary : Theme.success)
            .borderRadius(8)
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        Scroll() {
          Column({ space: 10 }) {
            if (!this.loaded) {
              Text(this.msg === '' ? '加载中...' : this.msg)
                .fontSize(13).fontColor(Theme.textTertiary).margin({ top: 40 })
            } else {
              TextInput({ text: this.title, placeholder: '活动名称 *' })
                .onChange((v: string) => this.title = v)
              TextArea({ text: this.content, placeholder: '活动内容描述(支持多行)' })
                .height(100).fontSize(14)
                .onChange((v: string) => this.content = v)
              TextInput({ text: this.location, placeholder: '活动地点(如: 教学楼 A-301)' })
                .onChange((v: string) => this.location = v)

              this.timeCell('开始时间', true)
              this.timeCell('结束时间', false)

              Row({ space: 10 }) {
                TextInput({ text: this.hours, placeholder: '学时(如 2.0)' })
                  .type(InputType.NUMBER_DECIMAL).layoutWeight(1).onChange((v: string) => this.hours = v)
                TextInput({ text: this.capacity, placeholder: '人数上限(0不限)' })
                  .type(InputType.NUMBER_DECIMAL).layoutWeight(1).onChange((v: string) => this.capacity = v)
              }
              TextInput({ text: this.publisher, placeholder: '发布人' })
                .onChange((v: string) => this.publisher = v)

              Text('已报名记录与已认定学时不受编辑影响; 历史活动可保留原开始时间')
                .fontSize(11).fontColor(Theme.textTertiary).width('100%')

              Row({ space: 10 }) {
                Button('取消').layoutWeight(1).height(40).fontSize(14).backgroundColor(Theme.textTertiary)
                  .onClick(() => router.back())
                Button(this.busy ? '保存中...' : '保存修改')
                  .layoutWeight(1).height(40).fontSize(14).backgroundColor(Theme.primary)
                  .enabled(!this.busy).onClick(() => this.save())
              }
              if (this.msg !== '') {
                Text(this.msg).fontSize(12).fontColor(Theme.primary).textAlign(TextAlign.Center).width('100%')
              }
            }
          }
          .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14).margin({ top: 4 })
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        .padding({ left: 14, right: 14 })
      }
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
