import { HupuApi } from '../network/HupuApi';
import { ThreadListItem } from '../model/Models';
import { LoadState, StateView } from '../views/StateView';
import { AppNavBar } from '../views/AppNavBar';
import { Spacing, Radius, RouteName } from '../common/Theme';
import { HistoryStore } from '../database/HistoryStore';
import { compactCount } from '../views/TagChip';

/**
 * 英雄联盟 · 全部帖子
 *
 * 信息流默认只展示「热帖质量」的内容（综合排序 + 官方/热度加权）；
 * 这里展示 bbs.hupu.com/lol 的完整帖子流（按最后回复排序，包含质量一般的新帖），
 * 对应官方 App 里「进入专区看全部」的入口。
 */
@Component
export struct LolAllPostsPage {
  @Consume('pageStack') pageStack: NavPathStack;
  @State items: ThreadListItem[] = [];
  @State state: LoadState = LoadState.Loading;
  @State loadingMore: boolean = false;
  private page: number = 0;
  private hasMore: boolean = true;

  aboutToAppear(): void {
    this.loadFirst();
  }

  private async loadFirst(): Promise<void> {
    this.state = LoadState.Loading;
    this.page = 0;
    this.hasMore = true;
    try {
      const res = await HupuApi.getForumThreadsBySlug('lol', 1);
      this.items = res.items;
      this.page = 1;
      this.hasMore = res.items.length > 0;
      this.state = this.items.length > 0 ? LoadState.Ready : LoadState.Empty;
    } catch (e) {
      this.state = LoadState.Error;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.state !== LoadState.Ready) {
      return;
    }
    this.loadingMore = true;
    try {
      const res = await HupuApi.getForumThreadsBySlug('lol', this.page + 1);
      const existing: Set<string> = new Set<string>();
      for (const it of this.items) {
        existing.add(it.tid);
      }
      const fresh: ThreadListItem[] = res.items.filter((it: ThreadListItem) => !existing.has(it.tid));
      if (fresh.length === 0) {
        this.hasMore = false;
      } else {
        this.items = this.items.concat(fresh);
        this.page = this.page + 1;
      }
    } catch (e) {
      // 下一页失败不打断已加载内容
      this.hasMore = false;
    }
    this.loadingMore = false;
  }

  private open(item: ThreadListItem): void {
    this.pageStack.pushPathByName(RouteName.POST_DETAIL, item.tid, () => {
      // 返回后重新计算已读态（行 key 含已读位，会重建对应行）
      this.items = this.items.slice();
    });
  }

  private readColor(tid: string): ResourceColor {
    return HistoryStore.isRead(tid) ? $r('app.color.text_secondary') : $r('app.color.text_primary');
  }

  @Builder
  ThreadRow(item: ThreadListItem) {
    Column({ space: 6 }) {
      Text(item.title)
        .fontSize(15)
        .fontColor(this.readColor(item.tid))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 8 }) {
        if (item.official) {
          Text('官方')
            .fontSize(9)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .border({ width: 1, color: $r('app.color.brand_primary') })
            .borderRadius(3)
        }
        Text(item.userName.length > 0 ? item.userName : '虎扑JR')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(`${compactCount(item.replies)} 回复`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text(item.time)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_feed'))
    .onClick(() => {
      this.open(item);
    })
  }

  build() {
    NavDestination() {
      Column() {
        AppNavBar({ title: '英雄联盟 · 全部帖子' })
        if (this.state === LoadState.Ready) {
          List({ space: 0 }) {
            ForEach(this.items, (item: ThreadListItem) => {
              ListItem() {
                Column() {
                  this.ThreadRow(item)
                  Divider().color($r('app.color.divider')).margin({ left: Spacing.lg })
                }
              }
            }, (item: ThreadListItem) => `lolall_${item.tid}_${HistoryStore.isRead(item.tid) ? 1 : 0}`)
            ListItem() {
              Text(this.loadingMore ? '加载中…' : (this.hasMore ? '上拉加载更多' : '已经到底了'))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 24 })
            }
          }
          .onReachEnd(() => {
            this.loadMore();
          })
          .cachedCount(3)
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        } else {
          StateView({
            state: this.state,
            message: '暂时没有帖子',
            onRetry: () => {
              this.loadFirst();
            }
          })
            .width('100%')
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
