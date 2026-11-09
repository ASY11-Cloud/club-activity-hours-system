/**
 * 设计 token 统一出口
 * 目的: 颜色/字号/圆角/间距不再散落在各页面的字面量里。
 * 改主色、调圆角只需要动这一个文件; 也便于说明"本项目有统一视觉规范"。
 *
 * v3.2: 颜色改为资源引用($r('app.color.c_xxx')), 由 resources/base 与 resources/dark
 * 两套调色板分别提供浅色/深色值 —— 系统切换深色模式时自动生效, 页面代码零改动。
 * 注意: 颜色只在这里出口, 页面里不要再写死十六进制; 新增颜色要同时补 base 与 dark。
 */
export class Theme {
  // ---- 主色与语义色 ----
  static readonly primary: ResourceColor = $r('app.color.c_primary');            // 主色(按钮/选中/链接)
  static readonly primaryDark: ResourceColor = $r('app.color.c_primary_dark');   // 主色按压态
  static readonly primaryBg: ResourceColor = $r('app.color.c_primary_bg');       // 主色浅底(标签/选中块)
  static readonly gradientStart: ResourceColor = $r('app.color.c_gradient_start'); // 渐变头图起点色
  static readonly success: ResourceColor = $r('app.color.c_success');            // 通过/已认定/在线
  static readonly successBg: ResourceColor = $r('app.color.c_success_bg');
  static readonly danger: ResourceColor = $r('app.color.c_danger');              // 驳回/已结束/退出
  static readonly dangerBg: ResourceColor = $r('app.color.c_danger_bg');
  static readonly warning: ResourceColor = $r('app.color.c_warning');            // 待审核/名额已满
  static readonly warningBg: ResourceColor = $r('app.color.c_warning_bg');
  static readonly admin: ResourceColor = $r('app.color.c_admin');                // 管理员身份标识
  static readonly adminBg: ResourceColor = $r('app.color.c_admin_bg');
  static readonly signin: ResourceColor = $r('app.color.c_signin');              // 刷卡/签到码相关
  static readonly signinBg: ResourceColor = $r('app.color.c_signin_bg');
  static readonly report: ResourceColor = $r('app.color.c_report');              // 报表/导出
  static readonly reportBg: ResourceColor = $r('app.color.c_report_bg');
  static readonly onColorSuccess: ResourceColor = $r('app.color.c_on_success');  // 深底上的成功浅色文字
  static readonly onColorDanger: ResourceColor = $r('app.color.c_on_danger');    // 深底上的失败浅色文字

  // ---- 文本 ----
  static readonly textPrimary: ResourceColor = $r('app.color.c_text_primary');
  static readonly textBody: ResourceColor = $r('app.color.c_text_body');
  static readonly textSecondary: ResourceColor = $r('app.color.c_text_secondary');
  static readonly textTertiary: ResourceColor = $r('app.color.c_text_tertiary');
  static readonly textDisabled: ResourceColor = $r('app.color.c_text_disabled');
  static readonly textOnPrimary: ResourceColor = $r('app.color.c_text_on_primary');

  // ---- 背景与描边 ----
  static readonly bgPage: ResourceColor = $r('app.color.c_bg_page');
  static readonly bgCard: ResourceColor = $r('app.color.c_bg_card');
  static readonly bgSubtle: ResourceColor = $r('app.color.c_bg_subtle');
  static readonly bgNeutral: ResourceColor = $r('app.color.c_bg_neutral');
  static readonly divider: ResourceColor = $r('app.color.c_divider');

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
