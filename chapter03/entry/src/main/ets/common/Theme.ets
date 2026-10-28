/**
 * 设计 token 统一出口
 * 目的: 颜色/字号/圆角/间距不再散落在各页面的字面量里。
 * 改主色、调圆角只需要动这一个文件; 也便于说明"本项目有统一视觉规范"。
 * 注意: 本文件是全项目唯一的颜色字面量落点, 不要改成引用自身。
 */
export class Theme {
  // ---- 主色与语义色 ----
  static readonly primary: string = '#1E6FFF';        // 主色(按钮/选中/链接)
  static readonly primaryDark: string = '#1557CC';    // 主色按压态
  static readonly primaryBg: string = '#EAF1FF';      // 主色浅底(标签/选中块)
  static readonly success: string = '#07C160';        // 通过/已认定/在线
  static readonly successBg: string = '#E8F8EF';
  static readonly danger: string = '#E84026';         // 驳回/已结束/退出
  static readonly dangerBg: string = '#FDECEA';
  static readonly warning: string = '#B25E00';        // 待审核/名额已满
  static readonly warningBg: string = '#FFF3E0';
  static readonly admin: string = '#F5652F';          // 管理员身份标识
  static readonly adminBg: string = '#FFF0E9';
  static readonly signin: string = '#6C5CE7';         // 刷卡/RFID 相关
  static readonly signinBg: string = '#EFECFF';
  static readonly report: string = '#00A884';         // 报表/导出
  static readonly reportBg: string = '#E6F7F3';
  static readonly onColorSuccess: string = '#D4F5DD';  // 深底上的成功浅色文字(如头部在线状态)
  static readonly onColorDanger: string = '#FFD9D2';   // 深底上的失败浅色文字(如头部离线状态)

  // ---- 文本 ----
  static readonly textPrimary: string = '#1F2329';
  static readonly textBody: string = '#333333';
  static readonly textSecondary: string = '#666666';
  static readonly textTertiary: string = '#999999';
  static readonly textDisabled: string = '#BBBBBB';
  static readonly textOnPrimary: string = '#FFFFFF';

  // ---- 背景与描边 ----
  static readonly bgPage: string = '#F5F7FA';
  static readonly bgCard: string = '#FFFFFF';
  static readonly bgSubtle: string = '#F2F4F8';
  static readonly bgNeutral: string = '#E9ECF3';
  static readonly divider: string = '#EEEEEE';

  // ---- 字号 ----
  static readonly fsCaption: number = 11;   // 辅助说明
  static readonly fsSmall: number = 12;     // 次要信息
  static readonly fsBody: number = 13;      // 正文
  static readonly fsTitle: number = 15;     // 卡片标题
  static readonly fsHeading: number = 18;   // 页面标题
  static readonly fsDisplay: number = 22;   // 大数字/主标题

  // ---- 圆角 ----
  static readonly radiusSm: number = 8;
  static readonly radiusMd: number = 12;
  static readonly radiusLg: number = 16;
  static readonly radiusPill: number = 999;

  // ---- 间距(8 栅格, 4 为半格) ----
  static readonly gapXs: number = 4;
  static readonly gapSm: number = 8;
  static readonly gapMd: number = 12;
  static readonly gapLg: number = 16;
  static readonly gapXl: number = 20;

  // ---- 常用尺寸 ----
  static readonly pagePadding: number = 14;  // 页面左右留白
  static readonly tapHeight: number = 44;    // 最小可点高度
}
