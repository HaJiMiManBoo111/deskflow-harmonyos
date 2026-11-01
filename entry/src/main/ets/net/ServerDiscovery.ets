import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'DeskflowDisc';

/** 与 Windows 侧 deskflow-beacon.ps1 约定一致 */
export const DISCOVERY_PORT: number = 47000;
/**
 * 后台承载进程专用监听口。
 * 主界面与承载进程是两个独立进程，抢同一个 UDP 口只会有一个绑定成功，
 * 所以承载进程用 47001 独立监听（Windows 侧 beacon 两个口都发）。
 */
export const DISCOVERY_PORT_BG: number = 47001;
const BEACON_PREFIX: string = 'DESKFLOW_SERVER';

export type ServerFoundHandler = (host: string, port: number) => void;

let gSocket: socket.UDPSocket | null = null;

/**
 * 监听服务端 UDP 广播，发现即回调。
 * 包格式：DESKFLOW_SERVER|1|<ip>|<port>
 */
export function startServerDiscovery(onFound: ServerFoundHandler,
                                     listenPort: number = DISCOVERY_PORT): void {
  if (gSocket) {
    return;
  }
  try {
    const port: number = listenPort;
    const sock = socket.constructUDPSocketInstance();
    sock.on('message', (info: socket.SocketMessageInfo) => {
      try {
        const decoder = util.TextDecoder.create('utf-8');
        const text = decoder.decodeToString(new Uint8Array(info.message));
        const parts: string[] = text.split('|');
        if (parts.length >= 4 && parts[0] === BEACON_PREFIX) {
          const host: string = parts[2].trim();
          const port: number = Number(parts[3]);
          if (host.length > 0 && port > 0) {
            hilog.info(DOMAIN, TAG, 'beacon from %{public}s:%{public}d', host, port);
            onFound(host, port);
          }
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'parse beacon fail: %{public}s', JSON.stringify(e));
      }
    });
    sock.bind({ address: '0.0.0.0', port: port, family: 1 })
      .then(() => {
        gSocket = sock;
        hilog.info(DOMAIN, TAG, 'discovery listening on udp/%{public}d', port);
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'bind udp/%{public}d failed: %{public}d %{public}s',
          port, err.code, err.message);
      });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'start discovery error: %{public}s', JSON.stringify(e));
  }
}

export function stopServerDiscovery(): void {
  if (!gSocket) {
    return;
  }
  try {
    gSocket.off('message');
    gSocket.close();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'stop discovery error: %{public}s', JSON.stringify(e));
  }
  gSocket = null;
}

/**
 * 判断 host:port 是否可连（TCP 建连成功即返回 true）。
 * 广播包里的地址是 Windows 侧猜的，换网卡/换网段时可能暂时不可达，
 * 用它挡掉无效地址，避免把已经好的连接顶成 error。
 */
export function probeTcp(host: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise<boolean>((resolve: (v: boolean) => void) => {
    let settled: boolean = false;
    let sock: socket.TCPSocket | null = null;
    const finish = (ok: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (sock) {
        try {
          sock.close();
        } catch (e) {
        }
      }
      resolve(ok);
    };
    const timer = setTimeout(() => {
      finish(false);
    }, timeoutMs);
    try {
      sock = socket.constructTCPSocketInstance();
      sock.connect({ address: { address: host, port: port, family: 1 }, timeout: timeoutMs })
        .then(() => {
          clearTimeout(timer);
          finish(true);
        })
        .catch((err: BusinessError) => {
          clearTimeout(timer);
          hilog.info(DOMAIN, TAG, 'probe %{public}s:%{public}d fail %{public}d', host, port, err.code);
          finish(false);
        });
    } catch (e) {
      clearTimeout(timer);
      finish(false);
    }
  });
}
