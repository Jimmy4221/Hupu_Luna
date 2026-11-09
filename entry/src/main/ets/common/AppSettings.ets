/**
 * 应用偏好设置（Preferences 持久化 + AppStorage 全局同步）
 *
 * - 图片磁盘缓存上限：默认 512MB，设置页可自定义
 * - 播放设置：信息流（首页推荐）是否自动播放 / 打开帖子是否自动播放
 *
 * 所有值在 EntryAbility 首帧前同步写入 AppStorage，页面用 @StorageLink 直接读，
 * 无需等异步恢复，避免首帧用默认值导致"开关是关的却先播了一帧"。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ImageKnife } from '@ohos/imageknife';

const STORE_NAME: string = 'hupluna_settings';
const KEY_IMAGE_CACHE_MB: string = 'image_cache_mb';
const KEY_AUTOPLAY_FEED: string = 'autoplay_feed';
const KEY_AUTOPLAY_POST: string = 'autoplay_post';
const KEY_READER_FONT_SCALE: string = 'reader_font_scale';
const KEY_READER_FONT_WEIGHT: string = 'reader_font_weight';

/** AppStorage 键（页面 @StorageLink 同名读取） */
export class SettingsKey {
  static readonly IMAGE_CACHE_MB: string = 'imageCacheMb';
  static readonly AUTOPLAY_FEED: string = 'autoplayFeed';
  static readonly AUTOPLAY_POST: string = 'autoplayPost';
  static readonly READER_FONT_SCALE: string = 'readerFontScale';
  static readonly READER_FONT_WEIGHT: string = 'readerFontWeight';
}

/** 缓存上限默认/边界（MB） */
export const DEFAULT_CACHE_MB: number = 512;
export const MIN_CACHE_MB: number = 64;
export const MAX_CACHE_MB: number = 4096;
/** 常用档位（长按弹出的快捷选项） */
export const CACHE_PRESETS: number[] = [128, 256, 512, 1024, 2048];

export class AppSettings {
  private static pref(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: STORE_NAME });
  }

  /** 首帧前同步恢复全部设置到 AppStorage（EntryAbility 调用） */
  static restore(context: common.Context): void {
    let cacheMb: number = DEFAULT_CACHE_MB;
    let feed: boolean = true;
    let post: boolean = true;
    let readerFontScale: number = 0;
    let readerFontWeight: number = 0;
    try {
      const pref: preferences.Preferences = AppSettings.pref(context);
      cacheMb = AppSettings.clampMb(Number(pref.getSync(KEY_IMAGE_CACHE_MB, DEFAULT_CACHE_MB) as number));
      feed = pref.getSync(KEY_AUTOPLAY_FEED, true) as boolean;
      post = pref.getSync(KEY_AUTOPLAY_POST, true) as boolean;
      readerFontScale = AppSettings.clampChoice(Number(pref.getSync(KEY_READER_FONT_SCALE, 0) as number), 4);
      readerFontWeight = AppSettings.clampChoice(Number(pref.getSync(KEY_READER_FONT_WEIGHT, 0) as number), 3);
    } catch (e) {
    }
    AppStorage.setOrCreate<number>(SettingsKey.IMAGE_CACHE_MB, cacheMb);
    AppStorage.setOrCreate<boolean>(SettingsKey.AUTOPLAY_FEED, feed);
    AppStorage.setOrCreate<boolean>(SettingsKey.AUTOPLAY_POST, post);
    AppStorage.setOrCreate<number>(SettingsKey.READER_FONT_SCALE, readerFontScale);
    AppStorage.setOrCreate<number>(SettingsKey.READER_FONT_WEIGHT, readerFontWeight);
  }

  /** 读取当前缓存上限（MB） */
  static imageCacheMb(): number {
    const v: number | undefined = AppStorage.get<number>(SettingsKey.IMAGE_CACHE_MB);
    return AppSettings.clampMb(v === undefined ? DEFAULT_CACHE_MB : v);
  }

  /** 缓存上限规整到合法区间（非法值回退默认） */
  static clampMb(v: number): number {
    if (!Number.isFinite(v) || v <= 0) {
      return DEFAULT_CACHE_MB;
    }
    const n: number = Math.floor(v);
    if (n < MIN_CACHE_MB) {
      return MIN_CACHE_MB;
    }
    if (n > MAX_CACHE_MB) {
      return MAX_CACHE_MB;
    }
    return n;
  }

  /**
   * 按上限初始化 ImageKnife 磁盘缓存。
   * 文件数按 ~128KB/张 估算（上限 MB × 8），保证"张数上限"与"容量上限"不互相打架。
   */
  static async applyImageCache(context: common.Context, mb: number): Promise<void> {
    const size: number = AppSettings.clampMb(mb);
    const maxFiles: number = Math.max(256, size * 8);
    try {
      await ImageKnife.getInstance().initFileCache(context, maxFiles, size * 1024 * 1024);
    } catch (e) {
    }
  }

  /** 保存缓存上限并立即生效 */
  static async setImageCacheMb(context: common.Context, mb: number): Promise<void> {
    const size: number = AppSettings.clampMb(mb);
    AppStorage.setOrCreate<number>(SettingsKey.IMAGE_CACHE_MB, size);
    await AppSettings.applyImageCache(context, size);
    try {
      const pref: preferences.Preferences = AppSettings.pref(context);
      await pref.put(KEY_IMAGE_CACHE_MB, size);
      await pref.flush();
    } catch (e) {
    }
  }

  /** 信息流自动播放开关 */
  static async setAutoPlayFeed(context: common.Context, on: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(SettingsKey.AUTOPLAY_FEED, on);
    try {
      const pref: preferences.Preferences = AppSettings.pref(context);
      await pref.put(KEY_AUTOPLAY_FEED, on);
      await pref.flush();
    } catch (e) {
    }
  }

  /** 打开帖子自动播放开关 */
  static async setAutoPlayPost(context: common.Context, on: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(SettingsKey.AUTOPLAY_POST, on);
    try {
      const pref: preferences.Preferences = AppSettings.pref(context);
      await pref.put(KEY_AUTOPLAY_POST, on);
      await pref.flush();
    } catch (e) {
    }
  }

  /** Post-detail reading size: 0 follows current system setting; 1–4 are custom sizes. */
  static async setReaderFontScale(context: common.Context, choice: number): Promise<void> {
    const value: number = AppSettings.clampChoice(choice, 4);
    AppStorage.setOrCreate<number>(SettingsKey.READER_FONT_SCALE, value);
    try {
      const pref: preferences.Preferences = AppSettings.pref(context);
      await pref.put(KEY_READER_FONT_SCALE, value);
      await pref.flush();
    } catch (e) {
    }
  }

  /** Post-detail reading weight: 0 follows current system setting; 1–3 are custom weights. */
  static async setReaderFontWeight(context: common.Context, choice: number): Promise<void> {
    const value: number = AppSettings.clampChoice(choice, 3);
    AppStorage.setOrCreate<number>(SettingsKey.READER_FONT_WEIGHT, value);
    try {
      const pref: preferences.Preferences = AppSettings.pref(context);
      await pref.put(KEY_READER_FONT_WEIGHT, value);
      await pref.flush();
    } catch (e) {
    }
  }

  private static clampChoice(value: number, max: number): number {
    if (!Number.isFinite(value)) return 0;
    return Math.max(0, Math.min(max, Math.floor(value)));
  }
}
