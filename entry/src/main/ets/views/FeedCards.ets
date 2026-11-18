import { ApprovalOption, ChatAttachment, TurnItem, UserInputQuestion, UserInputQuestionOption } from '../model/Types';
import { AttachmentPreviews, attachmentPreviews, sizeLabel } from '../services/Attachments';
import { FeedEntry, workItemIcon, workItemTitle } from '../model/ThreadDetail';
import { MarkdownView } from '../components/Markdown';
import { durationLabel } from '../common/Format';
import { lightEffects } from '../services/LightEffects';
import { Type } from '../common/Typography';
import { animate, FADE, REVEAL, SPRING, SPRING_SOFT, STATE_CHANGE } from '../common/Motion';

/** A photo or file sent with a message: the picture itself, or a card with the name and size. */
@ComponentV2
struct SentAttachment {
  @Param file: ChatAttachment = { type: 'file', id: '', name: '', mimeType: '', sizeBytes: 0 };
  @Param environmentId: string = '';
  @Local previews: AttachmentPreviews = attachmentPreviews;

  build() {
    if (this.file.type === 'image') {
      // Reading `version` re-renders once the download lands.
      if (this.previews.version >= 0 && this.previews.imageUri(this.environmentId, this.file).length > 0) {
        Image(this.previews.imageUri(this.environmentId, this.file))
          .width(120)
          .height(120)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .id(`message.file.${this.file.name}`)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.picture')).fontSize(22).fontColor([$r('app.color.fg_tertiary')])
        }
        .width(120)
        .height(120)
        .justifyContent(FlexAlign.Center)
        .borderRadius(12)
        .backgroundColor($r('app.color.user_bubble'))
        .id(`message.file.${this.file.name}`)
      }
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
          Text(sizeLabel(this.file.sizeBytes)).fontSize(11).fontColor($r('app.color.fg_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: 200 })
      }
      .padding({ left: 10, right: 12, top: 8, bottom: 8 })
      .borderRadius(12)
      .backgroundColor($r('app.color.user_bubble'))
      .id(`message.file.${this.file.name}`)
    }
  }
}

@ComponentV2
export struct UserBubble {
  @Param text: string = '';
  @Param alignLeft: boolean = false;
  /** Photos and files sent with the message, shown above its text. */
  @Param files: ChatAttachment[] = [];
  @Param environmentId: string = '';

  build() {
    Column({ space: 6 }) {
      if (this.files.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: this.alignLeft ? FlexAlign.Start : FlexAlign.End }) {
          ForEach(this.files, (file: ChatAttachment) => {
            SentAttachment({ file: file, environmentId: this.environmentId })
              .margin({ left: 3, right: 3, bottom: 3 })
          }, (file: ChatAttachment) => file.id)
        }
        .constraintSize({ maxWidth: '85%' })
      }
      if (this.text.length > 0) {
        Row() {
          if (!this.alignLeft) {
            Blank()
          }
          Text(this.text)
            .fontSize(Type.body)
            .lineHeight(Type.bodyLine)
            .fontColor($r('app.color.fg'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(14)
            .backgroundColor($r('app.color.user_bubble'))
            .constraintSize({ maxWidth: '85%' })
            .copyOption(CopyOptions.LocalDevice)
          if (this.alignLeft) {
            Blank()
          }
        }
        .width('100%')
      }
    }
    .alignItems(this.alignLeft ? HorizontalAlign.Start : HorizontalAlign.End)
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }
}

@ComponentV2
export struct AssistantMessage {
  @Param text: string = '';
  @Param streaming: boolean = false;

  build() {
    Column({ space: 6 }) {
      MarkdownView({ text: this.text, fontSize: Type.body })
      if (this.streaming) {
        Row({ space: 6 }) {
          LoadingProgress().width(16).height(16).color($r('app.color.fg_tertiary'))
          Text('正在输出…').fontSize(Type.small).fontColor($r('app.color.fg_tertiary'))
        }
        .transition(FADE)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }
}

/** Collapsed run of tool calls, commands, edits and reasoning, like the iOS work log. */
@ComponentV2
export struct WorkGroup {
  @Param entry: FeedEntry = new FeedEntry('', 'work');
  @Param now: number = 0;
  @Local expanded: boolean = false;
  @Local openItem: string = '';

  private summary(): string {
    let commands = 0;
    let edits = 0;
    let tools = 0;
    let thoughts = 0;
    this.entry.items.forEach((item: TurnItem) => {
      if (item.type === 'command_execution') {
        commands++;
      } else if (item.type === 'file_change') {
        edits++;
      } else if (item.type === 'reasoning') {
        thoughts++;
      } else {
        tools++;
      }
    });
    const parts: string[] = [];
    if (commands > 0) {
      parts.push(`${commands} 条命令`);
    }
    if (edits > 0) {
      parts.push(`${edits} 处修改`);
    }
    if (tools > 0) {
      parts.push(`${tools} 次工具调用`);
    }
    if (parts.length === 0 && thoughts > 0) {
      parts.push('思考');
    }
    return parts.join(' · ');
  }

  private headline(): string {
    if (this.entry.running) {
      return `正在工作 · ${this.summary()}`;
    }
    const took = this.duration();
    return took.length > 0 ? `已工作 ${took} · ${this.summary()}` : this.summary();
  }

  private duration(): string {
    const first = this.entry.items[0];
    const last = this.entry.items[this.entry.items.length - 1];
    return durationLabel(first.startedAt, this.entry.running ? null : (last.completedAt ?? last.updatedAt), this.now);
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph(this.entry.running ? $r('sys.symbol.circle_dashed') : $r('sys.symbol.wrench_and_screwdriver'))
          .fontSize(Type.small)
          .fontColor([this.entry.running ? $r('app.color.status_working') : $r('app.color.fg_tertiary')])
        Text(this.headline())
          .fontSize(12)
          .fontColor(this.entry.running ? $r('app.color.fg_secondary') : $r('app.color.fg_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(Type.small)
          .fontColor([$r('app.color.fg_tertiary')])
          .rotate({ angle: this.expanded ? 180 : 0 })
          .animation({ curve: SPRING })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        animate(this.getUIContext(), () => {
          this.expanded = !this.expanded;
        });
      })

      if (!this.expanded && this.entry.running) {
        Text(workItemTitle(this.entry.items[this.entry.items.length - 1]))
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.fg_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 32, right: 12, bottom: 8 })
          .width('100%')
          .transition(FADE)
      }

      if (this.expanded) {
        Column() {
          ForEach(this.entry.items, (item: TurnItem) => {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(workItemIcon(item))
                  .fontSize(12)
                  .fontColor(item.status === 'failed' ? $r('app.color.danger_fg') : $r('app.color.fg_tertiary'))
                  .width(14)
                Text(workItemTitle(item))
                  .fontSize(Type.small)
                  .fontFamily(item.type === 'command_execution' ? 'monospace' : 'sans-serif')
                  .fontColor(item.status === 'failed' || (item.exitCode !== undefined && item.exitCode !== 0) ? $r('app.color.danger_fg') : $r('app.color.fg_secondary'))
                  .maxLines(this.openItem === item.id ? 12 : 1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              if (this.openItem === item.id && item.type === 'reasoning' && (item.text ?? '').length > 0) {
                Text(item.text)
                  .fontSize(Type.small)
                  .lineHeight(18)
                  .fontColor($r('app.color.fg_secondary'))
                  .padding({ left: 22 })
                  .transition(REVEAL)
              }
              if (this.openItem === item.id && (item.output ?? '').length > 0) {
                Text(item.output)
                  .fontSize(Type.caption)
                  .fontFamily('monospace')
                  .fontColor($r('app.color.fg_secondary'))
                  .maxLines(30)
                  .padding(8)
                  .borderRadius(8)
                  .backgroundColor($r('app.color.code_bg'))
                  .width('100%')
                  .transition(REVEAL)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .width('100%')
            .onClick(() => {
              animate(this.getUIContext(), () => {
                this.openItem = this.openItem === item.id ? '' : item.id;
              });
            })
          }, (item: TurnItem) => `${item.id}:${item.status ?? ''}:${item.updatedAt ?? ''}`)
        }
        .padding({ bottom: 6 })
        .transition(REVEAL)
      }
    }
    .width('100%')
    .borderRadius(10)
    .border({ width: 0.5, color: $r('app.color.border') })
    .margin({ top: 2, bottom: 2 })
    .clip(true)
  }
}

@ComponentV2
export struct ApprovalCard {
  @Param item: TurnItem | null = null;
  @Param pending: boolean = false;
  @Param busy: boolean = false;
  @Event onDecision: (decision: string) => void = () => {
  };

  private options(): ApprovalOption[] {
    const given = this.item?.options ?? [];
    if (given.length > 0) {
      return given;
    }
    const defaults: ApprovalOption[] = [
      { decision: 'decline', label: '拒绝' },
      { decision: 'accept', label: '批准' },
    ];
    return defaults;
  }

  private kindLabel(): string {
    switch (this.item?.requestKind ?? '') {
      case 'command':
        return '运行命令';
      case 'file-change':
        return '修改文件';
      case 'file-read':
        return '读取文件';
      case 'permission':
        return '权限请求';
      default:
        return '需要批准';
    }
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_shield_fill'))
          .fontSize(Type.small)
          .fontColor([this.pending ? $r('app.color.status_attention') : $r('app.color.fg_tertiary')])
        Text(this.pending ? '审批' : '已处理')
          .fontSize(Type.small)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pending ? $r('app.color.status_attention') : $r('app.color.fg_tertiary'))
        Text(this.kindLabel())
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_secondary'))
      }
      if ((this.item?.prompt ?? this.item?.title ?? '').length > 0) {
        Text(this.item?.prompt ?? this.item?.title ?? '')
          .fontSize(Type.code)
          .lineHeight(Type.codeLine)
          .fontFamily('monospace')
          .fontColor($r('app.color.fg'))
          .maxLines(this.pending ? 14 : 3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding(10)
          .borderRadius(10)
          .backgroundColor($r('app.color.code_bg'))
          .width('100%')
      }
      if ((this.item?.reason ?? '').length > 0) {
        Text(this.item?.reason ?? '')
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_secondary'))
      }
      if (this.pending) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
          ForEach(this.options(), (option: ApprovalOption) => {
            Button(option.label, { type: ButtonType.Capsule, stateEffect: true })
              .id(`approval.${option.decision}`)
              .fontSize(13)
              .height(32)
              .padding({ left: 16, right: 16 })
              .margin({ left: 8, top: 2 })
              .enabled(!this.busy)
              .backgroundColor(option.decision.startsWith('accept') ? $r('app.color.prominent') : $r('app.color.grouped_card'))
              .fontColor(option.decision.startsWith('accept') ? $r('app.color.prominent_fg') : $r('app.color.fg'))
              .onClick(() => {
                lightEffects.tap();
                this.onDecision(option.decision);
              })
          }, (option: ApprovalOption) => option.decision)
        }
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.card'))
    .border({ width: 0.5, color: this.pending ? $r('app.color.status_attention') : $r('app.color.border') })
    .visualEffect(this.pending ? lightEffects.illuminatedBorder() : undefined)
    .width('100%')
    .margin({ top: 6, bottom: 6 })
  }
}

/**
 * The agent's questions. Several are asked one page at a time, as on the desktop: a progress row on
 * top, swipe or 上一题 / 下一题 to move, a single choice moves on by itself, and the last page submits.
 */
@ComponentV2
export struct QuestionCard {
  @Param item: TurnItem | null = null;
  @Param pending: boolean = false;
  @Param busy: boolean = false;
  @Event onAnswer: (answers: Record<string, Object>) => void = () => {
  };
  @Local selected: Map<string, string[]> = new Map();
  @Local custom: Map<string, string> = new Map();
  @Local revision: number = 0;
  @Local page: number = 0;
  /** +1 when moving forward, -1 back: which side the next page slides in from. */
  @Local slideFrom: number = 1;
  private advanceTimer: number = -1;

  aboutToDisappear(): void {
    if (this.advanceTimer >= 0) {
      clearTimeout(this.advanceTimer);
    }
  }

  private questions(): UserInputQuestion[] {
    return this.item?.questions ?? [];
  }

  private paged(): boolean {
    return this.pending && this.questions().length > 1;
  }

  private current(): UserInputQuestion | null {
    const questions = this.questions();
    return questions.length > 0 ? questions[Math.min(this.page, questions.length - 1)] : null;
  }

  private optionValue(option: UserInputQuestionOption): string {
    return option.value ?? option.label;
  }

  private isSelected(question: UserInputQuestion, option: UserInputQuestionOption): boolean {
    if (this.revision < 0) {
      return false;
    }
    return (this.selected.get(question.id) ?? []).indexOf(this.optionValue(option)) >= 0;
  }

  private answered(question: UserInputQuestion): boolean {
    if (this.revision < 0) {
      return false;
    }
    return (this.custom.get(question.id) ?? '').trim().length > 0 || (this.selected.get(question.id) ?? []).length > 0;
  }

  private allAnswered(): boolean {
    return this.questions().every((question: UserInputQuestion) => this.answered(question));
  }

  private toggle(question: UserInputQuestion, option: UserInputQuestionOption): void {
    const value = this.optionValue(option);
    const current = this.selected.get(question.id) ?? [];
    let next: string[];
    if (question.multiSelect === true) {
      next = current.indexOf(value) >= 0 ? current.filter((v: string) => v !== value) : current.concat([value]);
    } else {
      next = [value];
    }
    this.selected.set(question.id, next);
    this.custom.delete(question.id);
    this.revision++;
    lightEffects.tap();
    const questions = this.questions();
    if (question.multiSelect === true) {
      return;
    }
    if (questions.length === 1) {
      this.submit();
    } else if (this.page < questions.length - 1) {
      // A single choice answers the page: show it picked for a moment, then move on.
      if (this.advanceTimer >= 0) {
        clearTimeout(this.advanceTimer);
      }
      const from = this.page;
      this.advanceTimer = setTimeout(() => {
        this.advanceTimer = -1;
        if (this.page === from) {
          this.goTo(from + 1);
        }
      }, 220);
    }
  }

  private goTo(page: number): void {
    const count = this.questions().length;
    if (page < 0 || page >= count || page === this.page) {
      return;
    }
    this.getUIContext().getFocusController().clearFocus();
    this.slideFrom = page > this.page ? 1 : -1;
    animate(this.getUIContext(), () => {
      this.page = page;
    }, SPRING_SOFT);
  }

  private next(): void {
    const question = this.current();
    if (question !== null && this.answered(question)) {
      lightEffects.tap();
      this.goTo(this.page + 1);
    }
  }

  private previous(): void {
    lightEffects.tap();
    this.goTo(this.page - 1);
  }

  private submit(): void {
    const answers: Record<string, Object> = {};
    const questions = this.questions();
    for (let index = 0; index < questions.length; index++) {
      const question = questions[index];
      const custom = (this.custom.get(question.id) ?? '').trim();
      const chosen = this.selected.get(question.id) ?? [];
      if (custom.length > 0) {
        answers[question.id] = custom;
      } else if (question.multiSelect === true && chosen.length > 0) {
        answers[question.id] = chosen;
      } else if (chosen.length > 0) {
        answers[question.id] = chosen[0];
      } else {
        // Something is still open: show that page instead.
        this.goTo(index);
        return;
      }
    }
    this.onAnswer(answers);
  }

  /** Enter in the answer field: next page, or submit on the last one. */
  private submitFromField(): void {
    if (this.paged() && this.page < this.questions().length - 1) {
      this.next();
    } else {
      this.submit();
    }
  }

  @Builder
  questionBody(question: UserInputQuestion) {
    Column({ space: 8 }) {
      if (this.paged() && question.header.length > 0) {
        Text(question.header)
          .id('question.header')
          .fontSize(Type.small)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.fg_secondary'))
      }
      Text(question.question)
        .fontSize(Type.body)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
      if (this.pending) {
        ForEach(question.options, (option: UserInputQuestionOption) => {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(option.label)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isSelected(question, option) ? $r('app.color.prominent_fg') : $r('app.color.fg'))
              if (option.description.length > 0) {
                Text(option.description)
                  .fontSize(Type.small)
                  .fontColor(this.isSelected(question, option) ? $r('app.color.prominent_fg') : $r('app.color.fg_secondary'))
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (question.multiSelect === true) {
              SymbolGlyph(this.isSelected(question, option) ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
                .fontSize(16)
                .fontColor([this.isSelected(question, option) ? $r('app.color.prominent_fg') : $r('app.color.fg_tertiary')])
            }
          }
          .id(`question.option.${option.label}`)
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .borderRadius(10)
          .backgroundColor(this.isSelected(question, option) ? $r('app.color.prominent') : $r('app.color.grouped_card'))
          .border({ width: 0.5, color: $r('app.color.border') })
          .animation(STATE_CHANGE)
          .enabled(!this.busy)
          .onClick(() => this.toggle(question, option))
        }, (option: UserInputQuestionOption) => `${question.id}:${option.label}`)
        if (question.allowCustomAnswer !== false) {
          TextInput({ text: this.custom.get(question.id) ?? '', placeholder: '或者输入你的回答' })
            .id('question.custom')
            .fontSize(Type.body)
            .height(40)
            .backgroundColor($r('app.color.card'))
            .enterKeyType(this.paged() && this.page < this.questions().length - 1 ? EnterKeyType.Next : EnterKeyType.Done)
            .onChange((value: string) => {
              this.custom.set(question.id, value);
              if (value.trim().length > 0 && (this.selected.get(question.id) ?? []).length > 0) {
                this.selected.delete(question.id);
              }
              this.revision++;
            })
            .onSubmit(() => this.submitFromField())
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** One short bar per question: the current one dark, answered ones tinted. */
  @Builder
  progress() {
    Row({ space: 4 }) {
      ForEach(this.questions(), (question: UserInputQuestion, index: number) => {
        Column()
          .width(index === this.page ? 16 : 6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(index === this.page || this.answered(question) ? $r('app.color.status_input') : $r('app.color.fg_tertiary'))
          .opacity(index === this.page ? 1 : this.answered(question) ? 0.45 : 0.3)
          .animation({ curve: SPRING })
      }, (question: UserInputQuestion, index: number) => `${question.id}:${index}`)
      Text(`${this.page + 1} / ${this.questions().length}`)
        .id('question.page')
        .fontSize(Type.small)
        .fontColor($r('app.color.fg_secondary'))
        .margin({ left: 4 })
    }
  }

  @Builder
  pageButtons() {
    Row({ space: 8 }) {
      if (this.page > 0) {
        Button('上一题', { type: ButtonType.Capsule, stateEffect: true })
          .id('question.prev')
          .height(32)
          .fontSize(13)
          .padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.grouped_card'))
          .fontColor($r('app.color.fg'))
          .enabled(!this.busy)
          .onClick(() => this.previous())
          .transition(FADE)
      }
      Blank()
      Stack({ alignContent: Alignment.End }) {
        this.forwardButton()
      }
    }
    .width('100%')
  }

  @Builder
  forwardButton() {
    if (this.page < this.questions().length - 1) {
      Button('下一题', { type: ButtonType.Capsule, stateEffect: true })
        .id('question.next')
        .height(32)
        .fontSize(13)
        .padding({ left: 14, right: 14 })
        .enabled(!this.busy && this.current() !== null && this.answered(this.current() as UserInputQuestion))
        .backgroundColor($r('app.color.prominent'))
        .fontColor($r('app.color.prominent_fg'))
        .onClick(() => this.next())
        .transition(FADE)
    } else {
      Button('提交回答', { type: ButtonType.Capsule, stateEffect: true })
        .id('question.submit')
        .height(32)
        .fontSize(13)
        .padding({ left: 14, right: 14 })
        .enabled(!this.busy && this.allAnswered())
        .backgroundColor($r('app.color.prominent'))
        .fontColor($r('app.color.prominent_fg'))
        .onClick(() => this.submit())
        .transition(FADE)
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.questionmark_circle'))
          .fontSize(Type.small)
          .fontColor([this.pending ? $r('app.color.status_input') : $r('app.color.fg_tertiary')])
        Text(this.pending ? '待回答' : '问题已回答')
          .fontSize(Type.small)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pending ? $r('app.color.status_input') : $r('app.color.fg_tertiary'))
        Blank()
        if (this.paged()) {
          this.progress()
        }
      }
      .width('100%')
      if (this.paged()) {
        // One page at a time; the new one slides in from the side you are moving towards.
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach([this.current()], (question: UserInputQuestion | null) => {
            if (question !== null) {
              Column() {
                this.questionBody(question)
              }
              .width('100%')
              .transition(TransitionEffect.asymmetric(
                TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 28 * this.slideFrom })),
                TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -28 * this.slideFrom }))))
            }
          }, (question: UserInputQuestion | null) => question?.id ?? 'none')
        }
        .id('question.body')
        .width('100%')
        .clip(true)
        .gesture(SwipeGesture({ direction: SwipeDirection.Horizontal })
          .onAction((event: GestureEvent) => {
            if (Math.abs(event.angle) > 90) {
              this.next();
            } else {
              this.previous();
            }
          }))
        this.pageButtons()
      } else {
        ForEach(this.questions(), (question: UserInputQuestion) => {
          this.questionBody(question)
        }, (question: UserInputQuestion) => question.id)
        if (this.pending && this.questions().some((q: UserInputQuestion) => q.multiSelect === true || q.allowCustomAnswer !== false)) {
          Row() {
            Blank()
            Button('提交回答', { type: ButtonType.Capsule })
              .id('question.submit')
              .height(32)
              .fontSize(13)
              .enabled(!this.busy && this.allAnswered())
              .backgroundColor($r('app.color.prominent'))
              .fontColor($r('app.color.prominent_fg'))
              .onClick(() => this.submit())
          }
          .width('100%')
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.card'))
    .border({ width: 0.5, color: this.pending ? $r('app.color.status_input') : $r('app.color.border') })
    .width('100%')
    .margin({ top: 6, bottom: 6 })
  }
}

@ComponentV2
export struct NoticeRow {
  @Param item: TurnItem | null = null;

  build() {
    Row({ space: 8 }) {
      SymbolGlyph(this.item?.type === 'error' ? $r('sys.symbol.exclamationmark_circle') : $r('sys.symbol.lightbulb'))
        .fontSize(Type.small)
        .fontColor([this.item?.type === 'error' ? $r('app.color.danger_fg') : $r('app.color.fg_tertiary')])
      Text(this.item?.message ?? this.item?.text ?? this.item?.title ?? this.item?.type ?? '')
        .fontSize(Type.small)
        .fontColor(this.item?.type === 'error' ? $r('app.color.danger_fg') : $r('app.color.fg_secondary'))
        .maxLines(6)
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .width('100%')
  }
}
