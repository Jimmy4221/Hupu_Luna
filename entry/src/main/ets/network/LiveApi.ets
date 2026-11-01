import { HttpManager } from './HttpManager';
import { MatchLiveInfo, LiveTvEntry, LiveVideoEntry } from '../model/Models';

/**
 * 比赛直播信息（数据来自虎扑 H5 直播间 SSR 页）。
 *
 * 页面：https://m.hupu.com/{league}/live/{matchId}
 * 内嵌 __NEXT_DATA__.props.pageProps.matchInfo：
 * - matchTvList  官方转播平台入口（tvName/tvUrl/pay），pay=false 即免费；
 * - matchVideoList 虎扑官方视频流（可能为空数组，有值时可在 App 内直接播放）；
 * - openLive / liveOption / defaultShowType 直播开放状态与默认形态（mText=文字直播）。
 *
 * 说明：本应用只使用虎扑公开页面里给出的官方入口与官方流地址，
 * 不解析也不内置任何第三方/未授权直播源。
 */
const BASE: string = 'https://m.hupu.com';

interface LiveFrontStatusDto {
  id?: number;
  desc?: string;
}

interface LiveTvDto {
  tvName?: string;
  tvUrl?: string;
  pay?: boolean;
}

/** matchVideoList 元素结构官方未公开，字段按惯例多名单备，命中即用 */
interface LiveVideoDto {
  title?: string;
  name?: string;
  videoTitle?: string;
  url?: string;
  videoUrl?: string;
  playUrl?: string;
  m3u8?: string;
  src?: string;
  cover?: string;
  img?: string;
  pic?: string;
  quality?: string;
  definition?: string;
  resolution?: string;
}

interface LiveMatchInfoDto {
  matchId?: string;
  matchStatus?: string;
  matchStatusChinese?: string;
  matchTime?: string;
  frontEndMatchStatus?: LiveFrontStatusDto;
  openLive?: boolean;
  liveOption?: string;
  defaultShowType?: string;
  matchTvList?: LiveTvDto[] | null;
  matchVideoList?: LiveVideoDto[] | null;
}

interface LivePagePropsDto {
  matchInfo?: LiveMatchInfoDto;
}

interface LivePageDataDto {
  pageProps?: LivePagePropsDto;
}

interface LiveRespDto {
  props?: LivePageDataDto;
}

export class LiveApi {
  /**
   * 拉取某场比赛的直播入口。
   * @param matchId 比赛 id
   * @param league  联赛路径段（nba / cba），默认 nba
   */
  static async getMatchLive(matchId: string, league: string = 'nba'): Promise<MatchLiveInfo> {
    const info: MatchLiveInfo = new MatchLiveInfo();
    // 已结束/久远的比赛没有直播间页（404 或无 __NEXT_DATA__），统一降级为"无直播入口"
    let html: string = '';
    try {
      html = await HttpManager.get(`${BASE}/${league}/live/${matchId}`);
    } catch (e) {
      return info;
    }
    const json: string = LiveApi.extractNextData(html);
    if (json.length === 0) {
      return info;
    }
    let resp: LiveRespDto;
    try {
      resp = JSON.parse(json) as LiveRespDto;
    } catch (e) {
      return info;
    }
    const mi = resp.props?.pageProps?.matchInfo;
    if (!mi) {
      return info;
    }
    info.matchStatus = mi.matchStatus ?? '';
    info.statusText = LiveApi.statusText(info.matchStatus, mi.matchStatusChinese ?? '');
    info.startText = LiveApi.startText(mi.matchTime ?? '', mi.frontEndMatchStatus?.desc ?? '');
    info.openLive = mi.openLive === true;
    const tvList = mi.matchTvList;
    if (tvList) {
      for (const t of tvList) {
        const name: string = t.tvName ?? '';
        const url: string = t.tvUrl ?? '';
        if (name.length === 0 && url.length === 0) {
          continue;
        }
        const entry: LiveTvEntry = new LiveTvEntry();
        entry.name = name.length > 0 ? name : '官方直播';
        entry.url = url;
        entry.pay = t.pay === true;
        info.tvList.push(entry);
      }
    }
    const videoList = mi.matchVideoList;
    if (videoList) {
      for (const v of videoList) {
        const url: string =
          v.url ?? v.videoUrl ?? v.playUrl ?? v.m3u8 ?? v.src ?? '';
        if (url.length === 0) {
          continue;
        }
        const entry: LiveVideoEntry = new LiveVideoEntry();
        entry.url = url;
        entry.title = v.title ?? v.name ?? v.videoTitle ?? '官方直播';
        entry.cover = v.cover ?? v.img ?? v.pic ?? '';
        entry.quality = v.quality ?? v.definition ?? v.resolution ?? '';
        info.videoList.push(entry);
      }
    }
    return info;
  }

  private static statusText(status: string, cn: string): string {
    if (status === 'INPROGRESS' || status === 'STARTED') {
      return '比赛进行中';
    }
    if (status === 'COMPLETED' || status === 'FINISHED') {
      return '比赛已结束';
    }
    if (status === 'NOTSTARTED' || status === 'SCHEDULED') {
      return '比赛未开始';
    }
    return cn.length > 0 ? cn : '';
  }

  /** 开始时间文案：优先 SSR 的 matchTime，回退到前端状态文案 */
  private static startText(matchTime: string, desc: string): string {
    if (matchTime.length >= 16) {
      const date: string = matchTime.substring(5, 10).replace('-', '月') + '日';
      return `${date} ${matchTime.substring(11, 16)}`;
    }
    return desc;
  }

  /** 取内嵌 JSON；页面没有该标记（非直播间页）时返回空串 */
  private static extractNextData(html: string): string {
    const marker: string = '__NEXT_DATA__';
    const i: number = html.indexOf(marker);
    if (i < 0) {
      return '';
    }
    const s: number = html.indexOf('>', i) + 1;
    const e: number = html.indexOf('</script>', s);
    if (s <= 0 || e <= s) {
      return '';
    }
    return html.substring(s, e);
  }
}
