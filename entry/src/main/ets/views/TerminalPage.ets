import { webview } from '@kit.ArkWeb';
import { MaterialStyle, ScrollMaterial } from '../common/Material';
import { resourceManager } from '@kit.LocalizationKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { appState, AppState, EnvironmentState } from '../model/AppState';
import {
  baseName,
  TerminalAttachEvent,
  TerminalAttachInput,
  TerminalCloseInput,
  TerminalResizeInput,
  TerminalSummary,
  TerminalWriteInput,
} from '../model/Workspace';
import { WorkspaceRouteParam } from '../common/Nav';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { ThreadWorkspace, workspaces } from '../services/Workspace';
import { symbolItem, titleBar } from '../components/TitleBars';
import { confirmDialog } from '../components/Dialogs';
import { Log } from '../common/Log';
import { Type } from '../common/Typography';

const TAG = 'Terminal';
const MAX_HISTORY_BYTES = 512 * 1024;
const WRITE_CHUNK = 60000;

/** Called from terminal.html through javaScriptProxy. */
class TerminalBridge {
  onReadyHandler: (cols: number, rows: number) => void = () => {
  };
  onInputHandler: (data: string) => void = () => {
  };
  onResizeHandler: (cols: number, rows: number) => void = () => {
  };

  onReady(cols: number, rows: number): void {
    this.onReadyHandler(cols, rows);
  }

  onInput(data: string): void {
    this.onInputHandler(data);
  }

  onResize(cols: number, rows: number): void {
    this.onResizeHandler(cols, rows);
  }
}

class AccessoryKey {
  id: string;
  label: string;
  /** Bytes sent to the shell; '' for the Ctrl toggle. */
  data: string;

  constructor(id: string, label: string, data: string) {
    this.id = id;
    this.label = label;
    this.data = data;
  }
}

const KEYS: AccessoryKey[] = [
  new AccessoryKey('esc', 'Esc', '\u001b'),
  new AccessoryKey('tab', 'Tab', '\t'),
  new AccessoryKey('ctrl', 'Ctrl', ''),
  new AccessoryKey('up', '↑', '\u001b[A'),
  new AccessoryKey('down', '↓', '\u001b[B'),
  new AccessoryKey('left', '←', '\u001b[D'),
  new AccessoryKey('right', '→', '\u001b[C'),
  new AccessoryKey('ctrlc', '^C', '\u0003'),
  new AccessoryKey('pipe', '|', '|'),
  new AccessoryKey('dash', '-', '-'),
  new AccessoryKey('slash', '/', '/'),
  new AccessoryKey('tilde', '~', '~'),
];

/**
 * A thread's terminal, like the iOS terminal screen: an xterm.js surface (ArkWeb) attached to the
 * computer's PTY, with an accessory key row for keys a phone keyboard lacks.
 */
@ComponentV2
export struct TerminalPage {
  @Local app: AppState = appState;
  @Local workspace: ThreadWorkspace | null = null;
  @Local status: string = '正在连接…';
  @Local ctrlArmed: boolean = false;
  @Local exited: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: TerminalBridge = new TerminalBridge();
  private stack: NavPathStack | null = null;
  private threadId: string = '';
  private terminalId: string = 'term-1';
  private environmentId: string = '';
  private cwd: string = '';
  private attachRequest: string = '';
  private cols: number = 80;
  private rows: number = 24;
  private ready: boolean = false;
  private attached: boolean = false;
  private pendingOutput: string = '';
  private flushTimer: number = -1;
  private resizeTimer: number = -1;
  private disposed: boolean = false;
  /** A project script waiting for the shell to attach. */
  private pendingCommand: string = '';
  private resumeTimer: number = -1;

  @Computed
  get environment(): EnvironmentState | null {
    return this.app.environmentFor(this.environmentId);
  }

  @Computed
  get summary(): TerminalSummary | null {
    const list = this.workspace?.terminals ?? [];
    const found = list.find((t: TerminalSummary) => t.terminalId === this.terminalId);
    return found ?? null;
  }

  /** The attach stream dies with the socket; resume it once the computer is back. */
  private scheduleResume(): void {
    if (this.resumeTimer >= 0 || this.disposed) {
      return;
    }
    this.resumeTimer = setTimeout(() => {
      this.resumeTimer = -1;
      if (this.disposed) {
        return;
      }
      if (this.environment?.phase === 'connected') {
        this.attach(true);
      } else {
        this.scheduleResume();
      }
    }, 1500);
  }

  private isDark(): boolean {
    try {
      const config = this.getUIContext().getHostContext()?.resourceManager.getConfigurationSync();
      return config?.colorMode === resourceManager.ColorMode.DARK;
    } catch (e) {
      return false;
    }
  }

  private js(script: string): void {
    try {
      this.controller.runJavaScript(script).catch((e: Error) => Log.d(TAG, `js failed ${e.message}`));
    } catch (e) {
      Log.d(TAG, 'web not ready');
    }
  }

  private writeToScreen(data: string): void {
    this.pendingOutput += data;
    if (this.flushTimer < 0) {
      this.flushTimer = setTimeout(() => {
        this.flushTimer = -1;
        const chunk = this.pendingOutput;
        this.pendingOutput = '';
        if (chunk.length > 0) {
          this.js(`window.t3 && t3.write(${JSON.stringify(chunk)})`);
        }
      }, 16);
    }
  }

  private attach(resume: boolean): void {
    if (this.attachRequest.length > 0) {
      connection.rpcInterrupt(this.environmentId, this.attachRequest);
      this.attachRequest = '';
    }
    const input: TerminalAttachInput = {
      threadId: this.threadId,
      terminalId: this.terminalId,
      cwd: this.cwd,
      cols: this.cols,
      rows: this.rows,
      maxHistoryBytes: MAX_HISTORY_BYTES,
    };
    if (resume) {
      input.resume = true;
    }
    this.status = '正在连接…';
    this.attachRequest = connection.rpcStream(this.environmentId, 'terminal.attach', input, (values: Object[]) => {
      values.forEach((value: Object) => this.onEvent(value as TerminalAttachEvent));
    }, (ok: boolean, value: Object | null, error: string) => {
      this.attached = false;
      if (!ok && error.length > 0 && !this.disposed) {
        this.status = `已断开：${error}，正在重连…`;
        this.scheduleResume();
      }
    });
  }

  private onEvent(event: TerminalAttachEvent): void {
    switch (event.type) {
      case 'snapshot':
      case 'restarted': {
        this.attached = true;
        this.exited = false;
        this.status = '';
        const history = event.snapshot?.history ?? '';
        this.pendingOutput = '';
        this.js(`window.t3 && t3.reset(${JSON.stringify(history)})`);
        if (event.snapshot?.error) {
          this.status = event.snapshot.error;
        }
        // The PTY keeps the size the last client set; match it to this screen.
        this.sendResize();
        if (this.pendingCommand.length > 0) {
          const command = this.pendingCommand;
          this.pendingCommand = '';
          this.send(`${command}\r`);
        }
        break;
      }
      case 'output':
        this.writeToScreen(event.data ?? '');
        break;
      case 'cleared':
        this.js('window.t3 && t3.clear()');
        break;
      case 'exited':
        this.exited = true;
        this.writeToScreen(`\r\n\u001b[2m[进程已退出${event.exitCode !== null && event.exitCode !== undefined ? `，代码 ${event.exitCode}` : ''}]\u001b[0m\r\n`);
        break;
      case 'closed':
        this.exited = true;
        this.status = '终端已关闭';
        break;
      case 'error':
        this.status = event.message ?? '终端出错';
        break;
      default:
        break;
    }
  }

  private send(data: string): void {
    if (data.length === 0 || !this.attached) {
      return;
    }
    for (let start = 0; start < data.length; start += WRITE_CHUNK) {
      const input: TerminalWriteInput = {
        threadId: this.threadId,
        terminalId: this.terminalId,
        data: data.substring(start, Math.min(data.length, start + WRITE_CHUNK)),
      };
      connection.rpc(this.environmentId, 'terminal.write', input).catch((e: Error) => {
        this.status = `发送失败：${e.message}`;
      });
    }
  }

  /** Keyboard input from xterm; a armed Ctrl turns the next letter into its control code. */
  private onInput(data: string): void {
    let out = data;
    if (this.ctrlArmed && data.length === 1) {
      const code = data.toUpperCase().charCodeAt(0);
      if (code >= 64 && code <= 95) {
        out = String.fromCharCode(code - 64);
      }
      this.ctrlArmed = false;
    }
    this.send(out);
  }

  private sendResize(): void {
    if (!this.attached) {
      return;
    }
    const input: TerminalResizeInput = { threadId: this.threadId, terminalId: this.terminalId, cols: this.cols, rows: this.rows };
    connection.rpc(this.environmentId, 'terminal.resize', input).catch(() => {
    });
  }

  private onResize(cols: number, rows: number): void {
    this.cols = Math.max(1, Math.min(1000, cols));
    this.rows = Math.max(1, Math.min(500, rows));
    if (this.resizeTimer >= 0) {
      clearTimeout(this.resizeTimer);
    }
    this.resizeTimer = setTimeout(() => {
      this.resizeTimer = -1;
      this.sendResize();
    }, 150);
  }

  private pressKey(key: AccessoryKey): void {
    lightEffects.tap();
    if (key.id === 'ctrl') {
      this.ctrlArmed = !this.ctrlArmed;
      return;
    }
    this.send(key.data);
    this.js('window.t3 && t3.focus()');
  }

  private async closeTerminal(): Promise<void> {
    const ok = await confirmDialog(this.getUIContext(), '关闭这个终端？', '会结束其中运行的进程。', '关闭', true);
    if (!ok) {
      return;
    }
    const input: TerminalCloseInput = { threadId: this.threadId, terminalId: this.terminalId };
    try {
      await connection.rpc(this.environmentId, 'terminal.close', input);
      this.stack?.pop();
    } catch (e) {
      this.status = `关闭失败：${(e as Error).message}`;
    }
  }

  private subtitle(): string {
    const parts: string[] = [];
    if (this.app.multiEnv && this.environment !== null) {
      parts.push(this.environment.label);
    }
    const cwd = this.summary?.cwd ?? this.cwd;
    if (cwd.length > 0) {
      parts.push(baseName(cwd));
    }
    if (this.exited) {
      parts.push('已退出');
    } else if (this.summary?.hasRunningSubprocess) {
      parts.push('运行中');
    }
    return parts.join(' · ');
  }

  @Builder
  accessoryBar() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(KEYS, (key: AccessoryKey) => {
          Text(key.label)
            .id(`terminal.key.${key.id}`)
            .fontSize(Type.small)
            .fontWeight(FontWeight.Medium)
            .fontFamily('monospace')
            .fontColor(key.id === 'ctrl' && this.ctrlArmed ? $r('app.color.prominent_fg') : $r('app.color.fg'))
            .textAlign(TextAlign.Center)
            .constraintSize({ minWidth: 44 })
            .height(34)
            .padding({ left: 10, right: 10 })
            .borderRadius(17)
            .backgroundColor(key.id === 'ctrl' && this.ctrlArmed ? $r('app.color.prominent') : $r('app.color.chip_bg'))
            .onClick(() => this.pressKey(key))
        }, (key: AccessoryKey) => `${key.id}:${key.id === 'ctrl' ? this.ctrlArmed : ''}`)
      }
      .padding({ left: 12, right: 12 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(48)
    .backgroundColor($r('app.color.status_backdrop'))
    .backdropBlur(24)
    .border({ width: { top: 0.5 }, color: { top: $r('app.color.hairline') } })
    .attributeModifier(new ScrollMaterial(MaterialStyle.THIN))
  }

  build() {
    HdsNavDestination() {
      Column() {
        Stack({ alignContent: Alignment.Top }) {
          Web({ src: $rawfile('terminal/terminal.html'), controller: this.controller })
            .id('terminal.web')
            .javaScriptAccess(true)
            .domStorageAccess(false)
            .fileAccess(true)
            .zoomAccess(false)
            .overScrollMode(OverScrollMode.NEVER)
            .backgroundColor(this.isDark() ? '#0F0F11' : '#FFFFFF')
            .javaScriptProxy({
              object: this.bridge,
              name: 't3native',
              methodList: ['onReady', 'onInput', 'onResize'],
              controller: this.controller,
            })
            .onPageEnd(() => {
              this.js(`window.t3 && t3.setDark(${this.isDark()})`);
            })
            .width('100%')
            .height('100%')

          if (this.status.length > 0) {
            Text(this.status)
              .id('terminal.status')
              .fontSize(Type.small)
              .fontColor($r('app.color.fg_secondary'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor($r('app.color.glass'))
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .margin({ top: 8 })
          }
        }
        .layoutWeight(1)
        .width('100%')

        this.accessoryBar()
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.app.keyboardHeight > 0 ? 0 : this.app.bottomInset })
    }
    .titleBar(titleBar(this.summary?.label && this.summary.label !== 'shell' ? this.summary.label : `终端 ${this.terminalId.replace('term-', '')}`,
      this.subtitle(), [
        symbolItem($r('sys.symbol.keyboard'), '键盘', 'terminal.keyboard', () => this.js('window.t3 && t3.focus()')),
        symbolItem($r('sys.symbol.xmark_circle'), '关闭终端', 'terminal.close', () => this.closeTerminal()),
      ], 'terminal.title', 'page.back', () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor(this.isDark() ? '#0F0F11' : '#FFFFFF')
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      const param = context.pathInfo.param as WorkspaceRouteParam;
      this.threadId = param?.threadId ?? '';
      this.terminalId = (param?.target ?? '').length > 0 ? param.target : 'term-1';
      this.pendingCommand = param?.command ?? '';
      this.environmentId = this.app.environmentOfThread(this.threadId)?.id ?? '';
      this.workspace = workspaces.acquire(this.threadId);
      this.cwd = this.workspace?.cwd ?? '';
      this.bridge.onReadyHandler = (cols: number, rows: number) => {
        this.cols = cols;
        this.rows = rows;
        this.ready = true;
        this.attach(false);
      };
      this.bridge.onInputHandler = (data: string) => this.onInput(data);
      this.bridge.onResizeHandler = (cols: number, rows: number) => this.onResize(cols, rows);
    })
    .onWillDisappear(() => {
      this.disposed = true;
      if (this.resumeTimer >= 0) {
        clearTimeout(this.resumeTimer);
        this.resumeTimer = -1;
      }
      if (this.attachRequest.length > 0) {
        connection.rpcInterrupt(this.environmentId, this.attachRequest);
        this.attachRequest = '';
      }
      workspaces.release(this.workspace);
      this.workspace = null;
    })
  }
}
