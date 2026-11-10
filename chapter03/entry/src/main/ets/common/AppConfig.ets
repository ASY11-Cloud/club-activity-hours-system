/**
 * 社团活动报名与学时认定系统 —— 全局配置(服务器地址 / 登录会话)
 * 使用 Preferences 持久化:
 *  - 登录会话: role(admin/student) + token + 姓名 + 学号
 *  - 社团会话(v5.0): club_id / club_name / account_type
 *  - 服务器地址: 默认 10.0.2.2:8000(模拟器访问宿主机), 演示时填宿主机局域网 IPv4
 *
 * 注意: 服务端对"社团账号"下发的 role 仍是 admin(兼容旧判断),
 * 真正的区别在 clubId > 0 —— 社团账号只能看到自己社团的数据。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'club_cfg';

export class AppConfig {
  private static pref: preferences.Preferences | null = null;

  // 登录会话
  static role: string = '';      // '' 未登录 | 'admin' 管理员(含社团管理员) | 'student' 普通成员
  static token: string = '';
  static stuNo: string = '';
  static stuName: string = '';

  // 社团会话(v5.0): clubId > 0 表示当前是社团账号
  static clubId: number = 0;
  static clubName: string = '';
  static accountType: string = '';   // 'admin' | 'club' | 'student'

  // 服务器地址(设置页可改, 默认端口 8000)
  static serverHost: string = '10.0.2.2';
  static serverPort: string = '8000';

  /** 当前是否管理员(平台管理员与社团管理员都算) */
  static get isAdmin(): boolean {
    return AppConfig.role === 'admin';
  }

  /** 当前是否社团账号(认证主体是社团, 能管理本社团数据与换届) */
  static get isClubAccount(): boolean {
    return AppConfig.role === 'admin' && AppConfig.clubId > 0;
  }

  /** 当前是否已登录 */
  static get isLoggedIn(): boolean {
    return AppConfig.token !== '';
  }

  /** 角色显示名 */
  static get roleText(): string {
    if (AppConfig.isClubAccount) {
      return AppConfig.clubName === '' ? '社团账号' : AppConfig.clubName;
    }
    if (AppConfig.role === 'admin') return '平台管理员';
    if (AppConfig.role === 'student') return '普通成员';
    return '未登录';
  }

  static get serverBase(): string {
    let host = AppConfig.serverHost.trim();
    if (host === '') host = '10.0.2.2';
    return 'http://' + host + ':' + AppConfig.serverPort.trim();
  }

  /** 初始化: 读取持久化配置 */
  static async init(context: common.UIAbilityContext): Promise<void> {
    if (AppConfig.pref) return;
    const pref = await preferences.getPreferences(context, STORE_NAME);
    AppConfig.pref = pref;
    AppConfig.role = (await pref.get('role', '')) as string;
    AppConfig.token = (await pref.get('token', '')) as string;
    AppConfig.stuNo = (await pref.get('stu_no', '')) as string;
    AppConfig.stuName = (await pref.get('stu_name', '')) as string;
    AppConfig.clubId = (await pref.get('club_id', 0)) as number;
    AppConfig.clubName = (await pref.get('club_name', '')) as string;
    AppConfig.accountType = (await pref.get('account_type', '')) as string;
    AppConfig.serverHost = (await pref.get('server_host', '10.0.2.2')) as string;
    AppConfig.serverPort = (await pref.get('server_port', '8000')) as string;
  }

  /** 登录成功: 保存会话(社团账号额外保存 clubId / clubName) */
  static async saveLogin(role: string, name: string, stuNo: string, token: string,
    clubId: number = 0, clubName: string = '', accountType: string = ''): Promise<void> {
    AppConfig.role = role;
    AppConfig.stuName = name;
    AppConfig.stuNo = stuNo;
    AppConfig.token = token;
    AppConfig.clubId = clubId;
    AppConfig.clubName = clubName;
    AppConfig.accountType = accountType;
    if (!AppConfig.pref) return;
    await AppConfig.pref.put('role', role);
    await AppConfig.pref.put('stu_name', name);
    await AppConfig.pref.put('stu_no', stuNo);
    await AppConfig.pref.put('token', token);
    await AppConfig.pref.put('club_id', clubId);
    await AppConfig.pref.put('club_name', clubName);
    await AppConfig.pref.put('account_type', accountType);
    await AppConfig.pref.flush();
  }

  /** 退出登录: 清空会话 */
  static async logout(): Promise<void> {
    AppConfig.role = '';
    AppConfig.token = '';
    AppConfig.stuNo = '';
    AppConfig.stuName = '';
    AppConfig.clubId = 0;
    AppConfig.clubName = '';
    AppConfig.accountType = '';
    if (!AppConfig.pref) return;
    await AppConfig.pref.put('role', '');
    await AppConfig.pref.put('token', '');
    await AppConfig.pref.put('stu_no', '');
    await AppConfig.pref.put('stu_name', '');
    await AppConfig.pref.put('club_id', 0);
    await AppConfig.pref.put('club_name', '');
    await AppConfig.pref.put('account_type', '');
    await AppConfig.pref.flush();
  }

  /** 保存服务器地址 */
  static async saveServer(host: string, port: string): Promise<void> {
    AppConfig.serverHost = host.trim();
    AppConfig.serverPort = port.trim() === '' ? '8000' : port.trim();
    if (!AppConfig.pref) return;
    await AppConfig.pref.put('server_host', AppConfig.serverHost);
    await AppConfig.pref.put('server_port', AppConfig.serverPort);
    await AppConfig.pref.flush();
  }
}
