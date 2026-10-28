/**
 * 社团活动报名与学时认定系统 —— 统一权限守卫视图(v2.2)
 * 收敛原先各页风格分裂的守卫:
 *  - LoginGuardView : 未登录 -> 「去登录」统一 replaceUrl 引导页(登录成功后会 replace 到主界面, 返回栈干净)
 *  - AdminGuardView : 非管理员访问管理员功能 -> 「返回」回上一页
 */
import { router } from '@kit.ArkUI';
import { Nav } from './Nav';

@Component
export struct LoginGuardView {
  tip: string = '请先登录后使用本功能';

  build() {
    Column({ space: 12 }) {
      Text('🔒').fontSize(40)
      Text('请先登录').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text(this.tip).fontSize(12).fontColor('#999999').textAlign(TextAlign.Center)
      Button('去登录').fontSize(14).height(38).width(160).backgroundColor('#1E6FFF')
        .onClick(() => {
          Nav.resetTo('pages/LandingPage');
        })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }
}

@Component
export struct AdminGuardView {
  tip: string = '此功能仅限管理员使用';

  build() {
    Column({ space: 12 }) {
      Text('🛡').fontSize(40)
      Text('仅管理员可访问').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#333333')
      Text(this.tip).fontSize(12).fontColor('#999999').textAlign(TextAlign.Center)
      Button('返回').fontSize(14).height(38).width(160).backgroundColor('#1E6FFF')
        .onClick(() => {
          router.back();
        })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }
}
