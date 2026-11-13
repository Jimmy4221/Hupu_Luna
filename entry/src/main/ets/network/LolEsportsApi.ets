import { HttpManager, ExtraHeaders } from './HttpManager';
import { SessionManager } from './SessionManager';
import { CacheStore, CachedPayload } from '../database/CacheStore';
import { common } from '@kit.AbilityKit';

const LPL_DATA: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_MATCH_HOMEPAGE_BMATCH_LIST_';
const HUPU_BPL: string = 'https://games.mobileapi.hupu.com/1/8.2.99/bplcommentapi/bpl';
const LPL_TEAM_LIST: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_TEAM_LIST.js';
const LPL_MEMBER_LIST: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_TEAM_MEMBER_LIST.js';
/** 虎扑「英雄联盟赛事」评分树根节点（搜索接口按 nodeId 限定范围） */
const LOL_ROOT_NODE_ID: string = '1458935';

interface LolTeamDto {
  TeamLogo?: string;
  TeamName?: string;
  TeamShortName?: string;
  TeamEnName?: string;
}

interface LolTeamListDto {
  msg?: Record<string, LolTeamDto>;
}

interface LolRatingCommentDto {
  commentId?: string | number;
  commentUserName?: string;
  commentUserHeadImg?: string;
  commentContent?: string;
  commentDate?: string;
  lightCount?: number | string;
  score?: number | string;
  publishTime?: number | string;
  subCommentCount?: number | string;
  descendantCount?: number | string;
  parentCommentId?: string | number;
  subCommentList?: LolRatingCommentDto[];
}

interface LolMemberDto {
  NickName?: string;
  GameName?: string;
  TeamId?: string | number;
  GamePlace?: string;
  UserStatus?: string | number;
}

interface LolMemberListDto {
  msg?: Record<string, LolMemberDto>;
}

class LolScoreBizKey {
  outBizType: string = '';
  outBizNo: string = '';
}

class LolScoreRequest {
  outBizKey: LolScoreBizKey = new LolScoreBizKey();
  score: number = 0;
  source: string = '';
}

export class LolFixture {
  matchId: string = '';
  eventId: string = '';
  eventName: string = '';
  teams: string = '';
  teamA: string = '';
  teamB: string = '';
  teamAId: string = '';
  teamBId: string = '';
  teamALogo: string = '';
  teamBLogo: string = '';
  scoreA: string = '';
  scoreB: string = '';
  matchTime: string = '';
  status: string = '';
  stage: string = '';
  round: string = '';
  bo: string = '';
}

export class LolMatchNode {
  bizId: string = '';
  title: string = '';
  teamA: string = '';
  teamB: string = '';
  teamAId: string = '';
  teamBId: string = '';
  teamALogo: string = '';
  teamBLogo: string = '';
  scoreA: string = '';
  scoreB: string = '';
  event: string = '';
  stage: string = '';
  matchTime: number = 0;
  status: string = '';
  /** 对局节点（match 详情里的 subNodes，省掉一次 children 请求） */
  games: LolGameNode[] = [];
}

export class LolGameNode {
  bizId: string = '';
  name: string = '';
  score: number = 0;
  boNum: number = 0;
}

/** 信息流顶部：最近一场赛果 + 下一场 */
export class LolMatchHighlights {
  last: LolFixture | null = null;
  next: LolFixture | null = null;
}

export class LolPlayerScore {
  bizId: string = '';
  name: string = '';
  kind: string = '';
  teamId: string = '';
  score: number = 0;
  votes: number = 0;
  kills: number = 0;
  deaths: number = 0;
  assists: number = 0;
  champion: string = '';
  avatar: string = '';
  ratingDistribution: number[] = [];
  commentCount: number = 0;
  featuredComment: string = '';
  featuredCommentLights: number = 0;
  label: string = '';
}

export class LolRatingComment {
  commentId: string = '';
  userName: string = '';
  avatar: string = '';
  content: string = '';
  date: string = '';
  lightCount: number = 0;
  score: number = 0;
  publishTime: number = 0;
  subCommentCount: number = 0;
  descendantCount: number = 0;
  previewReplies: LolRatingComment[] = [];
}

export class LolRatingCommentPage {
  comments: LolRatingComment[] = [];
  cursor: number = 0;
  hasMore: boolean = false;
  total: number = 0;
}

/** 比赛列表扫描进度（持久化：已命中的比赛 + 下次从哪继续） */
class LolMatchScanState {
  /** 结构版本：探测区间/字段变化时递增，避免旧缓存里的下标错位 */
  version: number = 3;
  matches: LolMatchNode[] = [];
  /** 已命中的最大 bizId 在 scanIds() 里的下标（增量探测起点） */
  lastMatchIndex: number = -1;
  savedAt: number = 0;
  /** 上次全量扫描时间（存量比赛有缺口时定期补扫） */
  fullScanAt: number = 0;
}

/** 缓存新鲜度：30 分钟内不重复扫描比赛列表 */
const MATCH_CACHE_TTL_MS: number = 30 * 60 * 1000;
/** 单局评分缓存 30 分钟（评分会持续变化） */
const SCORE_CACHE_TTL_MS: number = 30 * 60 * 1000;
/** 深刷间隔：bizId 分块之间有长空档，靠更宽的尾部窗口定期兜底新赛事 */
const DEEP_REFRESH_INTERVAL_MS: number = 12 * 3600 * 1000;
/** 常规刷新窗口：只探"最后一场之后"这一段（新比赛追加在更大的 bizId 上） */
const REFRESH_WINDOW: number = 40;
/** 深刷窗口：从最后一场一直探到当前区间末尾，兜底跨块新增的赛事 */
const DEEP_REFRESH_WINDOW: number = 200;
/** 赛程表（信息流顶部赛果/下一场）缓存时长 */
const FIXTURE_TTL_MS: number = 10 * 60 * 1000;

function textOf(value: Object | string | number | boolean | null | undefined): string {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return `${value}`;
  if (Array.isArray(value)) return value.length > 0 ? textOf(value[0]) : '';
  return '';
}

function numberOf(value: Object | string | number | boolean | null | undefined): number {
  const s: string = textOf(value);
  const n: number = Number(s);
  return Number.isFinite(n) ? n : 0;
}

function logoUrl(value: string): string {
  if (value.indexOf('//') === 0) return `https:${value}`;
  return value;
}

function mapFixture(raw: Record<string, Object>, eventId: string, logos: Map<string, string>): LolFixture {
  const item: LolFixture = new LolFixture();
  item.matchId = textOf(raw['bMatchId']);
  item.eventId = eventId;
  item.eventName = textOf(raw['GameName']);
  item.teams = textOf(raw['bMatchName']);
  const parts: string[] = item.teams.split(' vs ');
  item.teamA = textOf(raw['TeamShortNameA']) || (parts.length > 0 ? parts[0].trim() : '');
  item.teamB = textOf(raw['TeamShortNameB']) || (parts.length > 1 ? parts[1].trim() : '');
  item.teamAId = textOf(raw['TeamA']);
  item.teamBId = textOf(raw['TeamB']);
  item.teamALogo = logos.get(item.teamAId) ?? '';
  item.teamBLogo = logos.get(item.teamBId) ?? '';
  item.scoreA = textOf(raw['ScoreA']);
  item.scoreB = textOf(raw['ScoreB']);
  item.matchTime = textOf(raw['MatchDate']);
  item.status = textOf(raw['MatchStatus']);
  item.stage = textOf(raw['GameTypeName']);
  item.round = textOf(raw['GameProcName']);
  item.bo = textOf(raw['GameModeName']);
  return item;
}

/** Public LoL schedules plus Hupu's public esports rating tree. */
export class LolEsportsApi {
  private static cachedMatches: LolMatchNode[] = [];
  private static cachedTeamLogos: Map<string, string> = new Map<string, string>();
  private static cachedTeamIds: Map<string, string> = new Map<string, string>();
  private static cachedPlayerLanes: Map<string, number> = new Map<string, number>();
  /** 选手名 → 分路（忽略队伍；队伍映射失配时的兜底，避免整个分路摘要空掉） */
  private static cachedPlayerLanesByName: Map<string, number> = new Map<string, number>();
  private static memberLaneLookupReady: boolean = false;
  /** 对局/评分缓存（比赛结束后数据不变，重复打开不再请求） */
  private static memGames: Map<string, LolGameNode[]> = new Map<string, LolGameNode[]>();
  private static memScores: Map<string, LolPlayerScore[]> = new Map<string, LolPlayerScore[]>();
  /** 比赛列表扫描状态（跨启动持久化，避免每次进赛事页全量探测） */
  private static scanState: LolMatchScanState = new LolMatchScanState();
  private static scanStateLoaded: boolean = false;
  private static scanHadError: boolean = false;
  /** 同一时刻只允许一个扫描在跑（标签页切换/赛程点入可能并发触发） */
  private static scanInFlight: Promise<void> | null = null;
  /** 赛程表内存缓存（信息流顶部赛果/下一场复用） */
  private static cachedFixtures: LolFixture[] = [];
  private static fixturesAt: number = 0;

  private static async getTeamLogos(): Promise<Map<string, string>> {
    if (LolEsportsApi.cachedTeamLogos.size > 0) return LolEsportsApi.cachedTeamLogos;
    try {
      const raw: string = await HttpManager.get(LPL_TEAM_LIST);
      const eq: number = raw.indexOf('=');
      let jsonText: string = eq >= 0 ? raw.substring(eq + 1).trim() : raw.trim();
      if (jsonText.endsWith(';')) jsonText = jsonText.substring(0, jsonText.length - 1);
      const root: LolTeamListDto = JSON.parse(jsonText) as LolTeamListDto;
      const rows: Record<string, LolTeamDto> = root.msg ?? {};
      for (const id of Object.keys(rows)) {
        const url: string = logoUrl(rows[id].TeamLogo ?? '');
        if (url.length > 0) LolEsportsApi.cachedTeamLogos.set(id, url);
        const shortName: string = rows[id].TeamShortName ?? '';
        const teamName: string = rows[id].TeamName ?? '';
        const enName: string = rows[id].TeamEnName ?? '';
        if (shortName.length > 0) LolEsportsApi.cachedTeamIds.set(LolEsportsApi.normalize(shortName), id);
        if (teamName.length > 0) LolEsportsApi.cachedTeamIds.set(LolEsportsApi.normalize(teamName), id);
        if (enName.length > 0) LolEsportsApi.cachedTeamIds.set(LolEsportsApi.normalize(enName), id);
      }
    } catch (e) {
      // Keep the schedule usable if the auxiliary logo feed is unavailable.
    }
    return LolEsportsApi.cachedTeamLogos;
  }

  /** 2026 LPL, MSI and Worlds schedule files. */
  static async getFixtures(): Promise<LolFixture[]> {
    // 信息流顶部「最近赛果 / 下一场」只依赖赛程表，10 分钟内复用同一份
    if (LolEsportsApi.cachedFixtures.length > 0 && Date.now() - LolEsportsApi.fixturesAt < FIXTURE_TTL_MS) {
      return LolEsportsApi.cachedFixtures;
    }
    const eventIds: string[] = ['237', '239', '246'];
    const all: LolFixture[] = [];
    const logos: Map<string, string> = await LolEsportsApi.getTeamLogos();
    for (const eventId of eventIds) {
      try {
        const raw: string = await HttpManager.get(`${LPL_DATA}${eventId}.js`);
        const root: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        const rows: Object = root['msg'] as Object;
        if (!Array.isArray(rows)) continue;
        const fixtureRows: Object[] = rows as Object[];
        for (let i: number = 0; i < fixtureRows.length; i++) {
          const row: Record<string, Object> = fixtureRows[i] as Record<string, Object>;
          const fixture: LolFixture = mapFixture(row, eventId, logos);
          if (fixture.matchId.length > 0) all.push(fixture);
        }
      } catch (e) {
        // One event feed can be unavailable without hiding the other tournaments.
      }
    }
    all.sort((a: LolFixture, b: LolFixture): number => {
      const rank = (s: string): number => s === '1' ? 0 : (s === '2' ? 1 : 2);
      const statusDiff: number = rank(a.status) - rank(b.status);
      if (statusDiff !== 0) return statusDiff;
      if (rank(a.status) < 2) return a.matchTime.localeCompare(b.matchTime);
      return b.matchTime.localeCompare(a.matchTime);
    });
    LolEsportsApi.cachedFixtures = all;
    LolEsportsApi.fixturesAt = all.length > 0 ? Date.now() : 0;
    return all;
  }

  /**
   * 信息流顶部「最近一场赛果 + 下一场」：直接取腾讯赛程表（3 个赛事文件，已做 10 分钟缓存），
   * 不需要虎扑评分节点，因此不会触发 bizId 探测扫描。
   */
  static async getFeedHighlights(): Promise<LolMatchHighlights> {
    const out: LolMatchHighlights = new LolMatchHighlights();
    try {
      const all: LolFixture[] = await LolEsportsApi.getFixtures();
      const now: number = Date.now();
      let lastMs: number = -1;
      let nextMs: number = Number.MAX_VALUE;
      for (const f of all) {
        const ms: number = Date.parse(`${f.matchTime.replace(' ', 'T')}+08:00`);
        if (!Number.isFinite(ms)) continue;
        const finished: boolean = f.status === '3'
          || (f.scoreA.length > 0 && f.scoreB.length > 0 && ms < now - 3 * 3600 * 1000);
        if (finished) {
          if (ms > lastMs) {
            lastMs = ms;
            out.last = f;
          }
        } else if (ms > now - 6 * 3600 * 1000 && ms < nextMs) {
          // 进行中/即将开始：取最早的一场
          nextMs = ms;
          out.next = f;
        }
      }
    } catch (e) {
    }
    return out;
  }

  static async getMatch(bizId: string): Promise<LolMatchNode | null> {
    const url: string = `${HUPU_BPL}/score_tree/getSelfByBizKey?outBizType=lol_match&outBizNo=${encodeURIComponent(bizId)}`;
    const raw: Record<string, Object> = await HttpManager.getJson<Record<string, Object>>(url);
    const data: Record<string, Object> = (raw['data'] ?? {}) as Record<string, Object>;
    const detail: Record<string, Object> = (data['detail'] ?? {}) as Record<string, Object>;
    if (!detail['bizId']) return null;
    const info: Record<string, Object> = (detail['infoJson'] ?? {}) as Record<string, Object>;
    const match: LolMatchNode = new LolMatchNode();
    match.bizId = textOf(detail['bizId']);
    match.title = textOf(detail['name']);
    match.teamA = textOf(info['homeTeamName']);
    match.teamB = textOf(info['awayTeamName']);
    // 选手节点的 teamId 使用赛事俱乐部 ID；从比赛元数据取值才能正确分组。
    match.teamAId = textOf(info['homeTeamId']);
    match.teamBId = textOf(info['awayTeamId']);
    match.teamALogo = logoUrl(textOf(info['homeTeamLogo']));
    match.teamBLogo = logoUrl(textOf(info['awayTeamLogo']));
    match.scoreA = textOf(info['homeTeamScore']);
    match.scoreB = textOf(info['awayTeamScore']);
    match.event = textOf(info['competitionTypeCn']);
    match.stage = textOf(info['competitionStageTypeCn']);
    match.matchTime = numberOf(info['matchTime']);
    match.status = textOf(info['matchStatus']);
    // match 详情自带 subNodes（对局列表）：直接复用，避免再打一次 children 接口
    const subNodes: Object = detail['subNodes'] as Object;
    if (Array.isArray(subNodes)) {
      const rows: Object[] = subNodes as Object[];
      for (let i: number = 0; i < rows.length; i++) {
        const row: Record<string, Object> = rows[i] as Record<string, Object>;
        if (textOf(row['outBizType']) !== 'lol_bo') continue;
        const game: LolGameNode = new LolGameNode();
        game.bizId = textOf(row['outBizNo']);
        game.name = textOf(row['name']);
        game.boNum = numberOf(row['boNum']);
        if (game.bizId.length > 0) match.games.push(game);
      }
      match.games.sort((a: LolGameNode, b: LolGameNode): number => a.boNum - b.boNum);
    }
    LolEsportsApi.memGames.set(match.bizId, match.games);
    return match;
  }

  /**
   * 2026 LPL / 国际赛事比赛节点。
   *
   * 虎扑没有公开的赛事列表接口，只能按 bizId 探测（4101~4225 + 4501~4700）。
   * bizId 按赛事分块、块之间存在很长的空档（例：4130 之后到 4210 才有下一块），
   * 所以**不能用"连续探空即结束"来截断**，否则会漏掉后面的赛事（曾导致全球总决赛缺失）。
   * 这里改为：
   * - 首次（或上次扫描失败）：整段全量探测，结果持久化；
   * - 之后：只探"最后一场之后"的 40 个 bizId（新比赛追加在更大的 bizId 上），30 分钟内不重复；
   * - 每 12 小时做一次深刷（从最后一场探到区间末尾），兜底跨块新增的赛事。
   */
  static async getRecentMatches(forceRefresh: boolean = false): Promise<LolMatchNode[]> {
    await LolEsportsApi.loadScanState();
    const state: LolMatchScanState = LolEsportsApi.scanState;
    const fresh: boolean = state.savedAt > 0 && Date.now() - state.savedAt < MATCH_CACHE_TTL_MS;
    if (!forceRefresh && fresh && state.matches.length > 0) {
      LolEsportsApi.cachedMatches = state.matches.slice();
      return LolEsportsApi.cachedMatches;
    }
    const running: Promise<void> | null = LolEsportsApi.scanInFlight;
    if (running !== null) {
      await running;
      return LolEsportsApi.cachedMatches;
    }
    const task: Promise<void> = LolEsportsApi.scanMatches();
    LolEsportsApi.scanInFlight = task;
    try {
      await task;
    } finally {
      LolEsportsApi.scanInFlight = null;
    }
    return LolEsportsApi.cachedMatches;
  }

  /** 探测窗口（Hupu 赛事节点连号区间） */
  private static scanIds(): string[] {
    const ids: string[] = [];
    for (let id: number = 4101; id <= 4225; id++) ids.push(`${id}`);
    for (let id: number = 4501; id <= 4700; id++) ids.push(`${id}`);
    return ids;
  }

  private static async scanMatches(): Promise<void> {
    const ids: string[] = LolEsportsApi.scanIds();
    const state: LolMatchScanState = LolEsportsApi.scanState;
    const now: number = Date.now();
    // 只有"从未成功扫完过"才整段全量探测；之后用尾部窗口刷新（新比赛只会追加在更大的 bizId 上）
    const fullScan: boolean = state.matches.length === 0 || state.fullScanAt === 0;
    const deep: boolean = !fullScan && now - state.fullScanAt > DEEP_REFRESH_INTERVAL_MS;
    let start: number = 0;
    let end: number = ids.length;
    if (!fullScan) {
      const window: number = deep ? DEEP_REFRESH_WINDOW : REFRESH_WINDOW;
      start = state.lastMatchIndex >= 0 ? state.lastMatchIndex : 0;
      end = Math.min(ids.length, start + window);
    }
    const found: LolMatchNode[] = [];
    LolEsportsApi.scanHadError = false;
    const batchSize: number = 8;
    for (let from: number = start; from < end; from += batchSize) {
      const batch: string[] = ids.slice(from, Math.min(end, from + batchSize));
      const results: (LolMatchNode | null)[] = await Promise.all(batch.map(async (id: string): Promise<LolMatchNode | null> => {
        try {
          return await LolEsportsApi.getMatch(id);
        } catch (e) {
          LolEsportsApi.scanHadError = true;
          return null;
        }
      }));
      for (let k: number = 0; k < results.length; k++) {
        const match: LolMatchNode | null = results[k];
        if (match === null) continue;
        found.push(match);
        const index: number = from + k;
        if (index > state.lastMatchIndex) {
          state.lastMatchIndex = index;
        }
      }
    }
    LolEsportsApi.mergeMatches(found);
    // 扫描失败时不推进 fullScanAt：下次（30 分钟后）仍会重新全量补扫，避免残缺列表被永久缓存
    if (!LolEsportsApi.scanHadError && (fullScan || deep)) {
      state.fullScanAt = now;
    }
    state.savedAt = now;
    LolEsportsApi.cachedMatches = state.matches.slice();
    await LolEsportsApi.saveScanState();
  }

  private static mergeMatches(found: LolMatchNode[]): void {
    const state: LolMatchScanState = LolEsportsApi.scanState;
    const byId: Map<string, LolMatchNode> = new Map<string, LolMatchNode>();
    for (const old of state.matches) {
      byId.set(old.bizId, old);
    }
    for (const item of found) {
      byId.set(item.bizId, item);
    }
    const rows: LolMatchNode[] = Array.from(byId.values());
    rows.sort((a: LolMatchNode, b: LolMatchNode): number => b.matchTime - a.matchTime);
    state.matches = rows;
  }

  private static appContext(): common.Context | undefined {
    return AppStorage.get<common.Context>('appContext');
  }

  private static async loadScanState(): Promise<void> {
    if (LolEsportsApi.scanStateLoaded) return;
    LolEsportsApi.scanStateLoaded = true;
    const ctx: common.Context | undefined = LolEsportsApi.appContext();
    if (ctx === undefined) return;
    try {
      const cached: CachedPayload | null = await CacheStore.get(ctx, 'lol/matchscan');
      if (cached === null) return;
      const parsed: LolMatchScanState = JSON.parse(cached.json) as LolMatchScanState;
      if (parsed !== null && parsed.matches !== undefined && parsed.version === 3) {
        LolEsportsApi.scanState = parsed;
      }
    } catch (e) {
    }
  }

  private static async saveScanState(): Promise<void> {
    const ctx: common.Context | undefined = LolEsportsApi.appContext();
    if (ctx === undefined) return;
    await CacheStore.put(ctx, 'lol/matchscan', JSON.stringify(LolEsportsApi.scanState));
  }

  /**
   * 按赛程（腾讯赛程表）反查虎扑比赛节点：
   * 虎扑搜索接口支持在赛事根节点下按关键字检索，命中对局后可用 parentBizKey 拿到比赛 bizId。
   * 先用对局自身的 createDt 过滤日期，最多深挖 4 个候选；没命中就交给调用方走本地列表/扫描兜底。
   */
  static async findMatchForTeams(teamA: string, teamB: string, matchTimeText: string): Promise<LolMatchNode | null> {
    const a: string = LolEsportsApi.normalize(teamA);
    const b: string = LolEsportsApi.normalize(teamB);
    if (a.length === 0 || b.length === 0) return null;
    const taskDate: string = matchTimeText.length >= 10 ? matchTimeText.substring(0, 10) : '';
    const taskMs: number = taskDate.length > 0 ? Date.parse(`${taskDate}T00:00:00`) : Number.NaN;
    const tried: Set<string> = new Set<string>();
    for (const keyword of [teamA, teamB]) {
      if (keyword.length === 0) continue;
      const rows: Record<string, Object>[] = await LolEsportsApi.searchScoreNodes(keyword);
      let deepChecks: number = 0;
      for (const row of rows) {
        const info: Record<string, Object> = (row['infoJson'] ?? {}) as Record<string, Object>;
        const title: string = LolEsportsApi.normalize(textOf(info['lol_match']));
        if (title.indexOf(a) < 0 || title.indexOf(b) < 0) continue;
        // 关键：先按对局创建日期筛掉同对阵的历史场次，避免为每一场都请求详情
        if (Number.isFinite(taskMs)) {
          const created: string = textOf(row['createDt']);
          if (created.length >= 10) {
            const createdMs: number = Date.parse(`${created.substring(0, 10)}T00:00:00`);
            if (Number.isFinite(createdMs) && Math.abs(createdMs - taskMs) > 3 * 24 * 3600 * 1000) continue;
          }
        }
        const parent: Record<string, Object> = (row['parentBizKey'] ?? {}) as Record<string, Object>;
        const parentId: string = textOf(parent['outBizNo']);
        if (parentId.length === 0 || tried.has(parentId)) continue;
        tried.add(parentId);
        if (deepChecks >= 4) break;
        deepChecks++;
        const match: LolMatchNode | null = await LolEsportsApi.getMatch(parentId);
        if (match === null) continue;
        const home: string = LolEsportsApi.normalize(match.teamA);
        const away: string = LolEsportsApi.normalize(match.teamB);
        const teamsMatch: boolean = (home === a && away === b) || (home === b && away === a);
        if (!teamsMatch) continue;
        if (Number.isFinite(taskMs) && match.matchTime > 0) {
          const matchDate: string = LolEsportsApi.localDate(match.matchTime * 1000);
          const diff: number = Math.abs(Date.parse(`${matchDate}T00:00:00`) - taskMs);
          if (Number.isFinite(diff) && diff > 3 * 24 * 3600 * 1000) continue;
        }
        return match;
      }
    }
    return null;
  }

  private static localDate(ms: number): string {
    const d: Date = new Date(ms);
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
  }

  private static async searchScoreNodes(keyword: string): Promise<Record<string, Object>[]> {
    const url: string = `${HUPU_BPL}/search/queryScoreByNodeId?size=30&page=1` +
      `&searchText=${encodeURIComponent(keyword)}&nodeId=${LOL_ROOT_NODE_ID}&puid=0`;
    const out: Record<string, Object>[] = [];
    try {
      const raw: Record<string, Object> = await HttpManager.getJson<Record<string, Object>>(url);
      const data: Record<string, Object> = (raw['data'] ?? {}) as Record<string, Object>;
      const rows: Object = data['data'] as Object;
      if (Array.isArray(rows)) {
        const list: Object[] = rows as Object[];
        for (let i: number = 0; i < list.length; i++) {
          out.push(list[i] as Record<string, Object>);
        }
      }
    } catch (e) {
    }
    return out;
  }

  /** Resolve a player's lane from Tencent's official LPL roster feed. */
  static async getPlayerLane(teamName: string, playerName: string): Promise<number> {
    await LolEsportsApi.getTeamLogos();
    if (!LolEsportsApi.memberLaneLookupReady) {
      try {
        const raw: string = await HttpManager.get(LPL_MEMBER_LIST);
        const eq: number = raw.indexOf('=');
        let jsonText: string = eq >= 0 ? raw.substring(eq + 1).trim() : raw.trim();
        if (jsonText.endsWith(';')) jsonText = jsonText.substring(0, jsonText.length - 1);
        const root: LolMemberListDto = JSON.parse(jsonText) as LolMemberListDto;
        const members: Record<string, LolMemberDto> = root.msg ?? {};
        for (const id of Object.keys(members)) {
          const member: LolMemberDto = members[id];
          if (textOf(member.UserStatus) !== '1') continue;
          const role: number = Number(textOf(member.GamePlace).split(',')[0]);
          const nick: string = member.NickName ?? '';
          const teamId: string = textOf(member.TeamId);
          if (nick.length > 0 && role >= 1 && role <= 5) {
            LolEsportsApi.cachedPlayerLanesByName.set(LolEsportsApi.normalize(nick), role);
            if (teamId.length > 0) {
              LolEsportsApi.cachedPlayerLanes.set(`${teamId}:${LolEsportsApi.normalize(nick)}`, role);
            }
          }
        }
        LolEsportsApi.memberLaneLookupReady = true;
      } catch (e) {
        // Lane badges remain available as an unassigned placeholder when this auxiliary feed is down.
        LolEsportsApi.memberLaneLookupReady = true;
      }
    }
    const player: string = LolEsportsApi.normalize(playerName);
    const teamId: string = LolEsportsApi.resolveTeamId(teamName);
    if (teamId.length > 0) {
      const lane: number | undefined = LolEsportsApi.cachedPlayerLanes.get(`${teamId}:${player}`);
      if (lane !== undefined && lane > 0) return lane;
    }
    // 队伍名对不上（国际赛事/队名写法差异）时按选手名兜底，避免整块分路摘要空掉
    return LolEsportsApi.cachedPlayerLanesByName.get(player) ?? 0;
  }

  /** Hupu 队名 → 腾讯 TeamId（兼容短名/全名/常见后缀写法） */
  private static resolveTeamId(teamName: string): string {
    const key: string = LolEsportsApi.normalize(teamName);
    if (key.length === 0) return '';
    const exact: string | undefined = LolEsportsApi.cachedTeamIds.get(key);
    if (exact !== undefined) return exact;
    const stripped: string = key
      .replace('gaming', '')
      .replace('esports', '')
      .replace('esport', '')
      .replace('team', '')
      .replace('电子竞技俱乐部', '')
      .replace('俱乐部', '');
    if (stripped.length === 0) return '';
    for (const candidate of LolEsportsApi.cachedTeamIds.keys()) {
      if (candidate === stripped) return LolEsportsApi.cachedTeamIds.get(candidate) ?? '';
    }
    for (const candidate of LolEsportsApi.cachedTeamIds.keys()) {
      if (candidate.length >= 2 && (candidate.startsWith(stripped) || stripped.startsWith(candidate))) {
        return LolEsportsApi.cachedTeamIds.get(candidate) ?? '';
      }
    }
    return '';
  }

  private static normalize(value: string): string {
    return value.toLowerCase().replace(/\s+/g, '').trim();
  }

  private static mapRatingComment(dto: LolRatingCommentDto): LolRatingComment {
    const comment: LolRatingComment = new LolRatingComment();
    comment.commentId = textOf(dto.commentId);
    comment.userName = dto.commentUserName ?? '虎扑用户';
    comment.avatar = logoUrl(dto.commentUserHeadImg ?? '');
    comment.content = dto.commentContent ?? '';
    comment.date = dto.commentDate ?? '';
    comment.lightCount = numberOf(dto.lightCount);
    comment.score = numberOf(dto.score);
    comment.publishTime = numberOf(dto.publishTime);
    comment.subCommentCount = numberOf(dto.subCommentCount);
    comment.descendantCount = numberOf(dto.descendantCount);
    const previews: LolRatingCommentDto[] = dto.subCommentList ?? [];
    for (const reply of previews) comment.previewReplies.push(LolEsportsApi.mapRatingComment(reply));
    return comment;
  }

  static async getPlayerRatingDetail(bizId: string): Promise<LolPlayerScore> {
    const url: string = `${HUPU_BPL}/score_tree/getSelfByBizKey?outBizType=lol_item&outBizNo=${encodeURIComponent(bizId)}`;
    const raw: Record<string, Object> = await HttpManager.getJson<Record<string, Object>>(url);
    const data: Record<string, Object> = (raw['data'] ?? {}) as Record<string, Object>;
    const node: Record<string, Object> = (data['detail'] ?? {}) as Record<string, Object>;
    const info: Record<string, Object> = (node['infoJson'] ?? {}) as Record<string, Object>;
    const score: LolPlayerScore = new LolPlayerScore();
    score.bizId = textOf(node['bizId']);
    score.name = textOf(node['name']);
    score.kind = textOf(info['type']);
    score.teamId = textOf(info['teamId']);
    score.score = numberOf(node['scoreAvg']);
    score.votes = numberOf(node['scorePersonCount']);
    score.commentCount = numberOf(node['commentCount']);
    score.kills = numberOf(info['killCount']);
    score.deaths = numberOf(info['deathCount']);
    score.assists = numberOf(info['assistCount']);
    const champion: string = textOf(info['auxiliaryPic']);
    score.champion = champion.indexOf('6488fab0a2d3') >= 0 ? '' : champion;
    score.avatar = textOf(node['image']);
    const distribution: Record<string, Object> = (node['scoreDistribution'] ?? {}) as Record<string, Object>;
    score.ratingDistribution = [
      numberOf(distribution['2']), numberOf(distribution['4']), numberOf(distribution['6']),
      numberOf(distribution['8']), numberOf(distribution['10'])
    ];
    const hotComments: Object = node['hotCommentModels'] as Object;
    if (Array.isArray(hotComments) && hotComments.length > 0) {
      const hot: LolRatingCommentDto = hotComments[0] as LolRatingCommentDto;
      score.featuredComment = hot.commentContent ?? '';
      score.featuredCommentLights = numberOf(hot.lightCount);
    }
    const labels: Object = info['label'] as Object;
    if (Array.isArray(labels) && labels.length > 0) {
      const first: Record<string, Object> = labels[0] as Record<string, Object>;
      score.label = textOf(first['text']);
    }
    return score;
  }

  static async getRatingComments(bizId: string, order: string, cursor: number): Promise<LolRatingCommentPage> {
    const page: LolRatingCommentPage = new LolRatingCommentPage();
    const root: Record<string, Object> = order === 'hot'
      ? await HttpManager.getJson<Record<string, Object>>(
        `${HUPU_BPL}/comment/list/primarySingleRow/hottest?outBizType=lol_item&outBizNo=${encodeURIComponent(bizId)}&clientCode=&cid=`)
      : await HttpManager.getJson<Record<string, Object>>(
        `${HUPU_BPL}/comment/list/primarySingleRow?publishTime=${cursor > 0 ? cursor : (order === 'old' ? 0 : Date.now())}` +
        `&order=${order === 'old' ? 'asc' : 'desc'}&outBizType=lol_item&outBizNo=${encodeURIComponent(bizId)}&clientCode=&cid=`);
    const data: Object = root['data'] as Object;
    if (order === 'hot') {
      if (!Array.isArray(data)) return page;
      const rows: LolRatingCommentDto[] = data as LolRatingCommentDto[];
      for (const row of rows) page.comments.push(LolEsportsApi.mapRatingComment(row));
      page.total = page.comments.length;
      page.hasMore = false;
      return page;
    }
    const result: Record<string, Object> = (data ?? {}) as Record<string, Object>;
    const rows: Object = result['comments'] as Object;
    if (Array.isArray(rows)) {
      const comments: LolRatingCommentDto[] = rows as LolRatingCommentDto[];
      for (const row of comments) page.comments.push(LolEsportsApi.mapRatingComment(row));
    }
    const cursorData: Record<string, Object> = (result['cursor'] ?? {}) as Record<string, Object>;
    page.cursor = numberOf(cursorData['publishTime']);
    page.hasMore = textOf(result['hasMore']) === 'true';
    page.total = numberOf(result['commentCount']);
    return page;
  }

  static async getRatingReplies(bizId: string, parent: LolRatingComment, order: string, cursor: number): Promise<LolRatingCommentPage> {
    const page: LolRatingCommentPage = new LolRatingCommentPage();
    const publishTime: number = cursor > 0 ? cursor : parent.publishTime;
    const direction: string = order === 'old' ? 'asc' : 'desc';
    const url: string = `${HUPU_BPL}/comment/list/primarySingleRow/getMore?publishTime=${publishTime}` +
      `&outBizNo=${encodeURIComponent(bizId)}&outBizType=lol_item&queryType=${direction}` +
      `&parentCommentId=${encodeURIComponent(parent.commentId)}&pageSize=20&clientCode=&cid=`;
    const root: Record<string, Object> = await HttpManager.getJson<Record<string, Object>>(url);
    const data: Record<string, Object> = (root['data'] ?? {}) as Record<string, Object>;
    const rows: Object = data['comments'] as Object;
    if (Array.isArray(rows)) {
      const comments: LolRatingCommentDto[] = rows as LolRatingCommentDto[];
      for (const row of comments) page.comments.push(LolEsportsApi.mapRatingComment(row));
    }
    const cursorData: Record<string, Object> = (data['cursor'] ?? {}) as Record<string, Object>;
    page.cursor = numberOf(cursorData['publishTime']);
    page.hasMore = textOf(data['hasMore']) === 'true';
    page.total = numberOf(data['commentCount']);
    return page;
  }

  /** 对局列表：优先用 match 详情里的 subNodes，其次内存/持久化缓存，最后才发请求 */
  static async getGames(matchBizId: string): Promise<LolGameNode[]> {
    const mem: LolGameNode[] | undefined = LolEsportsApi.memGames.get(matchBizId);
    if (mem !== undefined && mem.length > 0) return mem;
    const cacheKey: string = `lol/games/${matchBizId}`;
    const cachedText: string = await LolEsportsApi.readCacheJson(cacheKey);
    if (cachedText.length > 0) {
      try {
        const cached: LolGameNode[] = JSON.parse(cachedText) as LolGameNode[];
        if (cached.length > 0) {
          LolEsportsApi.memGames.set(matchBizId, cached);
          return cached;
        }
      } catch (e) {
      }
    }
    const raw: Record<string, Object> = await LolEsportsApi.children('lol_match', matchBizId);
    const page: Record<string, Object> = ((raw['data'] as Record<string, Object>)?.['pageResult'] ?? {}) as Record<string, Object>;
    const rows: Object = page['data'] as Object;
    const out: LolGameNode[] = [];
    if (!Array.isArray(rows)) return out;
    const gameRows: Object[] = rows as Object[];
    for (let i: number = 0; i < gameRows.length; i++) {
      const row: Record<string, Object> = gameRows[i] as Record<string, Object>;
      const node: Record<string, Object> = (row['node'] ?? {}) as Record<string, Object>;
      const game: LolGameNode = new LolGameNode();
      game.bizId = textOf(node['bizId']);
      game.name = textOf(node['name']);
      game.score = numberOf(node['scoreAvg']);
      if (game.bizId.length > 0) out.push(game);
    }
    if (out.length > 0) {
      LolEsportsApi.memGames.set(matchBizId, out);
      await LolEsportsApi.writeCacheJson(cacheKey, JSON.stringify(out));
    }
    return out;
  }

  /** 单局选手评分：半小时内复用缓存（评分会持续变化，不能长期缓存） */
  static async getGameScores(gameBizId: string): Promise<LolPlayerScore[]> {
    const mem: LolPlayerScore[] | undefined = LolEsportsApi.memScores.get(gameBizId);
    if (mem !== undefined && mem.length > 0) return mem;
    const cacheKey: string = `lol/scores/${gameBizId}`;
    let cachedText: string = '';
    let cachedAge: number = 0;
    const ctx: common.Context | undefined = LolEsportsApi.appContext();
    if (ctx !== undefined) {
      try {
        const cached: CachedPayload | null = await CacheStore.get(ctx, cacheKey);
        if (cached !== null) {
          cachedText = cached.json;
          cachedAge = cached.ageMs;
        }
      } catch (e) {
      }
    }
    if (cachedText.length > 0 && cachedAge < SCORE_CACHE_TTL_MS) {
      try {
        const rows: LolPlayerScore[] = JSON.parse(cachedText) as LolPlayerScore[];
        if (rows.length > 0) {
          LolEsportsApi.memScores.set(gameBizId, rows);
          return rows;
        }
      } catch (e) {
      }
    }
    const raw: Record<string, Object> = await LolEsportsApi.children('lol_bo', gameBizId);
    const page: Record<string, Object> = ((raw['data'] as Record<string, Object>)?.['pageResult'] ?? {}) as Record<string, Object>;
    const rows: Object = page['data'] as Object;
    const out: LolPlayerScore[] = [];
    if (!Array.isArray(rows)) return out;
    const scoreRows: Object[] = rows as Object[];
    for (let i: number = 0; i < scoreRows.length; i++) {
      const row: Record<string, Object> = scoreRows[i] as Record<string, Object>;
      const node: Record<string, Object> = (row['node'] ?? {}) as Record<string, Object>;
      const info: Record<string, Object> = (node['infoJson'] ?? {}) as Record<string, Object>;
      const score: LolPlayerScore = new LolPlayerScore();
      score.bizId = textOf(node['bizId']);
      score.name = textOf(node['name']);
      score.kind = textOf(info['type']);
      score.teamId = textOf(info['teamId']);
      score.score = numberOf(node['scoreAvg']);
      score.votes = numberOf(node['scorePersonCount']);
      score.kills = numberOf(info['killCount']);
      score.deaths = numberOf(info['deathCount']);
      score.assists = numberOf(info['assistCount']);
      const champion: string = textOf(info['auxiliaryPic']);
      score.champion = champion.indexOf('6488fab0a2d3') >= 0 ? '' : champion;
      score.avatar = textOf(node['image']);
      score.commentCount = numberOf(row['commentCount']);
      const distribution: Record<string, Object> = (row['scoreDistribution'] ?? {}) as Record<string, Object>;
      score.ratingDistribution = [
        numberOf(distribution['2']), numberOf(distribution['4']), numberOf(distribution['6']),
        numberOf(distribution['8']), numberOf(distribution['10'])
      ];
      const hotComments: Object = row['hotCommentModels'] as Object;
      if (Array.isArray(hotComments) && hotComments.length > 0) {
        const hot: LolRatingCommentDto = hotComments[0] as LolRatingCommentDto;
        score.featuredComment = hot.commentContent ?? '';
        score.featuredCommentLights = numberOf(hot.lightCount);
      }
      const labels: Object = info['label'] as Object;
      if (Array.isArray(labels) && labels.length > 0) {
        const first: Record<string, Object> = labels[0] as Record<string, Object>;
        score.label = textOf(first['text']);
      }
      if (score.kind === 'player' || score.kind === 'coach') out.push(score);
    }
    if (out.length > 0) {
      LolEsportsApi.memScores.set(gameBizId, out);
      await LolEsportsApi.writeCacheJson(cacheKey, JSON.stringify(out));
    }
    return out;
  }

  /** 本局有人提交评分后失效该局缓存，下一次读取拿到新均分 */
  static async invalidateGameScores(gameBizId: string): Promise<void> {
    LolEsportsApi.memScores.delete(gameBizId);
    await LolEsportsApi.writeCacheJson(`lol/scores/${gameBizId}`, '[]');
  }

  private static async readCacheJson(key: string): Promise<string> {
    const ctx: common.Context | undefined = LolEsportsApi.appContext();
    if (ctx === undefined) return '';
    try {
      const cached: CachedPayload | null = await CacheStore.get(ctx, key);
      return cached === null ? '' : cached.json;
    } catch (e) {
      return '';
    }
  }

  private static async writeCacheJson(key: string, json: string): Promise<void> {
    const ctx: common.Context | undefined = LolEsportsApi.appContext();
    if (ctx === undefined) return;
    await CacheStore.put(ctx, key, json);
  }

  /** Submit a Hupu player rating using its public score-tree write endpoint. */
  static async savePlayerScore(bizId: string, score: number): Promise<void> {
    if (!SessionManager.hasCookie()) throw new Error('请先登录虎扑后再评分');
    const url: string = `${HUPU_BPL}/score/save`;
    const request: LolScoreRequest = new LolScoreRequest();
    request.outBizKey.outBizType = 'lol_item';
    request.outBizKey.outBizNo = bizId;
    request.score = score;
    request.source = 'games_front';
    const body: string = JSON.stringify(request);
    const headers: ExtraHeaders = new ExtraHeaders();
    headers.cookie = SessionManager.cookieHeader();
    headers.contentType = 'application/json';
    headers.referer = `https://m.hupu.com/score/detail.html?outBizType=lol_item&outBizNo=${bizId}`;
    const text: string = await HttpManager.postJson(url, body, headers, '');
    const response: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    if (numberOf(response['code']) !== 1) {
      throw new Error(textOf(response['msg']) || '虎扑评分提交失败');
    }
  }

  private static async children(type: string, no: string): Promise<Record<string, Object>> {
    const url: string = `${HUPU_BPL}/score_tree/getCurAndSubNodeByBizKey?relation=CHILD&page=1&pageSize=30&outBizType=${type}&outBizNo=${encodeURIComponent(no)}`;
    return await HttpManager.getJson<Record<string, Object>>(url);
  }
}
