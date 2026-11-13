import { HistoryEntry, HistoryStore } from '../database/HistoryStore';
import { AppNavBar } from '../views/AppNavBar';
import { Spacing, Radius, RouteName } from '../common/Theme';
import { formatTime, thumbUrl } from '../common/Utils';
import { ImageKnifeComponent } from '@ohos/imageknife';
import { common } from '@kit.AbilityKit';

/** 浏览历史（同时是所有"已读"帖子的完整列表） */
@Component
export struct HistoryPage {
  @Consume('pageStack') pageStack: NavPathStack;
  @State items: HistoryEntry[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private getCtx(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private async reload(): Promise<void> {
    await HistoryStore.ensureLoaded(this.getCtx());
    this.items = HistoryStore.list();
  }

  private open(item: HistoryEntry): void {
    this.pageStack.pushPathByName(RouteName.POST_DETAIL, item.tid, () => {
      this.reload();
    });
  }

  private removeOne(tid: string): void {
    HistoryStore.remove(this.getCtx(), tid);
    this.items = HistoryStore.list();
  }

  private clearAll(): void {
    this.getUIContext().showAlertDialog({
      title: '清空浏览历史',
      message: '清空后所有帖子的"已读"标记也会一并清除。',
      autoCancel: true,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.brand_primary'),
        action: () => {
          HistoryStore.clear(this.getCtx());
          this.items = [];
        }
      }
    });
  }

  /** 打开时间：今日/近 7 天用相对时间，更早显示日期 */
  private openedText(item: HistoryEntry): string {
    if (item.openedAt <= 0) {
      return '';
    }
    return formatTime(Math.floor(item.openedAt / 1000));
  }

  @Builder
  HistoryRow(item: HistoryEntry) {
    Row({ space: 10 }) {
      Column({ space: 6 }) {
        Text(item.title.length > 0 ? item.title : `帖子 ${item.tid}`)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          if (item.tag.length > 0) {
            Text(item.tag)
              .fontSize(11)
              .fontColor($r('app.color.brand_primary'))
              .maxLines(1)
          }
          Text(item.author.length > 0 ? item.author : '虎扑JR')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.openedText(item))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text('移除')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.tag_bg'))
            .borderRadius(9)
            .onClick(() => {
              this.removeOne(item.tid);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (item.cover.length > 0) {
        ImageKnifeComponent({
          imageKnifeOption: {
            loadSrc: thumbUrl(item.cover, 200),
            objectFit: ImageFit.Cover,
            border: { radius: Radius.sm }
          }
        })
          .width(64)
          .height(48)
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_feed'))
    .onClick(() => {
      this.open(item);
    })
  }

  build() {
    NavDestination() {
      Column() {
        AppNavBar({ title: '浏览历史' })
        if (this.items.length === 0) {
          Column({ space: 10 }) {
            Text('还没有浏览记录')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
            Text('打开过的帖子会出现在这里，并在信息流里标记为已读')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ left: Spacing.xl, right: Spacing.xl })
        } else {
          Row({ space: 8 }) {
            Text(`共 ${this.items.length} 条`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text('清空')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .backgroundColor($r('app.color.tag_bg'))
              .borderRadius(13)
              .onClick(() => {
                this.clearAll();
              })
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: 4, bottom: 8 })

          List({ space: 0 }) {
            ForEach(this.items, (item: HistoryEntry) => {
              ListItem() {
                Column() {
                  this.HistoryRow(item)
                  Divider().color($r('app.color.divider')).margin({ left: Spacing.lg })
                }
              }
            }, (item: HistoryEntry) => `history_${item.tid}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .backgroundColor($r('app.color.bg_feed'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onShown(() => {
      this.reload();
    })
  }
}
