/**
 * 社团审核 (v5.0 重构, 仅平台管理员)
 *
 * 平台管理员职责: 社团注册审批(通过分配独立编号 / 驳回需理由) + 停用/恢复社团。
 * 判据全部在服务端, 本页只做呈现与提交。
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ApiClient } from '../common/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { Theme } from '../common/Theme';
import { StateView } from '../components/StateView';
import { AdminGuardView } from '../common/GuardViews';
import {
  AdminClubInfo, parseAdminClubs, clubStatusText
} from '../common/Models';

@Entry
@Component
struct ClubAuditPage {
  @State list: AdminClubInfo[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  // v5.0: 顶部状态筛选胶囊条已按需求移除, 一次拉全量列表, 状态在卡片标签上区分
  @State busyId: number = -1;
  @State editingId: number = -1;      // 驳回/停用时需要填理由的社团 id
  @State reason: string = '';
  @State notAdmin: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.notAdmin = !AppConfig.isAdmin || AppConfig.isClubAccount;
      this.load();
    });
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    const resp = await ApiClient.get('/api/admin/clubs?size=100');
    if (resp['code'] !== 0) {
      this.loadError = (resp['msg'] as string) || '加载失败';
      this.loading = false;
      return;
    }
    this.list = parseAdminClubs(resp);
    this.loading = false;
  }

  async audit(c: AdminClubInfo, action: string): Promise<void> {
    if (this.busyId >= 0) return;
    // 驳回/停用必须填写理由: 先展开理由输入框, 二次点击才真正提交
    if ((action === 'reject' || action === 'disable') && this.editingId !== c.club_id) {
      this.editingId = c.club_id;
      this.reason = '';
      return;
    }
    this.busyId = c.club_id;
    const body: Record<string, Object> = { 'club_id': c.club_id, 'action': action };
    if (this.reason.trim() !== '') body['reason'] = this.reason.trim();
    const resp = await ApiClient.post('/api/admin/club/audit', body);
    this.busyId = -1;
    this.editingId = -1;
    this.reason = '';
    promptAction.showToast({ message: (resp['msg'] as string) || (resp['code'] === 0 ? '操作成功' : '操作失败') });
    if (resp['code'] === 0) this.load();
  }

  @Builder
  header() {
    Row() {
      Text('‹ 返回').fontSize(Theme.fsBody).fontColor(Theme.primary)
        .onClick(() => router.back())
      Text('社团审核').fontSize(Theme.fsHeading).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textBody).layoutWeight(1).textAlign(TextAlign.Center)
      Text('').fontSize(Theme.fsBody).width(52)
    }
    .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 10 })
  }

  @Builder
  statusTag(s: number) {
    Text(clubStatusText(s))
      .fontSize(10)
      .fontColor(s === 0 ? Theme.textBody : s === 1 ? Theme.onColorSuccess : Theme.onColorDanger)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(s === 0 ? Theme.bgNeutral : s === 1 ? Theme.success : Theme.danger)
      .borderRadius(6)
  }

  @Builder
  clubCard(c: AdminClubInfo) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(c.club_name.substring(0, 1))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.textOnPrimary)
          .width(40).height(40).textAlign(TextAlign.Center)
          .backgroundColor(Theme.admin).borderRadius(10)
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(c.club_name).fontSize(Theme.fsTitle).fontWeight(FontWeight.Bold)
              .fontColor(Theme.textBody).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.statusTag(c.status)
          }
          Text('账号 ' + c.account + ' · 编号 #' + c.club_id +
            (c.leader_name === '' ? '' : ' · 社长 ' + c.leader_name))
            .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')

      if (c.intro !== '') {
        Text(c.intro).fontSize(Theme.fsSmall).fontColor(Theme.textSecondary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      if (c.reject_reason !== '') {
        Text('理由: ' + c.reject_reason)
          .fontSize(Theme.fsCaption).fontColor(Theme.danger).width('100%')
      }
      Text(c.member_count + ' 名成员 · ' + c.activity_count + ' 个活动 · 注册于 ' + c.audited_at)
        .fontSize(Theme.fsCaption).fontColor(Theme.textTertiary).width('100%')

      // 动作区: 判据在服务端(状态机 0→1→3 等), 按钮只对合法状态展示
      if (c.status === 0) {
        Row({ space: 10 }) {
          Button('通过')
            .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.success)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.audit(c, 'approve'))
          Button('驳回')
            .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
            .fontColor(Theme.onColorDanger).backgroundColor(Theme.dangerBg)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.audit(c, 'reject'))
        }.width('100%')
      } else if (c.status === 1) {
        Row({ space: 10 }) {
          Button('停用')
            .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
            .fontColor(Theme.onColorDanger).backgroundColor(Theme.dangerBg)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.audit(c, 'disable'))
        }.width('100%')
      } else if (c.status === 3) {
        Row({ space: 10 }) {
          Button('恢复')
            .layoutWeight(1).height(34).fontSize(Theme.fsSmall)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.success)
            .borderRadius(Theme.radiusPill)
            .enabled(this.busyId !== c.club_id)
            .onClick(() => this.audit(c, 'enable'))
        }.width('100%')
      }

      if (this.editingId === c.club_id) {
        Column({ space: 6 }) {
          TextInput({ placeholder: '请填写驳回/停用理由(必填)', text: this.reason })
            .fontSize(Theme.fsSmall).height(40).width('100%')
            .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
            .onChange((v: string) => { this.reason = v; })
          Button('确认提交')
            .width('100%').height(34).fontSize(Theme.fsSmall)
            .fontColor(Theme.textOnPrimary).backgroundColor(Theme.danger)
            .borderRadius(Theme.radiusPill)
            .enabled(this.reason.trim() !== '' && this.busyId !== c.club_id)
            .onClick(() => {
              const target = this.list.find((x: AdminClubInfo) => x.club_id === this.editingId);
              if (target !== undefined) {
                this.audit(target, target.status === 0 ? 'reject' : 'disable');
              }
            })
        }
        .width('100%').padding(8)
        .backgroundColor(Theme.bgSubtle).borderRadius(Theme.radiusMd)
      }
    }
    .width('100%').padding(14)
    .backgroundColor(Theme.bgCard).borderRadius(Theme.radiusLg)
  }

  build() {
    Column() {
      this.header()
      if (this.notAdmin) {
        AdminGuardView({ tip: '社团审核仅平台管理员可用(社团账号请到「社团主页」)' })
      } else {
        if (this.loading) {
          StateView({ kind: 'loading', title: '正在加载社团' })
        } else if (this.loadError !== '') {
          StateView({ kind: 'error', title: '社团加载失败', desc: this.loadError,
            onRetry: () => { this.load(); } })
        } else if (this.list.length === 0) {
          StateView({ kind: 'empty', title: '该状态下暂无社团' })
        } else {
          List({ space: 10 }) {
            ForEach(this.list, (c: AdminClubInfo) => {
              ListItem() {
                this.clubCard(c)
              }
            }, (c: AdminClubInfo) => c.club_id.toString())
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
          .scrollBar(BarState.Off)
        }
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.bgPage)
  }
}
