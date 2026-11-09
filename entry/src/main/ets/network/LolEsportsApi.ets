import { HttpManager, ExtraHeaders } from './HttpManager';
import { SessionManager } from './SessionManager';

const LPL_DATA: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_MATCH_HOMEPAGE_BMATCH_LIST_';
const HUPU_BPL: string = 'https://games.mobileapi.hupu.com/1/8.2.99/bplcommentapi/bpl';
const LPL_TEAM_LIST: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_TEAM_LIST.js';
const LPL_MEMBER_LIST: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_TEAM_MEMBER_LIST.js';

interface LolTeamDto {
  TeamLogo?: string;
  TeamName?: string;
  TeamShortName?: string;
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
}

export class LolGameNode {
  bizId: string = '';
  name: string = '';
  score: number = 0;
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
  private static memberLaneLookupReady: boolean = false;
  private static matchScanComplete: boolean = false;

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
        if (shortName.length > 0) LolEsportsApi.cachedTeamIds.set(LolEsportsApi.normalize(shortName), id);
        if (teamName.length > 0) LolEsportsApi.cachedTeamIds.set(LolEsportsApi.normalize(teamName), id);
      }
    } catch (e) {
      // Keep the schedule usable if the auxiliary logo feed is unavailable.
    }
    return LolEsportsApi.cachedTeamLogos;
  }

  /** 2026 LPL, MSI and Worlds schedule files. */
  static async getFixtures(): Promise<LolFixture[]> {
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
    return all;
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
    return match;
  }

  /** Fetch 2026 Hupu match nodes for the LPL/international event windows. */
  static async getRecentMatches(forceRefresh: boolean = false): Promise<LolMatchNode[]> {
    if (!forceRefresh && LolEsportsApi.cachedMatches.length > 0 && LolEsportsApi.matchScanComplete) {
      return LolEsportsApi.cachedMatches;
    }
    const found: LolMatchNode[] = [];
    const ids: string[] = [];
    const failedIds: string[] = [];
    // Hupu has no public LoL match index. Probe the 2026 LPL and international
    // event ID windows, including the late Worlds knockout match nodes.
    for (let id: number = 4101; id <= 4225; id++) ids.push(`${id}`);
    for (let id: number = 4501; id <= 4700; id++) ids.push(`${id}`);
    for (let start: number = 0; start < ids.length; start += 20) {
      const batch: string[] = ids.slice(start, start + 20);
      const results: (LolMatchNode | null)[] = await Promise.all(batch.map(async (id: string): Promise<LolMatchNode | null> => {
        try {
          return await LolEsportsApi.getMatch(id);
        } catch (e) {
          failedIds.push(id);
          return null;
        }
      }));
      for (const match of results) if (match !== null) found.push(match);
    }
    // HttpManager already retries GET once. Retry any remaining transport failures once more,
    // and do not mark a partial scan complete if the service stayed unavailable.
    const stillFailed: string[] = [];
    for (const id of failedIds) {
      try {
        const match: LolMatchNode | null = await LolEsportsApi.getMatch(id);
        if (match !== null) found.push(match);
      } catch (e) {
        stillFailed.push(id);
      }
    }
    found.sort((a: LolMatchNode, b: LolMatchNode): number => b.matchTime - a.matchTime);
    LolEsportsApi.cachedMatches = found;
    LolEsportsApi.matchScanComplete = stillFailed.length === 0;
    return found;
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
          if (nick.length > 0 && role >= 1 && role <= 5 && teamId.length > 0) {
            LolEsportsApi.cachedPlayerLanes.set(`${teamId}:${LolEsportsApi.normalize(nick)}`, role);
          }
        }
        LolEsportsApi.memberLaneLookupReady = true;
      } catch (e) {
        // Lane badges remain available as an unassigned placeholder when this auxiliary feed is down.
        LolEsportsApi.memberLaneLookupReady = true;
      }
    }
    const teamId: string = LolEsportsApi.cachedTeamIds.get(LolEsportsApi.normalize(teamName)) ?? '';
    if (teamId.length === 0) return 0;
    return LolEsportsApi.cachedPlayerLanes.get(`${teamId}:${LolEsportsApi.normalize(playerName)}`) ?? 0;
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

  static async getGames(matchBizId: string): Promise<LolGameNode[]> {
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
    return out;
  }

  static async getGameScores(gameBizId: string): Promise<LolPlayerScore[]> {
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
    return out;
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
