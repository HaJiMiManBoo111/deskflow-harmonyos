/*
 * Deskflow -- HarmonicOHOS Deskflow client -- background connection carrier
 * 以独立进程承载 Deskflow 连接原生 worker（processMode=1 NEW_PROCESS_ATTACH_TO_PARENT）。
 * 主界面隐藏到托盘时，主 Ability 进入后台，但承载进程保持 FOREGROUND，
 * 因此 TCP 连接与自动重连仍持续运行，无需重新打开主界面。
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import deskflow from 'libentry.so';
import { startServerDiscovery, DISCOVERY_PORT_BG } from '../net/ServerDiscovery';

const DOMAIN = 0x0000;
const TAG = 'DeskflowBG';

/** 广播给主窗口页面的事件名（与 Index.ets 保持一致） */
export const BGEVT_STATUS = 'deskflow.bg.status';
export const BGEVT_CLIP = 'deskflow.bg.clip';
export const BGEVT_STOP = 'deskflow.bg.stop';
export const BGEVT_CLIP_PUSH = 'deskflow.bg.clip.push';
/** 主窗口开关变更广播（连接在本承载进程，主进程的原生实例改不到它） */
export const BGEVT_INVERT = 'deskflow.bg.invert';
export const BGEVT_CLIP_SYNC = 'deskflow.bg.clip.sync';

/**
 * want 参数来源不同：主界面传的是 boolean，`aa start --ps k v` 传进来的是字符串 "true"/"false"。
 * 统一按布尔解析，避免 `param === true` 把字符串 "true" 判成 false。
 */
function toBool(v: Object | undefined | null, def: boolean): boolean {
  if (v === undefined || v === null) {
    return def;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  const s: string = `${v}`.toLowerCase();
  if (s === 'true' || s === '1') {
    return true;
  }
  if (s === 'false' || s === '0') {
    return false;
  }
  return def;
}

export default class BackGroundAbility extends UIAbility {
  /** 当前已生效的服务端地址；用于判断广播来的新地址是否真的变了 */
  private curHost: string = '';
  private curPort: number = 24800;
  private curScreen: string = 'HarmonyPC';
  private curAutoReconnect: boolean = true;
  private curInvert: boolean = false;
  private curClipboard: boolean = false;
  private beaconStarted: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'BackGroundAbility onCreate');
    const host = want.parameters?.['host'] as string;

    if (!host) {
      hilog.info(DOMAIN, TAG, 'no host in want, running as pure carrier');
      // 即使没有 want 推入地址，也要自己听广播：这样冷启动纯载体进程
      // （或 want 里地址已过期）也能靠 beacon 自愈，而不是一直干等主界面。
      this.loadPrefsThenWatch();
      this.wireEvents();
      return;
    }
    this.applyWant(want);
    this.wireEvents();
    this.watchBeacon();
  }

  /**
   * Ability 已存在时再次 startAbility 走这里而不是 onCreate。
   * 修复前没有实现它 —— 旧的承载进程活着时，新推入的 host 永远进不来，
   * 表现就是「Windows 换了 IP，代拉脚本明明跑了，鸿蒙端还连老地址」。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'BackGroundAbility onNewWant');
    const host = want.parameters?.['host'] as string;
    if (!host) {
      hilog.info(DOMAIN, TAG, 'onNewWant without host, ignored');
      return;
    }
    this.applyWant(want);
  }

  /** 从 want 取参数并真正发起连接 / 回写配置 */
  private applyWant(want: Want): void {
    const host = (want.parameters?.['host'] as string).trim();
    if (host.length === 0) {
      return;
    }
    const port = Number(want.parameters?.['port'] ?? 24800);
    const screen = (want.parameters?.['screen'] as string) ?? 'HarmonyPC';
    const autoReconnect = toBool(want.parameters?.['autoreconnect'], true);

    // want 里显式给了就用给的（主界面点「连接」时带），没给就沿用用户上次在界面上的设置。
    // 否则每次启动器代拉都会把滚轮方向/剪贴板开关重置成默认值 —— 用户明明开了反转，
    // 一开机又被拉回默认，表现就是「滚轮方向又反了」。
    const invertRaw = want.parameters?.['invert'];
    const clipRaw = want.parameters?.['clipboard'];
    const invertExplicit: boolean = invertRaw !== undefined && invertRaw !== null;
    const clipExplicit: boolean = clipRaw !== undefined && clipRaw !== null;

    this.connectTo(host, port, screen, autoReconnect,
      invertExplicit ? toBool(invertRaw, false) : undefined,
      clipExplicit ? toBool(clipRaw, false) : undefined);
  }

  /**
   * 统一连接入口：want 推送和 beacon 自愈都走这里。
   * invert/clipboard 传 undefined 表示「沿用偏好里的值」。
   */
  private connectTo(host: string, port: number, screen: string, autoReconnect: boolean,
                    invert: boolean | undefined, clipboard: boolean | undefined): void {
    if (host === this.curHost && port === this.curPort) {
      // 同址重复推送：不动现有连接
      if (invert !== undefined) {
        this.curInvert = invert;
        try {
          deskflow.setInvertScroll(invert);
        } catch (e) {
        }
      }
      if (clipboard !== undefined) {
        this.curClipboard = clipboard;
        try {
          deskflow.setClipboardSync(clipboard);
        } catch (e) {
        }
      }
      hilog.info(DOMAIN, TAG, 'same target, keep current connection %{public}s:%{public}d', host, port);
      return;
    }

    this.curHost = host;
    this.curPort = port;
    this.curScreen = screen;
    this.curAutoReconnect = autoReconnect;
    if (invert !== undefined) {
      this.curInvert = invert;
    }
    if (clipboard !== undefined) {
      this.curClipboard = clipboard;
    }

    this.doConnect(host, port, screen, autoReconnect, 0);
    this.persistConfig(host, port, screen, autoReconnect);
  }

  /**
   * 真正调原生 connectDeskflow，并处理「旧 worker 还没退完」的情况。
   * 原生侧最多等 1.5s，实测切地址时旧连接正在断，经常超过这个窗口，
   * 不重试就会白白丢掉这次换地址请求（旧地址继续连、新地址永远不生效）。
   */
  private doConnect(host: string, port: number, screen: string,
                    autoReconnect: boolean, attempt: number): void {
    try {
      const d = display.getDefaultDisplaySync();
      const w = Math.round(d.width);
      const h = Math.round(d.height);
      deskflow.setAutoReconnect(autoReconnect);
      deskflow.setInvertScroll(this.curInvert);
      deskflow.setClipboardSync(this.curClipboard);
      const ret: string = deskflow.connectDeskflow(host, port, screen, w, h);
      hilog.info(DOMAIN, TAG, 'connect %{public}s:%{public}d attempt=%{public}d ret=%{public}s',
        host, port, attempt, ret);
      if (ret.indexOf('still stopping') >= 0 && attempt < 10) {
        setTimeout(() => {
          // 期间地址又被改掉了就放弃这次重试
          if (this.curHost === host && this.curPort === port) {
            this.doConnect(host, port, screen, autoReconnect, attempt + 1);
          }
        }, 600);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'connect/push failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 冷启动且没有 want 地址时：先读偏好拿上次地址，再开始听广播 */
  private loadPrefsThenWatch(): void {
    try {
      preferences.getPreferences(this.context, 'deskflow_config').then((pref: preferences.Preferences) => {
        const host = (pref.getSync('host', '') as string).trim();
        const port = Number(pref.getSync('port', '24800'));
        const screen = (pref.getSync('client_name', 'HarmonyPC') as string);
        const autoReconnect = pref.getSync('auto_reconnect', true) as boolean;
        const invert = pref.getSync('invert_scroll', false) as boolean;
        const clip = pref.getSync('clipboard_sync', false) as boolean;
        this.curScreen = screen;
        this.curInvert = invert;
        this.curClipboard = clip;
        if (host.length > 0) {
          hilog.info(DOMAIN, TAG, 'carrier resuming saved target %{public}s:%{public}d', host, port);
          this.connectTo(host, port, screen, autoReconnect, invert, clip);
        }
        this.watchBeacon();
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'read prefs fail: %{public}s', JSON.stringify(e));
        this.watchBeacon();
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read prefs throw: %{public}s', JSON.stringify(e));
      this.watchBeacon();
    }
  }

  /**
   * 后台监听 Windows 侧广播（udp/47001），地址变了就自己重连。
   * 这是「主界面没开、Windows 换了 IP」场景的唯一自愈路径：
   * 不再依赖代拉脚本能看见设备，也不依赖用户手动点连接。
   */
  private watchBeacon(): void {
    if (this.beaconStarted) {
      return;
    }
    this.beaconStarted = true;
    startServerDiscovery((host: string, port: number) => {
      if (host === this.curHost && port === this.curPort) {
        return; // 没变，什么都不做
      }
      hilog.info(DOMAIN, TAG, 'beacon %{public}s:%{public}d (current %{public}s:%{public}d)',
        host, port, this.curHost, this.curPort);
      // 不要在这里做 TCP 探测：Deskflow 服务端同一时刻只收一个客户端，
      // 探测连接会占掉客户端槽位、把正在用的连接挤断，
      // 而且探测失败时的「unreachable」日志常常和真实状态相反。
      // 直接连，原生层自带 5s 连接超时 + 重连退避，连不上会自己重试。
      this.connectTo(host, port, this.curScreen, this.curAutoReconnect,
        this.curInvert, this.curClipboard);
    }, DISCOVERY_PORT_BG);
  }

  /**
   * 把本次由 want 推入的服务端地址写回偏好设置。
   * 否则主界面下次仍按旧 IP 自动连接，会把本进程已建立好的连接顶掉
   * （Windows 端重启后 DHCP 换 IP 时必现）。
   */
  private persistConfig(host: string, port: number, screen: string,
                        autoReconnect: boolean): void {
    try {
      preferences.getPreferences(this.context, 'deskflow_config').then((pref: preferences.Preferences) => {
        pref.putSync('host', host);
        pref.putSync('port', `${port}`);
        pref.putSync('client_name', screen);
        pref.putSync('auto_reconnect', autoReconnect);
        pref.putSync('invert_scroll', this.curInvert);
        pref.putSync('clipboard_sync', this.curClipboard);
        pref.flush();
        hilog.info(DOMAIN, TAG, 'persist config host=%{public}s port=%{public}d', host, port);
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'persist config fail: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'persist config throw: %{public}s', JSON.stringify(e));
    }
  }

  private wireEvents(): void {
    // 订阅主窗口的「反转滚轮」开关：连接与注入都在本进程，主进程改原生实例无效
    try {
      const invInfo: commonEventManager.CommonEventSubscribeInfo = { events: [BGEVT_INVERT] };
      const invSub = commonEventManager.createSubscriberSync(invInfo);
      commonEventManager.subscribe(invSub, (err, data) => {
        if (!err && data?.data !== undefined) {
          const on = `${data.data}` === 'true';
          try {
            deskflow.setInvertScroll(on);
            this.curInvert = on;
            hilog.info(DOMAIN, TAG, 'invert scroll applied: %{public}s', on ? 'ON' : 'OFF');
          } catch (e) {
            hilog.error(DOMAIN, TAG, 'setInvertScroll fail: %{public}s', JSON.stringify(e));
          }
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'invert sub fail: %{public}s', JSON.stringify(e));
    }
    // 订阅「剪贴板同步」开关（同样必须落在本进程）
    try {
      const csInfo: commonEventManager.CommonEventSubscribeInfo = { events: [BGEVT_CLIP_SYNC] };
      const csSub = commonEventManager.createSubscriberSync(csInfo);
      commonEventManager.subscribe(csSub, (err, data) => {
        if (!err && data?.data !== undefined) {
          const on = `${data.data}` === 'true';
          try {
            deskflow.setClipboardSync(on);
            this.curClipboard = on;
            hilog.info(DOMAIN, TAG, 'clipboard sync applied: %{public}s', on ? 'ON' : 'OFF');
          } catch (e) {
            hilog.error(DOMAIN, TAG, 'setClipboardSync fail: %{public}s', JSON.stringify(e));
          }
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clip sync sub fail: %{public}s', JSON.stringify(e));
    }
    try {
      deskflow.onDeskflowStatus((event: deskflow.ValueChangeEvent) => {
        const msg: commonEventManager.CommonEventData = { event: BGEVT_STATUS, data: event.value };
        this.publish(msg);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'status cb fail: %{public}s', JSON.stringify(e));
    }
    try {
      deskflow.onClipboardData((event: deskflow.ValueChangeEvent) => {
        hilog.info(DOMAIN, TAG, 'onClipboardData recv len=%{public}d, publish BGEVT_CLIP', (event.value ?? '').length);
        const msg: commonEventManager.CommonEventData = { event: BGEVT_CLIP, data: event.value };
        this.publish(msg);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clip cb fail: %{public}s', JSON.stringify(e));
    }
    // 订阅「断开」事件：主窗口触发时停止后台承载
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = { events: [BGEVT_STOP] };
      const sub = commonEventManager.createSubscriberSync(info);
      commonEventManager.subscribe(sub, (err, data) => {
        if (!err) {
          hilog.info(DOMAIN, TAG, 'stop request received');
          this.context.terminateSelf().catch((e: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'terminateSelf fail: %{public}s', JSON.stringify(e));
          });
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stop sub fail: %{public}s', JSON.stringify(e));
    }
    // 订阅「推送本机剪贴板」：主窗口把本机剪贴板文本发来，由本进程（持有连接）推给服务端（鸿蒙→Windows）
    try {
      const pushInfo: commonEventManager.CommonEventSubscribeInfo = { events: [BGEVT_CLIP_PUSH] };
      const pushSub = commonEventManager.createSubscriberSync(pushInfo);
      commonEventManager.subscribe(pushSub, (err, data) => {
        if (!err && data?.data) {
          const text = `${data.data}`;
          hilog.info(DOMAIN, TAG, 'clip push request len=%{public}d', text.length);
          try {
            // 用户点击 PasteButton 即代表期望同步，确保本进程同步开关打开再推
            deskflow.setClipboardSync(true);
            deskflow.pushClipboard(text);
            hilog.info(DOMAIN, TAG, 'clip pushed to server ok');
          } catch (e) {
            hilog.error(DOMAIN, TAG, 'pushClipboard fail: %{public}s', JSON.stringify(e));
          }
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clip push sub fail: %{public}s', JSON.stringify(e));
    }
  }

  private publish(msg: commonEventManager.CommonEventData): void {
    try {
      const opts: commonEventManager.CommonEventPublishData = { data: msg.data };
      commonEventManager.publish(msg.event, opts, (err) => {
        if (err) {
          hilog.error(DOMAIN, TAG, 'publish %{public}s fail: %{public}s', msg.event, JSON.stringify(err));
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'publish %{public}s error: %{public}s', msg.event, JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'BackGroundAbility onDestroy, stopping client');
    try {
      deskflow.disconnectDeskflow();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'disconnect fail: %{public}s', JSON.stringify(e));
    }
  }
}