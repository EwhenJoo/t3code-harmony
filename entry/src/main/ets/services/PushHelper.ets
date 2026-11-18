import { pushService } from '@kit.PushKit';
import { http } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { appState } from '../model/AppState';
import { httpRequest, HttpResult } from '../net/HttpClient';
import { Prefs, PREF_PUSH_DEVICE_ID, PREF_PUSH_HELPER } from '../common/Prefs';
import { Log } from '../common/Log';

const TAG = 'PushHelper';

/** Where the helper listens and the key that proves we scanned its QR. */
export class PushHelperBinding {
  url: string = '';
  key: string = '';
  name: string = '';
}

interface DeviceRegistration {
  key: string;
  token: string;
  deviceId: string;
  label: string;
}

interface TestRequest {
  key: string;
  deviceId: string;
}

interface HelperComputer {
  id?: string;
  label?: string;
  state?: string;
}

export interface HelperStatus {
  ok?: boolean;
  name?: string;
  push?: boolean;
  error?: string;
  computers?: HelperComputer[];
}

function readParam(query: string, name: string): string {
  for (const part of query.split('&')) {
    const eq = part.indexOf('=');
    const key = eq >= 0 ? part.substring(0, eq) : part;
    if (key === name) {
      try {
        return decodeURIComponent(eq >= 0 ? part.substring(eq + 1) : '');
      } catch (e) {
        return '';
      }
    }
  }
  return '';
}

/** `t3code://push?url=http%3A%2F%2F100.x.y.z%3A8790&key=…&name=…`, as `t3-push bind` prints it. */
export function parsePushLink(input: string): PushHelperBinding | null {
  const value = input.trim();
  if (!value.startsWith('t3code://push')) {
    return null;
  }
  const q = value.indexOf('?');
  if (q < 0) {
    return null;
  }
  const query = value.substring(q + 1);
  const binding = new PushHelperBinding();
  binding.url = readParam(query, 'url').replace(/\/+$/, '');
  binding.key = readParam(query, 'key');
  binding.name = readParam(query, 'name');
  if (!/^https?:\/\/[^/]+$/.test(binding.url) || binding.key.length < 16) {
    return null;
  }
  return binding;
}

function describeStatus(status: HelperStatus): string {
  const computers = status.computers ?? [];
  const online = computers.filter((c: HelperComputer) => c.state === 'connected').length;
  if (computers.length === 0) {
    return '还没有接入电脑';
  }
  return online === computers.length ? `${computers.length} 台电脑在线` : `${online}/${computers.length} 台电脑在线`;
}

/**
 * The push helper on one of your computers watches every T3 Code computer and sends Huawei Push Kit
 * notifications, so they arrive even when this app is closed. This side only fetches the Push Kit
 * token and hands it to the helper (over the LAN or Tailscale) when you scan its QR code.
 */
class PushHelperService {
  private token: string = '';
  private binding: PushHelperBinding | null = null;

  /** Restores the saved helper and refreshes the token it holds (tokens can change on reinstall). */
  init(): void {
    const saved = Prefs.getString(PREF_PUSH_HELPER, '');
    if (saved.length > 0) {
      try {
        this.binding = JSON.parse(saved) as PushHelperBinding;
        appState.pushHelperName = this.binding.name.length > 0 ? this.binding.name : this.binding.url;
      } catch (e) {
        Prefs.remove(PREF_PUSH_HELPER);
      }
    }
    this.fetchToken().then(() => {
      if (this.binding !== null) {
        this.register(this.binding).then((status: HelperStatus) => {
          appState.pushHelperDetail = describeStatus(status);
        }).catch((e: Error) => {
          appState.pushHelperDetail = '暂时连不上小助手';
          Log.w(TAG, `refresh registration failed ${e.message}`);
        });
      }
    }).catch((e: Error) => Log.w(TAG, `push token unavailable ${e.message}`));
  }

  private async fetchToken(): Promise<string> {
    if (this.token.length === 0) {
      this.token = await pushService.getToken();
    }
    return this.token;
  }

  private deviceId(): string {
    let id = Prefs.getString(PREF_PUSH_DEVICE_ID, '');
    if (id.length === 0) {
      id = util.generateRandomUUID(true);
      Prefs.put(PREF_PUSH_DEVICE_ID, id);
    }
    return id;
  }

  private async call(binding: PushHelperBinding, method: http.RequestMethod, path: string, body?: string): Promise<HelperStatus> {
    let res: HttpResult;
    try {
      res = await httpRequest(method, `${binding.url}${path}`,
        { 'content-type': 'application/json', 'x-t3-push-key': binding.key }, body, 8000);
    } catch (e) {
      throw new Error(`连不上 ${binding.url}（手机和这台电脑需要在同一网络或 Tailscale 里）`);
    }
    let parsed: HelperStatus = {};
    try {
      parsed = JSON.parse(res.body) as HelperStatus;
    } catch (e) {
      parsed = {};
    }
    if (res.status === 403) {
      throw new Error('二维码已失效，请在电脑上重新运行 t3-push bind');
    }
    if (res.status !== 200 || parsed.ok !== true) {
      throw new Error(parsed.error ?? `小助手返回 HTTP ${res.status}`);
    }
    return parsed;
  }

  private async register(binding: PushHelperBinding): Promise<HelperStatus> {
    const registration: DeviceRegistration = {
      key: binding.key,
      token: await this.fetchToken(),
      deviceId: this.deviceId(),
      label: deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS',
    };
    return await this.call(binding, http.RequestMethod.POST, '/v1/devices', JSON.stringify(registration));
  }

  /** Binds to the helper in a scanned or pasted link; returns a line for the toast. */
  async bind(link: string): Promise<string> {
    const binding = parsePushLink(link);
    if (binding === null) {
      throw new Error('这不是推送小助手的链接（应以 t3code://push 开头）');
    }
    const status = await this.register(binding);
    if (binding.name.length === 0) {
      binding.name = status.name ?? binding.url;
    }
    this.binding = binding;
    Prefs.put(PREF_PUSH_HELPER, JSON.stringify(binding));
    appState.pushHelperName = binding.name;
    appState.pushHelperDetail = describeStatus(status);
    return status.push === false ? `已绑定 ${binding.name}，但它还没配置 Push Kit` : `已绑定 ${binding.name}`;
  }

  async sendTest(): Promise<void> {
    if (this.binding === null) {
      throw new Error('还没有绑定推送小助手');
    }
    const request: TestRequest = { key: this.binding.key, deviceId: this.deviceId() };
    await this.call(this.binding, http.RequestMethod.POST, '/v1/test', JSON.stringify(request));
  }

  async refreshStatus(): Promise<void> {
    if (this.binding === null) {
      return;
    }
    try {
      appState.pushHelperDetail = describeStatus(await this.call(this.binding, http.RequestMethod.GET, '/v1/status'));
    } catch (e) {
      appState.pushHelperDetail = '暂时连不上小助手';
    }
  }

  /** Forgets the helper here; tells it too when it can be reached. */
  async unbind(): Promise<void> {
    const binding = this.binding;
    this.binding = null;
    Prefs.remove(PREF_PUSH_HELPER);
    appState.pushHelperName = '';
    appState.pushHelperDetail = '';
    if (binding !== null) {
      await this.call(binding, http.RequestMethod.DELETE, `/v1/devices/${encodeURIComponent(this.deviceId())}`)
        .catch((e: Error) => Log.w(TAG, `unbind on helper failed ${e.message}`));
    }
  }
}

export const pushHelper: PushHelperService = new PushHelperService();
