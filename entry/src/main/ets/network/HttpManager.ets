import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HttpManager';

const DEFAULT_UA: string =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

/**
 * 全局并发闸门
 *
 * 虎扑接口对并发非常敏感：页面里多个列表/预取同时触发时，几十个请求齐发会被风控限流。
 * 所有请求统一从这里排队，最多 MAX_INFLIGHT 个真正在途，其余按 FIFO 等待。
 * 一旦服务端返回 429/503，再给全局加一个冷却窗口，避免继续撞风控。
 */
const MAX_INFLIGHT: number = 4;
const COOLDOWN_MS: number = 4000;

/** 额外请求头（可选；class 字段点号访问，规避 arkts-no-props-by-index） */
export class ExtraHeaders {
  UA: string = '';
  contentType: string = '';
  referer: string = '';
  cookie: string = '';
}

/** 请求选项 */
export class RequestOptions {
  method: http.RequestMethod = http.RequestMethod.GET;
  headers: ExtraHeaders | null = null;
  body: string = '';
  timeoutMs: number = 0;
  /** 请求头 UA 覆盖（get 第二参数透传用） */
  ua: string = '';
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

class HttpGate {
  private static active: number = 0;
  private static waiters: (() => void)[] = [];
  private static cooldownUntil: number = 0;

  /** 申请一个在途名额（超出并发上限时排队） */
  static acquire(): Promise<void> {
    if (HttpGate.active < MAX_INFLIGHT) {
      HttpGate.active++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      HttpGate.waiters.push(() => {
        resolve();
      });
    });
  }

  /** 释放名额：优先交给排队的请求，否则扣减在途计数 */
  static release(): void {
    if (HttpGate.waiters.length > 0) {
      const next: (() => void) | undefined = HttpGate.waiters.shift();
      if (next !== undefined) {
        next();
        return;
      }
    }
    HttpGate.active = HttpGate.active > 0 ? HttpGate.active - 1 : 0;
  }

  /** 记录一次限流并开启全局冷却 */
  static noteThrottled(): void {
    HttpGate.cooldownUntil = Date.now() + COOLDOWN_MS;
  }

  /** 冷却期内统一等待（避免限流后继续高频撞接口） */
  static async waitCooldown(): Promise<void> {
    let remain: number = HttpGate.cooldownUntil - Date.now();
    while (remain > 0) {
      await sleep(remain > 500 ? 500 : remain);
      remain = HttpGate.cooldownUntil - Date.now();
    }
  }
}

/** 统一请求封装：并发闸门 / 去重 / 超时 / UA / 重试 / 429 冷却 */
export class HttpManager {
  private static inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  private static async requestOnce(url: string, opts: RequestOptions): Promise<string> {
    const request = http.createHttp();
    try {
      const header: Record<string, string> = {
        'User-Agent': opts.ua.length > 0 ? opts.ua : DEFAULT_UA,
        'Accept': 'application/json, text/html, */*'
      };
      const h: ExtraHeaders | null = opts.headers;
      if (h !== null) {
        if (h.UA.length > 0) {
          header['User-Agent'] = h.UA;
        }
        if (h.contentType.length > 0) {
          header['Content-Type'] = h.contentType;
        }
        if (h.referer.length > 0) {
          header['Referer'] = h.referer;
        }
        if (h.cookie.length > 0) {
          header['Cookie'] = h.cookie;
        }
      }
      const resp = await request.request(url, {
        method: opts.method,
        header: header,
        extraData: opts.body.length > 0 ? opts.body : undefined,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: opts.timeoutMs > 0 ? opts.timeoutMs : 10000,
        readTimeout: opts.timeoutMs > 0 ? opts.timeoutMs : 15000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return resp.result as string;
    } finally {
      request.destroy();
    }
  }

  /** GET：默认带网络层重试（超时/连接失败/429/503），相同 URL 的在途请求共享一次网络往返 */
  static async get(url: string, ua: string = DEFAULT_UA): Promise<string> {
    const opts: RequestOptions = new RequestOptions();
    opts.ua = ua;
    return HttpManager.request(url, opts);
  }

  static async request(url: string, opts: RequestOptions): Promise<string> {
    const isGet: boolean = opts.method === http.RequestMethod.GET;
    const key: string = isGet ? `GET|${opts.ua}|${url}` : '';
    if (key.length > 0) {
      const running: Promise<string> | undefined = HttpManager.inflight.get(key);
      if (running !== undefined) {
        return running;
      }
    }
    const task: Promise<string> = HttpManager.run(url, opts);
    if (key.length > 0) {
      HttpManager.inflight.set(key, task);
      task.then((): void => {
        HttpManager.inflight.delete(key);
      }, (): void => {
        HttpManager.inflight.delete(key);
      });
    }
    return task;
  }

  private static async run(url: string, opts: RequestOptions): Promise<string> {
    const isGet: boolean = opts.method === http.RequestMethod.GET;
    // 幂等 GET 最多 3 次；写操作不重试（超时后服务端可能已落库，重发会造成重复回复/重复收藏）
    const attempts: number = isGet ? 3 : 1;
    let lastErr: Error = new Error('unknown');
    for (let attempt: number = 0; attempt < attempts; attempt++) {
      await HttpGate.waitCooldown();
      await HttpGate.acquire();
      try {
        return await HttpManager.requestOnce(url, opts);
      } catch (e) {
        const err = e as Error;
        lastErr = err;
        const isHttp: boolean = err.message.indexOf('HTTP ') === 0;
        const throttled: boolean = err.message === 'HTTP 429' || err.message === 'HTTP 503';
        if (throttled) {
          HttpGate.noteThrottled();
        }
        // 非限流的 HTTP 错误（403/404/500…）重试无意义，直接失败
        if (isHttp && !throttled) {
          break;
        }
        if (attempt < attempts - 1) {
          await sleep(throttled ? 1500 : 400);
        }
      } finally {
        HttpGate.release();
      }
    }
    hilog.error(DOMAIN, TAG, 'request failed: %{public}s', url);
    throw new Error(`网络请求失败: ${lastErr.message}`);
  }

  static async getJson<T>(url: string): Promise<T> {
    const text: string = await HttpManager.get(url);
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      throw new Error('数据解析失败');
    }
  }

  /** 带登录态 Cookie 的 GET JSON（V2 会话验证用） */
  static async getJsonAuth<T>(url: string, cookie: string): Promise<T> {
    const opts: RequestOptions = new RequestOptions();
    const h: ExtraHeaders = new ExtraHeaders();
    h.cookie = cookie;
    opts.headers = h;
    const text: string = await HttpManager.request(url, opts);
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      throw new Error('数据解析失败');
    }
  }

  /** 写操作 POST（V2：桌面 Web 接口，需 Cookie/Referer） */
  static async postJson(url: string, body: string, headers: ExtraHeaders, ua: string): Promise<string> {
    const opts: RequestOptions = new RequestOptions();
    opts.method = http.RequestMethod.POST;
    opts.body = body;
    opts.headers = headers;
    opts.timeoutMs = 15000;
    if (ua.length > 0) {
      opts.ua = ua;
    }
    return HttpManager.request(url, opts);
  }
}
