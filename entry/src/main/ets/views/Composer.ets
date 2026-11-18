import { common } from '@kit.AbilityKit';
import { MaterialStyle, ColumnMaterial } from '../common/Material';
import { lightEffects } from '../services/LightEffects';
import { Space, Type } from '../common/Typography';
import { ChatAttachment } from '../model/Types';
import { attachments, DraftAttachment, MAX_ATTACHMENTS, sizeLabel } from '../services/Attachments';
import { drafts } from '../services/Drafts';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { MIN_RECORDING_SECONDS, voice, VoiceRecording, VoiceSettings } from '../services/Voice';
import { openVoiceSettings } from '../common/Nav';
import { FADE, RISE, SHIFT, STATE_CHANGE, SWAP } from '../common/Motion';

/** Bars in the recording level meter. */
const VOICE_BARS = 14;

/** "0:07" */
function clockLabel(seconds: number): string {
  const whole = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${(whole % 60).toString().padStart(2, '0')}`;
}

/** One attached photo or file above the field: thumbnail or name, upload state, and a remove button. */
@ComponentV2
struct AttachmentChip {
  @Param file: DraftAttachment = new DraftAttachment();
  @Event onRemove: () => void = () => {
  };
  @Event onRetry: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.file.kind === 'image') {
        Image(this.file.uri)
          .width(56)
          .height(56)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .backgroundColor($r('app.color.chip_bg'))
      } else {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.doc')).fontSize(20).fontColor([$r('app.color.fg_secondary')])
          Column({ space: 1 }) {
            Text(this.file.name)
              .fontSize(Type.small)
              .fontColor($r('app.color.fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.CENTER)
            Text(this.file.status === 'failed' ? this.file.error : sizeLabel(this.file.sizeBytes))
              .fontSize(11)
              .fontColor(this.file.status === 'failed' ? $r('app.color.status_failed') : $r('app.color.fg_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ maxWidth: 150 })
        }
        .height(56)
        .padding({ left: 10, right: 22 })
        .borderRadius(12)
        .backgroundColor($r('app.color.chip_bg'))
      }
      // Uploading: a quiet veil with a spinner; failed: tap to try again.
      if (this.file.status !== 'ready') {
        Column() {
          if (this.file.status === 'uploading') {
            LoadingProgress().width(20).height(20).color($r('app.color.fg_secondary'))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(18).fontColor([$r('app.color.status_failed')])
          }
        }
        .width('100%')
        .height(56)
        .justifyContent(FlexAlign.Center)
        .borderRadius(12)
        .backgroundColor($r('app.color.attachment_veil'))
        .hitTestBehavior(this.file.status === 'failed' ? HitTestMode.Default : HitTestMode.Transparent)
        .accessibilityText(this.file.status === 'failed' ? `重新上传 ${this.file.name}` : `正在上传 ${this.file.name}`)
        .onClick(() => {
          if (this.file.status === 'failed') {
            this.onRetry();
          }
        })
      }
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(10).fontColor([Color.White])
      }
      .id(`composer.file.remove.${this.file.name}`)
      .width(20)
      .height(20)
      .margin({ top: 3, right: 3 })
      .backgroundColor('#99000000')
      .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
      .accessibilityText(`移除 ${this.file.name}`)
      .onClick(() => this.onRemove())
    }
    .id(`composer.file.${this.file.name}`)
  }
}

/**
 * Bottom composer, laid out like the iOS one: the message on top, a quiet tool row underneath
 * with the model and plan controls on the left and send / stop always on the right.
 */
@ComponentV2
export struct Composer {
  @Param running: boolean = false;
  @Param active: boolean = true;
  @Param placeholder: string = '给代理发消息';
  @Param caption: string = '';
  @Param bottomInset: number = 0;
  /** "Opus 5.5 · 高 · 快速"; empty hides the model control. */
  @Param modelSummary: string = '';
  @Param planMode: boolean = false;
  /** 'send' makes the return key send; 'newline' keeps multi-line typing. */
  @Param returnKey: string = 'newline';
  /**
   * What the agent suggests saying next (desktop Labs "prompt suggestions"). While the field is empty
   * it shows in place of the placeholder and the send button becomes 补全, which fills it in.
   */
  @Param suggestion: string = '';
  /** The computer the message goes to; attachments upload there (and again if it changes). */
  @Param environmentId: string = '';
  /** Bumping `refillSeq` puts `refillText` back into the field (a message that could not be sent). */
  @Param refillText: string = '';
  @Param refillSeq: number = 0;
  /** The conversation whose unsent text this field keeps (a draft); '' keeps nothing. */
  @Param draftKey: string = '';
  @Event onSend: (text: string, files: ChatAttachment[]) => void = () => {
  };
  @Event onStop: () => void = () => {
  };
  @Event onModelTap: () => void = () => {
  };
  @Event onPlanToggle: () => void = () => {
  };
  @Local text: string = '';
  @Local focused: boolean = false;
  @Local files: DraftAttachment[] = [];
  @Local voicePrefs: VoiceSettings = voice.settings;
  /** idle | starting | recording | transcribing */
  @Local voicePhase: string = 'idle';
  @Local voiceLevels: number[] = [];
  @Local voiceSeconds: number = 0;
  private inputController: TextAreaController = new TextAreaController();
  private recording: VoiceRecording | null = null;
  private voiceTimer: number = -1;
  /** Bumped on cancel, so a transcript that arrives late is dropped. */
  private voiceTicket: number = 0;
  /** Where the words go: the caret when recording started, or -1 for the end. */
  private insertAt: number = -1;

  aboutToDisappear(): void {
    // Unsent attachments: free the computer's copies and the cache.
    this.files.forEach((file: DraftAttachment) => attachments.discard(file));
    this.voiceTicket++;
    this.stopVoiceTimer();
    this.recording?.cancel();
    this.recording = null;
  }

  @Monitor('refillSeq')
  onRefill(): void {
    if (this.refillText.length > 0 && this.text.trim().length === 0) {
      this.setText(this.refillText);
    }
  }

  aboutToAppear(): void {
    this.onDraftKey();
  }

  /** Opening a conversation brings back what was left unsent in it. */
  @Monitor('draftKey')
  onDraftKey(): void {
    if (this.draftKey.length > 0 && this.text.length === 0) {
      this.text = drafts.get(this.draftKey);
    }
  }

  /** Every edit is kept as the conversation's draft until it is sent. */
  private setText(value: string): void {
    this.text = value;
    if (this.draftKey.length > 0) {
      drafts.set(this.draftKey, value);
    }
  }

  @Monitor('environmentId')
  onEnvironmentChanged(): void {
    this.files.forEach((file: DraftAttachment) => {
      if (this.environmentId.length > 0 && file.environmentId !== this.environmentId) {
        attachments.upload(file, this.environmentId);
      }
    });
  }

  /** Everything attached has reached the computer (nothing still uploading or failed). */
  private filesReady(): boolean {
    return this.files.every((file: DraftAttachment) => file.status === 'ready');
  }

  private canSend(): boolean {
    return this.active && (this.text.trim().length > 0 || this.files.length > 0) && this.filesReady();
  }

  private offersSuggestion(): boolean {
    return this.active && !this.running && this.text.length === 0 && this.files.length === 0 && this.suggestion.length > 0;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
  }

  private showAttachMenu(): void {
    this.getUIContext().getFocusController().clearFocus();
    const room = MAX_ATTACHMENTS - this.files.length;
    showActionMenu(this.getUIContext(), 'composer.attach', [
      ActionMenuRow.of('composer.attach.photos', '照片', '', () => this.pick(true, room))
        .withSymbol($r('sys.symbol.picture')).disabled(room <= 0),
      ActionMenuRow.of('composer.attach.files', '文件', '', () => this.pick(false, room))
        .withSymbol($r('sys.symbol.doc')).disabled(room <= 0),
    ]);
  }

  private async pick(photos: boolean, room: number): Promise<void> {
    let uris: string[] = [];
    try {
      uris = photos ? await attachments.pickPhotos(room) : await attachments.pickFiles(room);
    } catch (e) {
      this.toast(`无法打开${photos ? '图库' : '文件'}：${(e as Error).message}`);
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    for (const uri of uris.slice(0, room)) {
      try {
        const file = await attachments.prepare(context, uri, photos);
        this.files = this.files.concat([file]);
        if (this.environmentId.length > 0) {
          attachments.upload(file, this.environmentId);
        }
      } catch (e) {
        this.toast((e as Error).message ?? '无法读取这个文件');
      }
    }
  }

  private removeFile(file: DraftAttachment): void {
    lightEffects.tap();
    this.files = this.files.filter((f: DraftAttachment) => f.key !== file.key);
    attachments.discard(file);
  }

  /** Fills the field with the suggestion; the button turns back into send. */
  private acceptSuggestion(): void {
    lightEffects.tap();
    this.setText(this.suggestion);
    // Caret after the text, so typing continues the sentence.
    setTimeout(() => this.inputController.caretPosition(this.suggestion.length), 0);
  }

  private send(): void {
    if (!this.canSend()) {
      return;
    }
    const value = this.text.trim();
    const sent = this.files;
    lightEffects.tap();
    this.setText('');
    this.files = [];
    this.onSend(value, sent.map((file: DraftAttachment) => file.toWire()));
    sent.forEach((file: DraftAttachment) => attachments.forget(file));
  }

  /** Voice input: record, send to the chosen computer, put the words where the caret was. */
  private async startVoice(): Promise<void> {
    if (this.voicePhase !== 'idle') {
      return;
    }
    lightEffects.tap();
    if (this.voicePrefs.mode !== 'local' && this.voicePrefs.mode !== 'cloud') {
      openVoiceSettings();
      return;
    }
    const reason = voice.unavailableReason();
    if (reason.length > 0) {
      this.toast(reason);
      return;
    }
    this.voicePhase = 'starting';
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!(await voice.requestMicrophone(context))) {
      this.voicePhase = 'idle';
      this.toast('需要麦克风权限才能语音输入');
      return;
    }
    if (this.voicePhase !== 'starting') {
      return; // left the conversation meanwhile
    }
    this.insertAt = this.focused ? this.inputController.getCaretOffset().index : -1;
    const recording = new VoiceRecording();
    let peak = 0;
    recording.onLevel = (level: number) => {
      peak = Math.max(peak, level);
    };
    recording.onLimit = () => {
      this.finishVoice();
    };
    try {
      await recording.start();
    } catch (e) {
      recording.cancel();
      this.voicePhase = 'idle';
      this.toast('无法打开麦克风');
      return;
    }
    this.recording = recording;
    this.voiceLevels = new Array<number>(VOICE_BARS).fill(0);
    this.voiceSeconds = 0;
    this.voicePhase = 'recording';
    this.voiceTimer = setInterval(() => {
      this.voiceLevels = this.voiceLevels.slice(1).concat([peak]);
      peak = 0;
      this.voiceSeconds = recording.seconds;
    }, 100);
  }

  private stopVoiceTimer(): void {
    if (this.voiceTimer >= 0) {
      clearInterval(this.voiceTimer);
      this.voiceTimer = -1;
    }
  }

  private async finishVoice(): Promise<void> {
    const recording = this.recording;
    if (this.voicePhase !== 'recording' || recording === null) {
      return;
    }
    lightEffects.tap();
    this.recording = null;
    this.stopVoiceTimer();
    const seconds = recording.seconds;
    const chunks = await recording.finish();
    if (seconds < MIN_RECORDING_SECONDS) {
      this.voicePhase = 'idle';
      this.toast('录音太短');
      return;
    }
    const ticket = ++this.voiceTicket;
    this.voicePhase = 'transcribing';
    try {
      let spoken = await voice.transcribe(chunks);
      if (ticket !== this.voiceTicket) {
        return;
      }
      if (spoken.length === 0) {
        this.toast('没有听到说话');
        return;
      }
      if (this.voicePrefs.cleanup) {
        const at = this.insertionPoint();
        spoken = await voice.cleanup(spoken, this.text, at, at);
        if (ticket !== this.voiceTicket) {
          return;
        }
      }
      this.insertSpoken(spoken);
    } catch (e) {
      if (ticket === this.voiceTicket) {
        this.toast((e as Error).message);
      }
    } finally {
      if (ticket === this.voiceTicket) {
        this.voicePhase = 'idle';
      }
    }
  }

  private cancelVoice(): void {
    lightEffects.tap();
    this.voiceTicket++;
    this.stopVoiceTimer();
    this.recording?.cancel();
    this.recording = null;
    this.voicePhase = 'idle';
  }

  private insertionPoint(): number {
    return this.insertAt >= 0 && this.insertAt <= this.text.length ? this.insertAt : this.text.length;
  }

  /** Puts the words in at the caret, with a space only between two Latin words. */
  private insertSpoken(spoken: string): void {
    const at = this.insertionPoint();
    const before = this.text.slice(0, at);
    const after = this.text.slice(at);
    const lead = /[A-Za-z0-9.,!?;:]$/.test(before) && /^[A-Za-z0-9]/.test(spoken) ? ' ' : '';
    const trail = /[A-Za-z0-9.,!?;:]$/.test(spoken) && /^[A-Za-z0-9]/.test(after) ? ' ' : '';
    const caret = before.length + lead.length + spoken.length;
    this.setText(before + lead + spoken + trail + after);
    this.insertAt = caret;
    setTimeout(() => this.inputController.caretPosition(caret), 0);
  }

  @Builder
  micButton() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      if (this.voicePhase === 'starting') {
        LoadingProgress().width(18).height(18).color($r('app.color.fg_secondary')).transition(SWAP)
      } else {
        SymbolGlyph($r('sys.symbol.mic')).fontSize(17).fontColor([$r('app.color.fg_secondary')]).transition(SWAP)
      }
    }
    .id('composer.mic')
    .transition(SWAP)
    .width(34)
    .height(34)
    .backgroundColor($r('app.color.chip_bg'))
    .accessibilityText('语音输入')
    .onClick(() => {
      this.startVoice();
    })
  }

  /** While recording: cancel, a level meter and the time, and a check to finish. */
  @Builder
  voiceBar() {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([$r('app.color.fg_secondary')])
      }
      .id('composer.voice.cancel')
      .width(30)
      .height(30)
      .backgroundColor($r('app.color.chip_bg'))
      .accessibilityText('取消语音输入')
      .onClick(() => this.cancelVoice())
      // The meter and time, then 转写中, in one slot: they cross-fade instead of crowding the row.
      Stack({ alignContent: Alignment.Start }) {
        if (this.voicePhase === 'transcribing') {
          Row({ space: 8 }) {
            LoadingProgress().width(20).height(20).color($r('app.color.fg_secondary'))
            Text('转写中').fontSize(Type.small).fontColor($r('app.color.fg_secondary'))
          }
          .id('composer.voice.transcribing')
          .transition(FADE)
        } else {
          Row({ space: 10 }) {
            Row({ space: 3 }) {
              // One bar per slot, read from the live levels, so each bar glides to its next height.
              ForEach(this.voiceLevels, (_level: number, index: number) => {
                Column()
                  .width(3)
                  .height(4 + Math.round((this.voiceLevels[index] ?? 0) * 18))
                  .borderRadius(1.5)
                  .backgroundColor($r('app.color.prominent'))
                  .opacity(0.35 + 0.65 * (this.voiceLevels[index] ?? 0))
                  .animation({ duration: 100, curve: Curve.Linear })
              }, (_level: number, index: number) => `${index}`)
            }
            .height(24)
            .id('composer.voice.level')
            Text(clockLabel(this.voiceSeconds))
              .id('composer.voice.time')
              .fontSize(Type.small)
              .fontColor($r('app.color.fg_secondary'))
              .fontFeature('"tnum" 1')
          }
          .transition(FADE)
        }
      }
      .layoutWeight(1)
      .height(40)
      if (this.voicePhase === 'recording') {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor([$r('app.color.prominent_fg')])
        }
        .id('composer.voice.done')
        .width(34)
        .height(34)
        .backgroundColor($r('app.color.prominent'))
        .visualEffect(lightEffects.lightSource())
        .transition(SWAP)
        .accessibilityText('完成录音')
        .onClick(() => {
          this.finishVoice();
        })
      }
    }
    .width('100%')
    .height(40)
    .transition(SHIFT)
  }

  /** Stop, take the suggestion, or send: one slot, and the buttons trade places in it. */
  @Builder
  actionButton() {
    Stack() {
      this.actionChoice()
    }
    .width(34)
    .height(34)
  }

  @Builder
  actionChoice() {
    if (this.running && this.text.trim().length === 0 && this.files.length === 0) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.square_fill'))
          .fontSize(13)
          .fontColor([$r('app.color.prominent_fg')])
      }
      .id('composer.stop')
      .width(34)
      .height(34)
      .backgroundColor($r('app.color.prominent'))
      .transition(SWAP)
      .accessibilityText('停止')
      .onClick(() => {
        lightEffects.tap();
        this.onStop();
      })
    } else if (this.offersSuggestion()) {
      // Same place and size as send; the ⇥ glyph (the desktop's Tab) says "take the suggestion".
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_right_to_line'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.prominent_fg')])
      }
      .id('composer.complete')
      .width(34)
      .height(34)
      .backgroundColor($r('app.color.prominent'))
      .visualEffect(lightEffects.lightSource())
      .transition(SWAP)
      .accessibilityText(`补全：${this.suggestion}`)
      .onClick(() => this.acceptSuggestion())
    } else {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor([this.canSend() ? $r('app.color.prominent_fg') : $r('app.color.fg_tertiary')])
          .animation(STATE_CHANGE)
      }
      .id('composer.send')
      .width(34)
      .height(34)
      .backgroundColor(this.canSend() ? $r('app.color.prominent') : $r('app.color.chip_bg'))
      .animation(STATE_CHANGE)
      .enabled(this.canSend())
      .visualEffect(this.canSend() ? lightEffects.lightSource() : undefined)
      .transition(SWAP)
      .accessibilityText('发送')
      .onClick(() => this.send())
    }
  }

  /** Model, reasoning and speed in one quiet control, as on iOS. */
  @Builder
  modelControl() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(14).fontColor([$r('app.color.fg_secondary')])
      Text(this.modelSummary)
        .id('composer.model.value')
        .fontSize(Type.small)
        .fontColor($r('app.color.fg_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.fg_tertiary')])
    }
    .id('composer.model')
    .height(30)
    .padding({ left: 10, right: 8 })
    .borderRadius(15)
    .backgroundColor($r('app.color.chip_bg'))
    .flexShrink(1)
    .responseRegion({ x: 0, y: -5, width: '100%', height: 40 })
    .accessibilityText(`模型与推理：${this.modelSummary}`)
    .onClick(() => {
      lightEffects.tap();
      this.onModelTap();
    })
  }

  @Builder
  planControl() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.doc_text')).fontSize(13)
        .fontColor([this.planMode ? $r('app.color.prominent_fg') : $r('app.color.fg_secondary')])
      Text('计划')
        .fontSize(Type.small)
        .fontColor(this.planMode ? $r('app.color.prominent_fg') : $r('app.color.fg_secondary'))
    }
    .id('composer.plan')
    .height(30)
    .padding({ left: 10, right: 10 })
    .borderRadius(15)
    .backgroundColor(this.planMode ? $r('app.color.prominent') : $r('app.color.chip_bg'))
    .animation(STATE_CHANGE)
    .responseRegion({ x: 0, y: -5, width: '100%', height: 40 })
    .accessibilityText(this.planMode ? '计划模式：开' : '计划模式：关')
    .onClick(() => {
      lightEffects.tap();
      this.onPlanToggle();
    })
  }

  /** Attach photos or files. */
  @Builder
  attachControl() {
    Row() {
      SymbolGlyph($r('sys.symbol.paperclip')).fontSize(15).fontColor([$r('app.color.fg_secondary')])
    }
    .id('composer.attach')
    .width(30)
    .height(30)
    .justifyContent(FlexAlign.Center)
    .borderRadius(15)
    .backgroundColor($r('app.color.chip_bg'))
    .responseRegion({ x: -4, y: -5, width: 38, height: 40 })
    .accessibilityText('添加照片或文件')
    .onClick(() => {
      lightEffects.tap();
      this.showAttachMenu();
    })
  }

  @Builder
  tools() {
    Row({ space: 6 }) {
      this.attachControl()
      if (this.modelSummary.length > 0) {
        this.modelControl()
      }
      this.planControl()
    }
    .flexShrink(1)
  }

  build() {
    Column({ space: 6 }) {
      if (this.caption.length > 0) {
        Text(this.caption)
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 4, right: 4 })
          .transition(FADE)
      }
      Column() {
        if (this.files.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.files, (file: DraftAttachment) => {
                AttachmentChip({
                  file: file,
                  onRemove: () => this.removeFile(file),
                  onRetry: () => attachments.upload(file, this.environmentId),
                })
              }, (file: DraftAttachment) => file.key)
            }
            .padding({ left: 4, right: 4, top: 6, bottom: 2 })
          }
          .id('composer.files')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .align(Alignment.Start)
          .transition(RISE)
        }
        TextArea({ text: this.text, placeholder: this.offersSuggestion() ? this.suggestion : this.placeholder,
          controller: this.inputController })
          .id('composer.input')
          .fontSize(Type.body)
          .placeholderFont({ size: Type.body })
          .placeholderColor($r('app.color.fg_tertiary'))
          .fontColor($r('app.color.fg'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6, top: 6, bottom: 2 })
          .constraintSize({ minHeight: 34, maxHeight: 160 })
          .width('100%')
          .enterKeyType(this.returnKey === 'send' ? EnterKeyType.Send : EnterKeyType.NEW_LINE)
          .onSubmit((enterKey: EnterKeyType) => {
            if (this.returnKey === 'send') {
              // Like Tab on the desktop: an empty field takes the suggestion first.
              if (this.offersSuggestion()) {
                this.acceptSuggestion();
              } else {
                this.send();
              }
            }
          })
          .onChange((value: string) => {
            this.setText(value);
          })
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
        // Tools on the left, send / stop always on the right; while recording, the voice controls.
        Stack() {
          if (this.voicePhase === 'recording' || this.voicePhase === 'transcribing') {
            this.voiceBar()
          } else {
            Row({ space: 8 }) {
              this.tools()
              Blank()
              if (this.active && this.voicePrefs.mode !== 'off') {
                this.micButton()
              }
              this.actionButton()
            }
            .width('100%')
            .height(40)
            .transition(SHIFT)
          }
        }
        .width('100%')
        .height(40)
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .width('100%')
      .borderRadius(22)
      .backgroundColor($r('app.color.composer_surface'))
      // Focus is shown by a darker neutral edge; colour stays reserved for agent state.
      .border({ width: this.focused ? 1 : 0.5, color: this.focused ? $r('app.color.fg_tertiary') : $r('app.color.composer_border') })
      .attributeModifier(new ColumnMaterial(MaterialStyle.REGULAR, true))
    }
    .alignItems(HorizontalAlign.Start)
    // Same margin as the conversation, so the composer lines up with the cards above it.
    .padding({ left: Space.margin, right: Space.margin, top: 8, bottom: Math.max(10, this.bottomInset) })
    .width('100%')
    .constraintSize({ maxWidth: 720 })
  }
}
