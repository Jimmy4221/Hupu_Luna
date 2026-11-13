/**
 * 通用工具：HTML 处理、时间格式化
 */

const TAG_REG: RegExp = new RegExp('<[^>]+>', 'g');
const IMG_REG: RegExp = new RegExp('<img[^>]+src="([^"]+)"', 'g');

/** HTML 转纯文本（保留段落换行） */
export function htmlToText(html: string): string {
  if (!html) {
    return '';
  }
  let s: string = html;
  s = s.replace(new RegExp('<br\\s*/?>', 'gi'), '\n');
  s = s.replace(new RegExp('</p>', 'gi'), '\n');
  s = s.replace(TAG_REG, '');
  s = s.replace(new RegExp('&nbsp;', 'g'), ' ');
  s = s.replace(new RegExp('&amp;', 'g'), '&');
  s = s.replace(new RegExp('&lt;', 'g'), '<');
  s = s.replace(new RegExp('&gt;', 'g'), '>');
  s = s.replace(new RegExp('&quot;', 'g'), '"');
  s = s.replace(new RegExp('&#39;', 'g'), "'");
  s = s.replace(new RegExp('\\n{3,}', 'g'), '\n\n');
  return s.trim();
}

/** 提取 HTML 中的图片地址 */
export function extractImages(html: string): string[] {
  const result: string[] = [];
  if (!html) {
    return result;
  }
  const reg: RegExp = new RegExp(IMG_REG.source, 'g');
  let m: RegExpExecArray | null = reg.exec(html);
  while (m !== null) {
    const url: string = m[1];
    if (url.indexOf('http') === 0) {
      result.push(url);
    }
    m = reg.exec(html);
  }
  return result;
}

/** 帖子正文字段兼容：纯 HTML 或 {"team":...} 卡片 JSON */
export function normalizeContent(raw: string): string {
  if (!raw) {
    return '';
  }
  const t: string = raw.trim();
  if (t.indexOf('{') === 0) {
    return '（含赛事卡片，详见原帖）';
  }
  return raw;
}

/** 秒级时间戳 → 相对时间 / 日期 */
export function formatTime(sec: number): string {  if (sec <= 0) {
    return '';
  }
  const now: number = Math.floor(Date.now() / 1000);
  const diff: number = now - sec;
  if (diff < 60) {
    return '刚刚';
  }
  if (diff < 3600) {
    return `${Math.floor(diff / 60)}分钟前`;
  }
  if (diff < 86400) {
    return `${Math.floor(diff / 3600)}小时前`;
  }
  if (diff < 86400 * 7) {
    return `${Math.floor(diff / 86400)}天前`;
  }
  const d: Date = new Date(sec * 1000);
  const mm: number = d.getMonth() + 1;
  const dd: number = d.getDate();
  return `${mm}-${dd < 10 ? '0' + dd : dd}`;
}

/** 图片地址瘦身：OSS 参数裁剪 */
export function thumbUrl(url: string, width: number): string {
  if (!url) {
    return '';
  }
  if (url.indexOf('hoopchina.com.cn') < 0) {
    return url;
  }
  const base: string = url.indexOf('?') >= 0 ? `${url}&` : `${url}?`;
  return `${base}x-oss-process=image/resize,w_${width}/format,webp`;
}

/** 把"昨天 HH:MM / 前天 HH:MM"换算成时间戳 */
function dayAt(nowMs: number, daysAgo: number, hour: number, minute: number): number {
  const d: Date = new Date(nowMs);
  d.setDate(d.getDate() - daysAgo);
  d.setHours(hour, minute, 0, 0);
  return d.getTime();
}

/**
 * 信息流时间文案 → 时间戳（ms）；无法识别返回 0。
 * 支持：刚刚 / N秒前 / N分钟前 / N小时前 / N天前 / 昨天 HH:MM / 前天 HH:MM /
 *      MM-DD / MM-DD HH:MM / YYYY-MM-DD / YYYY-MM-DD HH:MM
 */
export function parseFeedTime(text: string): number {
  const t: string = (text ?? '').trim();
  if (t.length === 0) {
    return 0;
  }
  const now: number = Date.now();
  if (t === '刚刚') {
    return now;
  }
  let m: RegExpExecArray | null = new RegExp('^(\\d+)\\s*秒前$').exec(t);
  if (m !== null) {
    return now - Number(m[1]) * 1000;
  }
  m = new RegExp('^(\\d+)\\s*分钟前$').exec(t);
  if (m !== null) {
    return now - Number(m[1]) * 60000;
  }
  m = new RegExp('^(\\d+)\\s*小时前$').exec(t);
  if (m !== null) {
    return now - Number(m[1]) * 3600000;
  }
  m = new RegExp('^(\\d+)\\s*天前$').exec(t);
  if (m !== null) {
    return now - Number(m[1]) * 86400000;
  }
  m = new RegExp('^昨天\\s*(\\d{1,2}):(\\d{2})$').exec(t);
  if (m !== null) {
    return dayAt(now, 1, Number(m[1]), Number(m[2]));
  }
  m = new RegExp('^前天\\s*(\\d{1,2}):(\\d{2})$').exec(t);
  if (m !== null) {
    return dayAt(now, 2, Number(m[1]), Number(m[2]));
  }
  m = new RegExp('^(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:\\s+(\\d{1,2}):(\\d{2}))?$').exec(t);
  if (m !== null) {
    const d: Date = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
      m[4] !== undefined ? Number(m[4]) : 0, m[5] !== undefined ? Number(m[5]) : 0);
    return d.getTime();
  }
  m = new RegExp('^(\\d{1,2})-(\\d{1,2})(?:\\s+(\\d{1,2}):(\\d{2}))?$').exec(t);
  if (m !== null) {
    const year: number = new Date(now).getFullYear();
    const d: Date = new Date(year, Number(m[1]) - 1, Number(m[2]),
      m[3] !== undefined ? Number(m[3]) : 0, m[4] !== undefined ? Number(m[4]) : 0);
    // 跨年（12 月看到 1 月的日期）视为去年
    if (d.getTime() > now + 24 * 3600 * 1000) {
      d.setFullYear(year - 1);
    }
    return d.getTime();
  }
  return 0;
}

