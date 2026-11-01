import { ImageKnife, CacheStrategy } from '@ohos/imageknife';
import { bundleManager, common } from '@kit.AbilityKit';
import { Spacing, Radius, RouteName } from '../common/Theme';
import { SessionManager, HupuUserInfo } from '../network/SessionManager';
import { AppSettings, CACHE_PRESETS, DEFAULT_CACHE_MB, MIN_CACHE_MB, MAX_CACHE_MB } from '../common/AppSettings';
import { AppNavBar } from '../views/AppNavBar';

/** 设置页：关于 / 账号 / 存储设置 / 播放设置 */
@Component
export struct SettingsPage {
  @Consume('pageStack') pageStack: NavPathStack;
  @StorageLink('loginState') @Watch('onLoginChanged') loginState: number = 0;
  @StorageLink('imageCacheMb') imageCacheMb: number = DEFAULT_CACHE_MB;
  @StorageLink('autoplayFeed') autoplayFeed: boolean = true;
  @StorageLink('autoplayPost') autoplayPost: boolean = true;
  @State version: string = '0.5.0';
  @State showCookieEditor: boolean = false;
  @State cookieInput: string = '';
  @State verifying: boolean = false;
  @State loginUser: HupuUserInfo = new HupuUserInfo();
  /** 缓存上限编辑面板（长按缓存行唤起） */
  @State showCacheEditor: boolean = false;
  @State cacheInput: string = '';
  /** 图片磁盘缓存已用大小（MB） */
  @State cacheUsedMb: number = 0;

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      if (info.versionName && info.versionName.length > 0) {
        this.version = info.versionName;
      }
    } catch (e) {
    }
    this.initSession();
    this.refreshCacheUsage();
  }

  private async initSession(): Promise<void> {
    await SessionManager.ensureLoaded(this.getCtx());
    this.refreshUser();
  }

  onLoginChanged(): void {
    this.refreshUser();
  }

  private async refreshUser(): Promise<void> {
    if (this.loginState !== 1) {
      this.loginUser = new HupuUserInfo();
      return;
    }
    const u: HupuUserInfo | null = await SessionManager.verify();
    if (u !== null) {
      this.loginUser = u;
    } else {
      await SessionManager.logout(this.getCtx());
      this.toast('登录已失效，请重新注入 Cookie');
    }
  }

  private getCtx(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (e) {
    }
  }

  /** 读取图片磁盘缓存当前占用（MB） */
  private refreshCacheUsage(): void {
    try {
      const used: number | undefined = ImageKnife.getInstance().getCurrentCacheSize(CacheStrategy.File);
      this.cacheUsedMb = used === undefined || used < 0 ? 0 : used / 1024 / 1024;
    } catch (e) {
      this.cacheUsedMb = 0;
    }
  }

  /** 缓存占用文案（保留一位小数） */
  private cacheUsedText(): string {
    if (this.cacheUsedMb < 1) {
      return `${(this.cacheUsedMb * 1024).toFixed(0)} KB`;
    }
    return `${this.cacheUsedMb.toFixed(1)} MB`;
  }

  /** 打开缓存上限编辑面板（长按触发） */
  private openCacheEditor(): void {
    this.cacheInput = `${this.imageCacheMb}`;
    this.showCacheEditor = true;
  }

  /** 保存缓存上限：合法值立即生效，越界提示 */
  private async saveCacheLimit(): Promise<void> {
    const raw: string = this.cacheInput.trim();
    const n: number = Number(raw);
    if (raw.length === 0 || !Number.isFinite(n) || n <= 0 || Math.floor(n) !== n) {
      this.toast('请输入整数（单位 MB）');
      return;
    }
    if (n < MIN_CACHE_MB || n > MAX_CACHE_MB) {
      this.toast(`请输入 ${MIN_CACHE_MB} – ${MAX_CACHE_MB} 之间的数值`);
      return;
    }
    await AppSettings.setImageCacheMb(this.getCtx(), n);
    this.showCacheEditor = false;
    this.refreshCacheUsage();
    this.toast(`缓存上限已设为 ${AppSettings.clampMb(n)} MB`);
  }

  /** 注入 Cookie：保存并实测验证 */
  private async doInjectCookie(): Promise<void> {
    if (this.verifying) {
      return;
    }
    const input: string = this.cookieInput.trim();
    if (input.length < 20 || input.indexOf('ua=') < 0) {
      this.toast('请粘贴完整的浏览器 Cookie（需包含 ua= 键）');
      return;
    }
    this.verifying = true;
    try {
      const u: HupuUserInfo | null = await SessionManager.saveAndVerify(this.getCtx(), input);
      if (u !== null) {
        this.loginUser = u;
        this.showCookieEditor = false;
        this.cookieInput = '';
        this.toast(`欢迎，${u.username}`);
      } else {
        this.toast('验证失败：Cookie 无效或已过期');
      }
    } catch (e) {
      this.toast('验证失败，请检查网络');
    }
    this.verifying = false;
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '将清除本机保存的登录 Cookie，恢复只读模式。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: $r('app.color.brand_primary'),
        action: () => {
          this.doLogout();
        }
      }
    });
  }

  private async doLogout(): Promise<void> {
    await SessionManager.logout(this.getCtx());
    this.loginUser = new HupuUserInfo();
    this.toast('已退出登录');
  }

  @Builder
  SectionTitle(t: string) {
    Text(t)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 4, top: 14, bottom: 6 })
  }

  @Builder
  RowItem(title: string, arrow: boolean, isAction: boolean, onTap: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor(isAction ? $r('app.color.brand_primary') : $r('app.color.text_primary'))
      Blank()
      if (arrow) {
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(50)
    .onClick(() => {
      onTap();
    })
  }

  /** 关于（第一位）：应用信息 + 免责声明 */
  @Builder
  AboutSection() {
    this.SectionTitle('关于')
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.app_icon'))
          .width(48)
          .height(48)
          .borderRadius(10)
        Column({ space: 3 }) {
          Text('Hupu Luna')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`版本 ${this.version} · 非官方客户端`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      Divider().color($r('app.color.divider'))

      Text('本应用为第三方学习项目，与虎扑官方无任何关联。所有内容数据均来自虎扑公开页面，版权归虎扑及相关权利人所有。仅供个人学习与交流使用，请勿用于商业用途。')
        .fontSize(12)
        .lineHeight(19)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ top: 12, bottom: 12 })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)
  }

  @Builder
  AccountSection() {
    this.SectionTitle('账号')
    Column() {
      if (this.loginState === 1 && this.loginUser.username.length > 0) {
        Row({ space: 12 }) {
          if (this.loginUser.header.length > 0) {
            Image(this.loginUser.header)
              .width(42)
              .height(42)
              .borderRadius(21)
              .alt($r('app.media.app_icon'))
          }
          Column({ space: 3 }) {
            Text(this.loginUser.username)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('已登录 · uid ' + this.loginUser.uid)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('退出')
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.tag_bg'))
            .borderRadius(14)
            .onClick(() => {
              this.confirmLogout();
            })
        }
        .width('100%')
        .height(66)
      } else {
        this.RowItem('虎扑账号登录（推荐）', true, false, () => {
          this.pageStack.pushPathByName(RouteName.LOGIN_WEB, '');
        })
        Divider().color($r('app.color.divider'))
        Row() {
          Text('或手动粘贴 Cookie（备用）')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text('›')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .height(44)
        .onClick(() => {
          this.showCookieEditor = !this.showCookieEditor;
        })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)

    if (this.showCookieEditor) {
      Column({ space: 10 }) {
        Text('粘贴浏览器整串 Cookie（F12 → Network → 请求标头 → Cookie）。仅存本机，用于解锁点亮/回复/云收藏。')
          .fontSize(11)
          .lineHeight(16)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextArea({ text: this.cookieInput, placeholder: 'smidV2=...; u=...; us=...; ua=...' })
          .fontSize(12)
          .height(110)
          .width('100%')
          .backgroundColor($r('app.color.tag_bg'))
          .borderRadius(Radius.sm)
          .onChange((v: string) => {
            this.cookieInput = v;
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 9, bottom: 9 })
            .backgroundColor($r('app.color.tag_bg'))
            .borderRadius(Radius.sm)
            .onClick(() => {
              this.showCookieEditor = false;
              this.cookieInput = '';
            })
          Text(this.verifying ? '验证中…' : '保存并验证')
            .fontSize(13)
            .fontColor(Color.White)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 9, bottom: 9 })
            .backgroundColor($r('app.color.brand_primary'))
            .borderRadius(Radius.sm)
            .onClick(() => {
              this.doInjectCookie();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(Radius.md)
      .margin({ top: 8 })
    }
  }

  /** 存储设置（第三位）：只有缓存上限，点击右侧箭头自定义 */
  @Builder
  StorageSection() {
    this.SectionTitle('存储设置')
    Column({ space: 2 }) {
      Row() {
        Text('图片缓存上限')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.imageCacheMb} MB`)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ left: 4 })
      }
      .width('100%')
      .height(50)
      .onClick(() => {
        this.openCacheEditor();
      })

      Text(`已占用 ${this.cacheUsedText()} · 点击右侧箭头可自定义`)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ bottom: 10 })
        .onClick(() => {
          this.openCacheEditor();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)

    if (this.showCacheEditor) {
      this.CacheEditor()
    }
  }

  /** 缓存上限编辑面板：常用档位 + 自定义输入 */
  @Builder
  CacheEditor() {
    Column({ space: 10 }) {
      Text(`缓存上限（${MIN_CACHE_MB} – ${MAX_CACHE_MB} MB）`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 8 }) {
        ForEach(CACHE_PRESETS, (mb: number) => {
          Text(`${mb}`)
            .fontSize(12)
            .fontColor(this.imageCacheMb === mb ? Color.White : $r('app.color.text_primary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.imageCacheMb === mb ? $r('app.color.brand_primary') : $r('app.color.tag_bg'))
            .borderRadius(13)
            .onClick(() => {
              this.cacheInput = `${mb}`;
              this.saveCacheLimit();
            })
        }, (mb: number) => `${mb}`)
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.cacheInput, placeholder: '自定义大小' })
          .type(InputType.Number)
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .backgroundColor($r('app.color.tag_bg'))
          .borderRadius(Radius.sm)
          .onChange((v: string) => {
            this.cacheInput = v;
          })
        Text('MB')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('取消')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor($r('app.color.tag_bg'))
          .borderRadius(Radius.sm)
          .onClick(() => {
            this.showCacheEditor = false;
          })
        Text('保存')
          .fontSize(13)
          .fontColor(Color.White)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor($r('app.color.brand_primary'))
          .borderRadius(Radius.sm)
          .onClick(() => {
            this.saveCacheLimit();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)
    .margin({ top: 8 })
  }

  /** 播放设置（第四位）：信息流 / 帖子详情两个自动播放开关 */
  @Builder
  PlaybackSection() {
    this.SectionTitle('播放设置')
    Column() {
      this.SwitchRow('信息流自动播放', '首页推荐流滚动到视频时自动静音播放', this.autoplayFeed, (on: boolean) => {
        AppSettings.setAutoPlayFeed(this.getCtx(), on);
      })
      Divider().color($r('app.color.divider'))
      this.SwitchRow('打开帖子自动播放', '进入视频帖详情页时自动静音播放', this.autoplayPost, (on: boolean) => {
        AppSettings.setAutoPlayPost(this.getCtx(), on);
      })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)
  }

  @Builder
  SwitchRow(title: string, desc: string, value: boolean, onToggle: (on: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(desc)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor($r('app.color.brand_primary'))
        .onChange((on: boolean) => {
          onToggle(on);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        AppNavBar({ title: '设置' })
        Scroll() {
          Column() {
            this.AboutSection()
            this.AccountSection()
            this.StorageSection()
            this.PlaybackSection()

            Text('数据来源：m.hupu.com / bbs.hupu.com 公开页面')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 20, bottom: 20 })
          }
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.lg })
          .width('100%')
          // 内容不足一屏时撑满视口，强制从顶部开始排版（否则 Scroll 会垂直居中留出大块空白）
          .constraintSize({ minHeight: '100%' })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .backgroundColor($r('app.color.bg_page'))
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
