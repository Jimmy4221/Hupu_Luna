import { HttpManager, ExtraHeaders } from './HttpManager';
import { SessionManager } from './SessionManager';

const LPL_DATA: string = 'https://lpl.qq.com/web201612/data/LOL_MATCH2_MATCH_HOMEPAGE_BMATCH_LIST_';
const HUPU_BPL: string = 'https://games.mobileapi.hupu.com/1/8.2.99/bplcommentapi/bpl';

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

function mapFixture(raw: Record<string, Object>, eventId: string): LolFixture {
  const item: LolFixture = new LolFixture();
  item.matchId = textOf(raw['bMatchId']);
  item.eventId = eventId;
  item.eventName = textOf(raw['GameName']);
  item.teams = textOf(raw['bMatchName']);
  const parts: string[] = item.teams.split(' vs ');
  item.teamA = textOf(raw['TeamShortNameA']) || (parts.length > 0 ? parts[0].trim() : '');
  item.teamB = textOf(raw['TeamShortNameB']) || (parts.length > 1 ? parts[1].trim() : '');
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

  /** 2026 LPL, MSI and Worlds schedule files. */
  static async getFixtures(): Promise<LolFixture[]> {
    const eventIds: string[] = ['237', '239', '246'];
    const all: LolFixture[] = [];
    for (const eventId of eventIds) {
      try {
        const raw: string = await HttpManager.get(`${LPL_DATA}${eventId}.js`);
        const root: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        const rows: Object = root['msg'] as Object;
        if (!Array.isArray(rows)) continue;
        const fixtureRows: Object[] = rows as Object[];
        for (let i: number = 0; i < fixtureRows.length; i++) {
          const row: Record<string, Object> = fixtureRows[i] as Record<string, Object>;
          const fixture: LolFixture = mapFixture(row, eventId);
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
    try {
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
      // 子选手节点用阵营编号 1/2（不是比赛节点上的俱乐部 bizId）。
      match.teamAId = '1';
      match.teamBId = '2';
      match.scoreA = textOf(info['homeTeamScore']);
      match.scoreB = textOf(info['awayTeamScore']);
      match.event = textOf(info['competitionTypeCn']);
      match.stage = textOf(info['competitionStageTypeCn']);
      match.matchTime = numberOf(info['matchTime']);
      match.status = textOf(info['matchStatus']);
      return match;
    } catch (e) {
      return null;
    }
  }

  /** Fetch 2026 Hupu match nodes for the LPL/international event windows. */
  static async getRecentMatches(): Promise<LolMatchNode[]> {
    if (LolEsportsApi.cachedMatches.length > 0) return LolEsportsApi.cachedMatches;
    const found: LolMatchNode[] = [];
    const ids: string[] = [];
    // Hupu has no public LoL match index. These compact bizId windows cover the
    // 2026 LPL finish and the 2026 international events; future ids are probed
    // beyond the current Worlds block to include the closing matches.
    for (let id: number = 4101; id <= 4225; id++) ids.push(`${id}`);
    for (let id: number = 4501; id <= 4560; id++) ids.push(`${id}`);
    for (let start: number = 0; start < ids.length; start += 20) {
      const batch: string[] = ids.slice(start, start + 20);
      const results: (LolMatchNode | null)[] = await Promise.all(batch.map((id: string) => LolEsportsApi.getMatch(id)));
      for (const match of results) if (match !== null) found.push(match);
    }
    found.sort((a: LolMatchNode, b: LolMatchNode): number => b.matchTime - a.matchTime);
    LolEsportsApi.cachedMatches = found;
    return found;
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
