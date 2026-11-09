import { LolEsportsApi, LolPlayerScore, LolRatingComment, LolRatingCommentPage } from '../network/LolEsportsApi';
import { AppNavBar } from '../views/AppNavBar';
import { Spacing, Radius, RouteName } from '../common/Theme';
import { ImageKnifeComponent } from '@ohos/imageknife';
import { SessionManager } from '../network/SessionManager';
import { ReaderTypography } from '../common/ReaderTypography';

@Component
export struct LolPlayerRatingPage {
  param: string = '';
  @Consume('pageStack') pageStack: NavPathStack;
  @State player: LolPlayerScore = new LolPlayerScore();
  @State comments: LolRatingComment[] = [];
  @State order: string = 'hot';
  @State commentCursor: number = 0;
  @State commentTotal: number = 0;
  @State commentsHasMore: boolean = false;
  @State loading: boolean = true;
  @State commentsLoading: boolean = false;
  @State loadingMore: boolean = false;
  @State errorMessage: string = '';
  @State showReplySheet: boolean = false;
  @State selectedComment: LolRatingComment = new LolRatingComment();
  @State replies: LolRatingComment[] = [];
  @State replyOrder: string = 'hot';
  @State replyCursor: number = 0;
  @State repliesHasMore: boolean = false;
  @State repliesLoading: boolean = false;
  @State repliesLoadingMore: boolean = false;
  @State repliesError: string = '';
  @StorageLink('readerFontScale') readerFontScale: number = 0;
  @StorageLink('readerFontWeight') readerFontWeight: number = 0;
  private playerBizId: string = '';
  private fallbackName: string = '';
  private fallbackTeam: string = '';

  private readerSize(base: number): number {
    return ReaderTypography.fontSize(base, this.readerFontScale);
  }

  private readerWeight(base: number): number {
    return ReaderTypography.fontWeight(base, this.readerFontWeight);
  }

  aboutToAppear(): void {
    const parts: string[] = this.param.split('||');
    this.playerBizId = parts[0] ?? '';
    this.fallbackName = parts[1] ?? '';
    this.fallbackTeam = parts[2] ?? '';
    this.loadPage();
  }

  private async loadPage(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      const detail: LolPlayerScore = await LolEsportsApi.getPlayerRatingDetail(this.playerBizId);
      if (detail.name.length === 0) detail.name = this.fallbackName;
      this.player = detail;
    } catch (e) {
      this.player.name = this.fallbackName;
      this.errorMessage = '选手评分信息加载失败';
    }
    this.loading = false;
    await this.loadComments(true);
  }

  private async loadComments(reset: boolean): Promise<void> {
    if (this.commentsLoading || this.loadingMore || this.playerBizId.length === 0) return;
    if (reset) {
      this.comments = [];
      this.commentCursor = 0;
      this.commentsLoading = true;
    } else {
      this.loadingMore = true;
    }
    try {
      const page: LolRatingCommentPage = await LolEsportsApi.getRatingComments(
        this.playerBizId, this.order, reset ? 0 : this.commentCursor);
      this.comments = reset ? page.comments : this.uniqueComments(this.comments, page.comments);
      this.commentCursor = page.cursor;
      this.commentTotal = this.order === 'hot' || page.total <= 0 ? this.player.commentCount : page.total;
      this.commentsHasMore = page.hasMore;
      if (reset && this.order === 'hot' && this.comments.length === 0 && this.player.commentCount > 0) {
        this.order = 'new';
        const fallback: LolRatingCommentPage = await LolEsportsApi.getRatingComments(this.playerBizId, 'new', 0);
        this.comments = fallback.comments;
        this.commentCursor = fallback.cursor;
        this.commentTotal = fallback.total;
        this.commentsHasMore = fallback.hasMore;
      }
    } catch (e) {
      if (reset) this.errorMessage = '评论暂时加载失败，请重试';
    } finally {
      this.commentsLoading = false;
      this.loadingMore = false;
    }
  }

  private uniqueComments(existing: LolRatingComment[], next: LolRatingComment[]): LolRatingComment[] {
    const out: LolRatingComment[] = existing.slice();
    for (const item of next) {
      if (!out.some((row: LolRatingComment) => row.commentId === item.commentId)) out.push(item);
    }
    return out;
  }

  private async setCommentOrder(value: string): Promise<void> {
    if (this.order === value) return;
    this.order = value;
    await this.loadComments(true);
  }

  private async openReplies(item: LolRatingComment): Promise<void> {
    this.selectedComment = item;
    this.replyOrder = 'hot';
    this.showReplySheet = true;
    this.replies = [];
    this.replyCursor = 0;
    this.repliesHasMore = false;
    this.repliesError = '';
    await this.loadReplies(true);
  }

  private async loadReplies(reset: boolean): Promise<void> {
    if (this.repliesLoading || this.repliesLoadingMore) return;
    if (reset) {
      this.replies = [];
      this.replyCursor = 0;
      this.repliesLoading = true;
    } else {
      this.repliesLoadingMore = true;
    }
    this.repliesError = '';
    try {
      const page: LolRatingCommentPage = await LolEsportsApi.getRatingReplies(
        this.playerBizId, this.selectedComment, this.replyOrder, reset ? 0 : this.replyCursor);
      this.replies = reset ? this.uniqueComments([], page.comments) : this.uniqueComments(this.replies, page.comments);
      this.replyCursor = page.cursor;
      this.repliesHasMore = page.hasMore;
    } catch (e) {
      this.repliesError = '回复暂时加载失败';
    } finally {
      this.repliesLoading = false;
      this.repliesLoadingMore = false;
    }
  }

  private async setReplyOrder(value: string): Promise<void> {
    if (this.replyOrder === value) return;
    this.replyOrder = value;
    await this.loadReplies(true);
  }

  private async saveScore(value: number): Promise<void> {
    if (!SessionManager.hasCookie()) {
      this.getUIContext().showAlertDialog({
        title: '登录后评分',
        message: '评分会提交到你的虎扑账号。请先登录。',
        autoCancel: true,
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: { value: '去登录', action: () => this.pageStack.pushPathByName(RouteName.LOGIN_WEB, '') }
      });
      return;
    }
    try {
      await LolEsportsApi.savePlayerScore(this.playerBizId, value);
      this.getUIContext().getPromptAction().showToast({ message: `已提交 ${value} 分` });
      this.player = await LolEsportsApi.getPlayerRatingDetail(this.playerBizId);
    } catch (e) {
      const err = e as Error;
      this.getUIContext().getPromptAction().showToast({ message: err.message });
    }
  }

  private ratingTotal(): number {
    let total: number = 0;
    for (const value of this.player.ratingDistribution) total += value;
    return total;
  }

  private ratingShare(index: number): number {
    const total: number = this.ratingTotal();
    if (total <= 0 || index < 0 || index >= this.player.ratingDistribution.length) return 0;
    return this.player.ratingDistribution[index] * 100 / total;
  }

  private scoreColor(): string {
    if (this.player.score >= 8) return '#51C8E8';
    if (this.player.score >= 6) return '#E5B84C';
    return '#F05B68';
  }

  private formatCount(value: number): string {
    if (value >= 10000) return `${(value / 10000).toFixed(1)}万`;
    if (value >= 1000) return `${(value / 1000).toFixed(1)}千`;
    return `${value}`;
  }

  @Builder
  Distribution() {
    if (this.ratingTotal() > 0) {
      Column({ space: 5 }) {
        ForEach([0, 1, 2, 3, 4], (idx: number) => {
          Row({ space: 7 }) {
            Text(`${(idx + 1) * 2}分`).fontSize(this.readerSize(13)).fontColor($r('app.color.text_secondary')).width(30)
            Progress({ value: this.ratingShare(idx), total: 100, type: ProgressType.Linear })
              .color($r('app.color.brand_primary')).layoutWeight(1).height(6)
            Text(`${this.ratingShare(idx).toFixed(1)}%`).fontSize(this.readerSize(12))
              .fontColor($r('app.color.text_tertiary')).width(42).textAlign(TextAlign.End)
          }.width('100%').alignItems(VerticalAlign.Center)
        }, (idx: number) => `lol_dist_${idx}`)
      }.width('100%')
    }
  }

  @Builder
  PlayerHeader() {
    Column({ space: 13 }) {
      Row({ space: 12 }) {
        if (this.player.avatar.length > 0) {
          ImageKnifeComponent({ imageKnifeOption: { loadSrc: this.player.avatar, objectFit: ImageFit.Cover } })
            .width(68).height(68).borderRadius(12)
        } else {
          Text(this.player.name.length > 0 ? this.player.name.substring(0, 1) : '选')
            .width(68).height(68).borderRadius(12).textAlign(TextAlign.Center)
            .fontSize(this.readerSize(26)).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_page'))
        }
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(this.player.name.length > 0 ? this.player.name : this.fallbackName)
              .fontSize(this.readerSize(21)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor($r('app.color.text_primary'))
            if (this.fallbackTeam.length > 0) {
              Text(this.fallbackTeam).fontSize(this.readerSize(13)).fontColor($r('app.color.text_secondary'))
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor($r('app.color.bg_page')).borderRadius(8)
            }
          }.width('100%')
          if (this.player.champion.length > 0) {
            Row({ space: 6 }) {
              ImageKnifeComponent({ imageKnifeOption: { loadSrc: this.player.champion, objectFit: ImageFit.Cover } })
                .width(24).height(24).borderRadius(6)
              Text(this.player.label.length > 0 ? this.player.label : '本局选手')
                .fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
            }.alignItems(VerticalAlign.Center)
          } else if (this.player.label.length > 0) {
            Text(this.player.label).fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
          }
          Text(`${this.player.kills}/${this.player.deaths}/${this.player.assists} K / D / A`)
            .fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Column({ space: 3 }) {
          Text(this.player.score > 0 ? this.player.score.toFixed(1) : '—')
            .fontSize(this.readerSize(30)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor(this.scoreColor())
          Text(`${this.formatCount(this.player.votes)} 人评分`)
            .fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary'))
        }.alignItems(HorizontalAlign.End)
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.player.featuredComment.length > 0) {
        Row({ space: 7 }) {
          Text('亮评').fontSize(this.readerSize(13)).fontColor($r('app.color.brand_primary'))
          Text(`“${this.player.featuredComment}”`).fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary'))
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.player.featuredCommentLights > 0) {
            Text(`${this.formatCount(this.player.featuredCommentLights)} 亮`).fontSize(this.readerSize(12))
              .fontColor($r('app.color.text_tertiary'))
          }
        }.width('100%')
      }
      this.Distribution()
      Row() {
        Text('立即评分').fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Row({ space: 5 }) {
          ForEach([2, 4, 6, 8, 10], (value: number) => {
            Text(`${value}`).fontSize(this.readerSize(13)).fontColor($r('app.color.brand_primary'))
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.bg_page')).borderRadius(7)
              .onClick(() => this.saveScore(value))
          }, (value: number) => `lol_detail_rate_${value}`)
        }
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%').padding(Spacing.md)
    .backgroundColor($r('app.color.bg_card')).borderRadius(Radius.lg)
  }

  @Builder
  SortChip(label: string, value: string) {
    Text(label).fontSize(this.readerSize(14))
      .fontColor(this.order === value ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.order === value ? $r('app.color.bg_card') : $r('app.color.bg_page'))
      .borderRadius(7).onClick(() => this.setCommentOrder(value))
  }

  @Builder
  CommentCard(item: LolRatingComment, isReply: boolean) {
    Column({ space: 9 }) {
      Row({ space: 9 }) {
        if (item.avatar.length > 0) {
          ImageKnifeComponent({ imageKnifeOption: { loadSrc: item.avatar, objectFit: ImageFit.Cover } })
            .width(isReply ? 30 : 38).height(isReply ? 30 : 38).borderRadius(19)
        } else {
          Text(item.userName.substring(0, 1)).width(isReply ? 30 : 38).height(isReply ? 30 : 38)
            .borderRadius(19).textAlign(TextAlign.Center).fontSize(this.readerSize(15))
            .fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.bg_page'))
        }
        Column({ space: 3 }) {
          Row({ space: 7 }) {
            Text(item.userName).fontSize(this.readerSize(15)).fontWeight(this.readerWeight(FontWeight.Medium))
              .fontColor($r('app.color.text_primary')).maxLines(1)
            if (item.score > 0) {
              Text(`${item.score} 分`).fontSize(this.readerSize(13)).fontColor($r('app.color.brand_primary'))
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .backgroundColor($r('app.color.bg_page')).borderRadius(5)
            }
          }.width('100%')
          Text(item.date.length > 0 ? item.date : '虎扑评分评论')
            .fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (item.lightCount > 0) {
          Text(`✦ ${this.formatCount(item.lightCount)}`).fontSize(this.readerSize(13))
            .fontColor($r('app.color.text_tertiary'))
        }
      }.width('100%').alignItems(VerticalAlign.Center)
      Text(item.content.length > 0 ? item.content : '（图片或表情内容）')
        .fontSize(this.readerSize(isReply ? 15 : 16))
        .fontWeight(this.readerWeight(FontWeight.Normal))
        .fontColor($r('app.color.text_primary'))
        .width('100%').lineHeight(isReply ? 22 : 24)
      if (!isReply && (item.subCommentCount > 0 || item.descendantCount > 0)) {
        Row({ space: 5 }) {
          Text(`${this.formatCount(item.descendantCount > 0 ? item.descendantCount : item.subCommentCount)} 条回复`)
            .fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
          Text('›').fontSize(this.readerSize(16)).fontColor($r('app.color.brand_primary'))
        }.width('100%').onClick(() => this.openReplies(item))
      }
    }
    .width('100%').padding(Spacing.md)
    .backgroundColor(isReply ? $r('app.color.bg_page') : $r('app.color.bg_card'))
    .borderRadius(Radius.md)
  }

  @Builder
  ReplySheetBuilder() {
    Column({ space: 0 }) {
      Row() {
        Text('×').fontSize(this.readerSize(28)).fontColor($r('app.color.text_secondary')).width(36)
          .onClick(() => this.showReplySheet = false)
        Text('查看回复').fontSize(this.readerSize(19)).fontWeight(this.readerWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary')).layoutWeight(1).textAlign(TextAlign.Center)
        Text(' ').width(36)
      }.width('100%').height(46).alignItems(VerticalAlign.Center)
      Scroll() {
        Column({ space: 12 }) {
          this.CommentCard(this.selectedComment, false)
          Divider().color($r('app.color.divider'))
          Row() {
            Text(`全部回复${this.selectedComment.descendantCount > 0 ? ` / ${this.selectedComment.descendantCount}` : ''}`)
              .fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor($r('app.color.text_primary')).layoutWeight(1)
            Row({ space: 4 }) {
              Text('最亮').fontSize(this.readerSize(13)).fontColor(this.replyOrder === 'hot' ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .padding({ left: 9, right: 9, top: 6, bottom: 6 })
                .backgroundColor(this.replyOrder === 'hot' ? $r('app.color.bg_card') : $r('app.color.bg_page'))
                .onClick(() => this.setReplyOrder('hot'))
              Text('最早').fontSize(this.readerSize(13)).fontColor(this.replyOrder === 'old' ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .padding({ left: 9, right: 9, top: 6, bottom: 6 })
                .backgroundColor(this.replyOrder === 'old' ? $r('app.color.bg_card') : $r('app.color.bg_page'))
                .onClick(() => this.setReplyOrder('old'))
            }
          }.width('100%').alignItems(VerticalAlign.Center)
          if (this.repliesLoading) {
            Row() { LoadingProgress().width(19).height(19).color($r('app.color.brand_primary')) }
              .width('100%').justifyContent(FlexAlign.Center).padding(Spacing.xl)
          } else if (this.replies.length === 0) {
            Column({ space: 7 }) {
              Text(this.repliesError.length > 0 ? this.repliesError : '暂时没有更多回复')
                .fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary'))
              if (this.repliesError.length > 0) {
                Text('点击重试').fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
                  .onClick(() => this.loadReplies(true))
              }
            }.width('100%').padding(Spacing.lg).alignItems(HorizontalAlign.Center)
          } else {
            ForEach(this.replies, (reply: LolRatingComment) => {
              this.CommentCard(reply, true)
            }, (reply: LolRatingComment) => `rating_reply_${reply.commentId}`)
            if (this.repliesLoadingMore) {
              LoadingProgress().width(16).height(16).color($r('app.color.brand_primary'))
                .width('100%').margin({ top: 8, bottom: 8 })
            } else if (this.repliesHasMore) {
              Text('加载更多回复').fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
                .width('100%').textAlign(TextAlign.Center).padding(Spacing.md)
                .onClick(() => this.loadReplies(false))
            }
          }
        }.width('100%').padding({ left: Spacing.md, right: Spacing.md, bottom: Spacing.xl })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
    .width('100%').height('100%').padding({ bottom: 12 })
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    NavDestination() {
      Column() {
        AppNavBar({ title: '选手评分与评论' })
        if (this.loading) {
          Column() { LoadingProgress().width(22).height(22).color($r('app.color.brand_primary')) }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 12 }) {
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage).fontSize(this.readerSize(14)).fontColor($r('app.color.text_tertiary'))
                  .width('100%').textAlign(TextAlign.Center)
              }
              this.PlayerHeader()
              Row() {
                Text(`亮回复 / ${this.formatCount(this.commentTotal > 0 ? this.commentTotal : this.player.commentCount)}`)
                  .fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor($r('app.color.text_primary')).layoutWeight(1)
                Row({ space: 4 }) {
                  this.SortChip('最亮', 'hot')
                  this.SortChip('最新', 'new')
                  this.SortChip('最早', 'old')
                }
              }.width('100%').alignItems(VerticalAlign.Center)
              if (this.commentsLoading && this.comments.length === 0) {
                Column() { LoadingProgress().width(18).height(18).color($r('app.color.brand_primary')) }
                  .width('100%').padding(Spacing.xl)
              } else if (this.comments.length === 0) {
                Column({ space: 8 }) {
                  Text(this.errorMessage.length > 0 ? this.errorMessage : '还没有评分评论')
                    .fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary'))
                  if (this.errorMessage.length > 0) {
                    Text('重新加载').fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
                      .onClick(() => this.loadComments(true))
                  }
                }.width('100%').padding(Spacing.lg).alignItems(HorizontalAlign.Center)
              } else {
                ForEach(this.comments, (item: LolRatingComment) => {
                  this.CommentCard(item, false)
                }, (item: LolRatingComment) => `rating_comment_${item.commentId}`)
                if (this.loadingMore) {
                  LoadingProgress().width(17).height(17).color($r('app.color.brand_primary'))
                    .width('100%').margin({ top: 8, bottom: 8 })
                } else if (this.commentsHasMore) {
                  Text('加载更多评论').fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary'))
                    .width('100%').textAlign(TextAlign.Center).padding(Spacing.md)
                    .onClick(() => this.loadComments(false))
                }
              }
            }.width('100%').padding(Spacing.md)
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
      .bindSheet($$this.showReplySheet, this.ReplySheetBuilder(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        preferType: SheetType.BOTTOM,
        title: { title: '查看回复' },
        backgroundColor: $r('app.color.bg_page')
      })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
