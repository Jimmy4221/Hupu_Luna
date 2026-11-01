import { HttpManager, RequestOptions, ExtraHeaders } from './HttpManager';
import { SessionManager } from './SessionManager';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
/** 与 EntryAbility / SessionManager 同一个 Preferences 库 */
const SETTINGS_STORE: string = 'hupluna_settings';
/** 本人权威资料落盘键（下次启动先读它，秒出真实数字，再由网络刷新） */
const KEY_SELF_CARD: string = 'self_card_json';

/** 我的页个人信息（m.hupu.com/my SSR 解析） */
export class MyProfile {
  avatar: string = '';
  username: string = '';
  level: string = '';
  calories: string = '';
  regDate: string = '';
  gender: string = '';
  selfIntro: string = '';
  joinedDays: number = 0;
  /** 主题帖数（userInfoData.bbs_post_count，全站总数） */
  threadCount: number = 0;
  /** 回帖数（userInfoData.bbs_msg_count，全站总数） */
  replyCount: number = 0;
  /** 声望（userInfoData.reputation.value） */
  reputation: number = 0;
  /** 等级文案（如 Lv.2 / MAX） */
  levelDesc: string = '';
  /** 资料是否来自权威源（用户主页 userInfoData，而非 /my 正则兜底） */
  fromCard: boolean = false;
}

/* ---- m.hupu.com/user/{puid} 内嵌 userInfoData（公开页，字段权威） ---- */

interface ReputationDto {
  value?: number;
}

interface UserInfoCardDto {
  nickname?: string;
  header?: string;
  reputation?: ReputationDto | null;
  /** 主题帖数 */
  bbs_post_count?: number;
  /** 回帖数 */
  bbs_msg_count?: number;
  /** 等级文案 */
  bbsUserLevelDesc?: string;
  level?: number;
  /** 加入天数文案，如「加入虎扑295天」 */
  reg_time_str?: string;
  gender?: number;
  /** 点亮数 */
  be_light_count?: number;
}

interface UserCardPagePropsDto {
  userInfoData?: UserInfoCardDto;
}

interface UserCardDataDto {
  pageProps?: UserCardPagePropsDto;
}

interface UserCardRespDto {
  props?: UserCardDataDto;
}

/** 我的主题帖/回帖条目（m 站 userthreads/userreplies SSR 解析） */
export class MyThreadItem {
  tid: string = '';
  title: string = '';
  lights: number = 0;
  replies: number = 0;
}

/**
 * m 站“我的”域接口（SSR 页面解析，需登录 Cookie）
 * - m.hupu.com/my：头像/昵称/等级/卡路里
 * - m.hupu.com/my/userdetail：数字ID/性别/注册时间/自我介绍
 * - m.hupu.com/my/userthreads / userreplies：主题帖/回帖流
 */
export class MyApi {
  /** 用户主页卡片缓存（puid → 资料）：我的页 / 个人主页共用，避免重复请求也避免一次失败长期显示 0 */
  private static cardCache: Map<string, MyProfile> = new Map();
  /** 进行中的请求（puid → Promise），同一用户只发一次 */
  private static cardInflight: Map<string, Promise<MyProfile | null>> = new Map();

  /** Preferences 句柄（全局上下文缺失时返回 null） */
  private static pref(): preferences.Preferences | null {
    try {
      const ctx: common.Context | undefined = AppStorage.get<common.Context>('appContext');
      if (ctx === undefined) {
        return null;
      }
      return preferences.getPreferencesSync(ctx, { name: SETTINGS_STORE });
    } catch (e) {
      return null;
    }
  }

  /** 落盘本人权威资料（同步写，供下次冷启动秒出） */
  private static saveSelfCard(p: MyProfile): void {
    try {
      const pref: preferences.Preferences | null = MyApi.pref();
      if (pref === null) {
        return;
      }
      pref.putSync(KEY_SELF_CARD, JSON.stringify(p));
      pref.flush();
    } catch (e) {
    }
  }

  /**
   * 同步读上次落盘的本人资料（启动首帧即可用，无网也能显示真实数字）。
   * 返回 null 表示从未成功获取过。
   */
  static loadSelfCard(): MyProfile | null {
    try {
      const pref: preferences.Preferences | null = MyApi.pref();
      if (pref === null) {
        return null;
      }
      const s: string = pref.getSync(KEY_SELF_CARD, '') as string;
      if (s.length === 0) {
        return null;
      }
      const o = JSON.parse(s) as MyProfile;
      if (!o || o.username === undefined) {
        return null;
      }
      const p: MyProfile = new MyProfile();
      p.avatar = o.avatar ?? '';
      p.username = o.username ?? '';
      p.level = o.level ?? '';
      p.calories = o.calories ?? '';
      p.regDate = o.regDate ?? '';
      p.gender = o.gender ?? '';
      p.selfIntro = o.selfIntro ?? '';
      p.joinedDays = o.joinedDays ?? 0;
      p.threadCount = o.threadCount ?? 0;
      p.replyCount = o.replyCount ?? 0;
      p.reputation = o.reputation ?? 0;
      p.levelDesc = o.levelDesc ?? '';
      p.fromCard = true;
      return p;
    } catch (e) {
      return null;
    }
  }

  /** 只读内存缓存（同步，不发请求）；没有返回 null */
  static cachedCard(puid: string): MyProfile | null {
    const c: MyProfile | undefined = MyApi.cardCache.get(puid);
    return c === undefined ? null : c;
  }

  /** 退出登录时清掉落盘资料 */
  static clearSelfCard(): void {
    MyApi.cardCache = new Map<string, MyProfile>();
    try {
      const pref: preferences.Preferences | null = MyApi.pref();
      if (pref === null) {
        return;
      }
      pref.deleteSync(KEY_SELF_CARD);
      pref.flush();
    } catch (e) {
    }
  }

  private static async getHtml(path: string): Promise<string> {
    const cookie: string = SessionManager.cookieHeader();
    if (cookie.length === 0) {
      throw new Error('未登录');
    }
    const url: string = `https://m.hupu.com${path}`;
    const opts: RequestOptions = new RequestOptions();
    opts.ua = MOBILE_UA;
    const h: ExtraHeaders = new ExtraHeaders();
    h.cookie = cookie;
    opts.headers = h;
    return HttpManager.request(url, opts);
  }

  /** 取页面 HTML，失败返回空串（不抛），withCookie=false 走匿名请求（公开页） */
  private static async tryHtml(path: string, withCookie: boolean): Promise<string> {
    try {
      if (withCookie) {
        return await MyApi.getHtml(path);
      }
      return await HttpManager.get(`https://m.hupu.com${path}`, MOBILE_UA);
    } catch (e) {
      return '';
    }
  }

  /** 解析 __NEXT_DATA__ 里的 userInfoData；结构不符返回 null */
  private static parseCard(html: string): MyProfile | null {
    if (html.length === 0) {
      return null;
    }
    const marker: string = '__NEXT_DATA__';
    const i: number = html.indexOf(marker);
    if (i < 0) {
      return null;
    }
    const s: number = html.indexOf('>', i) + 1;
    const e: number = html.indexOf('</script>', s);
    if (s <= 0 || e <= s) {
      return null;
    }
    let resp: UserCardRespDto;
    try {
      resp = JSON.parse(html.substring(s, e)) as UserCardRespDto;
    } catch (err) {
      return null;
    }
    const u = resp.props?.pageProps?.userInfoData;
    if (!u) {
      return null;
    }
    const p: MyProfile = new MyProfile();
    p.fromCard = true;
    p.avatar = u.header ?? '';
    p.username = u.nickname ?? '';
    p.threadCount = u.bbs_post_count ?? 0;
    p.replyCount = u.bbs_msg_count ?? 0;
    p.reputation = u.reputation?.value ?? 0;
    p.levelDesc = u.bbsUserLevelDesc ?? '';
    p.level = p.levelDesc.length > 0 ? p.levelDesc : (u.level === undefined ? '' : `Lv.${u.level}`);
    // 「加入虎扑295天」
    const reg: string = u.reg_time_str ?? '';
    const dm = reg.match(/(\d+)\s*天/);
    if (dm !== null) {
      p.joinedDays = Number(dm[1]);
    }
    p.gender = u.gender === 1 ? '男' : (u.gender === 2 ? '女' : '');
    return p;
  }

  /**
   * 权威资料：m.hupu.com/user/{puid} 公开页 userInfoData。
   * 一次请求拿到主题帖数 / 回帖数 / 声望 / 等级 / 加入天数。
   *
   * 稳定性：启动瞬间请求容易与首页等请求抢占连接而失败，
   * 这里先带 Cookie 取一次，失败再匿名取一次（公开页，他人主页走的正是这条路），
   * 成功后写入静态缓存，我的页与个人主页共用同一份数据。
   */
  static async getUserCard(puid: string): Promise<MyProfile | null> {
    if (puid.length === 0) {
      return null;
    }
    const cached: MyProfile | undefined = MyApi.cardCache.get(puid);
    if (cached !== undefined) {
      return cached;
    }
    // 同一 puid 并发调用共享一次请求（我的页 + 个人主页 + 重试可能同时触发）
    const inflight: Promise<MyProfile | null> | undefined = MyApi.cardInflight.get(puid);
    if (inflight !== undefined) {
      return inflight;
    }
    const task: Promise<MyProfile | null> = MyApi.fetchCard(puid);
    MyApi.cardInflight.set(puid, task);
    const p: MyProfile | null = await task;
    MyApi.cardInflight.delete(puid);
    return p;
  }

  /**
   * 实际抓取：**先匿名**再带 Cookie。
   * 匿名访问的是公开资料页（他人主页走的正是这条路，实测稳定）；
   * 带登录态时页面可能返回 is_self 变体，字段反而不全，故放在兜底位置。
   */
  private static async fetchCard(puid: string): Promise<MyProfile | null> {
    let p: MyProfile | null = MyApi.parseCard(await MyApi.tryHtml(`/user/${puid}`, false));
    if (p === null) {
      p = MyApi.parseCard(await MyApi.tryHtml(`/user/${puid}`, true));
    }
    if (p !== null && p.username.length > 0) {
      MyApi.cardCache.set(puid, p);
      return p;
    }
    return null;
  }

  /**
   * 我的资料（优先权威用户主页，回退 my + userdetail 正则）
   * @param puid    首选用户 id（/api/v2/user 的 puid）
   * @param altPuid 备选 id（uid）；puid 取不到时再试一次，兼容老账号两者不一致
   */
  static async getMyProfile(puid: string = '', altPuid: string = ''): Promise<MyProfile> {
    // 优先：用户主页 userInfoData（数字准确）。
    // 冷启动时该请求与首页热帖流抢占连接，较易失败，这里做 3 轮递增退避重试。
    const backoff: number[] = [400, 1200, 3000];
    for (let attempt: number = 0; attempt < backoff.length; attempt++) {
      if (backoff[attempt] > 0) {
        await MyApi.sleep(backoff[attempt]);
      }
      try {
        const card: MyProfile | null = await MyApi.getUserCard(puid);
        if (card !== null) {
          MyApi.saveSelfCard(card);
          return card;
        }
      } catch (e) {
      }
      if (altPuid.length > 0 && altPuid !== puid) {
        try {
          const alt: MyProfile | null = await MyApi.getUserCard(altPuid);
          if (alt !== null) {
            MyApi.saveSelfCard(alt);
            return alt;
          }
        } catch (e) {
        }
      }
    }
    const homeHtml: string = await MyApi.getHtml('/my');
    const p: MyProfile = new MyProfile();
    // 头像：url(...) 内地址
    const av = homeHtml.match(/class="avatar"\s+style="background-image:\s*url\(([^)]+)\)/);
    if (av !== null) {
      p.avatar = av[1];
    }
    const nm = homeHtml.match(/<div class="name">\s*([^<]+?)\s*<\/div>/);
    if (nm !== null) {
      p.username = nm[1];
    }
    const lv = homeHtml.match(/<div class="level">([^<]*?)<\/div>/);
    if (lv !== null) {
      p.level = lv[1].replace(/&nbsp;/g, ' ').trim();
    }
    const cal = homeHtml.match(/<div class="calories">([^<]*?)<\/div>/);
    if (cal !== null) {
      p.calories = cal[1].replace(/&nbsp;/g, ' ').trim();
    }
    // userdetail：注册时间等
    try {
      const dHtml: string = await MyApi.getHtml('/my/userdetail');
      const reg = dHtml.match(/注册时间\s*<\/[^>]+>\s*<[^>]+>\s*([0-9\-: ]+)/);
      if (reg !== null) {
        p.regDate = reg[1].trim();
        const ts = Date.parse(p.regDate.replace(/-/g, '/'));
        if (!Number.isNaN(ts)) {
          p.joinedDays = Math.max(0, Math.floor((Date.now() - ts) / 86400000));
        }
      }
      const g = dHtml.match(/性别\s*<\/[^>]+>\s*<[^>]+>\s*([^<\s]+)/);
      if (g !== null) {
        p.gender = g[1].trim();
      }
      // userdetail 兜底：论坛等级 / 银行现金（卡路里）——真机 home 页部分字段缺失
      const lv2 = dHtml.match(/论坛等级\s*<\/[^>]+>\s*<[^>]+>\s*([^<]+?)\s*</);
      if (lv2 !== null && p.level.length === 0) {
        p.level = lv2[1].trim();
      }
      if (lv2 !== null && p.level.length === 0) {
        p.level = '论坛等级 ' + lv2[1].trim();
      }
      const cal2 = dHtml.match(/(?:银行现金|卡路里)\s*<\/[^>]+>\s*<[^>]+>\s*([^<]+?)\s*</);
      if (cal2 !== null && p.calories.length === 0) {
        p.calories = cal2[1].trim();
      }
    } catch (e) {
    }
    // 注：不再用 userthreads/userreplies 的当页条数冒充总数（那只是 20 条上限），
    // 卡片拿不到时计数保持 0 并由 fromCard=false 标记，页面显示「—」而不是假数字。
    return p;
  }

  /** 延时（重试退避用） */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 从 userthreads / userreplies 页解析帖子流 */
  static async getMyThreads(path: string): Promise<MyThreadItem[]> {
    const html: string = await MyApi.getHtml(path);
    const result: MyThreadItem[] = [];
    // 逐 <li> 块解析
    const blocks = html.match(/<a href="\/\/m\.hupu\.com\/bbs\/(\d+)\.html"[^>]*class="bbs-list-a"[\s\S]*?<\/a>/g) || [];
    for (const block of blocks) {
      const item: MyThreadItem = new MyThreadItem();
      const tid = block.match(/bbs\/(\d+)\.html/);
      if (tid === null) {
        continue;
      }
      item.tid = tid[1];
      const title = block.match(/<h3>([\s\S]*?)<\/h3>/);
      item.title = title !== null ? title[1].trim() : '';
      const bright = block.match(/class="bright-no">(\d+)</);
      item.lights = bright !== null ? Number(bright[1]) : 0;
      // icon-comment 后第一个 <span>数字</span>
      const rep = block.match(/icon-comment"[^>]*>\s*<\/i>\s*<span>(\d+)<\/span>/);
      item.replies = rep !== null ? Number(rep[1]) : 0;
      if (item.title.length > 0) {
        result.push(item);
      }
    }
    return result;
  }
}
