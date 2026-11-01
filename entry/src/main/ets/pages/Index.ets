import { HomePage } from './HomePage';
import { CommunityPage } from './CommunityPage';
import { ProfilePage } from './ProfilePage';
import { PostDetailPage } from './PostDetailPage';
import { TopicThreadsPage } from './TopicThreadsPage';
import { TopicTagPage } from './TopicTagPage';
import { AllChannelsPage } from './AllChannelsPage';
import { SearchPage } from './SearchPage';
import { ImageViewerPage } from './ImageViewerPage';
import { SettingsPage } from './SettingsPage';
import { MatchScorePage } from './MatchScorePage';
import { MatchListPage } from './MatchListPage';
import { MatchReportPage } from './MatchReportPage';
import { PlayerScoreDetailPage } from './PlayerScoreDetailPage';
import { PlayerProfilePage } from './PlayerProfilePage';
import { CookieLoginPage } from './CookieLoginPage';
import { UserSpacePage } from './UserSpacePage';
import { CreateThreadPage } from './CreateThreadPage';
import { LiveWebPage } from './LiveWebPage';
import { RouteName } from '../common/Theme';
import { hapticTap } from '../common/Haptics';
import { SessionManager, HupuUserInfo } from '../network/SessionManager';
import { MyApi, MyProfile } from '../network/MyApi';
import { common } from '@kit.AbilityKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  @Provide('pageStack') pageStack: NavPathStack = new NavPathStack();
  @State currentIndex: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    // 启动后等首页主请求平息，再统一预取本人资料并落盘：
    // "我的"页首帧就能显示真实数字，不必依赖它自己那次冷启动请求是否成功
    setTimeout(() => {
      this.prefetchSelfCard(0);
    }, 1200);
  }

  /** 预取本人资料（失败递增退避重试 3 次），成功后广播给各页面 */
  private async prefetchSelfCard(round: number): Promise<void> {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      await SessionManager.ensureLoaded(ctx);
      if (AppStorage.get<number>('loginState') !== 1) {
        return;
      }
      const u: HupuUserInfo | null = await SessionManager.verify();
      if (u === null) {
        return;
      }
      const puid: string = u.puid.length > 0 ? u.puid : u.uid;
      const p: MyProfile | null = await MyApi.getUserCard(puid);
      if (p !== null && p.fromCard) {
        AppStorage.setOrCreate<number>('selfCardVersion', Date.now());
        return;
      }
      if (round < 2) {
        setTimeout(() => {
          this.prefetchSelfCard(round + 1);
        }, 2000 * (round + 1));
      }
    } catch (e) {
    }
  }

  /** 发帖页参数（可能未传，返回空串避免 undefined） */
  private createThreadParam(): string {
    const arr: string[] = this.pageStack.getParamByName(RouteName.CREATE_THREAD) as string[];
    return arr.length > 0 ? arr[0] : '';
  }

  private tabSymbol(normal: Resource, selected: Resource): TabBarSymbol {
    return {
      normal: new SymbolGlyphModifier(normal).fontColor(['#9499A0']).fontSize(24),
      selected: new SymbolGlyphModifier(selected).fontColor([$r('app.color.brand_primary')]).fontSize(24)
    };
  }

  @Builder
  PageMap(name: string) {
    if (name === RouteName.POST_DETAIL) {
      PostDetailPage({ tid: this.pageStack.getParamByName(RouteName.POST_DETAIL)[0] as string })
    } else if (name === RouteName.TOPIC_THREADS) {
      TopicThreadsPage({ param: this.pageStack.getParamByName(RouteName.TOPIC_THREADS)[0] as string })
    } else if (name === RouteName.TAG_THREADS) {
      TopicTagPage({ param: this.pageStack.getParamByName(RouteName.TAG_THREADS)[0] as string })
    } else if (name === RouteName.SEARCH) {
      SearchPage()
    } else if (name === RouteName.ALL_CHANNELS) {
      AllChannelsPage()
    } else if (name === RouteName.IMAGE_VIEWER) {
      ImageViewerPage({ param: this.pageStack.getParamByName(RouteName.IMAGE_VIEWER)[0] as string })
    } else if (name === RouteName.SETTINGS) {
      SettingsPage()
    } else if (name === RouteName.MATCH_SCORE) {
      MatchScorePage({ param: this.pageStack.getParamByName(RouteName.MATCH_SCORE)[0] as string })
    } else if (name === RouteName.MATCH_LIST) {
      MatchListPage({ param: this.pageStack.getParamByName(RouteName.MATCH_LIST)[0] as string })
    } else if (name === RouteName.MATCH_REPORT) {
      MatchReportPage({ param: this.pageStack.getParamByName(RouteName.MATCH_REPORT)[0] as string })
    } else if (name === RouteName.PLAYER_SCORE) {
      PlayerScoreDetailPage({ param: this.pageStack.getParamByName(RouteName.PLAYER_SCORE)[0] as string })
    } else if (name === RouteName.PLAYER_PROFILE) {
      PlayerProfilePage({ param: this.pageStack.getParamByName(RouteName.PLAYER_PROFILE)[0] as string })
    } else if (name === RouteName.LOGIN_WEB) {
      CookieLoginPage()
    } else if (name === RouteName.USER_SPACE) {
      UserSpacePage({ param: this.pageStack.getParamByName(RouteName.USER_SPACE)[0] as string })
    } else if (name === RouteName.CREATE_THREAD) {
      CreateThreadPage({ param: this.createThreadParam() })
    } else if (name === RouteName.LIVE_WEB) {
      LiveWebPage({ param: this.pageStack.getParamByName(RouteName.LIVE_WEB)[0] as string })
    } else {
      Column({ space: 8 }) {
        Text(name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        Text('页面开发中')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.bg_page'))
    }
  }

  build() {
    Navigation(this.pageStack) {
      HdsTabs({
        barPosition: BarPosition.End,
        index: this.currentIndex,
        controller: this.tabsController
      }) {
        TabContent() {
          HomePage()
        }
        .tabBar(new BottomTabBarStyle(
          this.tabSymbol($r('sys.symbol.house'), $r('sys.symbol.house_fill')), '首页'))

        TabContent() {
          CommunityPage()
        }
        .tabBar(new BottomTabBarStyle(
          this.tabSymbol($r('sys.symbol.person_2'), $r('sys.symbol.person_2_fill')), '社区'))

        TabContent() {
          ProfilePage()
        }
        .tabBar(new BottomTabBarStyle(
          this.tabSymbol($r('sys.symbol.person'), $r('sys.symbol.person_fill')), '我的'))
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .scrollable(false)
      // 悬浮页签：TabBar 层叠于内容之上，内容可延伸至栏下方
      .barOverlap(true)
      // 悬浮样式 + 沉浸光感材质（胶囊造型：左右留边、悬浮于导航条上方）
      .barFloatingStyle({
        barSideMargin: 14,
        barBottomMargin: 28,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      })
      .onChange((index: number) => {
        // 底部 Tab 切换时给一次轻震动反馈
        if (index !== this.currentIndex) {
          hapticTap();
        }
        this.currentIndex = index;
        // 切到「我的」时通知该页自检资料（已有权威数据则不发请求）
        if (index === 2) {
          AppStorage.setOrCreate<number>('profileTick', Date.now());
        }
      })
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
  }
}
