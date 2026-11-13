import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'hupluna_history';
const KEY_ITEMS: string = 'items';
/** 最多保留的浏览记录条数 */
const MAX_ITEMS: number = 300;

/** 一条浏览记录（同时也是"已读"凭证：存在于记录里即视为读过） */
export class HistoryEntry {
  tid: string = '';
  title: string = '';
  author: string = '';
  tag: string = '';
  cover: string = '';
  replies: number = 0;
  /** 最近一次打开时间（ms） */
  openedAt: number = 0;
}

/**
 * 浏览历史 / 已读状态
 *
 * - 内存里维护「记录列表 + tid 已读集合」，信息流首帧即可判断已读（无需异步等待）
 * - 启动时由 EntryAbility 在 loadContent 之前同步读盘（restoreSync）
 * - 写入为整表覆盖（最多 300 条，Preferences 单值上限 16MB 足够）
 */
export class HistoryStore {
  private static entries: HistoryEntry[] = [];
  private static readSet: Set<string> = new Set<string>();
  private static loaded: boolean = false;
  private static pref: preferences.Preferences | null = null;

  /** 同步读盘（EntryAbility 首帧前调用，保证信息流首屏就能标已读） */
  static restoreSync(context: common.Context): void {
    if (HistoryStore.loaded) {
      return;
    }
    try {
      const pref: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
      HistoryStore.pref = pref;
      const raw: preferences.ValueType = pref.getSync(KEY_ITEMS, '');
      const s: string = raw as string;
      if (s && s.length > 0) {
        const parsed: HistoryEntry[] = JSON.parse(s) as HistoryEntry[];
        HistoryStore.entries = parsed !== null && parsed.length > 0 ? parsed : [];
        HistoryStore.rebuildReadSet();
      }
      HistoryStore.loaded = true;
    } catch (e) {
      // 读盘失败时保持空列表，不影响启动
    }
  }

  /** 懒加载兜底（页面直接调用时） */
  static async ensureLoaded(context: common.Context): Promise<void> {
    if (HistoryStore.loaded) {
      return;
    }
    HistoryStore.restoreSync(context);
  }

  private static rebuildReadSet(): void {
    HistoryStore.readSet.clear();
    for (const e of HistoryStore.entries) {
      if (e.tid.length > 0) {
        HistoryStore.readSet.add(e.tid);
      }
    }
  }

  static isRead(tid: string): boolean {
    return tid.length > 0 && HistoryStore.readSet.has(tid);
  }

  static count(): number {
    return HistoryStore.entries.length;
  }

  /** 广播变更（我的页的记录数、信息流的已读状态据此刷新） */
  private static bump(): void {
    AppStorage.setOrCreate<number>('historyVersion', Date.now());
  }

  static list(): HistoryEntry[] {
    return HistoryStore.entries.slice();
  }

  /**
   * 记录一次打开（同时标记已读）。
   * 同一 tid 只保留一条，重复打开会更新标题等信息并移到最前。
   */
  static record(context: common.Context, tid: string, title: string, author: string, tag: string,
    cover: string, replies: number): void {
    if (tid.length === 0) {
      return;
    }
    let entry: HistoryEntry | null = null;
    for (const e of HistoryStore.entries) {
      if (e.tid === tid) {
        entry = e;
        break;
      }
    }
    if (entry === null) {
      entry = new HistoryEntry();
      entry.tid = tid;
    }
    // 详情页拿到的字段更全；空值不覆盖已有值
    if (title.length > 0) entry.title = title;
    if (author.length > 0) entry.author = author;
    if (tag.length > 0) entry.tag = tag;
    if (cover.length > 0) entry.cover = cover;
    if (replies > 0) entry.replies = replies;
    entry.openedAt = Date.now();
    // 移到最前
    const rest: HistoryEntry[] = [];
    for (const e of HistoryStore.entries) {
      if (e.tid !== tid) {
        rest.push(e);
      }
    }
    rest.unshift(entry);
    while (rest.length > MAX_ITEMS) {
      rest.pop();
    }
    HistoryStore.entries = rest;
    HistoryStore.readSet.add(tid);
    HistoryStore.persist(context);
    HistoryStore.bump();
  }

  static remove(context: common.Context, tid: string): void {
    const rest: HistoryEntry[] = [];
    for (const e of HistoryStore.entries) {
      if (e.tid !== tid) {
        rest.push(e);
      }
    }
    HistoryStore.entries = rest;
    HistoryStore.rebuildReadSet();
    HistoryStore.persist(context);
    HistoryStore.bump();
  }

  static clear(context: common.Context): void {
    HistoryStore.entries = [];
    HistoryStore.readSet.clear();
    HistoryStore.persist(context);
    HistoryStore.bump();
  }

  private static persist(context: common.Context): void {
    try {
      let pref: preferences.Preferences | null = HistoryStore.pref;
      if (pref === null) {
        pref = preferences.getPreferencesSync(context, { name: STORE_NAME });
        HistoryStore.pref = pref;
      }
      pref.putSync(KEY_ITEMS, JSON.stringify(HistoryStore.entries));
      pref.flush();
    } catch (e) {
    }
  }
}
