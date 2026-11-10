/**
 * 社团广场 (v5.0 重构)
 *
 * 全部登录用户可见:
 *  - 浏览/搜索全部正常社团(名称/简介/挂靠单位/社长/成员数/活动数)
 *  - 学生: 申请加入 / 申请退出 / 我的社团(两种视图: 全部社团 | 我的社团)
 *
 * 个人状态口径与服务端 my_status 一致:
 *   0=未加入 1=已加入 2=申请审核中 3=申请被驳回 4=已退出 5=退出审核中(仍是成员)
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { Theme } from '../common/Theme';
import { StateView } from '../components/StateView';
import {
  ClubSquareInfo, parseClubSquare, myStatusText
} from '../common/Models';

@Entry
@Component
struct ClubSquarePage {
  @State list: ClubSquareInfo[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State tab: string = 'all';          // all=全部社团 mine=我的社团(仅学生)
  @State kw: string = '';
  @State busyId: number = -1;          // 防重复提交: 正在操作的社团 id
  private isStudent: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.isStudent = !AppConfig.isAdmin;
      if (this.isStudent) this.tab = 'mine';
      this.load();
    });
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    const resp = await ApiClient.get('/api/club/square');
    if (resp['code'] !== 0) {
      this.loadError = (resp['msg'] as string) || '加载失败';
      this.loading = false;
      return;
    }
    this.list = parseClubSquare(resp);
    this.loading = false;
  }

  /** 按当前页签与关键字过滤 */
  visible(): ClubSquareInfo[] {
    const kw = this.kw.trim();
    return this.list.filter((c: ClubSquareInfo) => {
      if (this.tab === 'mine' && !(c.my_status === 1 || c.my_status === 2 || c.my_status === 5)) return false;
      if (kw !== '' && c.club_name.indexOf(kw) < 0 && c.intro.indexOf(kw) < 0 && c.dept.indexOf(kw) < 0) {
        return false;
      }
      return true;
    });
  }

  async join(c: ClubSquareInfo): Promise<void> {
    if (this.busyId >= 0) return;
    this.busyId = c.club_id;
    const resp = await ApiClient.post('/api/club/join', { 'club_id': c.club_id });
    this.busyId = -1;
    promptAction.showToast({ message: (resp['msg'] as string) || (resp['code'] === 0 ? '申请已提交' : '提交失败') });
    if (resp['code'] === 0) this.load();
  }

  async leave(c: ClubSquareInfo): Promise<void> {
    if (this.busyId >= 0) return;
    this.busyId = c.club_id;
    const resp = await ApiClient.post('/api/club/leave', { 'club_id': c.club_id });
    this.busyId = -1;
    promptAction.showToast({ message: (resp['msg'] as string) || (resp['code'] === 0 ? '退出申请已提交' : '提交失败') });
    if (resp['code'] === 0) this.load();
  }

  @Builder
  header() {
    Row() {
      Text('‹ 返回').fontSize(Theme.fsBody).fontColor(Theme.primary)
        .onClick(() => router.back())
      Text('社团广场').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody).layoutWeight(1).textAlign(TextAlign.Center)
      Text('').fontSize(Theme.fsBody).width(52)
    }
    .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 10 })
  }

  @Builder
  tabs() {
    Row({ space: 8 }) {
      this.tabChip('全部社团', 'all')
      if (this.isStudent) {
        this.tabChip('我的社团', 'mine')
      }
    }
    .width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })
  }

  @Builder
  tabChip(label: string, key: string) {
    Text(label)
      .fontSize(Theme.fsSmall)
      .fontColor(this.tab === key ? Theme.textOnPrimary : Theme.textSecondary)
      .fontWeight(this.tab === key ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.tab === key ? Theme.primary : Theme.bgSubtle)
      .borderRadius(Theme.radiusPill)
      .onClick(() => { this.tab = key; })
  }

  @Builder
  statusTag(s: number) {
    if (s > 0) {
      Text(myStatusText(s))
        .fontSize(10)
        .fontColor(s === 1 ? Theme.textOnPrimary : s === 3 ? Theme.onColorDanger : Theme.textBody)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(s === 1 ? Theme.success : s === 3 ? Theme.danger : Theme.bgNeutral)
        .borderRadius(6)
    }
  }

  @Builder
  clubCard(c: ClubSquareInfo) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(c.club_name.substring(0, 1))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
          .width(40).height(40).textAlign(TextAlign.Center)
          .backgroundColor(Theme.primary).borderRadius(10)
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(c.club_name).fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
              .fontColor(Theme.textBody).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.statusTag(c.my_status)
          }
          Text('社长 ' + (c.leader_name === '' ? '未录入' : c.leader_name) +
            ' · 挂靠 ' + (c.dept === '' ? '未填写' : c.dept))
            .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')

      if (c.intro !== '') {
        Text(c.intro).fontSize(Theme.fsSmall).fontColor(Theme.textSecondary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }

      Row() {
        Text(c.member_count + ' 名成员 · ' + c.activity_count + ' 个活动')
          .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary).layoutWeight(1)

        // 动作按钮: 判据来自服务端 my_status, App 只做呈现
        if (this.isStudent && c.my_status === 0) {
          Button('申请加入')
            .height(30).fontSize(Theme.fsSmall)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.primary)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.join(c))
        } else if (this.isStudent && c.my_status === 3) {
          Button('重新申请')
            .height(30).fontSize(Theme.fsSmall)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.primary)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.join(c))
        } else if (this.isStudent && c.my_status === 4) {
          Button('再次加入')
            .height(30).fontSize(Theme.fsSmall)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.primary)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.join(c))
        } else if (this.isStudent && c.my_status === 1) {
          Button('申请退出')
            .height(30).fontSize(Theme.fsSmall)
            .fontColor(Theme.danger).backgroundColor(Theme.dangerBg)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.leave(c))
        } else if (this.isStudent && c.my_status === 2) {
          Text('待社团审批').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        } else if (this.isStudent && c.my_status === 5) {
          Text('退出审批中').fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
        }
      }.width('100%')
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
  }

  build() {
    Column() {
      this.header()
      // 搜索框
      Row({ space: 8 }) {
        Text('🔍').fontSize(14)
        TextInput({ placeholder: '搜索社团名称 / 简介 / 挂靠单位', text: this.kw })
          .fontSize(Theme.fsSmall).layoutWeight(1)
          .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusPill)
          .onChange((v: string) => { this.kw = v; })
      }
      .width('100%').padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })

      this.tabs()

      if (this.loading) {
        StateView({ kind: 'loading', title: '正在加载社团' })
      } else if (this.loadError !== '') {
        StateView({ kind: 'error', title: '社团加载失败', desc: this.loadError,
          onRetry: () => { this.load(); } })
      } else if (this.visible().length === 0) {
        StateView({ kind: 'empty', title: this.tab === 'mine' ? '还没有加入任何社团' : '暂无社团',
          desc: this.tab === 'mine' ? '到「全部社团」里逛逛, 申请加入感兴趣的组织' : '' })
      } else {
        List({ space: 10 }) {
          ForEach(this.visible(), (c: ClubSquareInfo) => {
            ListItem() {
              this.clubCard(c)
            }
          }, (c: ClubSquareInfo) => c.club_id.toString())
          ListItem() {
            Text('共 ' + this.visible().length + ' 个社团 · 状态以服务端为准')
              .fontSize(10).fontColor(Theme.textDisabled)
              .width('100%').textAlign(TextAlign.Center).padding({ top: 4, bottom: 12 })
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
