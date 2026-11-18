import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { appState, AppState, EnvironmentState } from '../model/AppState';
import { titleBar } from '../components/TitleBars';
import { appNav } from '../common/Nav';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { confirmDialog } from '../components/Dialogs';
import { lightEffects } from '../services/LightEffects';
import { Space, Type } from '../common/Typography';
import { animate, ENTER, REVEAL, SPRING, SWAP } from '../common/Motion';
import {
  CLOUD_LANGUAGES,
  CloudModel,
  languageName,
  orderedLanguages,
  providerName,
  SpeechModel,
  SpeechStatus,
  voice,
  VoiceSettings,
} from '../services/Voice';

/** One place recordings can go: off, a computer's own model, or a cloud service through a computer. */
class Destination {
  id: string = '';
  mode: string = 'off';
  environmentId: string = '';
  provider: string = '';
  title: string = '';
  detail: string = '';
  enabled: boolean = true;
}

/** The cloud services one computer holds keys for. */
class CloudKeys {
  environmentId: string = '';
  providers: string[] = [];
}

/** "731 MB", "2.4 GB": model sizes as the desktop shows them. */
function modelSize(bytes: number): string {
  return bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`;
}

/**
 * Settings › 语音输入, as on the desktop: which computer turns speech into text and with which model
 * (one on that computer, or a cloud service it holds a key for), plus recognition options.
 */
@ComponentV2
export struct VoicePage {
  @Local app: AppState = appState;
  @Local prefs: VoiceSettings = voice.settings;
  @Local keys: CloudKeys[] = [];
  @Local models: SpeechModel[] = [];
  @Local status: SpeechStatus | null = null;
  @Local cloudModels: CloudModel[] = [];
  @Local loading: boolean = false;
  @Local loadError: string = '';
  /** A model being selected or downloaded on the computer. */
  @Local busyModelId: string = '';
  @Local downloadingId: string = '';
  @Local showDownloadable: boolean = false;
  private pollTimer: number = -1;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.loadKeys();
    this.loadModels();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  @Monitor('prefs.mode', 'prefs.environmentId', 'prefs.provider')
  onDestinationChanged(): void {
    this.showDownloadable = false;
    this.loadModels();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
  }

  private capable(env: EnvironmentState, capability: string): boolean {
    const caps = env.config?.environment?.capabilities;
    return caps !== undefined && caps[capability] === true;
  }

  /** Which cloud services each connected computer can transcribe with. */
  private async loadKeys(): Promise<void> {
    const found: CloudKeys[] = [];
    for (const env of this.app.environments) {
      if (env.phase !== 'connected' || !this.capable(env, 'cloudVoiceTranscription')) {
        continue;
      }
      try {
        const entry = new CloudKeys();
        entry.environmentId = env.id;
        entry.providers = await voice.cloudKeys(env.id);
        found.push(entry);
      } catch (e) {
        // That computer's keys stay unknown; its own model can still be chosen.
      }
    }
    this.keys = found;
  }

  /** The chosen computer's models (local) or OpenRouter's (cloud), and what is active. */
  private async loadModels(): Promise<void> {
    const seq = ++this.loadSeq;
    const s = this.prefs;
    this.loadError = '';
    this.models = [];
    this.status = null;
    this.cloudModels = [];
    const env = voice.environment();
    if (env === null || env.phase !== 'connected' || (s.mode !== 'local' && !(s.mode === 'cloud' && s.provider === 'openrouter'))) {
      return;
    }
    this.loading = true;
    try {
      if (s.mode === 'local') {
        const models = await voice.models(env.id);
        const status = await voice.status(env.id);
        if (seq === this.loadSeq) {
          animate(this.getUIContext(), () => {
            this.models = models;
            this.status = status;
            this.loading = false;
          });
        }
      } else {
        const models = await voice.cloudModels(env.id);
        if (seq === this.loadSeq) {
          animate(this.getUIContext(), () => {
            this.cloudModels = models;
            this.loading = false;
          });
          if (models.length > 0 && !models.some((m: CloudModel) => m.id === s.cloudModel)) {
            voice.setCloudModel(models[0].id);
          }
        }
      }
    } catch (e) {
      if (seq === this.loadSeq) {
        this.loadError = (e as Error).message;
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  private destinations(): Destination[] {
    const rows: Destination[] = [];
    const off = new Destination();
    off.id = 'voice.dest.off';
    off.title = '关闭';
    rows.push(off);
    this.app.environments.forEach((env: EnvironmentState) => {
      const connected = env.phase === 'connected';
      if (this.capable(env, 'voiceTranscription') || this.isCurrent('local', env.id, '')) {
        const row = new Destination();
        row.id = `voice.dest.${env.id}.local`;
        row.mode = 'local';
        row.environmentId = env.id;
        row.title = env.label;
        row.detail = '本机模型';
        row.enabled = connected;
        rows.push(row);
      }
      const keys = this.keys.find((k: CloudKeys) => k.environmentId === env.id)?.providers ?? [];
      const providers = keys.slice();
      if (this.prefs.mode === 'cloud' && this.prefs.environmentId === env.id && providers.indexOf(this.prefs.provider) < 0) {
        providers.push(this.prefs.provider);
      }
      providers.forEach((provider: string) => {
        const row = new Destination();
        row.id = `voice.dest.${env.id}.${provider}`;
        row.mode = 'cloud';
        row.environmentId = env.id;
        row.provider = provider;
        row.title = env.label;
        row.detail = providerName(provider);
        row.enabled = connected && keys.indexOf(provider) >= 0;
        rows.push(row);
      });
    });
    return rows;
  }

  private isCurrent(mode: string, environmentId: string, provider: string): boolean {
    const s = this.prefs;
    if (mode === 'off') {
      return s.mode === 'off' || s.mode === '';
    }
    return s.mode === mode && s.environmentId === environmentId && s.provider === provider;
  }

  private installed(): SpeechModel[] {
    return this.models.filter((m: SpeechModel) => m.state === 'installed' || m.state === 'verifying');
  }

  private downloading(): SpeechModel[] {
    return this.models.filter((m: SpeechModel) => m.state === 'downloading' ||
      (m.id === this.downloadingId && m.state !== 'installed'));
  }

  /** Not on the computer yet: recommended first, then those that speak the chosen language. */
  private downloadable(): SpeechModel[] {
    const language = this.prefs.language === 'auto' ? 'zh' : this.prefs.language;
    const rank = (m: SpeechModel): number => (m.recommended === true ? 0 : 2) + (m.languages.indexOf(language) >= 0 ? 0 : 1);
    return this.models.filter((m: SpeechModel) => m.state === 'downloadable' && m.id !== this.downloadingId)
      .sort((a: SpeechModel, b: SpeechModel) => rank(a) - rank(b));
  }

  private isActive(model: SpeechModel): boolean {
    return model.active === true || this.status?.modelId === model.id;
  }

  private async select(model: SpeechModel): Promise<void> {
    const env = voice.environment();
    if (env === null || this.isActive(model) || this.busyModelId.length > 0) {
      return;
    }
    this.busyModelId = model.id;
    try {
      this.models = await voice.selectModel(env.id, model.id);
      this.status = await voice.status(env.id);
    } catch (e) {
      this.toast((e as Error).message);
    } finally {
      this.busyModelId = '';
    }
  }

  private async download(model: SpeechModel): Promise<void> {
    const env = voice.environment();
    if (env === null || this.downloadingId.length > 0) {
      return;
    }
    const ok = await confirmDialog(this.getUIContext(), `下载 ${model.name}？`, `${modelSize(model.size)}，下载到 ${env.label}`, '下载');
    if (!ok) {
      return;
    }
    this.downloadingId = model.id;
    this.startPolling(env.id);
    try {
      this.models = await voice.downloadModel(env.id, model.id);
      // Downloaded on purpose: use it.
      this.downloadingId = '';
      this.stopPolling();
      await this.select(model);
    } catch (e) {
      this.toast((e as Error).message);
      this.loadModels();
    } finally {
      this.downloadingId = '';
      this.stopPolling();
    }
  }

  /** The download request answers only at the end; progress comes from the model list meanwhile. */
  private startPolling(environmentId: string): void {
    this.stopPolling();
    this.pollTimer = setInterval(() => {
      voice.models(environmentId).then((models: SpeechModel[]) => {
        if (this.downloadingId.length > 0) {
          this.models = models;
        }
      }).catch(() => {
      });
    }, 1500);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private languages(): string[] {
    if (this.prefs.mode === 'local') {
      return orderedLanguages(this.status?.languages ?? []);
    }
    return orderedLanguages(CLOUD_LANGUAGES);
  }

  private pickLanguage(): void {
    const values = ['auto'].concat(this.languages());
    if (values.indexOf(this.prefs.language) < 0) {
      values.push(this.prefs.language);
    }
    const rows: ActionMenuRow[] = values.map((code: string) =>
    ActionMenuRow.of(`voice.language.${code}`, languageName(code), '', () => voice.setLanguage(code))
      .withSymbol(code === this.prefs.language ? $r('sys.symbol.checkmark') : $r('sys.symbol.circle')));
    showActionMenu(this.getUIContext(), 'voice.language', rows);
  }

  @Builder
  groupTitle(title: string) {
    Text(title)
      .fontSize(Type.small)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.fg_tertiary'))
      .padding({ left: Space.margin, top: 16, bottom: 2 })
      .transition(ENTER)
  }

  @Builder
  divider() {
    Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: Space.margin })
  }

  /** Title, a quiet value and a check on the chosen one. */
  @Builder
  pickRow(id: string, title: string, detail: string, selected: boolean, enabled: boolean, busy: boolean, onTap: () => void) {
    Row({ space: 10 }) {
      Text(title)
        .fontSize(Type.body)
        .fontColor($r('app.color.fg'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (detail.length > 0) {
        Text(detail).fontSize(13).fontColor($r('app.color.fg_secondary')).maxLines(1)
      }
      Stack() {
        if (busy) {
          LoadingProgress().width(18).height(18).color($r('app.color.fg_secondary')).transition(SWAP)
        } else if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.primary')]).transition(SWAP)
        }
      }
      .width(20)
      .height(20)
    }
    .id(id)
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding({ left: 16, right: 14, top: 10, bottom: 10 })
    .opacity(enabled || selected ? 1 : 0.45)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.row_pressed'))
      },
      normal: {
        .backgroundColor(Color.Transparent)
      }
    })
    .onClick(() => {
      if (!enabled) {
        return;
      }
      lightEffects.tap();
      onTap();
    })
  }

  @Builder
  switchRow(id: string, title: string, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row({ space: 12 }) {
      Text(title).fontSize(Type.body).fontColor($r('app.color.fg')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .id(id)
        .onChange((value: boolean) => onChange(value))
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
  }

  @Builder
  destinationGroup() {
    Column() {
      ForEach(this.destinations(), (row: Destination, index: number) => {
        if (index > 0) {
          this.divider()
        }
        this.pickRow(row.id, row.title, row.detail, this.isCurrent(row.mode, row.environmentId, row.provider), row.enabled,
          false, () => animate(this.getUIContext(), () => voice.setDestination(row.mode, row.environmentId, row.provider)))
      }, (row: Destination) => `${row.id}:${row.enabled}:${this.isCurrent(row.mode, row.environmentId, row.provider)}`)
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor($r('app.color.grouped_card'))
    .clip(true)
  }

  @Builder
  statusRow() {
    if (this.loading) {
      Row() {
        LoadingProgress().width(22).height(22).color($r('app.color.fg_secondary'))
      }
      .width('100%')
      .height(56)
      .justifyContent(FlexAlign.Center)
      .transition(ENTER)
    } else if (this.loadError.length > 0) {
      Row({ space: 8 }) {
        Text(this.loadError)
          .fontSize(Type.small)
          .fontColor($r('app.color.status_failed'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([$r('app.color.fg_secondary')])
      }
      .id('voice.retry')
      .width('100%')
      .padding(16)
      .transition(ENTER)
      .onClick(() => this.loadModels())
    }
  }

  /** Models on the computer (tap to use), one downloading, and the catalog to download from. */
  @Builder
  localModelGroup() {
    Column() {
      this.statusRow()
      ForEach(this.installed(), (model: SpeechModel, index: number) => {
        if (index > 0) {
          this.divider()
        }
        this.pickRow(`voice.model.${model.id}`, model.name, modelSize(model.size), this.isActive(model), true,
          this.busyModelId === model.id, () => {
            this.select(model);
          })
      }, (model: SpeechModel) => `${model.id}:${model.state}:${this.isActive(model)}:${this.busyModelId === model.id}`)
      ForEach(this.downloading(), (model: SpeechModel) => {
        this.divider()
        Row({ space: 10 }) {
          Text(model.name).fontSize(Type.body).fontColor($r('app.color.fg')).maxLines(1).layoutWeight(1)
          Text(`${Math.floor(Math.min(1, (model.downloaded ?? 0) / Math.max(1, model.size)) * 100)}%`)
            .id(`voice.downloading.${model.id}`)
            .fontSize(13)
            .fontColor($r('app.color.fg_secondary'))
          LoadingProgress().width(18).height(18).color($r('app.color.fg_secondary'))
        }
        .width('100%')
        .constraintSize({ minHeight: 50 })
        .padding({ left: 16, right: 14, top: 10, bottom: 10 })
      }, (model: SpeechModel) => `${model.id}:${model.downloaded ?? 0}`)
      if (!this.loading && this.loadError.length === 0 && this.downloadable().length > 0) {
        if (this.installed().length + this.downloading().length > 0) {
          this.divider()
        }
        Row({ space: 8 }) {
          Text('下载其他模型').fontSize(Type.body).fontColor($r('app.color.primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(13)
            .fontColor([$r('app.color.fg_tertiary')])
            .rotate({ angle: this.showDownloadable ? 180 : 0 })
            .animation({ curve: SPRING })
        }
        .id('voice.more')
        .width('100%')
        .constraintSize({ minHeight: 50 })
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          lightEffects.tap();
          animate(this.getUIContext(), () => {
            this.showDownloadable = !this.showDownloadable;
          });
        })
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor($r('app.color.grouped_card'))
    .clip(true)
    .transition(ENTER)
    if (this.showDownloadable) {
      Column() {
        ForEach(this.downloadable(), (model: SpeechModel, index: number) => {
          if (index > 0) {
            this.divider()
          }
          Row({ space: 10 }) {
            Text(model.name)
              .fontSize(Type.body)
              .fontColor($r('app.color.fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(modelSize(model.size)).fontSize(13).fontColor($r('app.color.fg_secondary'))
            Button('下载', { type: ButtonType.Capsule, stateEffect: true })
              .id(`voice.download.${model.id}`)
              .fontSize(13)
              .height(30)
              .padding({ left: 12, right: 12 })
              .enabled(this.downloadingId.length === 0)
              .backgroundColor($r('app.color.chip_bg'))
              .fontColor($r('app.color.fg'))
              .onClick(() => {
                lightEffects.tap();
                this.download(model);
              })
          }
          .width('100%')
          .constraintSize({ minHeight: 50 })
          .padding({ left: 16, right: 12, top: 8, bottom: 8 })
        }, (model: SpeechModel) => `${model.id}:${this.downloadingId.length === 0}`)
      }
      .id('voice.downloadable')
      .width('100%')
      .margin({ top: 8 })
      .borderRadius(12)
      .backgroundColor($r('app.color.grouped_card'))
      .clip(true)
      .transition(REVEAL)
    }
  }

  @Builder
  cloudModelGroup() {
    Column() {
      this.statusRow()
      ForEach(this.cloudModels, (model: CloudModel, index: number) => {
        if (index > 0) {
          this.divider()
        }
        this.pickRow(`voice.cloudModel.${model.id}`, model.name, '', this.prefs.cloudModel === model.id, true, false,
          () => voice.setCloudModel(model.id))
      }, (model: CloudModel) => `${model.id}:${this.prefs.cloudModel === model.id}`)
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor($r('app.color.grouped_card'))
    .clip(true)
    .transition(ENTER)
  }

  @Builder
  recognitionGroup() {
    Column() {
      Row({ space: 12 }) {
        Text('语言').fontSize(Type.body).fontColor($r('app.color.fg')).layoutWeight(1)
        Text(languageName(this.prefs.language)).fontSize(Type.body).fontColor($r('app.color.fg_secondary')).maxLines(1)
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.fg_tertiary')])
      }
      .id('voice.language')
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .onClick(() => {
        lightEffects.tap();
        this.pickLanguage();
      })
      this.divider()
      this.switchRow('voice.filler', '去掉语气词', this.prefs.removeFillerWords, (isOn: boolean) => voice.setRemoveFillerWords(isOn))
      if (this.prefs.mode !== 'cloud') {
        this.divider()
        this.switchRow('voice.silence', '过滤静音', this.prefs.silenceFiltering, (isOn: boolean) => voice.setSilenceFiltering(isOn))
      }
      this.divider()
      this.switchRow('voice.cleanup', '整理文字', this.prefs.cleanup, (isOn: boolean) => voice.setCleanup(isOn))
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor($r('app.color.grouped_card'))
    .clip(true)
    .transition(ENTER)
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column({ space: 6 }) {
          this.groupTitle('转写位置')
          this.destinationGroup()
          if (this.prefs.mode === 'local' && voice.environment()?.phase === 'connected') {
            this.groupTitle('模型')
            this.localModelGroup()
          } else if (this.prefs.mode === 'cloud' && this.prefs.provider === 'openrouter' &&
            voice.environment()?.phase === 'connected') {
            this.groupTitle('模型')
            this.cloudModelGroup()
          }
          if (this.prefs.mode === 'local' || this.prefs.mode === 'cloud') {
            this.groupTitle('识别')
            this.recognitionGroup()
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 8, bottom: this.app.bottomInset + 48 })
        .width('100%')
      }
      .id('voice.scroll')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
    }
    .titleBar(titleBar('语音输入', '', [], 'voice.title', 'page.back', () => appNav.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
  }
}
