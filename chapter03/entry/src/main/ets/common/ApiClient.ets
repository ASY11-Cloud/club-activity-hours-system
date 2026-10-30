/**
 * 社团活动报名与学时认定系统 —— HTTP 网络封装
 * 基于 @ohos.net.http, 所有接口返回 {code, msg, data} 结构。
 */
import { http } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import { AppConfig } from './AppConfig';

export class ApiClient {
  /** GET 请求 */
  static async get(path: string): Promise<Record<string, Object>> {
    return ApiClient.request('GET', path, '', false);
  }

  /**
   * POST JSON 请求。
   * @param silentToast true 时不弹全局错误 toast(批量操作等自带失败统计的场景使用),
   *                    默认所有写操作失败都会弹 toast —— 用户主动做的动作必须得到结果反馈,
   *                    不能只靠页面角落一行小字(那里很容易被忽略, 等于没有提醒)。
   */
  static async post(path: string, body: Record<string, Object>, silentToast: boolean = false):
    Promise<Record<string, Object>> {
    return ApiClient.request('POST', path, JSON.stringify(body), silentToast);
  }

  private static async request(method: string, path: string, body: string, silentToast: boolean):
    Promise<Record<string, Object>> {
    const req = http.createHttp();
    let failed: Record<string, Object> | null = null;
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
          const j = JSON.parse(text) as Record<string, Object>;
          // 服务端约定: 业务错误也走 HTTP 200, 真正的 code 在 body 里 ——
          // 因此"登录失效"(code 401)必须在这里识别, 否则 token 过期后
          // 界面仍显示已登录, 用户点什么都是失败却不知道要重新登录。
          if (j['code'] !== undefined && Number(j['code']) === 401 && AppConfig.token !== '') {
            await AppConfig.logout();
          }
          return j;
        } catch (e) {
          failed = { 'code': -2, 'msg': '响应解析失败' };
        }
      } else if (resp.responseCode === 401) {
        // 401: Token 过期/服务端重启/已注销 —— 清掉本地会话后再给可执行提示,
        // 否则界面仍显示"已登录", 用户点什么都失败却不知道要先退出。
        if (AppConfig.token !== '') {
          await AppConfig.logout();
        }
        failed = { 'code': -401, 'msg': '登录已失效, 已清除本地登录状态, 请重新登录' };
      } else {
        // 4xx/5xx: 服务端的错误体是 JSON({code,msg}), 中文提示必须透传给页面 ——
        // 旧实现直接压成 "HTTP 404", 把"该报名已被学生撤销"这类原因全部丢掉了。
        const text = resp.result as string;
        let msg = 'HTTP ' + resp.responseCode.toString();
        try {
          const j = JSON.parse(text) as Record<string, Object>;
          if (j['msg'] !== undefined && j['msg'] !== '') {
            msg = j['msg'] as string;
          }
        } catch (e) {
        }
        failed = { 'code': -1, 'msg': msg };
      }
    } catch (e) {
      failed = { 'code': -3, 'msg': '无法连接服务器, 请检查服务端是否已启动' };
    } finally {
      req.destroy();
    }
    // 到这里说明请求失败(failed 非空): 写操作默认弹 toast, 让用户立刻看到结果
    if (method === 'POST' && !silentToast && failed['code'] !== -401) {
      promptAction.showToast({
        message: '操作失败: ' + (failed['msg'] as string),
        duration: 3000,
        bottom: 120
      });
    }
    return failed;
  }

  /** 测试服务器连接 */
  static async ping(): Promise<boolean> {
    const r = await ApiClient.get('/api/health');
    return r['code'] === 0;
  }
}
