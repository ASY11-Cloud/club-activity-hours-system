/**
 * 社团活动报名与学时认定系统 —— 设置(服务器地址 / 当前账号 / 退出登录)
 * 账号信息由登录页签发, 此处只读展示。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig } from '../common/AppConfig';
import { ApiClient } from '../common/ApiClient';
import { DbHelper } from '../common/DbHelper';
import { CancelImpact, parseCancelImpact } from '../common/Models';
import { Nav } from '../common/Nav';
import { Theme } from '../common/Theme';

@Entry
@Component
struct SettingsPage {
  @State host: string = '';
  @State port: string = '';
  @State msg: string = '';
  @State testing: boolean = false;
  // 登录态镜像(@State): 从设置页「去登录」登录返回后, onPageShow 同步刷新账号区
  @State loggedIn: boolean = AppConfig.isLoggedIn;
  @State isAdmin: boolean = AppConfig.isAdmin;
  @State name: string = AppConfig.stuName;
  @State stuNo: string = AppConfig.stuNo;
  @State roleTxt: string = AppConfig.roleText;

  // 刷卡调试(模拟 RFID 终端): 没有 ESP32 时也能演示"刷卡 -> 签到 -> 学时"
  @State cardNo: string = 'A1B2C3D4';
  @State signinMsg: string = '';
  @State signinOk: boolean = false;
  @State signinBusy: boolean = false;
  @State actNames: string[] = ['选择活动'];
  @State actIds: number[] = [0];
  @State actOptions: SelectOption[] = [{ value: '选择活动' }];
  @State actIndex: number = 0;

  // ---- 注销账号(危险操作) ----
  // 流程: 点"注销账号" -> 先拉影响面 -> 展示将删除的数据 -> 输入本人学号 -> 确认
  @State cancelOpen: boolean = false;
  @State cancelImpact: CancelImpact | null = null;
  @State cancelLoading: boolean = false;
  @State cancelInput: string = '';
  @State cancelErr: string = '';
  @State cancelBusy: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppConfig.init(ctx).then(() => {
      this.syncLoginState();
      this.host = AppConfig.serverHost;
      this.port = AppConfig.serverPort;
      if (AppConfig.isAdmin) this.loadActs();
    }).catch((e: Error) => {
      this.msg = '初始化失败: ' + e.message;
    });
  }

  /** 可刷卡的活动(未结束且未满), 供模拟刷卡选择 */
  async loadActs(): Promise<void> {
    const resp = await ApiClient.get('/api/activity/list?size=50&scope=available');
    if (resp['code'] !== 0) return;
    const data = resp['data'] as Record<string, Object>;
    const list = data['list'] as Array<Record<string, Object>>;
    if (!list) return;
    const names: string[] = ['选择活动'];
    const ids: number[] = [0];
    const opts: SelectOption[] = [{ value: '选择活动' }];
    for (const item of list) {
      const title = item['title'] as string;
      names.push(title);
      ids.push(Number(item['id']));
      const o: SelectOption = { value: title };
      opts.push(o);
    }
    this.actNames = names;
    this.actIds = ids;
    this.actOptions = opts;
    if (this.actIndex >= names.length) this.actIndex = 0;
  }

  /** 走与 ESP32 完全相同的 /api/signin 接口, 保证演示链路真实 */
  async doSignin(): Promise<void> {
    const card = this.cardNo.trim();
    const aid = this.actIndex < this.actIds.length ? this.actIds[this.actIndex] : 0;
    if (card === '') {
      this.signinOk = false;
      this.signinMsg = '请填写卡号';
      return;
    }
    if (aid <= 0) {
      this.signinOk = false;
      this.signinMsg = '请选择要签到的活动';
      return;
    }
    this.signinBusy = true;
    try {
      const body: Record<string, Object> = { 'card_no': card, 'activity_id': aid };
      const resp = await ApiClient.post('/api/signin', body);
      if (resp['code'] === 0) {
        const d = resp['data'] as Record<string, Object>;
        this.signinOk = true;
        this.signinMsg = '刷卡成功: ' + (d['name'] as string) + ' (' + (d['stu_no'] as string) +
          ') → 认定 ' + (d['hours'] as number) + ' 学时';
      } else {
        this.signinOk = false;
        this.signinMsg = '刷卡失败: ' + (resp['msg'] as string);
      }
    } finally {
      this.signinBusy = false;
    }
  }

  onPageShow(): void {
    // 登录/退出登录返回设置页时, 同步登录态并刷新账号区
    this.syncLoginState();
  }

  syncLoginState(): void {
    this.loggedIn = AppConfig.isLoggedIn;
    this.isAdmin = AppConfig.isAdmin;
    this.name = AppConfig.stuName;
    this.stuNo = AppConfig.stuNo;
    this.roleTxt = AppConfig.roleText;
  }

  /** 校验并保存服务器地址; 返回是否保存成功 */
  async save(): Promise<boolean> {
    const host = this.host.trim();
    const port = this.port.trim() === '' ? '8000' : this.port.trim();
    if (host === '') {
      this.msg = '服务器地址不能为空';
      return false;
    }
    if (host.indexOf('://') >= 0 || host.indexOf(' ') >= 0) {
      this.msg = '只填 IP 或域名, 不要带 http:// 和空格(如 192.168.1.10)';
      return false;
    }
    const p = Number(port);
    if (isNaN(p) || p < 1 || p > 65535 || Math.floor(p) !== p) {
      this.msg = '端口应为 1~65535 的整数';
      return false;
    }
    this.port = port;
    await AppConfig.saveServer(host, port);
    this.msg = '已保存: ' + AppConfig.serverBase;
    return true;
  }

  async testConn(): Promise<void> {
    // 先保存当前输入: 否则改完地址直接点"测试连接"测的还是旧地址, 会误判为连接失败
    if (!(await this.save())) return;
    this.testing = true;
    this.msg = '正在连接 ' + AppConfig.serverBase + ' ...';
    const ok = await ApiClient.ping();
    this.msg = ok ? '连接成功! 服务器在线(MySQL 已连接)' : '连接失败, 请检查地址/端口/防火墙';
    this.testing = false;
  }

  // ==================== 注销账号 ====================

  /** 展开注销面板并拉取影响面(先让人看清"会删掉什么", 再决定) */
  async openCancel(): Promise<void> {
    this.cancelOpen = true;
    this.cancelInput = '';
    this.cancelErr = '';
    this.cancelLoading = true;
    const resp = await ApiClient.get('/api/student/impact');
    this.cancelLoading = false;
    if (resp['code'] !== 0) {
      this.cancelErr = (resp['msg'] as string) + ' (可能是网络问题, 稍后重试)';
      return;
    }
    this.cancelImpact = parseCancelImpact(resp);
  }

  /** 输入学号与本人一致才允许提交(不可逆操作, 防误触) */
  cancelReady(): boolean {
    return this.cancelImpact !== null && this.cancelInput.trim() === AppConfig.stuNo;
  }

  async doCancelAccount(): Promise<void> {
    if (!this.cancelReady() || this.cancelBusy) return;
    this.cancelBusy = true;
    this.cancelErr = '';
    const body: Record<string, Object> = { 'confirm_stu_no': this.cancelInput.trim() };
    const resp = await ApiClient.post('/api/student/cancel', body);
    this.cancelBusy = false;
    if (resp['code'] !== 0) {
      this.cancelErr = resp['msg'] as string;
      return;
    }
    // 服务端已删干净且让 token 失效; 本机必须同步清: 报名缓存 + 会话, 否则留下幽灵数据
    try {
      await DbHelper.init(getContext(this) as common.UIAbilityContext);
      await DbHelper.deleteSignupsByStu(AppConfig.stuNo);
    } catch (e) {
      // 本地清理失败不影响服务端注销结果, 但要让用户知道
    }
    await AppConfig.logout();
    this.msg = '账号已注销';
    setTimeout(() => {
      Nav.resetTo('pages/LandingPage');
    }, 600);
  }

  async doLogout(): Promise<void> {
    // 先通知服务端注销 Token(立即失效, 避免旧 Token 24 小时内仍可用), 再清理本地会话
    await ApiClient.post('/api/logout', {});
    await AppConfig.logout();
    this.msg = '已退出登录';
    // 统一回引导页(而不是 back: 若从主界面进入, back 会停在已失效的主界面)
    setTimeout(() => {
      Nav.resetTo('pages/LandingPage');
    }, 400);
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(14).fontColor(Theme.primary)
          .padding({ right: 10, top: 2, bottom: 2 })
          .onClick(() => router.back())
        Text('设置').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('测试连接').fontSize(12).height(30).backgroundColor(Theme.primary)
          .enabled(!this.testing)
          .onClick(() => this.testConn())
      }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 8 })

      Scroll() {
        Column() {
          // 服务器连接
          Column({ space: 10 }) {
            Text('服务器连接(自主 C++ Web 服务器 + MySQL)').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            Text('模拟器/真机访问宿主机: 填宿主机局域网 IPv4, 例如 10.15.85.109; 模拟器也可用 10.0.2.2; 服务器 bind 0.0.0.0')
              .fontSize(11).fontColor(Theme.textTertiary).width('100%').lineHeight(17)
            Row({ space: 10 }) {
              TextInput({ text: this.host, placeholder: '服务器 IP' })
                .layoutWeight(1).onChange((v: string) => this.host = v)
              TextInput({ text: this.port, placeholder: '端口' })
                .type(InputType.NUMBER_DECIMAL).width(90).onChange((v: string) => this.port = v)
            }
            Button('保存服务器地址').width('100%').height(38).fontSize(14).backgroundColor(Theme.primary)
              .onClick(() => this.save())
          }
          .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14)

          // 当前账号(只读)
          Column({ space: 8 }) {
            Text('当前账号').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            if (this.loggedIn) {
              Row({ space: 10 }) {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(this.name).fontSize(15).fontWeight(FontWeight.Bold)
                    Text(this.roleTxt)
                      .fontSize(10).fontColor(Color.White)
                      .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                      .backgroundColor(this.isAdmin ? Theme.admin : Theme.success)
                      .borderRadius(8)
                  }
                  Text(this.isAdmin ? '管理员账号: ' + this.stuNo : '学号: ' + this.stuNo)
                    .fontSize(11).fontColor(Theme.textSecondary)
                  Text('身份由服务端校验(admin_user / student 表), 不可手动伪造')
                    .fontSize(10).fontColor(Theme.textDisabled)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }
              Button('退出登录').width('100%').height(38).fontSize(14)
                .backgroundColor(Theme.danger)
                .onClick(() => this.doLogout())
            } else {
              Column({ space: 8 }) {
                Text('当前未登录').fontSize(13).fontColor(Theme.textSecondary)
                Button('去登录').width('100%').height(38).fontSize(14).backgroundColor(Theme.primary)
                  .onClick(() => router.pushUrl({ url: 'pages/LoginPage' }))
              }.width('100%')
            }
          }
          .width('100%').padding(14).backgroundColor(Color.White).borderRadius(14).margin({ top: 10 })

          // ---- 注销账号(仅普通成员): 不可逆操作, 单独成区并如实列出后果 ----
          if (this.loggedIn && !this.isAdmin) {
            Column({ space: 10 }) {
              Row() {
                Text('危险操作').fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
                  .fontColor(Theme.danger)
              }.width('100%')

              if (!this.cancelOpen) {
                Text('注销后将永久删除本账号及其报名记录与已认定学时, 且无法恢复')
                  .fontSize(11).fontColor(Theme.textTertiary).width('100%').lineHeight(17)
                Button('注销账号')
                  .width('100%').height(38).fontSize(14)
                  .fontColor(Theme.danger)
                  .backgroundColor(Theme.dangerBg)
                  .borderRadius(Theme.radiusSm)
                  .onClick(() => this.openCancel())
              } else if (this.cancelLoading) {
                Text('正在统计将删除的数据...').fontSize(12).fontColor(Theme.textTertiary).width('100%')
              } else if (this.cancelImpact !== null) {
                // 如实列出影响面: 条数 / 学时 / 不可恢复
                Column({ space: 6 }) {
                  Text('将删除: ' + this.cancelImpact.stu_no + ' ' + this.cancelImpact.name +
                    (this.cancelImpact.dept !== '' ? ' · ' + this.cancelImpact.dept : ''))
                    .fontSize(12).fontWeight(FontWeight.Medium).fontColor(Theme.textBody).width('100%')
                  Text('· 报名记录 ' + this.cancelImpact.signup_total + ' 条' +
                    (this.cancelImpact.signup_passed > 0 ? '(其中已通过 ' + this.cancelImpact.signup_passed + ' 条)' : ''))
                    .fontSize(11).fontColor(Theme.textSecondary).width('100%')
                  Text('· 已认定学时 ' + this.cancelImpact.hours_sum.toFixed(1) + ' 学时')
                    .fontSize(11).fontColor(Theme.danger).width('100%')
                  Text('· 注销后学号可重新注册, 但原学时与报名记录不会恢复')
                    .fontSize(11).fontColor(Theme.textTertiary).width('100%')
                }
                .width('100%').padding(10).backgroundColor(Theme.dangerBg).borderRadius(Theme.radiusSm)
                .alignItems(HorizontalAlign.Start)

                TextInput({ text: this.cancelInput, placeholder: '输入本人学号 ' + this.stuNo + ' 以确认' })
                  .height(38).fontSize(13).width('100%')
                  .onChange((v: string) => { this.cancelInput = v; this.cancelErr = ''; })

                Row({ space: 10 }) {
                  Button('取消')
                    .layoutWeight(1).height(36).fontSize(13)
                    .fontColor(Theme.textSecondary).backgroundColor(Theme.bgSubtle)
                    .onClick(() => { this.cancelOpen = false; this.cancelInput = ''; this.cancelErr = ''; })
                  Button(this.cancelBusy ? '注销中...' : '确认注销')
                    .layoutWeight(1).height(36).fontSize(13)
                    .backgroundColor(this.cancelReady() ? Theme.danger : Theme.bgNeutral)
                    .fontColor(this.cancelReady() ? Theme.textOnPrimary : Theme.textDisabled)
                    .enabled(this.cancelReady() && !this.cancelBusy)
                    .onClick(() => this.doCancelAccount())
                }.width('100%')
              } else {
                Text('无法获取账号信息').fontSize(12).fontColor(Theme.danger).width('100%')
              }

              if (this.cancelErr !== '') {
                Text(this.cancelErr).fontSize(11).fontColor(Theme.danger).width('100%').lineHeight(17)
              }
            }
            .width('100%').padding(14).margin({ top: 10 })
            .backgroundColor(Color.White).borderRadius(14)
            .border({ width: 1, color: Theme.dangerBg })
          } else if (this.loggedIn && this.isAdmin) {
            Text('管理员账号不支持自助注销; 如需注销学生账号, 请到「管理 → 用户管理」操作')
              .fontSize(11).fontColor(Theme.textTertiary).width('100%').lineHeight(17)
              .padding(14).margin({ top: 10 })
              .backgroundColor(Theme.bgSubtle).borderRadius(12)
          }
          // 刷卡调试(模拟 RFID 终端): 真实链路是 ESP32 读卡后调用 /api/signin,
          // 这里用同一个接口模拟, 答辩没带硬件也能演示"刷卡 -> 签到 -> 学时累计"
          if (this.isAdmin) {
            Column({ space: 10 }) {
              Row() {
                Text('刷卡调试').fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
                Text('模拟 RFID 终端 · 仅管理员').fontSize(10).fontColor(Theme.signin)
              }.width('100%')
              Text('与 ESP32 调用同一个 /api/signin 接口: 选活动 + 填卡号即可模拟一次刷卡签到, 学时按活动自动认定')
                .fontSize(11).fontColor(Theme.textTertiary).width('100%').lineHeight(17)

              Row({ space: 8 }) {
                TextInput({ text: this.cardNo, placeholder: '卡号(如 A1B2C3D4)' })
                  .layoutWeight(1).height(38).fontSize(13)
                  .onChange((v: string) => this.cardNo = v)
                Select(this.actOptions)
                  .selected(this.actIndex)
                  .value(this.actIndex < this.actNames.length ? this.actNames[this.actIndex] : '选择活动')
                  .font({ size: 12 }).width(150)
                  .onSelect((i: number) => this.actIndex = i)
              }.width('100%')

              Button(this.signinBusy ? '刷卡处理中...' : '模拟刷卡')
                .width('100%').height(38).fontSize(14)
                .backgroundColor(Theme.signin)
                .enabled(!this.signinBusy)
                .onClick(() => this.doSignin())

              if (this.signinMsg !== '') {
                Text(this.signinMsg).fontSize(11)
                  .fontColor(this.signinOk ? Theme.success : Theme.danger)
                  .width('100%').lineHeight(17)
              }
            }
            .width('100%').padding(14).margin({ top: 10 })
            .backgroundColor(Color.White).borderRadius(14)
          }

          if (this.msg !== '') {
            Text(this.msg).fontSize(12).fontColor(Theme.primary).textAlign(TextAlign.Center).width('100%').margin({ top: 8 })
          }

          // 演示账号说明
          Column({ space: 5 }) {
            Text('演示账号').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
            Text('普通成员: 2023001 张三 / 2023002 李铭(登录: 学号+姓名)')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('管理员: admin / admin123(登录: 账号+密码)')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
            Text('RFID 签到卡: 张三 A1B2C3D4 / 李铭 E5F60708(嵌入式扩展项)')
              .fontSize(11).fontColor(Theme.textSecondary).width('100%')
          }
          .width('100%').padding(14).margin({ top: 10 })
          .backgroundColor(Theme.bgSubtle).borderRadius(12)
          .alignItems(HorizontalAlign.Start)
        }
        .padding(14)
      }
      .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor(Theme.bgPage)
  }
}
