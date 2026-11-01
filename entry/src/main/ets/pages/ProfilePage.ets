import { FavStore, FavRecord } from '../database/FavStore';
import { common } from '@kit.AbilityKit';
import { LoadState, StateView } from '../views/StateView';
import { Spacing, FontSize, RouteName } from '../common/Theme';
import { SessionManager, HupuUserInfo } from '../network/SessionManager';
import { MyApi, MyProfile } from '../network/MyApi';

@Component
export struct ProfilePage {
  @Consume('pageStack') pageStack: NavPathStack;
  @StorageLink('favVersion') @Watch('onFavChanged') favVersion: number = 0;
  @StorageLink('loginState') @Watch('onLoginChanged') loginState: number = 0;
  /** 个人主页拿到权威卡片后广播：我的页据此从缓存补齐数字（不再发请求） */
  @StorageLink('selfCardVersion') @Watch('onSelfCardReady') selfCardVersion: number = 0;
  /** 每次切到本 Tab 的自检信号：还没拿到权威资料时补拉一次 */
  @StorageLink('profileTick') @Watch('onTabShown') profileTick: number = 0;
  @State favs: FavRecord[] = [];
  @State state: LoadState = LoadState.Loading;
  @State loginUser: HupuUserInfo = new HupuUserInfo();
  @State myProfile: MyProfile = new MyProfile();
  @State profileLoading: boolean = false;
  @StorageLink('topAvoidPx') topAvoidPx: number = 0;
  /** 刷新序号：并发刷新时只让最新一次结果落地 */
  private refreshSeq: number = 0;
  /** 兜底数据补拉是否已排期 */
  private cardRetryScheduled: boolean = false;

  aboutToAppear(): void {
    // 先把上次成功落盘的权威资料同步铺上（无网/请求失败也能看到真实数字），随后再静默刷新
    const cached: MyProfile | null = MyApi.loadSelfCard();
    if (cached !== null) {
      this.myProfile = cached;
    }
    this.load();
    this.initSession();
  }

  onFavChanged(): void {
    this.load();
  }

  /** 切到「我的」Tab：还没拿到权威资料就补拉一次（已有则不发请求） */
  onTabShown(): void {
    if (this.loginState !== 1 || this.profileLoading) {
      return;
    }
    if (this.myProfile.fromCard) {
      return;
    }
    const puid: string = this.loginUser.puid.length > 0 ? this.loginUser.puid : this.loginUser.uid;
    this.cardRetryScheduled = false;
    if (puid.length === 0) {
      this.refreshUser();
      return;
    }
    this.retryCard(this.loginUser.uid);
  }

  /** 其他地方（启动预取 / 个人主页）已拿到权威卡片：直接取缓存，不发新请求 */
  onSelfCardReady(): void {
    if (this.myProfile.fromCard || this.loginState !== 1) {
      return;
    }
    const puid: string = this.loginUser.puid.length > 0 ? this.loginUser.puid : this.loginUser.uid;
    // 内存缓存里已有就直接用（同步，不产生请求）
    const cached: MyProfile | null = MyApi.cachedCard(puid);
    if (cached !== null) {
      this.myProfile = cached;
      this.profileLoading = false;
      return;
    }
    // 落盘数据（启动预取成功后写入）
    const disk: MyProfile | null = MyApi.loadSelfCard();
    if (disk !== null) {
      this.myProfile = disk;
      this.profileLoading = false;
    }
  }

  onLoginChanged(): void {
    this.initSession();
  }

  private getCtx(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private async initSession(): Promise<void> {
    await SessionManager.ensureLoaded(this.getCtx());
    if (this.loginState === 1) {
      this.refreshUser();
    } else {
      this.loginUser = new HupuUserInfo();
      this.myProfile = new MyProfile();
      // 已退出：清掉落盘资料与内存缓存，避免下次登录前显示上一个人的数字
      MyApi.clearSelfCard();
    }
  }

  private async refreshUser(): Promise<void> {
    const seq: number = ++this.refreshSeq;
    const u: HupuUserInfo | null = await SessionManager.verify();
    if (seq !== this.refreshSeq) {
      return;
    }
    if (u !== null) {
      this.loginUser = u;
      // 拉用户主页 userInfoData（主题帖数/回帖数/声望/等级/加入天数，均为全站总数）
      this.profileLoading = true;
      let p: MyProfile | null = null;
      try {
        const puid: string = u.puid.length > 0 ? u.puid : u.uid;
        p = await MyApi.getMyProfile(puid, u.uid);
      } catch (e) {
      }
      // 已有更新的刷新在跑：丢弃本次结果，避免慢响应覆盖新数据
      if (seq !== this.refreshSeq) {
        return;
      }
      // 只接受权威卡片：正则兜底的数据（0/0/0）不得覆盖已有真实数字
      if (p !== null && (p.fromCard || !this.myProfile.fromCard)) {
        this.myProfile = p;
      }
      this.profileLoading = false;
      // 没拿到权威卡片（用户主页 userInfoData）时后台补拉一次：
      // 启动瞬间请求容易失败，进入 Tab 后网络已就绪，能拿到真实数字
      if (p === null || !p.fromCard) {
        this.scheduleCardRetry(u.uid, seq);
      }
    } else {
      await SessionManager.logout(this.getCtx());
      this.loginUser = new HupuUserInfo();
    }
  }

  /** 兜底数据显示后延迟补拉权威卡片（最多补 3 次，间隔递增，拿到即停） */
  private scheduleCardRetry(altId: string, seq: number): void {
    if (this.cardRetryScheduled) {
      return;
    }
    this.cardRetryScheduled = true;
    this.retryCardLater(altId, seq, 0);
  }

  private retryCardLater(altId: string, seq: number, round: number): void {
    if (seq !== this.refreshSeq || this.myProfile.fromCard) {
      return;
    }
    const delays: number[] = [1500, 3000, 6000];
    if (round >= delays.length) {
      return;
    }
    setTimeout(() => {
      if (seq !== this.refreshSeq || this.myProfile.fromCard) {
        return;
      }
      this.retryCard(altId).then(() => {
        if (!this.myProfile.fromCard) {
          this.retryCardLater(altId, seq, round + 1);
        }
      });
    }, delays[round]);
  }

  private async retryCard(altId: string): Promise<void> {
    const seq: number = this.refreshSeq;
    const puid: string = this.loginUser.puid.length > 0 ? this.loginUser.puid : this.loginUser.uid;
    if (puid.length === 0) {
      this.refreshUser();
      return;
    }
    const alt: string = altId.length > 0 ? altId : this.loginUser.uid;
    this.profileLoading = true;
    try {
      const p: MyProfile = await MyApi.getMyProfile(puid, alt);
      if (seq !== this.refreshSeq || !p.fromCard) {
        this.profileLoading = false;
        return;
      }
      this.myProfile = p;
    } catch (e) {
    }
    if (seq === this.refreshSeq) {
      this.profileLoading = false;
    }
  }

  private async load(): Promise<void> {
    try {
      const rows: FavRecord[] = await FavStore.list(this.getCtx());
      this.favs = rows;
      this.state = rows.length > 0 ? LoadState.Ready : LoadState.Empty;
    } catch (e) {
      this.state = LoadState.Error;
    }
  }

  private async removeOne(tid: string): Promise<void> {
    try {
      await FavStore.remove(this.getCtx(), tid);
      AppStorage.setOrCreate<number>('favVersion', Date.now());
    } catch (e) {
    }
  }

  private async clearAll(): Promise<void> {
    try {
      await FavStore.clear(this.getCtx());
      AppStorage.setOrCreate<number>('favVersion', Date.now());
    } catch (e) {
    }
  }

  /** 加入天数（优先 m 站注册时间，回退 uid 无 → 显示等级） */
  private joinedText(): string {
    if (this.myProfile.joinedDays > 0) {
      return `加入虎扑 ${this.myProfile.joinedDays} 天`;
    }
    if (this.myProfile.level.length > 0) {
      return this.myProfile.level;
    }
    return '已登录';
  }

  @Builder
  AccountCard() {
    Column() {
      if (this.loginState === 1 && (this.loginUser.username.length > 0 || this.myProfile.username.length > 0)) {
        Row({ space: 14 }) {
          if (this.myProfile.avatar.length > 0) {
            Image(this.myProfile.avatar)
              .width(56)
              .height(56)
              .borderRadius(28)
              .alt($r('app.media.app_icon'))
          } else if (this.loginUser.header.length > 0) {
            Image(this.loginUser.header)
              .width(56)
              .height(56)
              .borderRadius(28)
              .alt($r('app.media.app_icon'))
          }
          Column({ space: 4 }) {
            Text(this.myProfile.username.length > 0 ? this.myProfile.username : this.loginUser.username)
              .fontSize(FontSize.title)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.joinedText())
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›')
            .fontSize(20)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.pageStack.pushPathByName(RouteName.USER_SPACE, '');
        })
      } else {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('未登录 · 只读模式')
              .fontSize(FontSize.title)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('登录后可点亮、回复、云收藏')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('去登录')
            .fontSize(13)
            .fontColor(Color.White)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor($r('app.color.brand_primary'))
            .borderRadius(16)
            .onClick(() => {
              this.pageStack.pushPathByName(RouteName.SETTINGS, '');
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 4, bottom: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
  }

  /**
   * 是否已有权威数据（用户主页 userInfoData）。
   * 没有时统计栏一律显示「—」，不再用页内条数/正则兜底冒充真实数字。
   */
  private hasCard(): boolean {
    // 已有权威数据就一直显示（刷新中也不回退成 —，避免闪烁）
    return this.myProfile.fromCard;
  }

  /** 计数文案：无权威数据/加载中显示 —，≥1 万用「x.x万」 */
  private countText(v: number): string {
    if (!this.hasCard()) {
      return '—';
    }
    if (v >= 10000) {
      return `${(v / 10000).toFixed(1)}万`;
    }
    return `${v}`;
  }

  /** 等级文案：优先 Lv.x，回退纯数字（去掉「论坛等级」前缀） */
  private levelText(): string {
    if (!this.hasCard()) {
      return '—';
    }
    const d: string = this.myProfile.levelDesc.trim();
    if (d.length > 0) {
      return d;
    }
    const lv: string = this.myProfile.level.replace('论坛等级', '').trim();
    return lv.length > 0 ? lv : '—';
  }

  @Builder
  StatLine() {
    Column() {
      Row() {
        this.StatCell(this.countText(this.myProfile.threadCount), '主题帖')
        this.StatCell(this.countText(this.myProfile.replyCount), '回帖')
        this.StatCell(this.countText(this.myProfile.reputation), '声望')
        this.StatCell(this.levelText(), '等级')
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      // 未取到权威数据时给出可点击的提示（点一下立即重试，不必等自动补拉）
      if (!this.hasCard() && this.loginState === 1) {
        Text(this.profileLoading ? '正在获取统计数据…' : '统计数据获取失败，点击重试')
          .fontSize(11)
          .fontColor(this.profileLoading ? $r('app.color.text_tertiary') : $r('app.color.brand_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 8 })
          .onClick(() => {
            if (!this.profileLoading) {
              this.cardRetryScheduled = false;
              this.retryCard(this.loginUser.uid);
            }
          })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
  }

  @Builder
  StatCell(num: string, label: string) {
    Column({ space: 4 }) {
      Text(num)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
  }

  @Builder
  RowList() {
    Column() {
      this.ListRow('我的收藏', this.favs.length > 0 ? `${this.favs.length} 条` : '', '', () => {
      })
    }
    .width('100%')
    .borderRadius(14)
    .clip(true)
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  ListRow(title: string, sub: string, icon: string, onTap: () => void) {
    Row({ space: 10 }) {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (sub.length > 0) {
        Text(sub)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  FavRow(item: FavRecord) {
    Row() {
      Column({ space: 4 }) {
        Text(item.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          if (item.forum.length > 0) {
            Text(item.forum)
              .fontSize(11)
              .fontColor($r('app.color.brand_primary'))
              .maxLines(1)
          }
          Text(item.author)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('删除')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.tag_bg'))
            .borderRadius(10)
            .onClick(() => {
              this.removeOne(item.tid);
            })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .onClick(() => {
      this.pageStack.pushPathByName(RouteName.POST_DETAIL, item.tid);
    })
  }

  build() {
    Column() {
      Column() {
      Row() {
        Text('我的')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('设置')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor($r('app.color.tag_bg'))
          .borderRadius(14)
          .onClick(() => {
            this.pageStack.pushPathByName(RouteName.SETTINGS, '');
          })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 2, bottom: 8 })
      }
      .width('100%')
      .padding({ top: px2vp(this.topAvoidPx) })
      .backgroundColor($r('app.color.bg_page'))

      Scroll() {
        Column({ space: 8 }) {
          this.AccountCard()
          if (this.loginState === 1) {
            this.StatLine()
          }
          this.RowList()

          if (this.favs.length > 0) {
            Row() {
              Text(`我的收藏（${this.favs.length}）`)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Blank()
              Text('清空')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor($r('app.color.tag_bg'))
                .borderRadius(12)
                .onClick(() => {
                  this.clearAll();
                })
            }
            .width('100%')
            .padding({ left: Spacing.lg, right: Spacing.lg, top: 4 })

            Column() {
              ForEach(this.favs, (item: FavRecord) => {
                Column() {
                  this.FavRow(item)
                  Divider().color($r('app.color.divider'))
                }
              }, (item: FavRecord) => item.tid)
            }
            .borderRadius(14)
            .clip(true)
          }

          Text('Hupu Luna · 非官方客户端 · 数据来自虎扑公开页面')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 20 })
        }
        .padding({ left: Spacing.lg, right: Spacing.lg, top: 20, bottom: 10 })
        .width('100%')
        // 内容不足一屏时撑满 Scroll 视口，强制从顶部开始布局（align 顶层对齐真机不可靠）
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
