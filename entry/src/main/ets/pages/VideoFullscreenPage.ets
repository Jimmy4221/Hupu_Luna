import { window } from '@kit.ArkUI';
import { VideoOrientation } from '../common/VideoOrientation';

/** 全屏播放返回给上一页的播放状态（用于原位续播） */
export class VideoPlaybackResult {
  position: number = 0;
  muted: boolean = true;
}

/**
 * 视频全屏播放页
 *
 * 为什么不直接用 VideoController.requestFullscreen：
 * 该接口在列表项/自定义控件场景下只会触发窗口旋转，画面并不会真正铺满屏幕。
 * 这里改为独立的 NavDestination 全屏页：视频铺满窗口 + 横屏 + 隐藏系统栏，
 * 退出时恢复竖屏与系统栏，并把播放进度回传给调用页续播。
 */
@Component
export struct VideoFullscreenPage {
  /** 格式："url||startSec||muted(1/0)||title" */
  param: string = '';
  @Consume('pageStack') pageStack: NavPathStack;
  @State muted: boolean = true;
  @State playing: boolean = false;
  @State prepared: boolean = false;
  @State controlsVisible: boolean = true;
  @State curSec: number = 0;
  @State durSec: number = 0;
  @State scrubbing: boolean = false;
  @State title: string = '';
  private url: string = '';
  private startSec: number = 0;
  private closed: boolean = false;
  private hideTimer: number = -1;
  private controller: VideoController = new VideoController();

  aboutToAppear(): void {
    const parts: string[] = this.param.split('||');
    this.url = parts.length > 0 ? parts[0] : '';
    if (parts.length > 1) {
      const sec: number = Number(parts[1]);
      this.startSec = Number.isFinite(sec) && sec > 0 ? sec : 0;
    }
    if (parts.length > 2) {
      this.muted = parts[2] === '1';
    }
    if (parts.length > 3) {
      this.title = parts[3];
    }
    this.applyWindow(true);
    VideoOrientation.enterLandscape();
  }

  aboutToDisappear(): void {
    this.applyWindow(false);
    VideoOrientation.restorePortrait();
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  /** 进入/退出全屏时的窗口处理：系统栏显隐 + 常亮 */
  private applyWindow(enter: boolean): void {
    const win: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
    if (win === undefined) {
      return;
    }
    try {
      win.setWindowSystemBarEnable(enter ? [] : ['status', 'navigation']);
    } catch (e) {
    }
    try {
      win.setWindowKeepScreenOn(enter);
    } catch (e) {
    }
  }

  /** 退出全屏：回传进度并返回上一页（重复调用安全） */
  private close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      this.controller.pause();
    } catch (e) {
    }
    const result: VideoPlaybackResult = new VideoPlaybackResult();
    result.position = this.curSec > 0 ? this.curSec : this.startSec;
    result.muted = this.muted;
    // 放到下一帧再出栈：避免在 onBackPressed 回调里直接操作路由栈
    setTimeout(() => {
      this.pageStack.pop(result, true);
    }, 0);
  }

  private togglePlay(): void {
    if (this.playing) {
      this.controller.pause();
    } else {
      this.controller.start();
    }
  }

  /** 控件条自动隐藏（播放中且未拖动进度时） */
  private scheduleHide(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (this.playing && !this.scrubbing) {
        this.controlsVisible = false;
      }
    }, 3500);
  }

  private onScrub(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      this.scrubbing = true;
      this.curSec = value;
      return;
    }
    this.curSec = value;
    this.scrubbing = false;
    this.controller.setCurrentTime(value);
    this.scheduleHide();
  }

  private formatSec(sec: number): string {
    let s: number = Math.floor(sec);
    if (s < 0 || Number.isNaN(s)) {
      s = 0;
    }
    const m: number = Math.floor(s / 60);
    const r: number = s % 60;
    return `${m < 10 ? '0' : ''}${m}:${r < 10 ? '0' : ''}${r}`;
  }

  @Builder
  Controls() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text(this.playing ? '❚❚' : '▶')
          .fontSize(16)
          .fontColor(Color.White)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .backgroundColor('#59000000')
          .borderRadius(17)
          .onClick(() => {
            this.togglePlay();
            this.scheduleHide();
          })
        Text(this.formatSec(this.curSec))
          .fontSize(12)
          .fontColor(Color.White)
        Slider({
          value: this.curSec,
          min: 0,
          max: this.durSec > 0 ? this.durSec : 1,
          step: 0.1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .trackThickness(3)
          .trackColor('#4DFFFFFF')
          .selectedColor($r('app.color.brand_primary'))
          .blockColor(Color.White)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onScrub(value, mode);
          })
        Text(this.formatSec(this.durSec))
          .fontSize(12)
          .fontColor(Color.White)
        Text(this.muted ? '🔇' : '🔊')
          .fontSize(15)
          .fontColor(Color.White)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .backgroundColor('#59000000')
          .borderRadius(17)
          .onClick(() => {
            this.muted = !this.muted;
            this.scheduleHide();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 18 })
    .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#99000000', 1.0]] })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Video({ src: this.url, controller: this.controller })
          .autoPlay(true)
          .controls(false)
          .loop(false)
          .muted(this.muted)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
          .onPrepared((e: PreparedInfo) => {
            this.prepared = true;
            if (e.duration > 0) {
              this.durSec = e.duration;
            }
            // 续播定位：onPrepared 立即 seek 在部分设备上会被随后起播覆盖，再补一次延时定位
            if (this.startSec > 0.5) {
              this.controller.setCurrentTime(this.startSec);
              this.curSec = this.startSec;
              setTimeout(() => {
                if (this.startSec > 0.5) {
                  this.controller.setCurrentTime(this.startSec);
                  this.curSec = this.startSec;
                }
              }, 260);
            }
            this.scheduleHide();
          })
          .onStart(() => {
            this.playing = true;
            this.scheduleHide();
          })
          .onPause(() => {
            this.playing = false;
            this.controlsVisible = true;
          })
          .onUpdate((e: PlaybackInfo) => {
            if (!this.scrubbing) {
              this.curSec = e.time;
            }
          })
          .onClick(() => {
            this.controlsVisible = !this.controlsVisible;
            if (this.controlsVisible) {
              this.scheduleHide();
            }
          })

        if (!this.prepared) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(30)
              .height(30)
              .color(Color.White)
            Text('正在加载视频…')
              .fontSize(13)
              .fontColor('#B3FFFFFF')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }

        if (this.controlsVisible) {
          this.Controls()
        }

        // 关闭按钮常驻左上角，避免和播放控件互相遮挡
        Row() {
          Text('✕')
            .fontSize(18)
            .fontColor(Color.White)
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .backgroundColor('#66000000')
            .borderRadius(19)
            .onClick(() => this.close())
          Blank()
          if (this.title.length > 0) {
            Text(this.title)
              .fontSize(13)
              .fontColor('#D9FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .margin({ left: 12, right: 8 })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 10 })
        .position({ x: 0, y: 0 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Black)
    .onBackPressed(() => {
      this.close();
      return true;
    })
  }
}
