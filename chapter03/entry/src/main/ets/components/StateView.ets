/**
 * 统一状态视图: 加载中 / 空 / 出错(带原因与重试)
 * 之前每个页面各写一遍"加载中..."，且网络失败时给的是业务文案
 * (例如详情页把"连不上服务器"显示成"活动不存在")。收敛到这里后，
 * 错误一律带上真实原因和重试入口。
 */
import { Theme } from '../common/Theme';

@Component
export struct StateView {
  /** loading | empty | error */
  @Prop kind: string = 'loading';
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop retryText: string = '重试';
  /** 点击重试(仅 error 生效); 未传则不显示按钮 */
  onRetry: () => void = () => {
  };

  @Builder
  markCircle(symbol: string, color: string, bg: string) {
    Text(symbol)
      .fontSize(26).fontColor(color).textAlign(TextAlign.Center)
      .width(64).height(64)
      .backgroundColor(bg).borderRadius(32)
  }

  build() {
    Column({ space: 10 }) {
      if (this.kind === 'loading') {
        LoadingProgress().width(36).height(36).color(Theme.primary)
        Text(this.title === '' ? '加载中...' : this.title)
          .fontSize(Theme.fsBody).fontColor(Theme.textTertiary)
      } else if (this.kind === 'error') {
        this.markCircle('!', Theme.danger, Theme.dangerBg)
        Text(this.title === '' ? '加载失败' : this.title)
          .fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium).fontColor(Theme.textBody)
        if (this.desc !== '') {
          Text(this.desc)
            .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
            .textAlign(TextAlign.Center).lineHeight(19)
            .padding({ left: 36, right: 36 })
        }
        Button(this.retryText)
          .fontSize(Theme.fsBody).height(36).width(120)
          .backgroundColor(Theme.primary)
          .margin({ top: 4 })
          .onClick(() => this.onRetry())
      } else {
        this.markCircle('—', Theme.textDisabled, Theme.bgSubtle)
        Text(this.title === '' ? '暂无数据' : this.title)
          .fontSize(Theme.fsTitle).fontWeight(FontWeight.Medium).fontColor(Theme.textSecondary)
        if (this.desc !== '') {
          Text(this.desc)
            .fontSize(Theme.fsSmall).fontColor(Theme.textTertiary)
            .textAlign(TextAlign.Center).lineHeight(19)
            .padding({ left: 36, right: 36 })
        }
      }
    }
    .width('100%')
    .padding({ top: 56, bottom: 56 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
