/**
 * 时间展示工具
 * 服务端统一下发 'YYYY-MM-DD HH:mm:ss'。直接铺在界面上既长又难读,
 * 这里统一转成 "11-19 周三 19:00" / "3 天后" 这类人能一眼读懂的形式。
 */
const WEEK: string[] = ['日', '一', '二', '三', '四', '五', '六'];

export class TimeFmt {
  /** 解析 'YYYY-MM-DD HH:mm:ss' 为毫秒(本地时区); 非法返回 0 */
  static parse(s: string): number {
    if (s === null || s === undefined || s.length < 19) return 0;
    const y = Number(s.substring(0, 4));
    const mo = Number(s.substring(5, 7)) - 1;
    const d = Number(s.substring(8, 10));
    const hh = Number(s.substring(11, 13));
    const mi = Number(s.substring(14, 16));
    const ss = Number(s.substring(17, 19));
    if (isNaN(y) || isNaN(mo) || isNaN(d)) return 0;
    return new Date(y, mo, d, hh, mi, ss).getTime();
  }

  static pad(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /** '2026-11-19 19:00:00' -> '11-19 周三 19:00'; 解析失败原样返回 */
  static short(s: string): string {
    const t = TimeFmt.parse(s);
    if (t === 0) return s;
    const dt = new Date(t);
    return (dt.getMonth() + 1).toString() + '-' + dt.getDate().toString() +
      ' 周' + WEEK[dt.getDay()] + ' ' + TimeFmt.pad(dt.getHours()) + ':' + TimeFmt.pad(dt.getMinutes());
  }

  /** '2026-11-19 19:00:00' -> '11-19'; 解析失败原样返回 */
  static day(s: string): string {
    const t = TimeFmt.parse(s);
    if (t === 0) return s;
    const dt = new Date(t);
    return (dt.getMonth() + 1).toString() + '-' + dt.getDate().toString();
  }

  /**
   * 活动当前所处阶段(用于列表上的状态标签):
   * 已结束 / 进行中 / 今天 HH:mm / N 天后 / N 个月后
   * 注意: 这里只给"相对时间", 具体日期由 TimeFmt.short 单独展示, 避免同一行出现两次日期。
   */
  static stage(startS: string, endS: string): string {
    const now = Date.now();
    const st = TimeFmt.parse(startS);
    const en = TimeFmt.parse(endS);
    if (en > 0 && now > en) return '已结束';
    if (st > 0 && now >= st) return '进行中';
    if (st > 0) {
      const diff = st - now;
      const days = Math.floor(diff / 86400000);
      if (days <= 0) return '今天 ' + TimeFmt.pad(new Date(st).getHours()) + ':' +
        TimeFmt.pad(new Date(st).getMinutes());
      if (days <= 30) return days.toString() + ' 天后';
      return Math.max(1, Math.round(days / 30)).toString() + ' 个月后';
    }
    return '时间待定';
  }

  /** 距开始还有几天(向上取整), 已开始/无法解析返回 0 */
  static daysUntil(startS: string): number {
    const st = TimeFmt.parse(startS);
    if (st === 0) return 0;
    const diff = st - Date.now();
    if (diff <= 0) return 0;
    return Math.ceil(diff / 86400000);
  }
}
