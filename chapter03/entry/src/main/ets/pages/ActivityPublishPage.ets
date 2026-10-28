/**
 * 社团活动报名与学时认定系统 —— 活动发布(草稿存本地 SQLite, 可同步发布)
 * 时间输入采用 DatePicker + TimePicker 滚轮选择, 杜绝随意输入;
 * 保存/发布前统一校验: 格式、结束>开始、开始不早于当前、学时/容量范围。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { AppConfig } from '../common/AppConfig';
import { LocalDraft } from '../common/Models';

@Entry
@Component
struct ActivityPublishPage {
  @State title: string = '';
  @State content: string = '';
  @State location: string = '';
  @State startDate: Date = new Date();
  @State endDate: Date = new Date();
  @State hours: string = '1.0';
  @State capacity: string = '0';
  @State publisher: string = '';
  @State drafts: LocalDraft[] = [];
  @State msg: string = '';
  @State busy: boolean = false;
  @State blocked: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => DbHelper.init(ctx)).then(() => {
      if (!AppConfig.isAdmin) {
        this.blocked = true; // 无权限: 仅管理员可发布活动
        return;
      }
      this.publisher = AppConfig.stuName;
      // 默认时间: 明天 19:00 - 21:00 (演示友好)
      const base = new Date();
      base.setDate(base.getDate() + 1);
      this.startDate = new Date(base.getFullYear(), base.getMonth(), base.getDate(), 19, 0);
      this.endDate = new Date(base.getFullYear(), base.getMonth(), base.getDate(), 21, 0);
      this.loadDrafts();
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

  /** 表单统一校验(保存草稿 / 发布前调用) */
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
    const now = new Date().getTime();
    if (this.startDate.getTime() < now) {
      this.msg = '开始时间不能早于当前时间';
      return false;
    }
    if (this.endDate.getTime() <= this.startDate.getTime()) {
      this.msg = '结束时间必须晚于开始时间';
      return false;
    }
    this.msg = '';
    return true;
  }

  // ---------------- 时间滚轮选择(开始/结束) ----------------

  pickStart(): void {
    DatePickerDialog.show({
      start: new Date(),
      end: new Date(2100, 11, 31),
      selected: this.startDate,
      onDateAccept: (d: Date) => {
        const t = this.startDate;
        this.startDate = new Date(d.getFullYear(), d.getMonth(), d.getDate(), t.getHours(), t.getMinutes());
        this.pickStartTime();
      }
    });
  }

  pickStartTime(): void {
    TimePickerDialog.show({
      selected: this.startDate,
      useMilitaryTime: true,
      onAccept: (v: TimePickerResult) => {
        this.startDate = new Date(this.startDate.getFullYear(), this.startDate.getMonth(),
          this.startDate.getDate(), v.hour, v.minute);
        this.afterPickStart();
      }
    });
  }

  afterPickStart(): void {
    // 开始不能早于当前: 自动调整到当前时间的下一整分
    const now = new Date();
    if (this.startDate.getTime() < now.getTime()) {
      const adj = new Date(now.getTime() + 60000);
      this.startDate = new Date(adj.getFullYear(), adj.getMonth(), adj.getDate(), adj.getHours(), adj.getMinutes());
      this.msg = '开始时间不能早于当前, 已自动调整';
    }
    // 若开始 >= 结束, 结束自动推到开始后 1 小时, 保证区间合法
    if (this.endDate.getTime() <= this.startDate.getTime()) {
      const e = new Date(this.startDate.getTime() + 3600000);
      this.endDate = new Date(e.getFullYear(), e.getMonth(), e.getDate(), e.getHours(), e.getMinutes());
      this.msg = '结束时间已自动调整为开始后 1 小时';
    }
  }

  pickEnd(): void {
    DatePickerDialog.show({
      start: new Date(),
      end: new Date(2100, 11, 31),
      selected: this.endDate,
      onDateAccept: (d: Date) => {
        const t = this.endDate;
        this.endDate = new Date(d.getFullYear(), d.getMonth(), d.getDate(), t.getHours(), t.getMinutes());
        this.pickEndTime();
      }
    });
  }

  pickEndTime(): void {
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

  // ---------------- 草稿与发布 ----------------

  async loadDrafts(): Promise<void> {
    this.drafts = await DbHelper.getDrafts();
  }

  /** 保存草稿(表单当前值) */
  async saveDraft(): Promise<void> {
    if (this.busy) return;
    if (!this.validForm()) return;
    this.busy = true;
    try {
      const id = await DbHelper.addDraft(this.title.trim(), this.content.trim(), this.location.trim(),
        this.fmtDate(this.startDate), this.fmtDate(this.endDate),
        Number(this.hours), Number(this.capacity), this.publisher.trim());
      this.msg = id > 0 ? '草稿已保存到本地 SQLite' : '草稿保存失败';
      await this.loadDrafts();
    } finally {
      this.busy = false;
    }
  }

  /** 保存草稿并立即发布到服务器(以表单当前值为准) */
  async saveAndPublish(): Promise<void> {
    if (this.busy) return;
    if (!this.validForm()) return;
    this.busy = true;
    try {
      const id = await DbHelper.addDraft(this.title.trim(), this.content.trim(), this.location.trim(),
        this.fmtDate(this.startDate), this.fmtDate(this.endDate),
        Number(this.hours), Number(this.capacity), this.publisher.trim());
      if (id > 0) {
        await this.loadDrafts();
        await this.publish(id, this.title.trim(), this.content.trim(), this.location.trim(),
          this.fmtDate(this.startDate), this.fmtDate(this.endDate),
          Number(this.hours), Number(this.capacity), this.publisher.trim());
      } else {
        this.msg = '草稿保存失败, 无法发布';
      }
    } finally {
      this.busy = false;
    }
  }

  /** 发布草稿(以草稿自身字段为准) */
  async publish(draftId: number, draftTitle: string, draftContent: string, draftLocation: string,
    draftStart: string, draftEnd: string, draftHours: number, draftCapacity: number,
    draftPublisher: string): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.msg = '';
    try {
      if (draftTitle.trim() === '') {
        this.msg = '活动名称不能为空';
        return;
      }
      const body: Record<string, Object> = {
        'title': draftTitle,
        'content': draftContent,
        'location': draftLocation,
        'start_time': draftStart,
        'end_time': draftEnd,
        'hours': draftHours,
        'capacity': draftCapacity,
        'publisher': draftPublisher
      };
      this.msg = '正在同步服务器(MySQL)...';
      const resp = await ApiClient.post('/api/activity/add', body);
      if (resp['code'] === 0) {
        const data = resp['data'] as Record<string, Object>;
        const serverId = data['id'] as number;
        await DbHelper.markDraftSynced(draftId, serverId);
        this.msg = '发布成功! 服务器活动ID: ' + serverId + ' (草稿已同步标记)';
      } else {
        this.msg = '发布失败: ' + (resp['msg'] as string) + ' (草稿保留在本地)';
      }
      await this.loadDrafts();
    } finally {
      this.busy = false;
    }
  }

  async removeDraft(id: number): Promise<void> {
    await DbHelper.deleteDraft(id);
    await this.loadDrafts();
  }

  @Builder
  draftItem(d: LocalDraft) {
    Column() {
      Row() {
        Text(d.title).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(d.synced === 1 ? '✓ 已发布' : '● 草稿')
          .fontSize(11).fontColor(d.synced === 1 ? '#07C160' : '#E84026')
      }.width('100%')
      Text('学时 ' + d.hours + ' | ' + (d.location === '' ? '待定' : d.location) + ' | ' + d.start_time)
        .fontSize(12).fontColor('#888888').width('100%').margin({ top: 4 })
      if (d.synced === 0) {
        Row({ space: 10 }) {
          Button('发布到服务器').fontSize(12).height(28).backgroundColor('#1E6FFF')
            .onClick(() => this.publish(d.id, d.title, d.content, d.location, d.start_time,
              d.end_time, d.hours, d.capacity, d.publisher))
          Button('删除').fontSize(12).height(28).backgroundColor('#E84026')
            .onClick(() => this.removeDraft(d.id))
        }.width('100%').justifyContent(FlexAlign.End).margin({ top: 8 })
      }
    }
    .width('100%').padding(12).backgroundColor('#F8FAFF').borderRadius(10).margin({ bottom: 8 })
  }

  @Builder
  timeCell(label: string, value: string, target: string) {
    Row() {
      Column() {
        Text(label).fontSize(12).fontColor('#999999')
        Text(value).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1E6FFF').margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('滚动选择 ›').fontSize(12).fontColor('#1E6FFF')
    }
    .width('100%').padding(12).backgroundColor('#F0F5FF').borderRadius(10)
    .onClick(() => {
      if (target === 'start') this.pickStart(); else this.pickEnd();
    })
  }

  @Builder
  deniedView() {
    Column({ space: 12 }) {
      Text('🔒').fontSize(40)
      Text('无权限访问').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text('活动发布仅限管理员, 请以管理员身份登录后访问')
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
          Text('发布活动').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('活动广场').fontSize(13).height(30).backgroundColor('#07C160')
            .onClick(() => router.pushUrl({ url: 'pages/ActivityListPage' }))
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

        Scroll() {
          Column() {
            // 表单
            Column({ space: 10 }) {
              TextInput({ text: this.title, placeholder: '活动名称 *' })
                .onChange((v: string) => this.title = v)
              TextInput({ text: this.content, placeholder: '活动内容描述' })
                .onChange((v: string) => this.content = v)
              TextInput({ text: this.location, placeholder: '活动地点(如: 教学楼 A-301)' })
                .onChange((v: string) => this.location = v)

              // 时间滚轮选择(点击弹出 DatePicker + TimePicker)
              this.timeCell('开始时间', this.fmtDate(this.startDate), 'start')
              this.timeCell('结束时间', this.fmtDate(this.endDate), 'end')
              Text('点击时间卡片通过滚轮选择, 结束必须晚于开始, 开始不得早于当前')
                .fontSize(11).fontColor('#999999').width('100%')

              Row({ space: 10 }) {
                TextInput({ text: this.hours, placeholder: '学时(如 2.0)' })
                  .type(InputType.NUMBER_DECIMAL).layoutWeight(1).onChange((v: string) => this.hours = v)
                TextInput({ text: this.capacity, placeholder: '人数上限(0不限)' })
                  .type(InputType.NUMBER_DECIMAL).layoutWeight(1).onChange((v: string) => this.capacity = v)
              }
              TextInput({ text: this.publisher, placeholder: '发布人(默认登录名)' })
                .onChange((v: string) => this.publisher = v)

              Row({ space: 10 }) {
                Button(this.busy ? '处理中...' : '保存草稿(本地 SQLite)')
                  .layoutWeight(1).height(40).fontSize(14).backgroundColor('#666666')
                  .enabled(!this.busy).onClick(() => this.saveDraft())
                Button(this.busy ? '处理中...' : '保存并发布到服务器')
                  .layoutWeight(1).height(40).fontSize(14).backgroundColor('#1E6FFF')
                  .enabled(!this.busy).onClick(() => this.saveAndPublish())
              }
              if (this.msg !== '') {
                Text(this.msg).fontSize(12).fontColor('#1E6FFF').textAlign(TextAlign.Center).width('100%')
              }
            }
            .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14)

            // 草稿箱
            Column() {
              Row() {
                Text('本地草稿箱(SQLite)').fontSize(15).fontWeight(FontWeight.Bold).layoutWeight(1)
                Text(this.drafts.length + ' 条').fontSize(12).fontColor('#999999')
              }.width('100%').margin({ bottom: 8 })
              if (this.drafts.length === 0) {
                Text('暂无草稿, 填写上方表单后点击「保存草稿」').fontSize(12).fontColor('#BBBBBB')
              } else {
                ForEach(this.drafts, (d: LocalDraft) => {
                  this.draftItem(d)
                }, (d: LocalDraft) => d.id.toString())
              }
            }
            .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14).margin({ top: 10 })
          }
          .padding(14)
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
