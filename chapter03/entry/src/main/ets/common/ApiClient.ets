/**
 * 社团活动报名与学时认定系统 —— HTTP 网络封装
 * 基于 @ohos.net.http, 所有接口返回 {code, msg, data} 结构。
 */
import { http } from '@kit.NetworkKit';
import { AppConfig } from './AppConfig';

export class ApiClient {
  /** GET 请求 */
  static async get(path: string): Promise<Record<string, Object>> {
    return ApiClient.request('GET', path, '');
  }

  /** POST JSON 请求 */
  static async post(path: string, body: Record<string, Object>): Promise<Record<string, Object>> {
    return ApiClient.request('POST', path, JSON.stringify(body));
  }

  private static async request(method: string, path: string, body: string): Promise<Record<string, Object>> {
    const req = http.createHttp();
    try {
      const url = AppConfig.serverBase + path;
      const header: Record<string, string> = { 'Content-Type': 'application/json; charset=utf-8' };
      // 登录后自动携带 Token, 服务端按角色鉴权
      if (AppConfig.token !== '') {
        header['Authorization'] = 'Bearer ' + AppConfig.token;
      }
      const option: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: header,
        connectTimeout: 8000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== '') {
        option.extraData = body;
      }
      const resp = await req.request(url, option);
      if (resp.responseCode === 200) {
        const text = resp.result as string;
        try {
          return JSON.parse(text) as Record<string, Object>;
        } catch (e) {
          return { 'code': -2, 'msg': '响应解析失败' };
        }
      }
      // 401: Token 过期/服务端重启/已注销 —— 清掉本地会话后再给可执行提示,
      // 否则界面仍显示"已登录", 用户点什么都失败却不知道要先退出。
      if (resp.responseCode === 401) {
        if (AppConfig.token !== '') {
          await AppConfig.logout();
        }
        return { 'code': -401, 'msg': '登录已失效, 已清除本地登录状态, 请重新登录' };
      }
      return { 'code': -1, 'msg': 'HTTP ' + resp.responseCode.toString() };
    } catch (e) {
      const msg = (e as Error).message;
      return { 'code': -3, 'msg': '无法连接服务器: ' + msg };
    } finally {
      req.destroy();
    }
  }

  /** 测试服务器连接 */
  static async ping(): Promise<boolean> {
    const r = await ApiClient.get('/api/health');
    return r['code'] === 0;
  }
}
