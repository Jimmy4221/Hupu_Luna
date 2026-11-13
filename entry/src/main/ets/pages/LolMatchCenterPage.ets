import { LolEsportsApi, LolFixture, LolMatchNode, LolGameNode, LolPlayerScore } from '../network/LolEsportsApi';
import { LoadState } from '../views/StateView';
import { AppNavBar } from '../views/AppNavBar';
import { Spacing, Radius, RouteName } from '../common/Theme';
import { ImageKnifeComponent } from '@ohos/imageknife';
import { SessionManager } from '../network/SessionManager';
import { ReaderTypography } from '../common/ReaderTypography';

class LolLaneMatchup {
  roleCode: number = 0;
  left: LolPlayerScore | null = null;
  right: LolPlayerScore | null = null;
}

class LolLeaderboardRow {
  name: string = '';
  games: number = 0;
  kills: number = 0;
  deaths: number = 0;
  assists: number = 0;
  scoreSum: number = 0;
  scoreCount: number = 0;
  get kda(): string {
    return `${this.kills}/${this.deaths}/${this.assists}`;
  }
  get average(): string {
    return this.scoreCount > 0 ? (this.scoreSum / this.scoreCount).toFixed(1) : '—';
  }
}

@Component
export struct LolMatchCenterPage {
  /** 可选参数："teamA||teamB||matchTime" —— 从信息流「最近赛果」直接进入该场评分对位 */
  param: string = '';
  @Consume('pageStack') pageStack: NavPathStack;
  @State fixtures: LolFixture[] = [];
  @State matches: LolMatchNode[] = [];
  @State games: LolGameNode[] = [];
  @State scores: LolPlayerScore[] = [];
  @State laneMatchups: LolLaneMatchup[] = [];
  @State leaderboard: LolLeaderboardRow[] = [];
  @State selectedMatch: LolMatchNode | null = null;
  @State selectedGame: LolGameNode | null = null;
  @State state: LoadState = LoadState.Loading;
  @State tab: number = 0;
  @State detailLoading: boolean = false;
  @State boardLoading: boolean = false;
  @State laneLoading: boolean = false;
  /** 分路数据缺失（国际赛事/新选手）时，改用两队双列摘要，保证名字与分数始终可见 */
  @State laneFallback: boolean = false;
  @State lookupFixture: LolFixture | null = null;
  @State lookupMessage: string = '';
  @StorageLink('readerFontScale') readerFontScale: number = 0;
  @StorageLink('readerFontWeight') readerFontWeight: number = 0;

  private readerSize(base: number): number {
    return ReaderTypography.fontSize(base, this.readerFontScale);
  }

  private readerWeight(base: number): number {
    return ReaderTypography.fontWeight(base, this.readerFontWeight);
  }

  aboutToAppear(): void {
    this.loadFixtures();
    if (this.param.length > 0) {
      const parts: string[] = this.param.split('||');
      if (parts.length >= 3) {
        const fixture: LolFixture = new LolFixture();
        fixture.teamA = parts[0];
        fixture.teamB = parts[1];
        fixture.matchTime = parts[2];
        this.openFixture(fixture);
      }
    }
  }

  private async loadFixtures(): Promise<void> {
    this.state = LoadState.Loading;
    try {
      this.fixtures = await LolEsportsApi.getFixtures();
      this.state = this.fixtures.length > 0 ? LoadState.Ready : LoadState.Empty;
    } catch (e) {
      this.state = LoadState.Error;
    }
  }

  private async loadMatchNodes(forceRefresh: boolean = false): Promise<void> {
    if (this.matches.length > 0 && !forceRefresh) return;
    this.detailLoading = true;
    try {
      this.matches = await LolEsportsApi.getRecentMatches(forceRefresh);
    } catch (e) {
      this.matches = [];
    } finally {
      this.detailLoading = false;
    }
  }

  private normalizedTeam(name: string): string {
    return name.toLowerCase().replace(/[^a-z0-9]/g, '').trim();
  }

  private matchForFixture(fixture: LolFixture): LolMatchNode | null {
    const a: string = this.normalizedTeam(fixture.teamA);
    const b: string = this.normalizedTeam(fixture.teamB);
    const fixtureTime: number = Date.parse(`${fixture.matchTime.replace(' ', 'T')}+08:00`);
    if (a.length === 0 || b.length === 0 || !Number.isFinite(fixtureTime)) return null;
    for (const match of this.matches) {
      const home: string = this.normalizedTeam(match.teamA);
      const away: string = this.normalizedTeam(match.teamB);
      const teamsMatch: boolean = (home === a && away === b) || (home === b && away === a);
      if (!teamsMatch) continue;
      const matchTime: number = match.matchTime * 1000;
      if (Math.abs(matchTime - fixtureTime) <= 36 * 60 * 60 * 1000) return match;
    }
    return null;
  }

  private async openFixture(item: LolFixture): Promise<void> {
    this.tab = 2;
    this.lookupFixture = item;
    this.lookupMessage = '';
    this.selectedMatch = null;
    this.selectedGame = null;
    this.games = [];
    this.scores = [];
    this.laneMatchups = [];
    this.laneFallback = false;
    // 可靠优先：本地已有比赛列表就直接匹配；没有就先把列表补齐（有持久化缓存，通常零请求），
    // 最后才用搜索接口按队名反查。
    let match: LolMatchNode | null = this.matches.length > 0 ? this.matchForFixture(item) : null;
    if (match === null && this.matches.length === 0) {
      this.lookupMessage = '正在匹配评分数据…';
      await this.loadMatchNodes();
      match = this.matchForFixture(item);
    }
    if (match === null) {
      this.lookupMessage = '正在匹配评分数据…';
      match = await LolEsportsApi.findMatchForTeams(item.teamA, item.teamB, item.matchTime);
    }
    if (match === null) {
      this.lookupMessage = '暂时没有匹配到虎扑评分数据。赛程和比赛结果仍可查看。';
      return;
    }
    this.lookupFixture = null;
    await this.selectMatch(match);
  }

  private async selectMatch(match: LolMatchNode): Promise<void> {
    this.lookupFixture = null;
    this.lookupMessage = '';
    this.selectedMatch = match;
    this.selectedGame = null;
    this.games = [];
    this.scores = [];
    this.laneFallback = false;
    this.detailLoading = true;
    try {
      // 比赛详情节点自带对局列表（getMatch 已解析），有就不再打 children 接口
      this.games = match.games.length > 0 ? match.games.slice() : await LolEsportsApi.getGames(match.bizId);
      if (this.games.length > 0) {
        this.selectedGame = this.games[0];
        this.scores = await LolEsportsApi.getGameScores(this.games[0].bizId);
        await this.loadLaneMatchups();
      }
    } catch (e) {
      this.games = [];
      this.laneMatchups = [];
    }
    this.detailLoading = false;
  }

  private async selectGame(game: LolGameNode): Promise<void> {
    this.selectedGame = game;
    this.laneFallback = false;
    this.detailLoading = true;
    try {
      this.scores = await LolEsportsApi.getGameScores(game.bizId);
      await this.loadLaneMatchups();
    } catch (e) {
      this.scores = [];
      this.laneMatchups = [];
    }
    this.detailLoading = false;
  }

  private async loadLeaderboard(): Promise<void> {
    if (this.leaderboard.length > 0 || this.boardLoading) return;
    this.boardLoading = true;
    await this.loadMatchNodes();
    const tally: Map<string, LolLeaderboardRow> = new Map<string, LolLeaderboardRow>();
    const recent: LolMatchNode[] = this.matches.slice(0, 8);
    for (const match of recent) {
      try {
        const games: LolGameNode[] = match.games.length > 0 ? match.games : await LolEsportsApi.getGames(match.bizId);
        for (const game of games) {
          const roster: LolPlayerScore[] = await LolEsportsApi.getGameScores(game.bizId);
          for (const p of roster) {
            if (p.kind !== 'player') continue;
            let row: LolLeaderboardRow | undefined = tally.get(p.name);
            if (row === undefined) {
              row = new LolLeaderboardRow();
              row.name = p.name;
              tally.set(p.name, row);
            }
            row.games++;
            row.kills += p.kills;
            row.deaths += p.deaths;
            row.assists += p.assists;
            if (p.score > 0) {
              row.scoreSum += p.score;
              row.scoreCount++;
            }
          }
        }
      } catch (e) {
      }
    }
    this.leaderboard = Array.from(tally.values()).sort((a: LolLeaderboardRow, b: LolLeaderboardRow): number =>
      Number(b.average) - Number(a.average));
    this.boardLoading = false;
  }

  private setTab(index: number): void {
    this.tab = index;
    if (index === 1) this.loadLeaderboard();
    if (index === 2) this.loadMatchNodes();
  }

  private fixtureStatus(item: LolFixture): string {
    if (item.status === '1') return '未开赛';
    if (item.status === '2') return '进行中';
    return item.scoreA.length > 0 || item.scoreB.length > 0 ? `${item.scoreA} : ${item.scoreB}` : '已结束';
  }

  private openRating(p: LolPlayerScore): void {
    if (p.bizId.length === 0) return;
    const teamName: string = this.selectedMatch !== null && p.teamId === this.selectedMatch.teamBId
      ? this.selectedMatch.teamB : (this.selectedMatch?.teamA ?? '');
    this.pageStack.pushPathByName(RouteName.LOL_PLAYER_RATING, `${p.bizId}||${p.name}||${teamName}`);
  }

  private openMatchInteraction(): void {
    const player: LolPlayerScore | undefined = this.scores.find((p: LolPlayerScore) => p.kind === 'player');
    if (player === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: '当前对局暂无选手互动数据' });
      return;
    }
    this.openRating(player);
  }

  private async saveScore(p: LolPlayerScore, value: number): Promise<void> {
    if (p.bizId.length === 0) return;
    if (!SessionManager.hasCookie()) {
      this.getUIContext().showAlertDialog({
        title: '登录后评分',
        message: '评分会提交到你的虎扑账号。请先登录。',
        autoCancel: true,
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: {
          value: '去登录',
          action: () => this.pageStack.pushPathByName(RouteName.LOGIN_WEB, '')
        }
      });
      return;
    }
    try {
      await LolEsportsApi.savePlayerScore(p.bizId, value);
      this.getUIContext().getPromptAction().showToast({ message: `已提交 ${value} 分` });
      if (this.selectedGame !== null) {
        await LolEsportsApi.invalidateGameScores(this.selectedGame.bizId);
        this.scores = await LolEsportsApi.getGameScores(this.selectedGame.bizId);
      }
    } catch (e) {
      const err = e as Error;
      this.getUIContext().getPromptAction().showToast({ message: err.message });
    }
  }

  @Builder
  RateButtons(p: LolPlayerScore) {
    Row({ space: 3 }) {
      ForEach([2, 4, 6, 8, 10], (value: number) => {
        Text(`${value}`)
          .fontSize(this.readerSize(12))
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 5, right: 5, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(5)
          .onClick(() => this.saveScore(p, value))
      }, (value: number) => `rate_${p.bizId}_${value}`)
    }
  }

  private teamScores(teamId: string): LolPlayerScore[] {
    return this.scores.filter((p: LolPlayerScore) => p.teamId === teamId && p.kind === 'player');
  }

  private async loadLaneMatchups(): Promise<void> {
    if (this.selectedMatch === null) return;
    this.laneLoading = true;
    const rows: LolLaneMatchup[] = [];
    const codes: number[] = [1, 5, 2, 3, 4];
    for (const code of codes) {
      const row: LolLaneMatchup = new LolLaneMatchup();
      row.roleCode = code;
      rows.push(row);
    }
    const match: LolMatchNode = this.selectedMatch;
    const leftAssigned: number = await this.assignSide(rows, this.teamScores(match.teamAId), match.teamA, true);
    const rightAssigned: number = await this.assignSide(rows, this.teamScores(match.teamBId), match.teamB, false);
    // 任一方完全拿不到分路数据（国际赛事队伍在 LPL 名单里没有）时改用两队双列摘要，
    // 而不是让顶部摘要空着——底部评分卡本来就有完整的名字与分数。
    this.laneFallback = leftAssigned === 0 || rightAssigned === 0;
    this.laneMatchups = rows.filter((row: LolLaneMatchup) => row.left !== null || row.right !== null);
    this.laneLoading = false;
  }

  /** 按分路把一队选手填进对应行；分路缺失的选手补进空位，保证摘要里不丢人 */
  private async assignSide(rows: LolLaneMatchup[], players: LolPlayerScore[], teamName: string,
    isLeft: boolean): Promise<number> {
    let assigned: number = 0;
    const unresolved: LolPlayerScore[] = [];
    for (const player of players) {
      const lane: number = await LolEsportsApi.getPlayerLane(teamName, player.name);
      const row: LolLaneMatchup | undefined = rows.find((entry: LolLaneMatchup) => entry.roleCode === lane);
      const free: boolean = row !== undefined && (isLeft ? row.left === null : row.right === null);
      if (row !== undefined && free) {
        if (isLeft) {
          row.left = player;
        } else {
          row.right = player;
        }
        assigned++;
      } else {
        unresolved.push(player);
      }
    }
    for (const player of unresolved) {
      const row: LolLaneMatchup | undefined = rows.find((entry: LolLaneMatchup) =>
        isLeft ? entry.left === null : entry.right === null);
      if (row === undefined) break;
      if (isLeft) {
        row.left = player;
      } else {
        row.right = player;
      }
    }
    return assigned;
  }

  /** 双列兜底数据：两队按各自阵容顺序并排 */
  private summaryRows(): LolLaneMatchup[] {
    const rows: LolLaneMatchup[] = [];
    if (this.selectedMatch === null) return rows;
    const left: LolPlayerScore[] = this.teamScores(this.selectedMatch.teamAId);
    const right: LolPlayerScore[] = this.teamScores(this.selectedMatch.teamBId);
    const count: number = Math.max(left.length, right.length);
    for (let i: number = 0; i < count; i++) {
      const row: LolLaneMatchup = new LolLaneMatchup();
      row.left = i < left.length ? left[i] : null;
      row.right = i < right.length ? right[i] : null;
      rows.push(row);
    }
    return rows;
  }

  @Builder
  LaneIcon(code: number) {
    if (code === 1) {
      Image($r('app.media.lol_lane_top')).width(30).height(30).objectFit(ImageFit.Contain)
    } else if (code === 5) {
      Image($r('app.media.lol_lane_jungle')).width(30).height(30).objectFit(ImageFit.Contain)
    } else if (code === 2) {
      Image($r('app.media.lol_lane_mid')).width(30).height(30).objectFit(ImageFit.Contain)
    } else if (code === 3) {
      Image($r('app.media.lol_lane_bot')).width(30).height(30).objectFit(ImageFit.Contain)
    } else {
      Image($r('app.media.lol_lane_support')).width(30).height(30).objectFit(ImageFit.Contain)
    }
  }

  /** 分路数据缺失时的两队双列摘要：名字 + 均分，始终可见 */
  @Builder
  TeamSummaryRows() {
    Row() {
      Text(this.selectedMatch?.teamA ?? '').fontSize(this.readerSize(13)).fontColor('#F05B68')
        .layoutWeight(1).maxLines(1)
      Text('选手均分').fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary'))
        .width(64).textAlign(TextAlign.Center)
      Text(this.selectedMatch?.teamB ?? '').fontSize(this.readerSize(13)).fontColor('#6F9FE8')
        .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
    }.width('100%').padding({ top: 3, bottom: 3 })

    ForEach(this.summaryRows(), (row: LolLaneMatchup, index: number) => {
      Row({ space: 6 }) {
        Row() {
          Text(row.left?.name ?? '—').fontSize(this.readerSize(14)).fontColor($r('app.color.text_primary'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => {
              if (row.left !== null) this.openRating(row.left);
            })
          Text(row.left !== null && row.left.score > 0 ? row.left.score.toFixed(1) : '—')
            .fontSize(this.readerSize(15)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor('#F05B68')
        }.layoutWeight(1)

        Column().width(20)

        Row() {
          Text(row.right !== null && row.right.score > 0 ? row.right.score.toFixed(1) : '—')
            .fontSize(this.readerSize(15)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor('#6F9FE8')
          Text(row.right?.name ?? '—').fontSize(this.readerSize(14)).fontColor($r('app.color.text_primary'))
            .layoutWeight(1).textAlign(TextAlign.End).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => {
              if (row.right !== null) this.openRating(row.right);
            })
        }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 2, bottom: 2 })
    }, (row: LolLaneMatchup, index: number) =>
      `summary_${index}_${row.left?.bizId ?? ''}_${row.right?.bizId ?? ''}`)
  }

  @Builder
  LaneSummary() {
    Column({ space: 7 }) {
      Row() {
        Text('本局分路评分').fontSize(this.readerSize(16)).fontWeight(this.readerWeight(FontWeight.Medium))
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text('选手均分').fontSize(this.readerSize(13)).fontColor($r('app.color.text_tertiary'))
      }.width('100%')
      if (this.laneLoading) {
        Row({ space: 6 }) {
          LoadingProgress().width(15).height(15).color($r('app.color.brand_primary'))
          Text('正在匹配选手位置').fontSize(this.readerSize(13)).fontColor($r('app.color.text_secondary'))
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 4, bottom: 4 })
      } else if (this.laneFallback || this.laneMatchups.length === 0) {
        this.TeamSummaryRows()
      } else {
        Row() {
          Text(this.selectedMatch?.teamA ?? '').fontSize(this.readerSize(13)).fontColor('#F05B68')
            .layoutWeight(1).maxLines(1)
          Text('分路').fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary')).width(42).textAlign(TextAlign.Center)
          Text(this.selectedMatch?.teamB ?? '').fontSize(this.readerSize(13)).fontColor('#6F9FE8')
            .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
        }.width('100%').padding({ top: 3, bottom: 3 })
        ForEach(this.laneMatchups, (row: LolLaneMatchup) => {
          Row({ space: 6 }) {
            Row() {
              Text(row.left?.name ?? '—').fontSize(this.readerSize(14)).fontColor($r('app.color.text_primary'))
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => {
                  if (row.left !== null) this.openRating(row.left);
                })
              Text(row.left !== null && row.left.score > 0 ? row.left.score.toFixed(1) : '—')
                .fontSize(this.readerSize(15)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor('#F05B68')
            }.layoutWeight(1)
            Column() {
              this.LaneIcon(row.roleCode)
            }.width(42).height(36).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            Row() {
              Text(row.right !== null && row.right.score > 0 ? row.right.score.toFixed(1) : '—')
                .fontSize(this.readerSize(15)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor('#6F9FE8')
              Text(row.right?.name ?? '—').fontSize(this.readerSize(14)).fontColor($r('app.color.text_primary'))
                .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => {
                  if (row.right !== null) this.openRating(row.right);
                })
            }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 2, bottom: 2 })
        }, (row: LolLaneMatchup) => `lane_${row.roleCode}`)
      }
    }
    .width('100%').padding(Spacing.md)
    .backgroundColor($r('app.color.bg_card')).borderRadius(Radius.md)
  }

  @Builder
  TabLabel(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(this.readerSize(17))
        .fontWeight(this.readerWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal))
        .fontColor(this.tab === index ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
      if (this.tab === index) {
        Divider().color($r('app.color.brand_primary')).strokeWidth(2).width('60%')
      }
    }
    .layoutWeight(1)
    .height(42)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.setTab(index))
  }

  @Builder
  FixtureCard(item: LolFixture) {
    Column({ space: 8 }) {
      Row() {
        Text(`${item.eventName} · ${item.stage} ${item.round}`)
          .fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Text(item.bo).fontSize(this.readerSize(14)).fontColor($r('app.color.text_tertiary'))
      }
      Row() {
        Row({ space: 8 }) {
          if (item.teamALogo.length > 0) {
            ImageKnifeComponent({ imageKnifeOption: { loadSrc: item.teamALogo, objectFit: ImageFit.Contain } })
              .width(30).height(30)
          }
          Text(item.teamA.length > 0 ? item.teamA : '待定')
            .fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium)).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(VerticalAlign.Center)
        Text(this.fixtureStatus(item))
          .fontSize(this.readerSize(15)).fontWeight(this.readerWeight(FontWeight.Medium)).fontColor($r('app.color.brand_primary'))
        Row({ space: 8 }) {
          Text(item.teamB.length > 0 ? item.teamB : '待定')
            .fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium)).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.teamBLogo.length > 0) {
            ImageKnifeComponent({ imageKnifeOption: { loadSrc: item.teamBLogo, objectFit: ImageFit.Contain } })
              .width(30).height(30)
          }
        }.layoutWeight(1).justifyContent(FlexAlign.End).alignItems(VerticalAlign.Center)
      }
      Text(item.matchTime)
        .fontSize(this.readerSize(14)).fontColor($r('app.color.text_tertiary'))
      if (item.status !== '1') {
        Text('查看选手评分与比赛互动 ›')
          .fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary')).width('100%')
      }
    }
    .width('100%')
    .padding(Spacing.md)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Radius.md)
    .onClick(() => this.openFixture(item))
  }

  @Builder
  HupuMatchCard(match: LolMatchNode) {
    Column({ space: 6 }) {
      Text(`${match.event} · ${match.stage}`)
        .fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary')).width('100%')
      Row() {
        Row({ space: 6 }) {
          if (match.teamALogo.length > 0) {
            ImageKnifeComponent({ imageKnifeOption: { loadSrc: match.teamALogo, objectFit: ImageFit.Contain } })
              .width(28).height(28)
          }
          Text(match.teamA).fontSize(this.readerSize(17)).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1)
        Text(`${match.scoreA} : ${match.scoreB}`).fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor($r('app.color.brand_primary'))
        Row({ space: 6 }) {
          Text(match.teamB).fontSize(this.readerSize(17)).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (match.teamBLogo.length > 0) {
            ImageKnifeComponent({ imageKnifeOption: { loadSrc: match.teamBLogo, objectFit: ImageFit.Contain } })
              .width(28).height(28)
          }
        }.layoutWeight(1).justifyContent(FlexAlign.End)
      }
      Text('打开选手评分与对位图 ›').fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary')).width('100%')
    }
    .width('100%').padding(Spacing.md).backgroundColor($r('app.color.bg_card')).borderRadius(Radius.md)
    .onClick(() => this.selectMatch(match))
  }

  ratingTotal(p: LolPlayerScore): number {
    let total: number = 0;
    for (const value of p.ratingDistribution) total += value;
    return total;
  }

  ratingShare(p: LolPlayerScore, index: number): number {
    const total: number = this.ratingTotal(p);
    if (total <= 0 || index < 0 || index >= p.ratingDistribution.length) return 0;
    return p.ratingDistribution[index] * 100 / total;
  }

  @Builder
  RatingBreakdown(p: LolPlayerScore) {
    if (this.ratingTotal(p) > 0) {
      Column({ space: 3 }) {
        ForEach([0, 1, 2, 3, 4], (idx: number) => {
          Row({ space: 7 }) {
            Text(`${(idx + 1) * 2}分`).fontSize(this.readerSize(12)).fontColor($r('app.color.text_secondary')).width(26)
            Progress({ value: this.ratingShare(p, idx), total: 100, type: ProgressType.Linear })
              .color($r('app.color.brand_primary')).layoutWeight(1).height(5)
            Text(`${this.ratingShare(p, idx).toFixed(1)}%`)
              .fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary')).width(40).textAlign(TextAlign.End)
          }.width('100%').alignItems(VerticalAlign.Center)
        }, (idx: number) => `distribution_${p.bizId}_${idx}`)
      }.width('100%')
    }
  }

  @Builder
  PlayerScoreCard(p: LolPlayerScore, ordinal: number, accent: string) {
    Column({ space: 9 }) {
      Row({ space: 10 }) {
        Text(`${ordinal + 1}`).fontSize(this.readerSize(15)).fontColor($r('app.color.text_tertiary')).width(18)
        if (p.avatar.length > 0) {
          ImageKnifeComponent({ imageKnifeOption: { loadSrc: p.avatar, objectFit: ImageFit.Cover } })
            .width(48).height(48).borderRadius(8)
        }
        Column({ space: 4 }) {
          Text(p.name).fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium)).fontColor($r('app.color.text_primary'))
          Text(`${p.kills}/${p.deaths}/${p.assists} K/D/A`)
            .fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary'))
          if (p.label.length > 0 || p.champion.length > 0) {
            Row({ space: 5 }) {
              if (p.champion.length > 0) {
                ImageKnifeComponent({ imageKnifeOption: { loadSrc: p.champion, objectFit: ImageFit.Cover } })
                  .width(22).height(22).borderRadius(5)
              }
              if (p.label.length > 0) {
                Text(p.label).fontSize(this.readerSize(13)).fontColor($r('app.color.brand_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }.alignItems(VerticalAlign.Center)
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 2 }) {
          Text(p.score.toFixed(1)).fontSize(this.readerSize(25)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor(accent)
          Text(`${p.votes > 0 ? `${p.votes} 人评分` : '暂无评分'}${p.commentCount > 0 ? ` · ${p.commentCount} 评论` : ''}`)
            .fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.End)
          Text('评分与互动 ›').fontSize(this.readerSize(13)).fontColor($r('app.color.brand_primary'))
            .onClick(() => this.openRating(p))
        }.alignItems(HorizontalAlign.End)
      }.width('100%')
      this.RatingBreakdown(p)
      if (p.featuredComment.length > 0) {
        Row({ space: 5 }) {
          Text('亮评').fontSize(this.readerSize(13)).fontColor($r('app.color.brand_primary'))
          Text(`“${p.featuredComment}”`).fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary'))
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (p.featuredCommentLights > 0) {
            Text(`${p.featuredCommentLights} 亮`).fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary'))
          }
        }.width('100%')
      }
      Row() {
        Text('快速评分').fontSize(this.readerSize(13)).fontColor($r('app.color.text_tertiary')).layoutWeight(1)
        this.RateButtons(p)
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%').padding(Spacing.md)
    .backgroundColor($r('app.color.bg_card')).borderRadius(Radius.md)
  }

  @Builder
  MatchupDiagram() {
    if (this.selectedMatch === null) {
      Column({ space: 8 }) {
        Text('选择一场有评分数据的比赛').fontSize(this.readerSize(17)).fontColor($r('app.color.text_secondary'))
        if (this.lookupMessage.length > 0 && this.lookupFixture !== null) {
          Column({ space: 8 }) {
            Text(this.lookupMessage).fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary'))
              .width('100%').textAlign(TextAlign.Center)
            Row({ space: 8 }) {
              Text('重试匹配').fontSize(this.readerSize(15)).fontColor($r('app.color.brand_primary'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor($r('app.color.bg_page')).borderRadius(12)
                .onClick(() => this.openFixture(this.lookupFixture as LolFixture))
              Text('查看其他比赛').fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor($r('app.color.bg_page')).borderRadius(12)
                .onClick(() => {
                  this.lookupMessage = '';
                  this.lookupFixture = null;
                })
            }.justifyContent(FlexAlign.Center).width('100%')
          }.width('100%').padding(Spacing.md).backgroundColor($r('app.color.bg_card')).borderRadius(Radius.md)
        }
        ForEach(this.matches, (m: LolMatchNode) => {
          ListItem() { this.HupuMatchCard(m) }
        }, (m: LolMatchNode) => `lolmatch_${m.bizId}`)
      }.width('100%')
    } else {
      Column({ space: 10 }) {
        Column({ space: 8 }) {
          Text(`${this.selectedMatch.event} · ${this.selectedMatch.stage}`)
            .fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary')).width('100%')
          Row() {
            Row({ space: 7 }) {
              if (this.selectedMatch.teamALogo.length > 0) {
                ImageKnifeComponent({ imageKnifeOption: { loadSrc: this.selectedMatch.teamALogo, objectFit: ImageFit.Contain } })
                  .width(34).height(34)
              }
              Text(this.selectedMatch.teamA).fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium))
                .fontColor($r('app.color.text_primary')).maxLines(1)
            }.layoutWeight(1)
            Column({ space: 1 }) {
              Text(`${this.selectedMatch.scoreA} : ${this.selectedMatch.scoreB}`)
                .fontSize(this.readerSize(25)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor($r('app.color.brand_primary'))
              Text('系列赛').fontSize(this.readerSize(12)).fontColor($r('app.color.text_tertiary'))
            }.alignItems(HorizontalAlign.Center)
            Row({ space: 7 }) {
              Text(this.selectedMatch.teamB).fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium))
                .fontColor($r('app.color.text_primary')).maxLines(1)
              if (this.selectedMatch.teamBLogo.length > 0) {
                ImageKnifeComponent({ imageKnifeOption: { loadSrc: this.selectedMatch.teamBLogo, objectFit: ImageFit.Contain } })
                  .width(34).height(34)
              }
            }.layoutWeight(1).justifyContent(FlexAlign.End)
          }.width('100%')
        }
        .width('100%').padding(Spacing.md).backgroundColor($r('app.color.bg_card')).borderRadius(Radius.md)
        Row() {
          Text('更换比赛').fontSize(this.readerSize(14)).fontColor($r('app.color.brand_primary')).layoutWeight(1)
            .onClick(() => {
              this.selectedMatch = null;
              this.scores = [];
            })
          Text(this.selectedGame?.name ?? '').fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary'))
        }.width('100%')
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.games, (g: LolGameNode) => {
              Text(g.name).fontSize(this.readerSize(15)).fontColor(this.selectedGame?.bizId === g.bizId ? $r('app.color.bg_card') : $r('app.color.text_secondary'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(this.selectedGame?.bizId === g.bizId ? $r('app.color.brand_primary') : $r('app.color.bg_page'))
                .borderRadius(14).onClick(() => this.selectGame(g))
            }, (g: LolGameNode) => `lolgame_${g.bizId}`)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
        if (this.detailLoading) {
          Row({ space: 8 }) {
            LoadingProgress().width(20).height(20).color($r('app.color.brand_primary'))
            Text('正在加载本局评分').fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary'))
          }.width('100%').justifyContent(FlexAlign.Center).padding(Spacing.md)
        } else if (this.scores.length === 0) {
          Text('虎扑暂未提供本局选手数据').fontSize(this.readerSize(15)).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center).padding(Spacing.lg)
        } else {
          Column({ space: 8 }) {
            this.LaneSummary()
            Row({ space: 7 }) {
              if (this.selectedMatch.teamALogo.length > 0) {
                ImageKnifeComponent({ imageKnifeOption: { loadSrc: this.selectedMatch.teamALogo, objectFit: ImageFit.Contain } })
                  .width(24).height(24)
              }
              Text(this.selectedMatch.teamA).fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium))
                .fontColor('#F05B68')
            }.width('100%').alignItems(VerticalAlign.Center)
            ForEach(this.teamScores(this.selectedMatch.teamAId), (p: LolPlayerScore, i: number) => {
              this.PlayerScoreCard(p, i, '#F05B68')
            }, (p: LolPlayerScore) => `left_${p.bizId}`)
            Row({ space: 7 }) {
              if (this.selectedMatch.teamBLogo.length > 0) {
                ImageKnifeComponent({ imageKnifeOption: { loadSrc: this.selectedMatch.teamBLogo, objectFit: ImageFit.Contain } })
                  .width(24).height(24)
              }
              Text(this.selectedMatch.teamB).fontSize(this.readerSize(17)).fontWeight(this.readerWeight(FontWeight.Medium))
                .fontColor('#6F9FE8')
            }.width('100%').alignItems(VerticalAlign.Center).margin({ top: 8 })
            ForEach(this.teamScores(this.selectedMatch.teamBId), (p: LolPlayerScore, i: number) => {
              this.PlayerScoreCard(p, i, '#6F9FE8')
            }, (p: LolPlayerScore) => `right_${p.bizId}`)
          }.width('100%')
        }
        Text('局中表态与讨论 ›').fontSize(this.readerSize(15)).fontColor($r('app.color.brand_primary'))
          .onClick(() => this.openMatchInteraction())
      }.width('100%')
    }
  }

  build() {
    NavDestination() {
      Column() {
        AppNavBar({ title: '英雄联盟赛事' })
        Row() {
          this.TabLabel('赛程', 0)
          this.TabLabel('选手榜', 1)
          this.TabLabel('评分对位', 2)
        }.width('100%').backgroundColor($r('app.color.bg_card'))
        if (this.tab === 0) {
          if (this.state === LoadState.Loading) {
            Column() { LoadingProgress().width(28).height(28).color($r('app.color.brand_primary')) }
              .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else if (this.state === LoadState.Error || this.state === LoadState.Empty) {
            Column({ space: 12 }) {
              Text(this.state === LoadState.Error ? '赛程加载失败' : '暂无赛程').fontSize(this.readerSize(17)).fontColor($r('app.color.text_secondary'))
              Button('重试').onClick(() => this.loadFixtures())
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else {
            List({ space: 10 }) {
              ForEach(this.fixtures, (item: LolFixture) => {
                ListItem() { this.FixtureCard(item) }
              }, (item: LolFixture) => `fixture_${item.eventId}_${item.matchId}`)
            }.width('100%').layoutWeight(1).padding(Spacing.md).scrollBar(BarState.Off)
          }
        } else if (this.tab === 1) {
          if (this.boardLoading) {
            Column() { LoadingProgress().width(28).height(28).color($r('app.color.brand_primary')) }
              .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else if (this.leaderboard.length === 0) {
            Column({ space: 8 }) {
              Text('需要读取近期 Hupu 选手评分数据').fontSize(this.readerSize(16)).fontColor($r('app.color.text_secondary'))
              Text('加载选手榜').fontSize(this.readerSize(17)).fontColor($r('app.color.brand_primary')).onClick(() => this.loadLeaderboard())
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else {
            List({ space: 1 }) {
              ForEach(this.leaderboard, (p: LolLeaderboardRow, index: number) => {
                ListItem() {
                  Row({ space: 10 }) {
                    Text(`${index + 1}`).fontSize(this.readerSize(16)).fontColor($r('app.color.text_tertiary')).width(24)
                    Column({ space: 4 }) {
                      Text(p.name).fontSize(this.readerSize(17)).fontColor($r('app.color.text_primary'))
                      Text(`${p.games} 局 · KDA ${p.kda}`).fontSize(this.readerSize(14)).fontColor($r('app.color.text_secondary'))
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                    Text(p.average).fontSize(this.readerSize(19)).fontWeight(this.readerWeight(FontWeight.Bold)).fontColor($r('app.color.brand_primary'))
                  }.padding(Spacing.md).width('100%').backgroundColor($r('app.color.bg_card'))
                }
              }, (p: LolLeaderboardRow) => `leader_${p.name}`)
            }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
          }
        } else {
          if (this.detailLoading && this.matches.length === 0 && this.selectedMatch === null) {
            Column() { LoadingProgress().width(28).height(28).color($r('app.color.brand_primary')) }
              .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else {
            Scroll() { this.MatchupDiagram() }
              .width('100%').layoutWeight(1).padding(Spacing.md).scrollBar(BarState.Off)
          }
        }
      }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
