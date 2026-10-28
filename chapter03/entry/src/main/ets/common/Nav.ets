/**
 * 路由工具(v2.3)
 * 背景: LandingPage 既是冷启动根页, 又可能被「我的 → 系统介绍」以二级页方式打开;
 * 若根级切换仍用 replaceUrl, 栈里会堆积重复的 MainPage (返回键回到上一个实例, 状态错乱)。
 * 根级切换统一走 resetTo(): 先清空历史栈再替换当前页, 保证栈里只有一个根页。
 */
import { router } from '@kit.ArkUI';

export class Nav {
  /** 根级切换: 清空历史栈后进入目标页(登录成功进主界面 / 退出回引导页) */
  static resetTo(url: string): void {
    try {
      router.clear(); // 保留当前页, 清掉历史页
    } catch (e) {
      console.warn('router.clear failed: ' + (e as Error).message);
    }
    router.replaceUrl({ url: url });
  }

  /** 进入二级页 */
  static to(url: string, params?: Record<string, Object>): void {
    if (params !== undefined) {
      router.pushUrl({ url: url, params: params });
    } else {
      router.pushUrl({ url: url });
    }
  }
}
