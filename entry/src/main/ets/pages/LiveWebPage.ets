import web_webview from '@ohos.web.webview';
import { Spacing } from '../common/Theme';
import { AppNavBar } from '../views/AppNavBar';

/**
 * 官方直播平台内嵌播放页。
 *
 * 只加载虎扑直播间给出的官方转播平台地址（如咪咕视频免费场次），
 * 视频由平台自己提供并鉴权，本应用不转存、不代理、不解析播放地址。
 */
@Component
export struct LiveWebPage {
  /** 参数格式："url||title" */
  param: string = '';
  @State url: string = '';
  @State title: string = '直播';
  @State progress: number = 0;
  private controller: web_webview.WebviewController = new web_webview.WebviewController();

  aboutToAppear(): void {
    const parts: string[] = this.param.split('||');
    if (parts.length >= 1) {
      this.url = parts[0];
    }
    if (parts.length >= 2 && parts[1].length > 0) {
      this.title = parts[1];
    }
  }

  build() {
    NavDestination() {
      Column() {
        AppNavBar({ title: this.title })
        if (this.progress > 0 && this.progress < 100) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(2)
            .color($r('app.color.brand_primary'))
        }
        Web({ src: this.url, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .mediaPlayGestureAccess(true)
          .mixedMode(MixedMode.All)
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(false)
          .onProgressChange((e) => {
            this.progress = e.newProgress;
          })
          .backgroundColor($r('app.color.bg_page'))
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: Spacing.xs })
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
