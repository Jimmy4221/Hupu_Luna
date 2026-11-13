import { HupuApi } from '../network/HupuApi';
import { NbaApi } from '../network/NbaApi';
import { SoccerApi } from '../network/SoccerApi';
import { LolEsportsApi, LolFixture, LolMatchHighlights } from '../network/LolEsportsApi';
import { ThreadListItem, ThreadListPage, ReplyItem, ReplyListPage, NbaNewsItem, MatchItem, MatchDay, HotRankItem, SoccerMatchItem } from '../model/Models';
import { LoadState, StateView } from '../views/StateView';
import { FeedSkeleton } from '../views/Skeleton';
import { Spacing, FontSize, Radius, RouteName } from '../common/Theme';
import { thumbUrl, parseFeedTime } from '../common/Utils';
import { compactCount, formatHeat } from '../views/TagChip';
import { ChannelDef, ChannelKind, ChannelCatalog } from '../common/Channels';
import { OfficialAccounts } from '../common/OfficialAccounts';
import { ChannelStore } from '../database/ChannelStore';
import { CacheStore, CachedPayload } from '../database/CacheStore';
import { HistoryStore } from '../database/HistoryStore';
import { VideoPlaybackResult } from './VideoFullscreenPage';
import { ImageKnifeComponent } from '@ohos/imageknife';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 频道缓存键前缀。
 * 版本号用于隔断历史缓存：本次修复了"中国足球/国际足球资讯"频道数据源错配，
 * 旧缓存中残留的错误内容（NBA 资讯）若继续命中会先于网络结果显示。
 */
const HOME_CACHE_PREFIX: string = 'home2/';

/** 通用信息流行 */
class FeedRow {
  tid: string = '';
  title: string = '';
  author: string = '';
  userHeader: string = '';
  tag: string = '';
  time: string = '';
  meta: string = '';
  cover: string = '';
  pics: string[] = [];
  isVideo: boolean = false;
  videoDur: string = '';
  /** true = rich media card style (recommend and LoL feeds) */
  officialCard: boolean = false;
  /** 视频直连播放地址（推荐流自动播放用） */
  videoUrl: string = '';
  /** 封面真实宽高（单图/视频区按比例定高） */
  coverW: number = 0;
  coverH: number = 0;
  /** 官方大卡数据栏：回复 / 亮 / 分享 / 浏览（视频为播放量） */
  replies: number = 0;
  lights: number = 0;
  shareNum: number = 0;
  viewNum: number = 0;
  /** 神回复（亮评） */
  lightReplyContent: string = '';
  lightReplyUser: string = '';
  lightReplyCount: number = 0;
  /** 发帖时间（ms，0=未知） */
  createTime: number = 0;
  /** 最后回复时间（ms，0=未知） */
  lastReplyTime: number = 0;
  /** 置顶帖（服务端标记） */
  pinned: boolean = false;
  /** 官方号发文（排序加权 + 卡片标记） */
  official: boolean = false;
  /** 作者 puid（官方判定） */
  authorPuid: string = '';
  /** 已读（存在于浏览历史） */
  read: boolean = false;
}

/** 媒体区尺寸（vp） */
class MediaBox {
  w: number = 0;
  h: number = 0;
}

/** 信息流排序中间结果 */
class RankedRow {
  row: FeedRow = new FeedRow();
  index: number = 0;
  score: number = 0;
}

/** 时间未知的帖子在时间排序里统一沉底 */
const UNKNOWN_TIME_MS: number = 9e15;

/** 信息流「亮评」回填缓存（避免同一条帖子反复翻评论页） */
class FeedLightReply {
  content: string = '';
  user: string = '';
  count: number = 0;
}

/**
 * 信息流详情回填缓存：
 * 配图/封面可长期复用；视频直链带 auth_key，只在其时效内（2 小时）使用。
 */
class FeedEnrich {
  /** 结构版本：旧缓存可能只有封面/空配图，版本不符直接作废重取 */
  v: number = 2;
  pics: string[] = [];
  cover: string = '';
  videoUrl: string = '';
  videoCover: string = '';
  videoWidth: number = 0;
  videoHeight: number = 0;
}

/** 频道顶部比赛条 */
class StripItem {
  matchId: string = '';
  title: string = '';
  homeName: string = '';
  awayName: string = '';
  homeLogo: string = '';
  awayLogo: string = '';
  homeScore: string = '';
  awayScore: string = '';
  homeTeamId: string = '';
  awayTeamId: string = '';
  stage: string = '';
  leagueName: string = '';
  league: string = '';
  done: boolean = false;
  timeText: string = '';
  pv: string = '';
}

/** 官方过滤频道的数据包 */
class OfficialFeed {
  rows: FeedRow[] = [];
}

/** Batched search results for image-backed topic feeds. */
class TopicSearchBatch {
  items: ThreadListItem[] = [];
  page: number = 0;
  hasMore: boolean = false;
}

/** 频道缓存快照（缓存优先渲染：先渲缓存再静默刷新） */
class HomeCacheData {
  rows: FeedRow[] = [];
  ranks: HotRankItem[] = [];
  days: MatchDay[] = [];
  strip: StripItem[] = [];
  cursor: string = '';
  hasMore: boolean = false;
  page: number = 0;
}

@Component
export struct HomePage {
  @Consume('pageStack') pageStack: NavPathStack;
  @StorageLink('channelIdsJson') @Watch('onChannelsChanged') channelIdsJson: string = '';
  @StorageLink('activeChannelId') @Watch('onActiveChanged') activeChannelId: string = '';
  @StorageLink('homeReselectTick') @Watch('onHomeReselected') homeReselectTick: number = 0;
  /** 浏览历史变更（在别的页面读过帖子后回来，信息流同步已读态） */
  @StorageLink('historyVersion') @Watch('onHistoryVersionChanged') historyVersion: number = 0;
  /** 信息流排序：recommend / time_desc / time_asc / reply_desc / reply_asc */
  @StorageLink('feedSortMode') @Watch('onFeedSortChanged') feedSortMode: string = 'recommend';
  @State channels: ChannelDef[] = [];
  @State rows: FeedRow[] = [];
  @State ranks: HotRankItem[] = [];
  @State days: MatchDay[] = [];
  @State strip: StripItem[] = [];
  @State activeLeague: string = '';
  /** 英雄联盟频道顶部：最近一场赛果 / 下一场（数据来自赛程表） */
  @State lolLast: LolFixture | null = null;
  @State lolNext: LolFixture | null = null;
  @State state: LoadState = LoadState.Loading;
  @State refreshing: boolean = false;
  @State staleTip: boolean = false;
  @State topBarsVisible: boolean = true;
  @StorageLink('topAvoidPx') topAvoidPx: number = 0;
  @State hasMore: boolean = false;
  @State activeKind: string = '';
  @State contentAlpha: number = 1;
  @State enterOffsetX: number = 0;
  /** 当前自动播放的视频帖 tid（推荐流；空=无） */
  @State playingTid: string = '';
  /** Controller shared by the single active feed video, including fullscreen playback. */
  private feedVideoController: VideoController = new VideoController();
  /** 达到自动播放可见阈值的视频帖（滚动停止后择一播放） */
  private visibleVideos: string[] = [];
  /** 列表滚动中（滚动期间不切换播放，防抖省流） */
  private listScrolling: boolean = false;
  /** 内容区宽度缓存（vp，惰性计算） */
  private cachedContentW: number = 0;
  /** 官方频道已展示的 tid（翻页捞历史时去重，跨请求保持） */
  private officialSeen: Set<string> = new Set<string>();
  /** 官方频道是否已回退到普通帖子流（回退后不再按官方过滤） */
  private officialFallback: boolean = false;
  /** LoL featured-reply requests are queued to avoid parallel large PC-page downloads. */
  private lightReplyRequests: string[] = [];
  private lightReplyQueue: string[] = [];
  private lightReplyWorkerActive: boolean = false;
  private lightReplyCurrentTid: string = '';
  /** Search2 can omit full photo arrays and signed video URLs; enrich visible cards lazily. */
  private threadDetailRequests: string[] = [];
  private threadDetailQueue: string[] = [];
  private threadDetailWorkerActive: boolean = false;
  private threadDetailCurrentTid: string = '';
  private playAfterVideoLoadTid: string = '';
  /** 官方频道连续无收获页数（用于判定官方内容到底） */
  private officialDryPages: number = 0;
  /** 当前视频是否静音（默认静音，切换视频时复位） */
  @State videoMuted: boolean = true;
  /** 信息流当前视频播放进度（进全屏时带上，返回时续播） */
  private feedVideoSec: number = 0;
  /** 设置项：信息流（推荐频道）视频是否自动播放 */
  @StorageLink('autoplayFeed') @Watch('onAutoplayChanged') autoplayFeed: boolean = true;
  /** 静音按钮按下标记：防止点击穿透触发卡片的"打开帖子" */
  private mutePressed: boolean = false;
  /** 手动点播按钮按下标记：自动播放关闭时点播，不触发"打开帖子" */
  private videoTapPressed: boolean = false;
  private pageIndex: number = 0;
  private cursor: string = '';
  private loadingMore: boolean = false;
  private loadSeq: number = 0;
  private channelScroller: Scroller = new Scroller();
  private feedScroller: Scroller = new Scroller();
  private topBarScrollDelta: number = 0;
  private lastTopBarScrollDirection: number = 0;
  private lastLoadedChannelId: string = '';
  private lastSwitchDir: number = 1;
  private tapThresholdPx: number = 0;
  private swipeThresholdPx: number = 0;
  private itemStartX: number = 0;
  private itemStartY: number = 0;
  private itemMoved: boolean = true;
  private swipeStartX: number = 0;
  private swipeStartY: number = 0;
  private swipeLastX: number = 0;
  private swipeLastY: number = 0;
  /** 内容区滑动手势状态：0=无 1=待判定 2=横向切频道 3=纵向（交列表） */
  private panState: number = 0;
  /** 滑动方向判定阈值（10vp 转 px） */
  private resolvePx: number = 0;
  /** 列表是否处于滚动中（滚动中的抬起不算点击，防误触跳帖） */
  private scrollArmed: boolean = false;
  /** 按下时间戳（点击时长上限判定） */
  private pressStartTs: number = 0;

  aboutToAppear(): void {
    this.initOnce();
  }

  private getCtx(): common.Context {
    // 优先用 EntryAbility 存入的全局上下文（最可靠），失败再取 getHostContext
    try {
      const stored: Object | undefined = AppStorage.get<Object>('appContext');
      if (stored) {
        return stored as common.Context;
      }
    } catch (e) {
    }
    return this.getUIContext().getHostContext() as common.Context;
  }

  private async initOnce(): Promise<void> {
    // 频道列表：EntryAbility 已在首帧前写回 AppStorage；此处兜底处理冷启动读盘失败的情况
    let json: string = this.channelIdsJson;
    if (json.length === 0) {
      let ids: string[] = [];
      try {
        ids = await ChannelStore.load(this.getCtx());
      } catch (e) {
      }
      ids = ChannelCatalog.sanitize(ids);
      if (ids.length === 0) {
        ids = ChannelCatalog.defaults();
      }
      json = JSON.stringify(ids);
      AppStorage.setOrCreate<string>('channelIdsJson', json);
    }
    // 上次停留栏目：EntryAbility 已同步恢复；若仍为空则回落到频道列表首项
    if (this.activeChannelId.length === 0) {
      const ids2: string[] = JSON.parse(json) as string[];
      const target: string = ids2.length > 0 ? ids2[0] : 'recommend';
      // 触发 onActiveChanged -> loadActive
      AppStorage.setOrCreate<string>('activeChannelId', target);
    }
    this.rebuildChannels();
    // 频道栏滚到选中项（恢复的栏目可能不在屏内；延迟等列表完成首次布局）
    const activeIdx: number = this.indexOfChannel(this.activeChannelId);
    if (activeIdx > 0) {
      setTimeout(() => {
        try {
          this.channelScroller.scrollToIndex(activeIdx, false, ScrollAlign.CENTER);
        } catch (e) {
        }
      }, 50);
    }
    if (this.activeChannelId.length > 0) {
      this.loadActive(false);
    }
  }

  /** 栏目切换时持久化，供下次启动恢复（同步写入，防退出前异步未落盘） */
  private saveLastChannel(id: string): void {
    if (id.length === 0) {
      return;
    }
    ChannelStore.saveLast(this.getCtx(), id);
    hilog.info(0x0000, 'HupuLuna', 'saveLastChannel ok: %{public}s', id);
  }

  onChannelsChanged(): void {
    this.rebuildChannels();
  }

  onActiveChanged(): void {
    const isSwitch: boolean =
      this.lastLoadedChannelId.length > 0 && this.lastLoadedChannelId !== this.activeChannelId;
    this.saveLastChannel(this.activeChannelId);
    this.topBarsVisible = true;
    this.topBarScrollDelta = 0;
    this.lastTopBarScrollDirection = 0;
    this.loadActive(isSwitch);
  }

  /** Tapping 首页 again returns the active feed to its top and reloads it. */
  onHomeReselected(): void {
    if (this.homeReselectTick <= 0) return;
    this.topBarsVisible = true;
    this.topBarScrollDelta = 0;
    this.lastTopBarScrollDirection = 0;
    setTimeout(() => {
      try {
        this.feedScroller.scrollToIndex(0, false, ScrollAlign.START);
      } catch (e) {
      }
      if (!this.refreshing) {
        this.refreshing = true;
        this.loadActive(false);
      }
    }, 80);
  }

  /** Positive List offsets mean the feed is moving up as the user scrolls down. */
  private onFeedDidScroll(offset: number): void {
    if (Math.abs(offset) < 1) return;
    const direction: number = offset > 0 ? 1 : -1;
    if (direction !== this.lastTopBarScrollDirection) {
      this.lastTopBarScrollDirection = direction;
      this.topBarScrollDelta = 0;
    }
    this.topBarScrollDelta += offset;
    if (this.topBarsVisible && this.topBarScrollDelta >= 22) {
      this.topBarScrollDelta = 0;
      this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.topBarsVisible = false;
      });
    } else if (!this.topBarsVisible && this.topBarScrollDelta <= -12) {
      this.topBarScrollDelta = 0;
      this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.topBarsVisible = true;
      });
    }
  }

  private rebuildChannels(): void {
    const list: ChannelDef[] = [];
    const json: string = this.channelIdsJson;
    if (json.length > 0) {
      try {
        const ids: string[] = ChannelCatalog.sanitize(JSON.parse(json) as string[]);
        for (const id of ids) {
          list.push(ChannelCatalog.find(id));
        }
      } catch (e) {
      }
    }
    if (list.length === 0) {
      for (const id of ChannelCatalog.defaults()) {
        list.push(ChannelCatalog.find(id));
      }
    }
    this.channels = list;
    let found: boolean = false;
    for (const c of list) {
      if (c.id === this.activeChannelId) {
        found = true;
      }
    }
    if (!found && list.length > 0) {
      AppStorage.setOrCreate<string>('activeChannelId', list[0].id);
    }
  }

  private mapThreads(items: ThreadListItem[], officialCard: boolean): FeedRow[] {
    const result: FeedRow[] = [];
    for (const t of items) {
      result.push(this.mapOne(t, officialCard));
    }
    return result;
  }

  /**
   * Search results are global, then filtered to a channel fid. Walk a few search
   * pages at a time so the LoL feed gets a full screen of matching posts even
   * when unrelated search results occupy the first pages.
   */
  private async searchTopicBatch(ch: ChannelDef, startPage: number, targetCount: number): Promise<TopicSearchBatch> {
    const batch: TopicSearchBatch = new TopicSearchBatch();
    const seen: Set<string> = new Set<string>();
    let page: number = startPage;
    for (let attempt: number = 0; attempt < 5 && batch.items.length < targetCount; attempt++) {
      const found: ThreadListItem[] = await HupuApi.searchThreads(ch.historyKeyword, page);
      batch.page = page;
      batch.hasMore = found.length >= 20;
      for (const item of found) {
        if (item.fid === ch.topicId && !seen.has(item.tid)) {
          batch.items.push(item);
          seen.add(item.tid);
        }
      }
      if (!batch.hasMore) break;
      page++;
    }
    return batch;
  }

  private requestLightReplyPreview(tid: string): void {
    if (tid.length === 0 || tid === this.lightReplyCurrentTid || this.lightReplyRequests.indexOf(tid) >= 0) return;
    this.lightReplyRequests.push(tid);
    this.lightReplyQueue.push(tid);
    this.processLightReplyQueue();
  }

  /** 亮评落到对应信息流行 */
  private applyLightReply(tid: string, content: string, user: string, count: number): void {
    const index: number = this.rows.findIndex((row: FeedRow) => row.tid === tid);
    if (index < 0) {
      return;
    }
    const nextRows: FeedRow[] = this.rows.slice();
    nextRows[index].lightReplyContent = content;
    nextRows[index].lightReplyUser = user;
    nextRows[index].lightReplyCount = count;
    this.rows = nextRows;
  }

  /** Backfill highlighted replies when the selected feed source omits its preview. */
  private async processLightReplyQueue(): Promise<void> {
    if (this.lightReplyWorkerActive) return;
    this.lightReplyWorkerActive = true;
    while (this.lightReplyQueue.length > 0) {
      const tid: string = this.lightReplyQueue.shift() ?? '';
      if (tid.length === 0) continue;
      this.lightReplyCurrentTid = tid;
      // 先看本地缓存：同一帖子在缓存有效期内不再逐页翻评论
      let servedFromCache: boolean = false;
      try {
        const cached: CachedPayload | null = await CacheStore.get(this.getCtx(), `feed/light/${tid}`);
        if (cached !== null) {
          const payload: FeedLightReply = JSON.parse(cached.json) as FeedLightReply;
          if (payload.content.length > 0) {
            this.applyLightReply(tid, payload.content, payload.user, payload.count);
            servedFromCache = true;
          }
        }
      } catch (e) {
      }
      if (servedFromCache) {
        this.lightReplyCurrentTid = '';
        continue;
      }
      let best: ReplyItem | null = null;
      // 亮评预览只需要首屏：m 站帖子页首屏本身就是按亮数排序的，
      // 再翻 PC 第 2/3 页（200~460KB）拿不到更高的亮评，反而拖慢整个队列。
      try {
        const result: ReplyListPage = await HupuApi.getReplies(tid, 1);
        for (const item of result.items) {
          if (item.content.length > 0 && (best === null || item.light > best.light)) best = item;
        }
      } catch (e) {
        best = null;
      }
      if (best !== null) {
        this.applyLightReply(tid, best.content, best.userName, best.light);
        const payload: FeedLightReply = new FeedLightReply();
        payload.content = best.content;
        payload.user = best.userName;
        payload.count = best.light;
        CacheStore.put(this.getCtx(), `feed/light/${tid}`, JSON.stringify(payload));
      } else {
        // Let a recycled card retry after a transient failure.
        const requestedIndex: number = this.lightReplyRequests.indexOf(tid);
        if (requestedIndex >= 0) this.lightReplyRequests.splice(requestedIndex, 1);
      }
      this.lightReplyCurrentTid = '';
    }
    this.lightReplyWorkerActive = false;
  }

  private requestThreadDetail(tid: string, playWhenReady: boolean = false): void {
    if (playWhenReady) this.playAfterVideoLoadTid = tid;
    if (tid.length === 0 || tid === this.threadDetailCurrentTid) return;
    const requestedIndex: number = this.threadDetailRequests.indexOf(tid);
    if (requestedIndex >= 0) {
      if (playWhenReady) {
        const row: FeedRow | undefined = this.rows.find((item: FeedRow) => item.tid === tid);
        if (row !== undefined && row.videoUrl.length > 0) {
          this.startPlay(tid);
          this.playAfterVideoLoadTid = '';
        } else if (this.threadDetailCurrentTid !== tid && this.threadDetailQueue.indexOf(tid) < 0) {
          this.threadDetailQueue.push(tid);
          this.processThreadDetailQueue();
        }
      }
      return;
    }
    this.threadDetailRequests.push(tid);
    this.threadDetailQueue.push(tid);
    this.processThreadDetailQueue();
  }

  private async processThreadDetailQueue(): Promise<void> {
    if (this.threadDetailWorkerActive) return;
    this.threadDetailWorkerActive = true;
    while (this.threadDetailQueue.length > 0) {
      const tid: string = this.threadDetailQueue.shift() ?? '';
      if (tid.length === 0) continue;
      this.threadDetailCurrentTid = tid;
      let playable: boolean = false;
      // 先看本地缓存：图文帖配图/封面可长期复用；视频直链带 auth_key，超过 2 小时按失效处理
      let needNetwork: boolean = true;
      try {
        const cached: CachedPayload | null = await CacheStore.get(this.getCtx(), `feed/enrich/${tid}`);
        if (cached !== null) {
          const enrich: FeedEnrich = JSON.parse(cached.json) as FeedEnrich;
          if (enrich.v !== 2) {
            // 旧版本缓存可能只存了封面/空配图：直接作废，重新取一次正文配图
            needNetwork = true;
          } else {
            const rowBefore: FeedRow | undefined = this.rows.find((item: FeedRow) => item.tid === tid);
            const wantsVideo: boolean = rowBefore !== undefined
              && (rowBefore.isVideo || this.playAfterVideoLoadTid === tid);
            const freshVideo: boolean = cached.ageMs < 2 * 3600 * 1000;
            const videoUrl: string = freshVideo ? enrich.videoUrl : '';
            this.applyEnrich(tid, enrich, videoUrl);
            playable = videoUrl.length > 0;
            // 1) 视频帖拿不到可用直链；2) 直链过期；3) 图文帖缓存里没有配图（旧的失败结果）
            needNetwork = (wantsVideo && videoUrl.length === 0)
              || (enrich.videoUrl.length > 0 && !freshVideo)
              || (enrich.pics.length === 0 && rowBefore !== undefined
                && rowBefore.cover.length > 0 && !rowBefore.isVideo);
          }
        }
      } catch (e) {
      }
      if (!needNetwork) {
        if (playable && this.playAfterVideoLoadTid === tid) {
          this.startPlay(tid);
        }
        if (this.playAfterVideoLoadTid === tid) {
          this.playAfterVideoLoadTid = '';
        }
        this.threadDetailCurrentTid = '';
        continue;
      }
      try {
        const rowForEnrich: FeedRow | undefined = this.rows.find((item: FeedRow) => item.tid === tid);
        const wantsVideo: boolean = rowForEnrich !== undefined && rowForEnrich.isVideo;
        const detail = wantsVideo
          ? await HupuApi.getThreadDetail(tid)
          : await HupuApi.getThreadDetailForFeed(tid);
        const index: number = this.rows.findIndex((row: FeedRow) => row.tid === tid);
        if (index >= 0) {
          const nextRows: FeedRow[] = this.rows.slice();
          let changed: boolean = false;
          if (detail.contentImages.length > 0 && nextRows[index].pics.length < 3) {
            const images: string[] = [];
            for (const imageUrl of detail.contentImages) {
              if (imageUrl.length > 0 && images.indexOf(imageUrl) < 0 && images.length < 3) {
                images.push(imageUrl);
              }
            }
            if (images.length > nextRows[index].pics.length) {
              nextRows[index].pics = images;
              if (nextRows[index].cover.length === 0) nextRows[index].cover = images[0];
              changed = true;
            }
          }
          if (detail.videoUrl.length > 0) {
            nextRows[index].isVideo = true;
            nextRows[index].videoUrl = detail.videoUrl;
            if (nextRows[index].cover.length === 0) nextRows[index].cover = detail.videoCover;
            if (detail.videoWidth > 0) nextRows[index].coverW = detail.videoWidth;
            if (detail.videoHeight > 0) nextRows[index].coverH = detail.videoHeight;
            changed = true;
            playable = true;
          }
          if (changed) this.rows = nextRows;
          // 写回缓存：下次进入同一频道不再为这批卡片请求 PC 详情页
          const enrich: FeedEnrich = new FeedEnrich();
          enrich.pics = nextRows[index].pics.slice(0, 3);
          enrich.cover = nextRows[index].cover;
          enrich.videoUrl = detail.videoUrl;
          enrich.videoCover = detail.videoCover;
          enrich.videoWidth = detail.videoWidth;
          enrich.videoHeight = detail.videoHeight;
          CacheStore.put(this.getCtx(), `feed/enrich/${tid}`, JSON.stringify(enrich));
          if (playable && this.playAfterVideoLoadTid === tid) {
            this.startPlay(tid);
            this.playAfterVideoLoadTid = '';
          }
        }
      } catch (e) {
      }
      if (!playable && this.playAfterVideoLoadTid === tid) this.playAfterVideoLoadTid = '';
      this.threadDetailCurrentTid = '';
    }
    this.threadDetailWorkerActive = false;
  }

  /** 把缓存的详情补充信息（配图/封面/视频直链）合并进信息流行 */
  private applyEnrich(tid: string, enrich: FeedEnrich, videoUrl: string): void {
    const index: number = this.rows.findIndex((row: FeedRow) => row.tid === tid);
    if (index < 0) {
      return;
    }
    const nextRows: FeedRow[] = this.rows.slice();
    let changed: boolean = false;
    if (enrich.pics.length > nextRows[index].pics.length) {
      nextRows[index].pics = enrich.pics.slice(0, 3);
      changed = true;
    }
    if (nextRows[index].cover.length === 0 && enrich.cover.length > 0) {
      nextRows[index].cover = enrich.cover;
      changed = true;
    }
    if (videoUrl.length > 0) {
      nextRows[index].isVideo = true;
      nextRows[index].videoUrl = videoUrl;
      if (nextRows[index].cover.length === 0) nextRows[index].cover = enrich.videoCover;
      if (enrich.videoWidth > 0) nextRows[index].coverW = enrich.videoWidth;
      if (enrich.videoHeight > 0) nextRows[index].coverH = enrich.videoHeight;
      changed = true;
    }
    if (changed) this.rows = nextRows;
  }

  /** 单条映射（loadMore 追加时复用） */
  private mapOne(t: ThreadListItem, officialCard: boolean = false): FeedRow {
    const row: FeedRow = new FeedRow();
    {
      row.tid = t.tid;
      row.title = t.title;
      row.author = t.userName;
      row.tag = t.topicName;
      row.time = t.time;
      // 浏览量有值时补充展示（PC 话题流提供；m 站接口无此字段）
      row.meta = t.visits > 0
        ? `${compactCount(t.visits)} 浏览 · ${compactCount(t.replies)} 回复`
        : `${compactCount(t.replies)} 回复 · ${compactCount(t.recommendCount)} 亮`;
      row.cover = t.coverUrl;
      row.userHeader = t.userHeader;
      for (const u of t.picUrls) {
        row.pics.push(u);
      }
      row.isVideo = t.isVideo;
      row.videoDur = t.videoDuration;
      row.videoUrl = t.videoUrl;
      row.coverW = t.coverWidth;
      row.coverH = t.coverHeight;
      row.replies = t.replies;
      row.lights = t.recommendCount;
      row.shareNum = t.shareNum;
      // 浏览数优先用 visits（官方号发文列表提供），视频帖回退到播放量
      row.viewNum = t.visits > 0 ? t.visits : t.playNum;
      row.lightReplyContent = t.lightReplyContent;
      row.lightReplyUser = t.lightReplyUser;
      row.lightReplyCount = t.lightReplyCount;
      // 排序/已读：发帖时间、最后回复、置顶标记、是否读过
      row.createTime = t.createTime;
      row.lastReplyTime = t.lastReplyTime;
      row.pinned = t.pinned;
      row.authorPuid = t.authorPuid;
      row.official = t.official || OfficialAccounts.isOfficialPuid(t.authorPuid)
        || OfficialAccounts.isOfficial(t.userName);
      row.read = HistoryStore.isRead(t.tid);
      // 关键：官方大卡样式标记（此前漏赋值，导致推荐频道仍走紧凑卡）
      row.officialCard = officialCard;
    }
    return row;
  }

  /**
   * 当前频道是否为可排序的帖子流（推荐 / 话题，且不是资讯频道）。
   */
  private isPostFeedChannel(): boolean {
    const ch: ChannelDef = ChannelCatalog.find(this.activeChannelId);
    return (ch.kind === ChannelKind.TOPIC || ch.kind === ChannelKind.RECOMMEND) && ch.newsSource.length === 0;
  }

  /** 排序模式变化：立即按新模式重排当前列表 */
  onFeedSortChanged(): void {
    if (this.rows.length > 0 && this.isPostFeedChannel()) {
      this.rows = this.sortRows(this.rows);
    }
  }

  /** 追加分页数据：推荐排序保持追加顺序（滚动中不跳动），显式排序保持全局有序 */
  private appendRows(more: FeedRow[]): void {
    if (more.length === 0) {
      return;
    }
    const merged: FeedRow[] = this.rows.concat(more);
    this.rows = this.feedSortMode === 'recommend' ? merged : this.sortRows(merged);
  }

  /** 按当前排序模式排列：推荐=综合评分，其余按发帖/最后回复时间升降序（置顶帖始终在最前） */
  private sortRows(rows: FeedRow[]): FeedRow[] {
    if (this.feedSortMode === 'recommend') {
      return this.rankFeed(rows);
    }
    const byReply: boolean = this.feedSortMode.indexOf('reply') === 0;
    const ascending: boolean = this.feedSortMode.indexOf('asc') >= 0;
    const pinned: FeedRow[] = [];
    const rest: FeedRow[] = [];
    for (const r of rows) {
      if (r.pinned) {
        pinned.push(r);
      } else {
        rest.push(r);
      }
    }
    rest.sort((a: FeedRow, b: FeedRow): number => {
      let ta: number = byReply ? a.lastReplyTime : a.createTime;
      let tb: number = byReply ? b.lastReplyTime : b.createTime;
      if (ta <= 0) ta = UNKNOWN_TIME_MS;
      if (tb <= 0) tb = UNKNOWN_TIME_MS;
      if (ta === tb) return 0;
      return ascending ? ta - tb : tb - ta;
    });
    if (pinned.length === 0) {
      return rest;
    }
    return pinned.concat(rest);
  }

  /**
   * 信息流重排：置顶帖 → 未读溢价 + 新鲜度 + 互动量。
   * 只排首屏；上拉追加页保持服务端顺序，避免滚动中列表跳动。
   */
  private rankFeed(rows: FeedRow[]): FeedRow[] {
    if (rows.length <= 1) {
      return rows;
    }
    const now: number = Date.now();
    const ranked: RankedRow[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const r: RankedRow = new RankedRow();
      r.row = rows[i];
      r.index = i;
      r.score = this.feedScore(rows[i], now);
      ranked.push(r);
    }
    ranked.sort((a: RankedRow, b: RankedRow): number => {
      if (a.score !== b.score) {
        return b.score - a.score;
      }
      return a.index - b.index;
    });
    const out: FeedRow[] = [];
    for (const r of ranked) {
      out.push(r.row);
    }
    return out;
  }

  private feedScore(row: FeedRow, now: number): number {
    if (row.pinned) {
      return 1e9;
    }
    let score: number = 0;
    // 官方号（虎扑官方资讯/平台号）优先，但权重远低于置顶
    if (row.official) {
      score += 120;
    }
    // 未读优先（读过的整体后移，但不会消失）
    if (!row.read) {
      score += 100;
    }
    // 新鲜度：以最后回复时间优先，其次发帖时间；72 小时内线性衰减
    const t: number = row.lastReplyTime > 0 ? row.lastReplyTime : row.createTime;
    if (t > 0) {
      const hours: number = (now - t) / 3600000;
      if (hours >= 0 && hours < 72) {
        score += (72 - hours) * 1.6;
      }
    }
    // 互动量：回复权重高于亮，取对数避免老热帖霸榜
    score += Math.min(60, Math.log(row.replies + 1) / Math.LN2 * 7);
    score += Math.min(30, Math.log(row.lights + 1) / Math.LN2 * 3);
    return score;
  }

  /** 列表底部文案（官方频道到底时说明原因，避免用户以为内容缺失） */
  private footerText(): string {
    const ch: ChannelDef = ChannelCatalog.find(this.activeChannelId);
    if (!this.hasMore) {
      if (ch.officialSources.length > 0 && !this.officialFallback) {
        return '已无更多官方资讯';
      }
      return '已经到底了';
    }
    return ch.officialSources.length > 0 ? '上拉加载更多官方资讯' : '上拉加载更多';
  }

  /** 内容区宽度（vp）：屏幕宽 - 列表左右内边距，供媒体区按比例定高 */
  private contentWidthVp(): number {
    if (this.cachedContentW > 0) {
      return this.cachedContentW;
    }
    let w: number = 328;
    try {
      const screenW: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
      if (screenW > 0) {
        w = screenW - Spacing.lg * 2;
      }
    } catch (e) {
    }
    this.cachedContentW = w;
    return w;
  }

  /**
   * 媒体区高度：按真实比例计算并限幅（对齐官方卡片尺寸）。
   * 16:9 横屏视频 ≈ 184vp 完整显示；4:3、竖屏内容封顶 200vp（视频侧 Cover 裁切铺满，消除黑边）。
   * 旧实现竖屏视频给到 340vp 且用 Contain，导致面积过大 + 左右黑边。
   */
  private mediaHeight(row: FeedRow): number {
    const minH: number = 150;
    const maxH: number = 200;
    if (row.coverW <= 0 || row.coverH <= 0) {
      return maxH;
    }
    const ratio: number = row.coverW / row.coverH;
    if (ratio <= 0) {
      return maxH;
    }
    const h: number = this.contentWidthVp() / ratio;
    if (h < minH) {
      return minH;
    }
    return h > maxH ? maxH : h;
  }

  /**
   * 单图媒体区尺寸（对齐官方形制）：
   * - 横图（宽高比 ≥ 1.2）：满宽，高度按比例限幅 150~200vp；
   * - 竖图/方图：给"小图"形态（内容宽 42%，高度封顶 200vp），
   *   避免满宽渲染成大横条并裁掉画面主体（官方此类图即为小图展示）。
   */
  private singleBox(row: FeedRow): MediaBox {
    const box: MediaBox = new MediaBox();
    const cw: number = this.contentWidthVp();
    let ratio: number = 1.5;
    if (row.coverW > 0 && row.coverH > 0) {
      ratio = row.coverW / row.coverH;
    }
    if (ratio >= 1.2) {
      let h: number = cw / ratio;
      if (h < 150) {
        h = 150;
      }
      if (h > 200) {
        h = 200;
      }
      box.w = cw;
      box.h = h;
      return box;
    }
    let w: number = cw * 0.42;
    let h: number = w / ratio;
    if (h > 200) {
      h = 200;
      w = h * ratio;
    }
    box.w = w;
    box.h = h;
    return box;
  }

  /** 视频可见性变化：维护可播集合；滚动中不抢播（停止后再决定播哪个） */
  private onVideoAreaChange(tid: string, ratio: number): void {
    const idx: number = this.visibleVideos.indexOf(tid);
    const playable: boolean = ratio >= 0.6;
    if (playable && idx < 0) {
      this.visibleVideos.push(tid);
      if (!this.listScrolling && this.autoplayFeed) {
        this.startPlay(tid);
      }
    } else if (!playable && idx >= 0) {
      this.visibleVideos.splice(idx, 1);
      if (this.playingTid === tid) {
        this.playingTid = '';
      }
    }
  }

  /** 关闭"信息流自动播放"时立刻停掉正在播的视频 */
  onAutoplayChanged(): void {
    if (!this.autoplayFeed && this.playingTid.length > 0) {
      this.playingTid = '';
    }
  }

  /** 开始播放某视频：每次换视频复位为静音（对齐官方，避免突然出声） */
  private startPlay(tid: string): void {
    this.playingTid = tid;
    this.videoMuted = true;
    this.feedVideoSec = 0;
  }

  /** 静音开关触摸：标记按下态，避免点击穿透到卡片触发"打开帖子" */
  private onMuteTouch(e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      this.mutePressed = true;
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      // 延迟清除：父级卡片 Up 判定发生在同一事件派发内，需等其读完标记
      setTimeout(() => {
        this.mutePressed = false;
      }, 0);
    }
  }

  /**
   * 打开全屏播放页。
   * 不用 VideoController.requestFullscreen：该接口只触发窗口旋转，画面不会真正铺满屏幕；
   * 独立全屏页铺满窗口 + 横屏 + 隐藏系统栏，返回时按进度续播。
   */
  private openFeedFullscreen(row: FeedRow): void {
    if (row.videoUrl.length === 0) {
      return;
    }
    this.feedVideoController.pause();
    const param: string = `${row.videoUrl}||${this.feedVideoSec}||${this.videoMuted ? '1' : '0'}||${row.author}`;
    this.pageStack.pushPathByName(RouteName.VIDEO_FULLSCREEN, param, (info: PopInfo) => {
      const result: VideoPlaybackResult = info.result as VideoPlaybackResult;
      if (result !== undefined && result !== null) {
        this.videoMuted = result.muted;
        if (result.position > 0) {
          this.feedVideoSec = result.position;
          this.feedVideoController.setCurrentTime(result.position);
        }
      }
      // 全屏期间信息流一直处于暂停态，返回后按原播放目标续播
      if (this.playingTid === row.tid) {
        this.feedVideoController.start();
      }
    });
  }

  /** 滚动开始：暂停在播视频（滚动中反复起停体验差且费流量） */
  private onFeedScrollStart(): void {
    this.listScrolling = true;
    if (this.playingTid.length > 0) {
      this.playingTid = '';
    }
  }

  /** 滚动停止：从当前可见视频帖中择一自动播放 */
  private onFeedScrollStop(): void {
    this.listScrolling = false;
    if (this.autoplayFeed && this.playingTid.length === 0 && this.visibleVideos.length > 0) {
      this.startPlay(this.visibleVideos[0]);
    }
  }

  /**
   * 官方资讯行
   * @param tag 来源标签（频道名，如 NBA / 中国篮球 / 国际足球）
   */
  private mapNews(items: NbaNewsItem[], tag: string): FeedRow[] {
    const result: FeedRow[] = [];
    for (const n of items) {
      const row: FeedRow = new FeedRow();
      row.tid = n.tid;
      row.title = n.title;
      row.tag = tag;
      row.time = n.publishTime.length >= 16 ? n.publishTime.substring(5, 16) : n.publishTime;
      row.meta = `${compactCount(n.replies)} 回复 · ${compactCount(n.lights)} 亮`;
      row.cover = n.img;
      row.createTime = parseFeedTime(n.publishTime);
      row.read = HistoryStore.isRead(n.tid);
      row.replies = n.replies;
      row.lights = n.lights;
      result.push(row);
    }
    return result;
  }

  /** 未开赛/未来在前（升序），往期在后（降序） */
  private orderDays(raw: MatchDay[]): MatchDay[] {
    const now: Date = new Date();
    const y: number = now.getFullYear();
    const mo: number = now.getMonth() + 1;
    const da: number = now.getDate();
    const todayStr: string = `${y}${mo < 10 ? '0' + mo : mo}${da < 10 ? '0' + da : da}`;
    const upcoming: MatchDay[] = [];
    const past: MatchDay[] = [];
    for (const day of raw) {
      if (day.day >= todayStr) {
        upcoming.push(day);
      } else {
        past.push(day);
      }
    }
    const result: MatchDay[] = upcoming;
    for (let i = past.length - 1; i >= 0; i--) {
      result.push(past[i]);
    }
    return result;
  }

  /**
   * 英雄联盟频道顶部：最近一场赛果 + 下一场。
   * 取腾讯赛程表（3 个赛事文件，10 分钟内存缓存），不触发虎扑 bizId 扫描。
   */
  private async loadLolHighlights(): Promise<void> {
    try {
      const h: LolMatchHighlights = await LolEsportsApi.getFeedHighlights();
      this.lolLast = h.last;
      this.lolNext = h.next;
    } catch (e) {
    }
  }

  /** "2026-11-15 03:00:00" → "11月15日 03:00" */
  private fixtureTimeText(raw: string): string {
    const ms: number = Date.parse(`${raw.replace(' ', 'T')}+08:00`);
    if (!Number.isFinite(ms)) {
      return raw;
    }
    const d: Date = new Date(ms);
    const mo: number = d.getMonth() + 1;
    const da: number = d.getDate();
    const hh: number = d.getHours();
    const mi: number = d.getMinutes();
    return `${mo}月${da}日 ${hh < 10 ? '0' : ''}${hh}:${mi < 10 ? '0' : ''}${mi}`;
  }

  private fixtureTitle(item: LolFixture): string {
    if (item.eventName.length === 0) {
      return item.stage;
    }
    if (item.stage.length === 0) {
      return item.eventName;
    }
    return `${item.eventName} · ${item.stage}`;
  }

  private openLolCenter(): void {
    this.pageStack.pushPathByName(RouteName.LOL_MATCH_CENTER, '');
  }

  /** 最近赛果 → 直接进入该场比赛的评分对位 */
  private openLolResult(item: LolFixture): void {
    this.pageStack.pushPathByName(RouteName.LOL_MATCH_CENTER, `${item.teamA}||${item.teamB}||${item.matchTime}`);
  }

  /** 打开帖子：先本地落历史/已读（不等详情返回），返回时再刷一次行状态 */
  private openPost(row: FeedRow): void {
    if (row.tid.length === 0) {
      return;
    }
    this.markRowRead(row);
    this.pageStack.pushPathByName(RouteName.POST_DETAIL, row.tid, () => {
      this.markRowRead(row);
    });
  }

  /** 浏览历史变化（在别的页面读过帖子后回来）：同步当前列表的已读态 */
  onHistoryVersionChanged(): void {
    let changed: boolean = false;
    const nextRows: FeedRow[] = this.rows.slice();
    for (let i: number = 0; i < nextRows.length; i++) {
      const read: boolean = HistoryStore.isRead(nextRows[i].tid);
      if (nextRows[i].read !== read) {
        nextRows[i].read = read;
        changed = true;
      }
    }
    if (changed) {
      this.rows = nextRows;
    }
  }

  /** 写入浏览历史并把当前行标为已读（key 含 read，会触发该行重建） */
  private markRowRead(row: FeedRow): void {
    HistoryStore.record(this.getCtx(), row.tid, row.title, row.author, row.tag, row.cover, row.replies);
    if (row.read) {
      return;
    }
    const index: number = this.rows.findIndex((item: FeedRow) => item.tid === row.tid);
    if (index < 0) {
      return;
    }
    const nextRows: FeedRow[] = this.rows.slice();
    nextRows[index].read = true;
    this.rows = nextRows;
  }

  /**
   * 加载当前频道数据
   * @param animate 频道切换场景（保留旧内容、新内容滑入淡入）
   */
  private async loadActive(animate: boolean): Promise<void> {
    const ch: ChannelDef = ChannelCatalog.find(this.activeChannelId);
    this.loadSeq = this.loadSeq + 1;
    const seq: number = this.loadSeq;
    // A reload creates fresh rows, so allow their lazy reply/media backfills to run again.
    this.lightReplyRequests = [];
    this.lightReplyQueue = [];
    this.threadDetailRequests = [];
    this.threadDetailQueue = [];
    const keepContent: boolean = animate && this.state === LoadState.Ready;
    this.pageIndex = 0;
    this.cursor = '';
    this.hasMore = false;
    // 官方频道状态复位（去重集合 / 回退标记 / 连续无收获计数）
    this.officialSeen = new Set<string>();
    this.officialFallback = false;
    this.officialDryPages = 0;
    // 内容重载：停止在播视频并清空可见集合，避免旧行残留播放
    this.playingTid = '';
    this.visibleVideos = [];
    if (!keepContent) {
      this.rows = [];
      this.ranks = [];
      this.days = [];
      this.strip = [];
      this.lolLast = null;
      this.lolNext = null;
      this.activeKind = ch.kind;
      this.activeLeague = ch.matchLeague;
      this.staleTip = false;
      // 缓存优先：下拉刷新（refreshing=true）时用户明确要新数据，跳过缓存直取网络
      if (!this.refreshing) {
        await this.renderFromCache(ch.id, seq);
      }
      if (this.state !== LoadState.Ready) {
        this.state = LoadState.Loading;
      }
    }
    try {
      let newRows: FeedRow[] = [];
      let newRanks: HotRankItem[] = [];
      let newDays: MatchDay[] = [];
      let newStrip: StripItem[] = [];
      let newCursor: string = '';
      let newHasMore: boolean = false;
      let newPage: number = 0;
      if (ch.kind === ChannelKind.HOT) {
        newRanks = await HupuApi.getHotRanks();
      } else if (ch.kind === ChannelKind.SCHEDULE) {
        newDays = this.orderDays(await NbaApi.getSchedule());
      } else if (ch.newsSource.length > 0 || ch.kind === ChannelKind.NBA) {
        // 官方资讯流（NBA / 中国篮球 / 国际足球）：替代帖子流，避免个人帖子混入
        // 首屏为资讯页固定 30+ 条；上拉时用 topicId 对应的资讯板块捞官方历史（见 loadMore）
        const src: string = ch.newsSource.length > 0 ? ch.newsSource : 'nba';
        newRows = this.mapNews(await NbaApi.getLeagueNews(src), ch.name);
        newCursor = '';
        newHasMore = ch.officialSources.length > 0 && ch.topicId > 0;
        // 首屏为资讯页，未消耗 PC 话题页，故页码从 0 起（上拉时从第 1 页开始捞）
        newPage = 0;
      } else if (ch.kind === ChannelKind.TOPIC && ch.officialSources.length > 0) {
        // 纯官方频道：官方号发文 + PC 话题页第 1 页官方帖过滤
        // 上拉时继续翻 PC 话题页捞官方历史帖（见 loadMore），滑到底才停
        const off: OfficialFeed = await this.fetchOfficialRows(ch);
        newRows = off.rows;
        newCursor = '';
        newHasMore = true;
        newPage = 1;
      } else if (ch.kind === ChannelKind.TOPIC) {
        // 搜索结果带图；配置了历史关键词的频道按 fid 过滤至对应板块。
        if (ch.historyKeyword.length > 0) {
          const batch: TopicSearchBatch = await this.searchTopicBatch(ch, 1, 20);
          newRows = this.mapThreads(batch.items, ch.id === 'lol');
          newHasMore = batch.hasMore;
          newPage = batch.page;
        } else {
          const res: ThreadListPage = await HupuApi.getForumThreads(ch.topicId, 1);
          newRows = this.mapThreads(res.items, ch.id === 'lol');
          newHasMore = res.hasMore;
        }
        newCursor = '';
        if (ch.historyKeyword.length === 0) newPage = 1;
      } else {
        const res: ThreadListPage = await HupuApi.getWalkingStreet(1, '');
        newRows = this.mapThreads(res.items, true);
        newCursor = res.cursor;
        newHasMore = res.hasMore;
        newPage = 1;
      }
      if (ch.matchLeague.length > 0) {
        try {
          // 比赛条最多展示 4 场
          const all: StripItem[] = await this.loadStrip(ch.matchLeague, ch.name);
          newStrip = all.length > 4 ? all.slice(0, 4) : all;
        } catch (e) {
          newStrip = [];
        }
      }
      if (seq !== this.loadSeq) {
        return;
      }
      // 帖子流（推荐/话题/官方）：按当前排序模式排列；资讯频道（newsSource 非空）保持服务端时间序。
      if (this.isPostFeedChannel()) {
        newRows = this.sortRows(newRows);
      }
      if (keepContent) {
        // 入场起始态：不可见 + 从切换反方向进入
        this.contentAlpha = 0;
        this.enterOffsetX = this.lastSwitchDir > 0 ? 36 : -36;
      }
      this.rows = newRows;
      this.ranks = newRanks;
      this.days = newDays;
      this.strip = newStrip;
      if (ch.id === 'lol') {
        this.loadLolHighlights();
      }
      // 官方频道：把首屏 tid 登记进去重集合，上拉捞历史时不会重复展示
      if (ch.officialSources.length > 0) {
        for (const r of newRows) {
          if (r.tid.length > 0) {
            this.officialSeen.add(r.tid);
          }
        }
      }
      this.activeKind = ch.kind;
      this.activeLeague = ch.matchLeague;
      this.pageIndex = newPage;
      this.cursor = newCursor;
      this.hasMore = newHasMore;
      const empty: boolean = newRows.length === 0 && newRanks.length === 0 && newDays.length === 0;
      this.state = empty ? LoadState.Empty : LoadState.Ready;
      this.lastLoadedChannelId = ch.id;
      this.staleTip = false;
      this.saveChannelCache(ch.id, newRows, newRanks, newDays, newStrip, newCursor, newHasMore, newPage);
      if (keepContent) {
        // 延迟一帧：等起始态渲染后再播入场动画（同一同步块内启动会被吞掉）
        const targetSeq: number = seq;
        setTimeout(() => {
          if (targetSeq !== this.loadSeq) {
            return;
          }
          this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
            this.contentAlpha = 1;
            this.enterOffsetX = 0;
          });
        }, 16);
      } else {
        this.contentAlpha = 1;
        this.enterOffsetX = 0;
      }
    } catch (e) {
      if (seq === this.loadSeq) {
        if (this.state === LoadState.Ready) {
          // 缓存内容已在渲染：保持展示 + 提示"稍早内容"，不显示错误页
          this.staleTip = true;
          this.lastLoadedChannelId = ch.id;
        } else {
          this.state = LoadState.Error;
          this.contentAlpha = 1;
          this.enterOffsetX = 0;
          this.lastLoadedChannelId = ch.id;
        }
      }
    }
    this.refreshing = false;
  }

  /** 缓存优先：读取频道快照并立即渲染（网络成功后会被静默替换） */
  /** 写频道缓存（fire-and-forget，失败静默） */
  private saveChannelCache(channelId: string, rows: FeedRow[], ranks: HotRankItem[], days: MatchDay[],
    strip: StripItem[], cursor: string, hasMore: boolean, page: number): void {
    const data: HomeCacheData = new HomeCacheData();
    data.rows = rows;
    data.ranks = ranks;
    data.days = days;
    data.strip = strip;
    data.cursor = cursor;
    data.hasMore = hasMore;
    data.page = page;
    CacheStore.put(this.getCtx(), `${HOME_CACHE_PREFIX}${channelId}`, JSON.stringify(data));
  }

  /**
   * 缓存行归一化：旧版本快照缺少新增字段（videoUrl/官方大卡数据等），
   * 直接渲染会取到 undefined.length 崩溃，逐字段兜底。
   */
  private normalizeRows(raw: FeedRow[]): FeedRow[] {
    const result: FeedRow[] = [];
    if (!raw) {
      return result;
    }
    for (const r of raw) {
      const row: FeedRow = new FeedRow();
      row.tid = r.tid ?? '';
      row.title = r.title ?? '';
      row.author = r.author ?? '';
      row.userHeader = r.userHeader ?? '';
      row.tag = r.tag ?? '';
      row.time = r.time ?? '';
      row.meta = r.meta ?? '';
      row.cover = r.cover ?? '';
      row.pics = r.pics ?? [];
      row.isVideo = r.isVideo === true;
      row.videoDur = r.videoDur ?? '';
      row.officialCard = r.officialCard === true;
      // 视频直链带时效 auth_key（数小时过期），缓存快照里的链接多已失效：
      // 缓存阶段不自动播放（封面+时长仍正常显示），网络返回最新链接后再播
      row.videoUrl = '';
      row.coverW = r.coverW ?? 0;
      row.coverH = r.coverH ?? 0;
      row.replies = r.replies ?? 0;
      row.lights = r.lights ?? 0;
      row.shareNum = r.shareNum ?? 0;
      row.viewNum = r.viewNum ?? 0;
      row.lightReplyContent = r.lightReplyContent ?? '';
      row.lightReplyUser = r.lightReplyUser ?? '';
      row.lightReplyCount = r.lightReplyCount ?? 0;
      row.createTime = r.createTime ?? 0;
      row.lastReplyTime = r.lastReplyTime ?? 0;
      row.pinned = r.pinned === true;
      row.authorPuid = r.authorPuid ?? '';
      row.official = r.official === true || OfficialAccounts.isOfficialPuid(row.authorPuid)
        || OfficialAccounts.isOfficial(row.author);
      // 已读以本地历史为准（缓存快照可能早于最近一次阅读）
      row.read = HistoryStore.isRead(row.tid);
      result.push(row);
    }
    return result;
  }

  private async renderFromCache(channelId: string, seq: number): Promise<void> {
    let cached: CachedPayload | null = null;
    try {
      cached = await CacheStore.get(this.getCtx(), `${HOME_CACHE_PREFIX}${channelId}`);
    } catch (e) {
    }
    if (cached === null || seq !== this.loadSeq) {
      return;
    }
    try {
      const data = JSON.parse(cached.json) as HomeCacheData;
      if (!data) {
        return;
      }
      this.rows = this.normalizeRows(data.rows);
      this.ranks = data.ranks || [];
      this.days = data.days || [];
      this.strip = data.strip || [];
      this.cursor = data.cursor || '';
      this.hasMore = data.hasMore === true;
      this.pageIndex = data.page || 0;
      const empty: boolean = this.rows.length === 0 && this.ranks.length === 0 && this.days.length === 0;
      this.state = empty ? LoadState.Empty : LoadState.Ready;
      this.staleTip = true;
      this.contentAlpha = 1;
      this.enterOffsetX = 0;
    } catch (e) {
      // 缓存损坏：忽略，走正常网络加载
    }
  }

  /**
   * 官方资讯优先：抓取该频道官方号发文 + PC 话题页官方帖过滤。
   *
   * 主源——官方号主页：`getUserPosts` 一次 20 条跨板块发文（快，一次请求），
   *   按 topicId 过滤即得本频道最新官方帖。
   * 补充源——PC 话题页第 1 页：单页约 50 条（是 m 站话题流的 5 倍），
   *   过滤白名单官方号即得更多官方内容。**上拉时继续翻页捞历史**（见 loadMore）。
   *
   * 若两源合计仍少于 FALLBACK_MIN，说明该话题确无稳定官方内容，
   * 回退展示原始帖子流——空频道比混入个人帖更糟。
   */
  private async fetchOfficialRows(ch: ChannelDef): Promise<OfficialFeed> {
    const MIN_SUPPLEMENT: number = 12;
    const FALLBACK_MIN: number = 3;
    const feed: OfficialFeed = new OfficialFeed();
    const merged: ThreadListItem[] = [];
    const seen: Set<string> = new Set<string>();
    this.officialSeen = seen;

    // 主源：频道配置的官方号发文，按本频道板块过滤
    if (ch.officialSources.length > 0) {
      const puids: string[] = ch.officialSources.split(',');
      for (const raw of puids) {
        const puid: string = raw.trim();
        if (puid.length === 0) {
          continue;
        }
        try {
          const posts: ThreadListItem[] = await HupuApi.getUserPosts(puid);
          for (const it of posts) {
            if (ch.topicId > 0 && it.topicId !== ch.topicId) {
              continue;
            }
            if (it.tid.length === 0 || seen.has(it.tid)) {
              continue;
            }
            seen.add(it.tid);
            merged.push(it);
          }
        } catch (e) {
        }
      }
    }

    // 补充源：PC 话题页第 1 页的官方帖（PC 被风控时降级到 m 站话题流）
    if (merged.length < MIN_SUPPLEMENT) {
      let items: ThreadListItem[] = [];
      try {
        const res: ThreadListPage = await HupuApi.getForumThreads(ch.topicId, 1);
        items = res.items;
      } catch (e) {
        try {
          const res: ThreadListPage = await HupuApi.getTopicThreads(ch.topicId, 1, '');
          items = res.items;
        } catch (e2) {
        }
      }
      for (const it of items) {
        if (!OfficialAccounts.isOfficial(it.userName) || seen.has(it.tid)) {
          continue;
        }
        seen.add(it.tid);
        merged.push(it);
      }
    }

    if (merged.length >= FALLBACK_MIN) {
      feed.rows = this.mapThreads(merged, false);
      return feed;
    }
    // 回退：原始帖子流
    const raw: ThreadListPage = await HupuApi.getTopicThreads(ch.topicId, 1, '');
    feed.rows = this.mapThreads(raw.items, false);
    this.officialFallback = true;
    return feed;
  }

  /**
   * 官方频道加载更多：翻 PC 话题页捞官方历史帖（纯官方，绝不混入个人帖）。
   * - 命中官方帖则追加
   * - 连续 DRY_LIMIT 页无官方帖 → 判定官方内容已到底（滑到底就停）
   * - 翻到 MAX_PAGE 或遇 WAF 风控 → 同样停止，不做无限重试
   *
   * 注：PC 话题页按"最后回复时间"排序，官方帖分布不均，故不因单页无收获就停，
   * 需连续多页无收获才判定到底（避免过早截断历史内容）。
   */
  private async loadMoreOfficial(ch: ChannelDef): Promise<void> {
    const MAX_PAGE: number = 30;
    const DRY_LIMIT: number = 2;
    // 单页命中率不均（搜索过滤后可能只有 2~5 条），内部连续翻页攒够 TARGET 条再返回，
    // 避免"上拉一次页面毫无变化"的体验
    const TARGET: number = 6;
    const MAX_ROUNDS: number = 4;
    const fresh: FeedRow[] = [];
    for (let round: number = 0; round < MAX_ROUNDS; round++) {
      if (this.pageIndex >= MAX_PAGE) {
        this.hasMore = false;
        break;
      }
      const page: number = this.pageIndex + 1;
      this.pageIndex = page;
      let items: ThreadListItem[] = [];
      if (ch.historyKeyword.length > 0) {
        // 资讯频道：搜索官方标志词（带图），按 fid 过滤到本频道板块
        try {
          const list: ThreadListItem[] = await HupuApi.searchThreads(ch.historyKeyword, page);
          for (const it of list) {
            if (it.fid === ch.topicId) {
              items.push(it);
            }
          }
        } catch (e) {
          this.hasMore = false;
          break;
        }
      } else {
        // 话题频道：PC 话题页（无图，但纯官方）
        try {
          const res: ThreadListPage = await HupuApi.getForumThreads(ch.topicId, page);
          items = res.items;
        } catch (e) {
          // 风控/网络异常：停止翻页（保留已加载内容），避免持续触发风控
          this.hasMore = false;
          break;
        }
      }
      let hit: number = 0;
      for (const it of items) {
        // 双保险：搜索分支按 fid 过滤 + 官方号白名单；话题分支按白名单过滤
        if (!OfficialAccounts.isOfficial(it.userName) || this.officialSeen.has(it.tid)) {
          continue;
        }
        this.officialSeen.add(it.tid);
        fresh.push(this.mapOne(it));
        hit++;
      }
      this.officialDryPages = hit > 0 ? 0 : this.officialDryPages + 1;
      if (fresh.length >= TARGET || this.officialDryPages >= DRY_LIMIT) {
        break;
      }
    }
    if (fresh.length > 0) {
      this.appendRows(fresh);
    }
    if (this.officialDryPages >= DRY_LIMIT) {
      this.hasMore = false;
    }
  }

  /**
   * 上拉加载更多。
   * - 官方频道（含 NBA/中国篮球/国际足球等资讯类）：翻 PC 资讯板块捞官方历史帖，
   *   官方内容耗尽即停（纯官方，绝不混入个人帖）
   * - 推荐频道：walkingStreet cursor 分页（无限）
   * - 普通话题频道：PC 站 page 分页（无限）
   * - 热榜/赛程：固定榜单，无历史
   */
  private async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.state !== LoadState.Ready) {
      return;
    }
    const ch: ChannelDef = ChannelCatalog.find(this.activeChannelId);
    const isRecommend: boolean = ch.kind === ChannelKind.RECOMMEND;
    const isTopic: boolean = ch.kind === ChannelKind.TOPIC;
    // 官方频道（含资讯类）：有官方号配置与板块才能捞历史
    const isOfficial: boolean = ch.officialSources.length > 0 && ch.topicId > 0 && !this.officialFallback;
    // 热榜/赛程为固定榜单；其余无官方号也无话题分页的频道同样不可加载
    if (ch.kind === ChannelKind.HOT || ch.kind === ChannelKind.SCHEDULE
      || (!isOfficial && !isTopic && !isRecommend)) {
      this.hasMore = false;
      return;
    }
    this.loadingMore = true;
    const seq: number = this.loadSeq;
    try {
      if (isOfficial) {
        // 纯官方频道（含资讯类）：翻 PC 资讯板块捞官方历史帖
        await this.loadMoreOfficial(ch);
        if (seq !== this.loadSeq) {
          return;
        }
      } else if (isRecommend) {
        const res: ThreadListPage = await HupuApi.getWalkingStreet(this.pageIndex + 1, this.cursor);
        if (seq !== this.loadSeq) {
          return;
        }
        this.appendRows(this.mapThreads(res.items, true));
        this.pageIndex = this.pageIndex + 1;
        this.cursor = res.cursor;
        this.hasMore = res.hasMore;
      } else {
        // 配置了搜索关键词的频道沿用带图搜索源分页。
        const nextPage: number = this.pageIndex + 1;
        if (ch.historyKeyword.length > 0) {
          const batch: TopicSearchBatch = await this.searchTopicBatch(ch, nextPage, 20);
          if (seq !== this.loadSeq) {
            return;
          }
          const existing: Set<string> = new Set<string>();
          for (const row of this.rows) existing.add(row.tid);
          const newItems: ThreadListItem[] = batch.items.filter((item: ThreadListItem) => !existing.has(item.tid));
          this.appendRows(this.mapThreads(newItems, ch.id === 'lol'));
          this.pageIndex = batch.page;
          this.hasMore = batch.hasMore;
        } else {
          const res: ThreadListPage = await HupuApi.getForumThreads(ch.topicId, nextPage);
          if (seq !== this.loadSeq) {
            return;
          }
          this.appendRows(this.mapThreads(res.items, ch.id === 'lol'));
          this.pageIndex = this.pageIndex + 1;
          this.hasMore = res.hasMore;
        }
      }
    } catch (e) {
    } finally {
      this.loadingMore = false;
    }
  }

  /** 加载频道比赛条：篮球（NBA/CBA）取最相关比赛日；足球取最相关比赛日 */
  private async loadStrip(league: string, channelName: string): Promise<StripItem[]> {
    const result: StripItem[] = [];
    if (league === 'soccer') {
      const list: SoccerMatchItem[] = await SoccerApi.getRelevantMatches();
      for (const m of list) {
        const s: StripItem = new StripItem();
        s.matchId = m.matchId;
        s.title = m.title;
        s.homeName = m.homeName;
        s.awayName = m.awayName;
        s.homeLogo = m.homeLogo;
        s.awayLogo = m.awayLogo;
        s.homeScore = m.homeScore;
        s.awayScore = m.awayScore;
        s.stage = m.title;
        s.leagueName = channelName;
        s.league = 'soccer';
        s.done = m.statusId === 4 || m.statusTxt.indexOf('结束') >= 0;
        s.timeText = m.timeText;
        s.pv = m.pv;
        result.push(s);
      }
      return result;
    }
    const days: MatchDay[] = league === 'cba' ? await NbaApi.getCbaSchedule() : await NbaApi.getSchedule();
    const day: MatchDay | null = this.pickDay(days);
    if (day === null) {
      return result;
    }
    for (const m of day.matches) {
      const s: StripItem = new StripItem();
      s.matchId = m.matchId;
      s.title = m.stage;
      s.homeName = m.homeName;
      s.awayName = m.awayName;
      s.homeLogo = m.homeLogo;
      s.awayLogo = m.awayLogo;
      s.homeScore = m.homeScore;
      s.awayScore = m.awayScore;
      s.homeTeamId = m.homeTeamId;
      s.awayTeamId = m.awayTeamId;
      s.stage = m.stage;
      s.leagueName = league === 'cba' ? 'CBA' : 'NBA';
      s.league = league;
      s.done = m.status === 'COMPLETED';
      s.timeText = m.statusDesc.length > 0
        ? m.statusDesc
        : (m.matchTime.length >= 16 ? m.matchTime.substring(11, 16) : '');
      result.push(s);
    }
    return result;
  }

  /** 选最相关比赛日：今天 > 最近未来 > 最近过去 */
  private pickDay(days: MatchDay[]): MatchDay | null {
    if (days.length === 0) {
      return null;
    }
    const now: Date = new Date();
    const y: number = now.getFullYear();
    const mo: number = now.getMonth() + 1;
    const da: number = now.getDate();
    const todayStr: string = `${y}${mo < 10 ? '0' + mo : mo}${da < 10 ? '0' + da : da}`;
    let future: MatchDay | null = null;
    let past: MatchDay | null = null;
    for (const d of days) {
      if (d.day === todayStr) {
        return d;
      }
      if (d.day > todayStr) {
        if (future === null || d.day < future.day) {
          future = d;
        }
      } else {
        if (past === null || d.day > past.day) {
          past = d;
        }
      }
    }
    return future !== null ? future : past;
  }

  /** 点击比赛条：篮球已完赛 → 球员评分页；足球已完赛 → 战报页 */
  private openStrip(s: StripItem): void {
    if (!s.done) {
      return;
    }
    const param: string = `${s.matchId}||${s.homeTeamId}||${s.awayTeamId}||${s.homeName}||${s.awayName}||${s.homeScore}||${s.awayScore}||${s.homeLogo}||${s.awayLogo}||${s.stage}||${s.leagueName}`;
    if (s.league === 'soccer') {
      this.pageStack.pushPathByName(RouteName.MATCH_REPORT, param);
      return;
    }
    this.pageStack.pushPathByName(RouteName.MATCH_SCORE, param);
  }

  private indexOfChannel(id: string): number {
    for (let i = 0; i < this.channels.length; i++) {
      if (this.channels[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  /** 切换频道并同步频道栏位置 */
  private switchToIndex(idx: number): void {
    if (idx < 0 || idx >= this.channels.length) {
      return;
    }
    const id: string = this.channels[idx].id;
    const curIdx: number = this.indexOfChannel(this.activeChannelId);
    if (curIdx >= 0 && idx !== curIdx) {
      this.lastSwitchDir = idx > curIdx ? 1 : -1;
    }
    if (id !== this.activeChannelId) {
      AppStorage.setOrCreate<string>('activeChannelId', id);
      // 直连持久化：不依赖 @Watch 时序，确保下次启动恢复
      this.saveLastChannel(id);
    }
    try {
      this.channelScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } catch (e) {
    }
  }

  private ensureThresholds(): void {
    if (this.tapThresholdPx <= 0) {
      try {
        this.tapThresholdPx = this.getUIContext().vp2px(10);
        this.swipeThresholdPx = this.getUIContext().vp2px(28);
        this.resolvePx = this.getUIContext().vp2px(10);
      } catch (e) {
        this.tapThresholdPx = 26;
        this.swipeThresholdPx = 74;
        this.resolvePx = 26;
      }
    }
  }

  /**
   * 内容区触摸：横向跟手切频道；纵向不拦截，交给列表滚动。
   * 旧实现里父容器 onTouch 与列表滚动竞争同一事件流，横向滑动经常被列表滚动吃掉（"划不动"）。
   * 现改为：先小窗内判定方向，确认横向后列表侧 onTouchIntercept 返回 Block 让出事件，跟手不被抢。
   */
  private onContentTouch(e: TouchEvent): void {
    this.ensureThresholds();
    if (e.type === TouchType.Down) {
      this.scrollArmed = false;
      if (e.touches.length !== 1 || this.state !== LoadState.Ready) {
        this.panState = 0;
        return;
      }
      this.panState = 1;
      this.swipeStartX = e.touches[0].windowX;
      this.swipeStartY = e.touches[0].windowY;
      this.swipeLastX = this.swipeStartX;
      this.swipeLastY = this.swipeStartY;
    } else if (e.type === TouchType.Move) {
      if (e.touches.length !== 1) {
        this.panState = 0;
        return;
      }
      this.swipeLastX = e.touches[0].windowX;
      this.swipeLastY = e.touches[0].windowY;
      const dx: number = this.swipeLastX - this.swipeStartX;
      const dy: number = this.swipeLastY - this.swipeStartY;
      const absX: number = dx < 0 ? -dx : dx;
      const absY: number = dy < 0 ? -dy : dy;
      if (this.panState === 1 && (absX > this.resolvePx || absY > this.resolvePx)) {
        if (absX > absY) {
          // 横向：进入跟手（列表侧由 onTouchIntercept 感知 panState 后主动放行事件）
          this.panState = 2;
        } else {
          // 纵向：放弃手势，滚动完全交给列表
          this.panState = 3;
        }
      }
      if (this.panState === 2) {
        // 1:1 跟手位移，满幅 ±56vp
        let off: number = dx;
        if (off > 56) {
          off = 56;
        }
        if (off < -56) {
          off = -56;
        }
        this.enterOffsetX = off;
      }
    } else {
      const curPan: number = this.panState;
      this.panState = 0;
      if (curPan !== 2) {
        return;
      }
      const dx: number = this.swipeLastX - this.swipeStartX;
      const dy: number = this.swipeLastY - this.swipeStartY;
      const absX: number = dx < 0 ? -dx : dx;
      const absY: number = dy < 0 ? -dy : dy;
      let switched: boolean = false;
      if (absX >= this.swipeThresholdPx && absX > absY) {
        const idx: number = this.indexOfChannel(this.activeChannelId);
        if (idx >= 0) {
          // 立即播放旧内容滑出动画（不等网络），方向与手势一致
          const dir: number = dx < 0 ? -1 : 1;
          this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
            this.contentAlpha = 0;
            this.enterOffsetX = 48 * dir;
          });
          if (dx < 0) {
            this.switchToIndex(idx + 1);
          } else {
            this.switchToIndex(idx - 1);
          }
          switched = true;
        }
      }
      if (!switched && this.enterOffsetX !== 0) {
        // 未达标：弹性回位
        this.getUIContext().animateTo({ duration: 160, curve: Curve.FastOutSlowIn }, () => {
          this.enterOffsetX = 0;
        });
      }
    }
  }

  /**
   * 列表触摸拦截：横向跟手期间返回 Block，让列表不再接收触摸、滚动立即停止，
   * 事件交回父容器完成切频道手势（解决列表滚动与横向滑动互相抢事件"划不动"）。
   */
  private feedTouchIntercept(): HitTestMode {
    return this.panState === 2 ? HitTestMode.Block : HitTestMode.Default;
  }

  /** 有效点击：位移小 + 列表未发生滚动 + 按压时长 < 400ms（防滑动/滚动误触跳帖） */
  private isValidTap(): boolean {
    if (this.mutePressed) {
      // 落在视频静音按钮上：只切静音，不进帖子
      return false;
    }
    if (this.videoTapPressed) {
      // 落在视频播放按钮上（自动播放关闭时手动点播）：只播视频，不进帖子
      return false;
    }
    return !this.itemMoved && !this.scrollArmed && (Date.now() - this.pressStartTs) < 400;
  }

  /** 列表项按下 */
  private itemTouchDown(e: TouchEvent): void {
    this.ensureThresholds();
    this.pressStartTs = Date.now();
    if (e.touches.length > 0) {
      this.itemStartX = e.touches[0].windowX;
      this.itemStartY = e.touches[0].windowY;
      this.itemMoved = false;
    }
  }

  /** 列表项移动：超过点击阈值即标记为滑动 */
  private itemTouchMove(e: TouchEvent): void {
    if (this.itemMoved || e.touches.length === 0) {
      return;
    }
    const dx: number = e.touches[0].windowX - this.itemStartX;
    const dy: number = e.touches[0].windowY - this.itemStartY;
    const absX: number = dx < 0 ? -dx : dx;
    const absY: number = dy < 0 ? -dy : dy;
    if (absX > this.tapThresholdPx || absY > this.tapThresholdPx) {
      this.itemMoved = true;
    }
  }

  @Builder
  HeaderBar() {
    Row({ space: 8 }) {
      Text('Hupu Luna')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.brand_primary'))
        .maxLines(1)
      Row() {
        Text('搜索帖子、球队、球员')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .height(34)
      .padding({ left: 12, right: 12 })
      .backgroundColor($r('app.color.tag_bg'))
      .borderRadius(17)
      .onClick(() => {
        this.pageStack.pushPathByName(RouteName.SEARCH, '');
      })

      Text('搜索')
        .fontSize(13)
        .fontColor(Color.White)
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.brand_primary'))
        .borderRadius(17)
        .onClick(() => {
          this.pageStack.pushPathByName(RouteName.SEARCH, '');
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 10, bottom: 6 })
  }

  @Builder
  ChannelTab(c: ChannelDef) {
    Column({ space: 4 }) {
      Text(c.name)
        .fontSize(15)
        .fontWeight(this.activeChannelId === c.id ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeChannelId === c.id ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
      Row()
        .width(20)
        .height(3)
        .borderRadius(2)
        .backgroundColor(this.activeChannelId === c.id ? $r('app.color.brand_primary') : Color.Transparent)
    }
    .onClick(() => {
      this.switchToIndex(this.indexOfChannel(c.id));
    })
  }

  @Builder
  Footer(msg: string) {
    Text(msg)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 16, bottom: 24 })
  }

  /** 英雄联盟频道顶部：最近赛果 + 下一场（同一张卡内两行，分隔线区隔） */
  @Builder
  LolHighlightsCard() {
    Column({ space: 0 }) {
      if (this.lolLast !== null) {
        this.LolMatchRow(this.lolLast, true)
      }
      if (this.lolLast !== null && this.lolNext !== null) {
        Divider().color($r('app.color.divider')).margin({ left: 2, right: 2 })
      }
      if (this.lolNext !== null) {
        this.LolMatchRow(this.lolNext, false)
      }
    }
    .width('100%')
    .padding({ left: Spacing.md, right: Spacing.md, top: 2, bottom: 2 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)
  }

  @Builder
  LolMatchRow(item: LolFixture, finished: boolean) {
    Column({ space: 8 }) {
      Row() {
        Text(this.fixtureTitle(item))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(finished ? '已结束' : (item.status === '2' ? '进行中' : '未开赛'))
          .fontSize(11)
          .fontColor(finished ? $r('app.color.text_tertiary') : $r('app.color.brand_primary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Row({ space: 8 }) {
          Text(item.teamA.length > 0 ? item.teamA : '待定')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.End)
          if (item.teamALogo.length > 0) {
            ImageKnifeComponent({ imageKnifeOption: { loadSrc: item.teamALogo, objectFit: ImageFit.Contain } })
              .width(28)
              .height(28)
          }
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Column({ space: 2 }) {
          if (finished || item.status === '2') {
            Text(`${item.scoreA} - ${item.scoreB}`)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
          } else {
            Text(this.fixtureTimeText(item.matchTime))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
        }
        .width(120)
        .alignItems(HorizontalAlign.Center)

        Row({ space: 8 }) {
          if (item.teamBLogo.length > 0) {
            ImageKnifeComponent({ imageKnifeOption: { loadSrc: item.teamBLogo, objectFit: ImageFit.Contain } })
              .width(28)
              .height(28)
          }
          Text(item.teamB.length > 0 ? item.teamB : '待定')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (finished) {
        Row({ space: 4 }) {
          Blank()
          Text('查看 JRs 评分')
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
          Text('›')
            .fontSize(14)
            .fontColor($r('app.color.brand_primary'))
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      if (finished) {
        this.openLolResult(item);
      } else {
        this.openLolCenter();
      }
    })
  }

  @Builder
  SortChip(label: string, mode: string) {
    Text(label)
      .fontSize(11)
      .fontColor(this.feedSortMode === mode ? Color.White : $r('app.color.text_secondary'))
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .backgroundColor(this.feedSortMode === mode ? $r('app.color.brand_primary') : $r('app.color.tag_bg'))
      .borderRadius(11)
      .onClick(() => {
        if (this.feedSortMode !== mode) {
          this.feedSortMode = mode;
          ChannelStore.saveFeedSort(this.getCtx(), mode);
        }
      })
  }

  @Builder
  StripCard(s: StripItem) {
    Column({ space: 6 }) {
      if (s.title.length > 0) {
        Text(s.title)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      Row() {
        Row({ space: 6 }) {
          Text(s.homeName)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: s.homeLogo,
              objectFit: ImageFit.Contain
            }
          })
            .width(28)
            .height(28)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)

        Column({ space: 2 }) {
          if (s.done) {
            Text(`${s.homeScore} - ${s.awayScore}`)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
          } else {
            Text(s.timeText.length > 0 ? s.timeText : '未开始')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
          }
          if (s.done && s.pv.length > 0) {
            Text(s.pv)
              .fontSize(10)
              .fontColor($r('app.color.score_blue'))
              .maxLines(1)
          } else if (s.done && s.league !== 'soccer') {
            Text('球员评分 ›')
              .fontSize(10)
              .fontColor($r('app.color.score_blue'))
          }
        }
        .width(116)
        .alignItems(HorizontalAlign.Center)

        Row({ space: 6 }) {
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: s.awayLogo,
              objectFit: ImageFit.Contain
            }
          })
            .width(28)
            .height(28)
          Text(s.awayName)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  FeedCard(row: FeedRow) {
    // 英雄联盟频道固定走「推荐」大卡样式（视频 / 单图 / 双图 / 三图 / 纯文字），
    // 即使缓存里的旧行没带 officialCard 标记也保持同一形态。
    if (row.officialCard || this.activeChannelId === 'lol') {
      this.OfficialFeedCard(row)
    } else {
      this.CompactFeedCard(row)
    }
  }

  @Builder
  OfficialFeedCard(row: FeedRow) {
    Column({ space: 8 }) {
      // 作者行：头像 + 昵称 + 时间
      Row({ space: 6 }) {
        if (row.userHeader.length > 0) {
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: thumbUrl(row.userHeader, 60),
              objectFit: ImageFit.Cover,
              border: { radius: 10 }
            }
          })
            .width(20)
            .height(20)
        }
        Text(row.author.length > 0 ? row.author : '虎扑JR')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (row.official) {
          Text('官方')
            .fontSize(9)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .border({ width: 1, color: $r('app.color.brand_primary') })
            .borderRadius(3)
        }
        if (row.read) {
          Text('已读')
            .fontSize(9)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor($r('app.color.tag_bg'))
            .borderRadius(3)
            .margin({ right: 6 })
        }
        Text(row.time)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 标题（读过的帖子标题降一档灰度，便于快速区分已读/未读）
      Text(row.title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .lineHeight(24)
        .fontColor(row.read ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // 媒体区：视频（自动播放）/ 多图网格 / 单图大图
      // 注：视频帖一律走 VideoBlock（videoUrl 为空时=缓存阶段，仅显示封面+时长，不播）
      if (row.isVideo) {
        this.VideoBlock(row)
      } else if (row.pics.length >= 3) {
        Row({ space: 4 }) {
          ForEach(row.pics.slice(0, 3), (img: string, idx: number) => {
            ImageKnifeComponent({
              imageKnifeOption: {
                loadSrc: thumbUrl(img, 300),
                objectFit: ImageFit.Cover,
                border: { radius: 6 }
              }
            })
              .layoutWeight(1)
              .aspectRatio(1)
          }, (img: string, idx: number) => `p${idx}_${img}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else if (row.pics.length === 2) {
        Row({ space: 4 }) {
          ForEach(row.pics, (img: string, idx: number) => {
            ImageKnifeComponent({
              imageKnifeOption: {
                loadSrc: thumbUrl(img, 300),
                objectFit: ImageFit.Cover,
                border: { radius: 6 }
              }
            })
              .layoutWeight(1)
              .aspectRatio(1.33)
          }, (img: string, idx: number) => `p${idx}_${img}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else if (row.pics.length === 1 || (row.pics.length === 0 && row.cover.length > 0)) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: thumbUrl(row.pics.length === 1 ? row.pics[0] : row.cover, 640),
              objectFit: ImageFit.Cover,
              border: { radius: 6 }
            }
          })
            // 视频贴缺播放地址时兜底：仍按满宽横条展示封面
            .width(row.isVideo ? this.contentWidthVp() : this.singleBox(row).w)
            .height(row.isVideo ? this.mediaHeight(row) : this.singleBox(row).h)
          if (row.isVideo) {
            Text(row.videoDur.length > 0 ? row.videoDur : '视频')
              .fontSize(10)
              .fontColor(Color.White)
              .backgroundColor('#80000000')
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin(6)
          }
        }
        .width(this.singleBox(row).w)
      }

      // 神回复（亮评）：官方推荐流高亮评论
      if (row.lightReplyContent.length > 0) {
        this.LightReplyBlock(row)
      }

      // 底部数据栏：浏览 / 回复 / 亮 / 分享
      Row({ space: 16 }) {
        if (row.viewNum > 0) {
          Text(`${compactCount(row.viewNum)} 浏览`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        Text(`${compactCount(row.replies)} 回复`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text(`${compactCount(row.lights)} 亮`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        if (row.shareNum > 0) {
          Text(`${compactCount(row.shareNum)} 分享`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  /**
   * 视频区：成为播放目标时渲染 Video 自动播放（静音循环），否则显示封面 + 播放按钮。
   * 同一时刻只存在一个 Video 实例，滚动性能可控。
   */
  @Builder
  VideoBlock(row: FeedRow) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.playingTid === row.tid) {
          // Cover 铺满容器：竖屏视频裁切显示中段，消除黑边。
          // controls(false)：去掉原生播放控件（暂停/进度/时间/全屏），对齐官方干净的播放画面
          Video({ src: row.videoUrl, controller: this.feedVideoController })
            .autoPlay(true)
            .muted(this.videoMuted)
            .loop(true)
            .controls(false)
            .onUpdate((e: PlaybackInfo) => {
              this.feedVideoSec = e.time;
            })
            .objectFit(ImageFit.Cover)
            .width('100%')
            .height(this.mediaHeight(row))
        } else {
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: thumbUrl(row.cover, 640),
              objectFit: ImageFit.Cover
            }
          })
            .width('100%')
            .height(this.mediaHeight(row))

          Column() {
            Text('▶')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .width(46)
          .height(46)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#59000000')
          .borderRadius(23)
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.videoTapPressed = true;
            } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
              setTimeout(() => {
                this.videoTapPressed = false;
              }, 0);
            }
          })
          .onClick(() => {
            // 自动播放关闭时，点封面播放按钮手动起播（不进帖子）
            if (row.videoUrl.length > 0) {
              this.startPlay(row.tid);
            } else {
              this.requestThreadDetail(row.tid, true);
            }
          })
        }
      }
      .width('100%')
      .height(this.mediaHeight(row))

      // 底部浮层：播放时左下角只有静音小喇叭（官方样式），未播放时右下角显示时长
      if (this.playingTid === row.tid || row.videoDur.length > 0) {
        Row() {
          if (this.playingTid === row.tid) {
            Row() {
              SymbolGlyph(this.videoMuted
                ? $r('sys.symbol.speaker_slash')
                : $r('sys.symbol.speaker_wave_3'))
                .fontSize(15)
                .fontColor([Color.White])
            }
            .width(28)
            .height(28)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#59000000')
            .borderRadius(14)
            .onTouch((e: TouchEvent) => {
              this.onMuteTouch(e);
            })
            .onClick(() => {
              this.videoMuted = !this.videoMuted;
            })
          }
          Blank()
          if (this.playingTid === row.tid) {
            Text('⛶')
              .fontSize(20)
              .fontColor(Color.White)
              .width(28)
              .height(28)
              .textAlign(TextAlign.Center)
              .backgroundColor('#59000000')
              .borderRadius(15)
              .onTouch((e: TouchEvent) => {
                if (e.type === TouchType.Down) {
                  this.videoTapPressed = true;
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  setTimeout(() => this.videoTapPressed = false, 0);
                }
              })
              .onClick(() => this.openFeedFullscreen(row))
          }
          if (row.videoDur.length > 0 && this.playingTid !== row.tid) {
            Text(row.videoDur)
              .fontSize(10)
              .fontColor(Color.White)
              .backgroundColor('#80000000')
              .borderRadius(3)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding(8)
      }
    }
    .width('100%')
    .borderRadius(8)
    .clip(true)
    .onVisibleAreaChange([0.0, 0.6], (isVisible: boolean, ratio: number) => {
      // 无有效播放地址（缓存阶段）不参与自动播放，避免加载过期链接黑屏
      if (row.videoUrl.length > 0) {
        this.onVideoAreaChange(row.tid, ratio);
      }
    })
  }

  /** 神回复（亮评）块 */
  @Builder
  LightReplyBlock(row: FeedRow) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text('亮')
          .fontSize(10)
          .fontColor(Color.White)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor($r('app.color.brand_primary'))
          .borderRadius(3)
        Text(row.lightReplyUser.length > 0 ? row.lightReplyUser : 'JRs')
          .fontSize(12)
          .fontColor($r('app.color.score_blue'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (row.lightReplyCount > 0) {
          Text(`${compactCount(row.lightReplyCount)} 亮`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(row.lightReplyContent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .lineHeight(20)
        .fontColor(Color.White)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(8)
  }

  /** 紧凑卡（NBA资讯/其它频道原有样式） */
  @Builder
  CompactFeedCard(row: FeedRow) {
    Row({ space: 10 }) {
      Column({ space: 6 }) {
        Text(row.title)
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Medium)
          .fontColor(row.read ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          if (row.tag.length > 0) {
            Text(row.tag)
              .fontSize(11)
              .fontColor($r('app.color.brand_primary'))
              .maxLines(1)
          }
          if (row.official) {
            Text('官方')
              .fontSize(9)
              .fontColor($r('app.color.brand_primary'))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .border({ width: 1, color: $r('app.color.brand_primary') })
              .borderRadius(3)
          }
          if (row.read) {
            Text('已读')
              .fontSize(9)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor($r('app.color.tag_bg'))
              .borderRadius(3)
          }
          if (row.author.length > 0) {
            Text(row.author)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
          Text(row.time)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        Row({ space: 10 }) {
          Blank()
          Text(row.meta)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        if (row.lightReplyContent.length > 0) {
          this.LightReplyBlock(row)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (row.cover.length > 0) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: thumbUrl(row.cover, 240),
              objectFit: ImageFit.Cover,
              border: { radius: Radius.sm }
            }
          })
            .width(96)
            .height(72)
          if (row.isVideo) {
            Text(row.videoDur.length > 0 ? row.videoDur : '视频')
              .fontSize(10)
              .fontColor(Color.White)
              .backgroundColor('#80000000')
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin(4)
          }
        }
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  RankRow(item: HotRankItem) {
    Row({ space: 12 }) {
      Text(`${item.rank}`)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(item.rank <= 3 ? $r('app.color.brand_primary') : $r('app.color.text_tertiary'))
        .width(26)
        .textAlign(TextAlign.Center)
      Column({ space: 4 }) {
        Text(item.tagName)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          if (item.competitionType.length > 0) {
            Text(item.competitionType)
              .fontSize(10)
              .fontColor($r('app.color.brand_primary'))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor($r('app.color.tag_bg'))
              .borderRadius(4)
          }
          Text(`热度 ${formatHeat(item.heat)}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          if (item.updateDesc.length > 0) {
            Text(item.updateDesc)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  MatchRow(m: MatchItem) {
    Column({ space: 6 }) {
      Row() {
        Row({ space: 6 }) {
          Text(m.homeName.length > 0 ? m.homeName : '主队')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: m.homeLogo,
              objectFit: ImageFit.Contain
            }
          })
            .width(26)
            .height(26)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)

        Column({ space: 2 }) {
          Text(m.homeScore.length > 0 || m.awayScore.length > 0 ? `${m.homeScore} - ${m.awayScore}` : m.statusCn)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(m.homeScore.length > 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
          Text(m.homeScore.length > 0 ? m.statusCn : (m.statusDesc.length > 0 ? m.statusDesc : (m.matchTime.length >= 16 ? m.matchTime.substring(11, 16) : '')))
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
        .width(112)
        .alignItems(HorizontalAlign.Center)

        Row({ space: 6 }) {
          ImageKnifeComponent({
            imageKnifeOption: {
              loadSrc: m.awayLogo,
              objectFit: ImageFit.Contain
            }
          })
            .width(26)
            .height(26)
          Text(m.awayName.length > 0 ? m.awayName : '客队')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
      }
      .width('100%')

      Row() {
        Text(m.stage)
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        if (m.status === 'COMPLETED') {
          Text('球员评分 ›')
            .fontSize(10)
            .fontColor($r('app.color.brand_primary'))
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      if (m.status === 'COMPLETED') {
        const p: string = `${m.matchId}||${m.homeTeamId}||${m.awayTeamId}||${m.homeName}||${m.awayName}||${m.homeScore}||${m.awayScore}||${m.homeLogo}||${m.awayLogo}||${m.stage}||NBA`;
        this.pageStack.pushPathByName(RouteName.MATCH_SCORE, p);
      }
    })
  }

  @Builder
  ContentArea() {
    if (this.state === LoadState.Ready) {
      if (this.activeKind === ChannelKind.HOT) {
        List({ space: 0, scroller: this.feedScroller }) {
          ForEach(this.ranks, (item: HotRankItem) => {
            ListItem() {
              Column() {
                this.RankRow(item)
                Divider().color($r('app.color.divider'))
              }
              .padding({ left: Spacing.lg, right: Spacing.lg })
              .backgroundColor($r('app.color.bg_feed'))
              .onTouch((e: TouchEvent) => {
                if (e.type === TouchType.Down) {
                  this.itemTouchDown(e);
                } else if (e.type === TouchType.Move) {
                  this.itemTouchMove(e);
                } else if (e.type === TouchType.Up) {
                  if (this.isValidTap()) {
                    this.pageStack.pushPathByName(RouteName.TAG_THREADS, `${item.tagId}|${item.tagName}`);
                  }
                }
              })
            }
          }, (item: HotRankItem) => `rank_${item.tagId}`)
          ListItem() {
            this.Footer('榜单每 10 分钟更新')
          }
        }
        .cachedCount(3)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .onDidScroll((offset: number, _state: ScrollState) => this.onFeedDidScroll(offset))
        .onTouchIntercept((): HitTestMode => {
          return this.feedTouchIntercept();
        })
        .onScrollStart(() => {
          this.scrollArmed = true;
        })
        .onScrollStop(() => {
          this.scrollArmed = false;
        })
      } else if (this.activeKind === ChannelKind.SCHEDULE) {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0, scroller: this.feedScroller }) {
            ForEach(this.days, (day: MatchDay) => {
              ListItem() {
                Row() {
                  Text(day.dayLabel.length > 0 ? day.dayLabel : day.day)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .padding({ left: Spacing.lg, right: Spacing.lg, top: 10, bottom: 6 })
                .backgroundColor($r('app.color.bg_page'))
              }

              ForEach(day.matches, (m: MatchItem) => {
                ListItem() {
                  Column() {
                    this.MatchRow(m)
                    Divider().color($r('app.color.divider'))
                  }
                  .padding({ left: Spacing.lg, right: Spacing.lg })
                  .backgroundColor($r('app.color.bg_feed'))
                }
              }, (m: MatchItem, idx: number) => `${day.day}_${m.matchId}_${idx}`)
            }, (day: MatchDay) => `day_${day.day}`)
          }
          .cachedCount(3)
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .onDidScroll((offset: number, _state: ScrollState) => this.onFeedDidScroll(offset))
          .onTouchIntercept((): HitTestMode => {
            return this.feedTouchIntercept();
          })
          .onScrollStart(() => {
            this.scrollArmed = true;
          })
          .onScrollStop(() => {
            this.scrollArmed = false;
          })
        }
        .onRefreshing(() => {
          this.loadActive(false);
        })
        .width('100%')
        .height('100%')
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0, scroller: this.feedScroller }) {
            if (this.activeChannelId === 'lol') {
              if (this.lolLast !== null || this.lolNext !== null) {
                ListItem() {
                  Column() {
                    this.LolHighlightsCard()
                  }
                  .width('100%')
                  .padding({ left: Spacing.lg, right: Spacing.lg, top: 10, bottom: 2 })
                  .backgroundColor($r('app.color.bg_feed'))
                }
              }
              // 默认信息流只保留高质量的帖子；完整「英雄联盟区」帖子流从这里进入
              ListItem() {
                Row({ space: 6 }) {
                  Text('英雄联盟 · 全部帖子')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                  Blank()
                  Text('查看 ›')
                    .fontSize(12)
                    .fontColor($r('app.color.brand_primary'))
                }
                .width('100%')
                .padding({ left: Spacing.lg, right: Spacing.lg, top: 8, bottom: 8 })
                .backgroundColor($r('app.color.bg_feed'))
                .onClick(() => this.pageStack.pushPathByName(RouteName.LOL_ALL_POSTS, ''))
              }
            }
            if (this.strip.length > 0) {
              ForEach(this.strip, (s: StripItem) => {
                ListItem() {
                  Column() {
                    this.StripCard(s)
                    Divider().color($r('app.color.divider'))
                  }
                  .padding({ left: Spacing.lg, right: Spacing.lg })
                  .backgroundColor($r('app.color.bg_feed'))
                  .onTouch((e: TouchEvent) => {
                    if (e.type === TouchType.Down) {
                      this.itemTouchDown(e);
                    } else if (e.type === TouchType.Move) {
                      this.itemTouchMove(e);
                    } else if (e.type === TouchType.Up) {
                      if (this.isValidTap()) {
                        this.openStrip(s);
                      }
                    }
                  })
                }
              }, (s: StripItem) => `strip_${s.matchId}`)
            }
            if (this.activeLeague.length > 0) {
              ListItem() {
                Column() {
                  Row({ space: 6 }) {
                    Text('🔥')
                      .fontSize(15)
                    Text('查看近期全部热门比赛')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                    Text('›')
                      .fontSize(16)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                  .width('100%')
                  .height(46)
                  .justifyContent(FlexAlign.Center)
                  Divider().color($r('app.color.divider'))
                }
                .backgroundColor($r('app.color.bg_feed'))
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.itemTouchDown(e);
                  } else if (e.type === TouchType.Move) {
                    this.itemTouchMove(e);
                  } else if (e.type === TouchType.Up) {
                    if (this.isValidTap()) {
                      const name: string = ChannelCatalog.find(this.activeChannelId).name;
                      this.pageStack.pushPathByName(RouteName.MATCH_LIST, `${this.activeLeague}||${name}`);
                    }
                  }
                })
              }
            }
            ForEach(this.rows, (row: FeedRow) => {
              ListItem() {
                Column() {
                  this.FeedCard(row)
                  Divider().color($r('app.color.divider'))
                }
                .padding({ left: Spacing.lg, right: Spacing.lg })
                .backgroundColor($r('app.color.bg_feed'))
                .onAppear(() => {
                  const isReplyPreviewFeed: boolean = this.activeChannelId === 'lol'
                    || this.activeChannelId === 'recommend';
                  if (isReplyPreviewFeed && row.lightReplyContent.length === 0 && row.replies > 0) {
                    this.requestLightReplyPreview(row.tid);
                  }
                  if ((row.isVideo && row.videoUrl.length === 0)
                    || (this.activeChannelId === 'lol' && !row.isVideo && row.cover.length > 0 && row.pics.length < 3)) {
                    this.requestThreadDetail(row.tid);
                  }
                })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.itemTouchDown(e);
                  } else if (e.type === TouchType.Move) {
                    this.itemTouchMove(e);
                  } else if (e.type === TouchType.Up) {
                    if (this.isValidTap() && row.tid.length > 0) {
                      this.openPost(row);
                    }
                  }
                })
              }
            }, (row: FeedRow, idx: number) =>
              // 关键：ForEach 复用相同 key 的子组件、不会重跑 item builder，
              // 信息流是「先出封面/无亮评，再异步补配图与亮评」，必须把这三个可变字段
              // 纳入 key，补数据后才会重建该行（否则界面永远停在首屏形态）。
              `${row.tid}_${idx}_${row.pics.length}_${row.lightReplyContent.length}_${row.videoUrl.length > 0 ? 1 : 0}_${row.read ? 1 : 0}`)
            ListItem() {
              this.Footer(this.footerText())
            }
          }
          .onReachEnd(() => {
            this.loadMore();
          })
          .cachedCount(3)
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .onDidScroll((offset: number, _state: ScrollState) => this.onFeedDidScroll(offset))
          .onTouchIntercept((): HitTestMode => {
            return this.feedTouchIntercept();
          })
          .onScrollStart(() => {
            this.scrollArmed = true;
            this.onFeedScrollStart();
          })
          .onScrollStop(() => {
            this.scrollArmed = false;
            this.onFeedScrollStop();
          })
        }
        .onRefreshing(() => {
          this.loadActive(false);
        })
        .width('100%')
        .height('100%')
      }
    } else if (this.state === LoadState.Loading) {
      Scroll() {
        FeedSkeleton({ withCover: true, count: 6 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
    } else {
      StateView({
        state: this.state,
        onRetry: () => {
          this.loadActive(false);
        }
      })
        .width('100%')
        .height('100%')
    }
  }

  build() {
    Column() {
      if (this.topBarsVisible) {
        Column() {
          this.HeaderBar()
        }
        .width('100%')
        .backgroundColor($r('app.color.bg_page'))

        Row() {
          List({ space: 18, scroller: this.channelScroller }) {
            ForEach(this.channels, (c: ChannelDef, index: number) => {
              ListItem() {
                this.ChannelTab(c)
              }
              .margin({
                left: index === 0 ? Spacing.lg : 0,
                right: index === this.channels.length - 1 ? 4 : 0
              })
            }, (c: ChannelDef) => `ch_${c.id}`)
          }
          .listDirection(Axis.Horizontal)
          .alignListItem(ListItemAlign.Center)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .height('100%')

          Text('≡')
            .fontSize(20)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: Spacing.lg })
            .onClick(() => {
              this.pageStack.pushPathByName(RouteName.ALL_CHANNELS, '');
            })
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)

        // 排序条：仅帖子流显示（热榜/赛程/资讯保持原顺序）
        if (this.isPostFeedChannel()) {
          Scroll() {
            Row({ space: 6 }) {
              this.SortChip('推荐', 'recommend')
              this.SortChip('最新发布', 'time_desc')
              this.SortChip('最早发布', 'time_asc')
              this.SortChip('最后回复', 'reply_desc')
              this.SortChip('最早回复', 'reply_asc')
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: 6 })
        }

        if (this.staleTip) {
          Row() {
            Text('网络不太顺畅，正在展示稍早内容')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .backgroundColor($r('app.color.tag_bg'))
        }
      }

      Column() {
        this.ContentArea()
      }
      .layoutWeight(1)
      .width('100%')
      .clip(true)
      .opacity(this.contentAlpha)
      .translate({ x: this.enterOffsetX })
      .onTouch((e: TouchEvent) => {
        this.onContentTouch(e);
      })
    }
    .width('100%')
    .height('100%')
    .padding({ top: px2vp(this.topAvoidPx) })
    .backgroundColor($r('app.color.bg_page'))
  }
}
