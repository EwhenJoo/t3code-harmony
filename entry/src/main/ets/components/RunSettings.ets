import { ActionMenuRow, showActionMenu } from './ActionMenu';
import { appState, AppState } from '../model/AppState';
import {
  ModelOption,
  ModelSelection,
  ProviderModelInfo,
  ProviderOptionChoice,
  ProviderOptionDescriptor,
  ProviderStatus,
} from '../model/Types';
import { modelLabel, providerLabel } from '../common/Format';
import { lightEffects } from '../services/LightEffects';
import { Space, Type } from '../common/Typography';

/**
 * Model and run settings, as the iOS composer offers them: model, its own options (reasoning
 * effort, fast mode, thinking…), permission (runtime mode) and plan mode.
 */
@ObservedV2
export class RunSettings {
  @Trace environmentId: string = '';
  @Trace instanceId: string = '';
  @Trace model: string = '';
  @Trace options: ModelOption[] = [];
  @Trace runtimeMode: string = 'full-access';
  @Trace interactionMode: string = 'default';

  selection(): ModelSelection {
    const selection: ModelSelection = { instanceId: this.instanceId, model: this.model };
    if (this.options.length > 0) {
      selection.options = this.options.slice();
    }
    return selection;
  }

  setOption(id: string, value: string | boolean): void {
    const others = this.options.filter((o: ModelOption) => o.id !== id);
    const option: ModelOption = { id: id, value: value };
    this.options = others.concat([option]);
  }

  optionOf(id: string): string | number | boolean | undefined {
    return this.options.find((o: ModelOption) => o.id === id)?.value;
  }
}

/** One model a computer offers, with the settings it supports. */
export class ModelEntry {
  instanceId: string = '';
  providerName: string = '';
  slug: string = '';
  name: string = '';
  shortName: string = '';
  isDefault: boolean = false;
  isNew: boolean = false;
  descriptors: ProviderOptionDescriptor[] = [];

  get key(): string {
    return `${this.instanceId}/${this.slug}`;
  }
}

export class ProviderGroup {
  instanceId: string = '';
  name: string = '';
  models: ModelEntry[] = [];
}

function entryOf(provider: ProviderStatus, info: ProviderModelInfo): ModelEntry {
  const entry = new ModelEntry();
  entry.instanceId = provider.instanceId ?? '';
  entry.providerName = provider.displayName ?? providerLabel(provider.instanceId);
  entry.slug = info.slug ?? '';
  entry.name = info.name ?? modelLabel(info.slug);
  entry.shortName = info.shortName ?? entry.name;
  entry.isDefault = info.isDefault === true;
  entry.isNew = info.badge === 'new';
  entry.descriptors = info.capabilities?.optionDescriptors ?? [];
  return entry;
}

/** Models of a computer's enabled providers, grouped by provider. */
export function providerGroups(environmentId: string): ProviderGroup[] {
  const groups: ProviderGroup[] = [];
  const providers: ProviderStatus[] = appState.environmentFor(environmentId)?.config?.providers ?? [];
  providers.forEach((provider: ProviderStatus) => {
    if (provider.enabled === false || !provider.instanceId) {
      return;
    }
    const models = (provider.models ?? []).filter((m: ProviderModelInfo) => (m.slug ?? '').length > 0 && m.isLegacy !== true);
    if (models.length === 0) {
      return;
    }
    const group = new ProviderGroup();
    group.instanceId = provider.instanceId;
    group.name = provider.displayName ?? providerLabel(provider.instanceId);
    group.models = models.map((m: ProviderModelInfo) => entryOf(provider, m));
    groups.push(group);
  });
  return groups;
}

export function findModel(environmentId: string, instanceId: string, slug: string): ModelEntry | null {
  for (const group of providerGroups(environmentId)) {
    for (const model of group.models) {
      if (model.instanceId === instanceId && model.slug === slug) {
        return model;
      }
    }
  }
  return null;
}

/** The provider's preferred model, else its first. */
export function defaultModel(environmentId: string): ModelEntry | null {
  const groups = providerGroups(environmentId);
  for (const group of groups) {
    const preferred = group.models.find((m: ModelEntry) => m.isDefault);
    if (preferred !== undefined) {
      return preferred;
    }
  }
  return groups.length > 0 && groups[0].models.length > 0 ? groups[0].models[0] : null;
}

function defaultChoice(descriptor: ProviderOptionDescriptor): string {
  if (typeof descriptor.currentValue === 'string') {
    return descriptor.currentValue as string;
  }
  const choices = descriptor.options ?? [];
  const preferred = choices.find((c: ProviderOptionChoice) => c.isDefault === true);
  return preferred?.id ?? (choices.length > 0 ? choices[0].id : '');
}

/** The value a setting has for this run: the explicit choice, else the provider's default. */
export function optionValue(settings: RunSettings, descriptor: ProviderOptionDescriptor): string | boolean {
  const chosen = settings.optionOf(descriptor.id);
  if (descriptor.type === 'boolean') {
    if (typeof chosen === 'boolean') {
      return chosen as boolean;
    }
    return descriptor.currentValue === true;
  }
  if (typeof chosen === 'string') {
    return chosen as string;
  }
  return defaultChoice(descriptor);
}

export function isReasoning(descriptor: ProviderOptionDescriptor): boolean {
  const id = descriptor.id.toLowerCase();
  return descriptor.role === 'reasoning' || id.indexOf('effort') >= 0 || id.indexOf('reasoning') >= 0 || id.indexOf('thought') >= 0;
}

export function isSpeed(descriptor: ProviderOptionDescriptor): boolean {
  const id = descriptor.id.toLowerCase();
  return id.indexOf('fast') >= 0 || id.indexOf('speed') >= 0;
}

export function descriptorLabel(descriptor: ProviderOptionDescriptor): string {
  if (isReasoning(descriptor)) {
    return '推理强度';
  }
  if (isSpeed(descriptor)) {
    return '快速模式';
  }
  const id = descriptor.id.toLowerCase();
  if (id.indexOf('thinking') >= 0) {
    return '深度思考';
  }
  if (id.indexOf('context') >= 0) {
    return '上下文窗口';
  }
  return descriptor.label;
}

export function choiceLabel(choice: ProviderOptionChoice): string {
  switch (choice.id.toLowerCase()) {
    case 'none':
    case 'off':
      return '关';
    case 'minimal':
      return '最低';
    case 'low':
      return '低';
    case 'medium':
      return '中';
    case 'high':
      return '高';
    case 'xhigh':
      return '超高';
    case 'max':
    case 'maximum':
      return '最高';
    case 'auto':
      return '自动';
    case 'default':
      return '默认';
    default:
      return choice.label;
  }
}

/** "Opus 5.5 · 高 · 快速", for the composer's model control. */
export function runSummary(settings: RunSettings): string {
  const model = findModel(settings.environmentId, settings.instanceId, settings.model);
  const parts: string[] = [model?.shortName ?? modelLabel(settings.model)];
  (model?.descriptors ?? []).forEach((descriptor: ProviderOptionDescriptor) => {
    const value = optionValue(settings, descriptor);
    if (descriptor.type === 'select' && isReasoning(descriptor)) {
      const choice = (descriptor.options ?? []).find((c: ProviderOptionChoice) => c.id === value);
      if (choice !== undefined) {
        parts.push(choiceLabel(choice));
      }
    } else if (descriptor.type === 'boolean' && value === true) {
      parts.push(isSpeed(descriptor) ? '快速' : descriptorLabel(descriptor));
    }
  });
  return parts.filter((p: string) => p.length > 0).join(' · ');
}

export function selectedChoiceLabel(settings: RunSettings, descriptor: ProviderOptionDescriptor): string {
  const value = optionValue(settings, descriptor);
  const choice = (descriptor.options ?? []).find((c: ProviderOptionChoice) => c.id === value);
  return choice !== undefined ? choiceLabel(choice) : '';
}

export class RuntimeChoice {
  value: string;
  label: string;
  detail: string;

  constructor(value: string, label: string, detail: string) {
    this.value = value;
    this.label = label;
    this.detail = detail;
  }
}

export const RUNTIME_CHOICES: RuntimeChoice[] = [
  new RuntimeChoice('full-access', '完全访问', ''),
  new RuntimeChoice('auto', '自动', ''),
  new RuntimeChoice('auto-accept-edits', '自动接受编辑', ''),
  new RuntimeChoice('approval-required', '每步审批', ''),
];

export function runtimeLabel(value: string): string {
  return RUNTIME_CHOICES.find((c: RuntimeChoice) => c.value === value)?.label ?? value;
}

/** Short column caption ("推理强度", "速度"). */
@Builder
function columnTitle(title: string) {
  Text(title)
    .fontSize(Type.caption)
    .fontWeight(FontWeight.Medium)
    .fontColor($r('app.color.fg_tertiary'))
    .padding({ left: 10, right: 6, top: 12, bottom: 6 })
    .width('100%')
}

/** A speed setting reads as two choices, like the desktop picker: 标准 / 快速. */
class SpeedChoice {
  value: boolean;
  label: string;

  constructor(value: boolean, label: string) {
    this.value = value;
    this.label = label;
  }
}

const SPEEDS: SpeedChoice[] = [new SpeedChoice(false, '标准'), new SpeedChoice(true, '快速')];

/**
 * The model picker, laid out like the desktop one: harnesses down the left, the chosen harness's
 * models in the middle, and the current model's reasoning effort and speed on the right. Plan
 * mode and permission sit in a bar underneath. Every change applies at once.
 */
@ComponentV2
export struct RunSettingsPanel {
  @Local app: AppState = appState;
  @Param settings: RunSettings = new RunSettings();
  /** Plan mode and permission bar. */
  @Param showModes: boolean = true;
  @Event onModelChanged: () => void = () => {
  };
  @Event onOptionChanged: () => void = () => {
  };
  @Event onRuntimeChanged: () => void = () => {
  };
  @Event onModeChanged: () => void = () => {
  };
  /** The harness being browsed; picking one of its models makes it the active one. */
  @Local focused: string = '';
  @Local panelWidth: number = 360;

  aboutToAppear(): void {
    this.focused = this.settings.instanceId;
  }

  @Computed
  get groups(): ProviderGroup[] {
    const providers = this.app.environmentFor(this.settings.environmentId)?.config?.providers;
    return providers !== undefined ? providerGroups(this.settings.environmentId) : [];
  }

  @Computed
  get focusedGroup(): ProviderGroup | null {
    const groups = this.groups;
    return groups.find((g: ProviderGroup) => g.instanceId === this.focused) ?? (groups.length > 0 ? groups[0] : null);
  }

  @Computed
  get selectedModel(): ModelEntry | null {
    return findModel(this.settings.environmentId, this.settings.instanceId, this.settings.model);
  }

  /** Column widths: compact on a phone, roomier once the sheet is wide. */
  private railWidth(): number {
    return this.panelWidth >= 560 ? 148 : 92;
  }

  private optionsWidth(): number {
    return this.panelWidth >= 560 ? 196 : 116;
  }

  private isCurrent(model: ModelEntry): boolean {
    return model.instanceId === this.settings.instanceId && model.slug === this.settings.model;
  }

  private pickModel(model: ModelEntry): void {
    if (this.isCurrent(model)) {
      return;
    }
    lightEffects.tap();
    this.settings.instanceId = model.instanceId;
    this.settings.model = model.slug;
    // Options belong to a model; keep only the ones the new model also has.
    const ids = model.descriptors.map((d: ProviderOptionDescriptor) => d.id);
    this.settings.options = this.settings.options.filter((o: ModelOption) => ids.indexOf(o.id) >= 0);
    this.onModelChanged();
  }

  private pickRuntime(): void {
    const rows: ActionMenuRow[] = RUNTIME_CHOICES.map((choice: RuntimeChoice) =>
    ActionMenuRow.of(`runSettings.runtime.${choice.value}`, choice.label, choice.detail, () => {
      if (choice.value !== this.settings.runtimeMode) {
        lightEffects.tap();
        this.settings.runtimeMode = choice.value;
        this.onRuntimeChanged();
      }
    }).withSymbol(choice.value === this.settings.runtimeMode ? $r('sys.symbol.checkmark') : $r('sys.symbol.circle')));
    showActionMenu(this.getUIContext(), 'runSettings.runtime', rows);
  }

  @Builder
  harnessItem(group: ProviderGroup) {
    Column({ space: 2 }) {
      Text(group.name)
        .fontSize(Type.body)
        .fontWeight(group.instanceId === this.focusedGroup?.instanceId ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(group.instanceId === this.focusedGroup?.instanceId ? $r('app.color.fg') : $r('app.color.fg_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 4 }) {
        if (group.instanceId === this.settings.instanceId) {
          Circle().width(5).height(5).fill($r('app.color.primary'))
        }
        Text(`${group.models.length} 个模型`)
          .fontSize(Type.caption)
          .fontColor($r('app.color.fg_tertiary'))
          .maxLines(1)
      }
    }
    .id(`runSettings.harness.${group.instanceId}`)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(54)
    .padding({ left: 10, right: 6 })
    .borderRadius(12)
    .backgroundColor(group.instanceId === this.focusedGroup?.instanceId ? $r('app.color.grouped_card') : Color.Transparent)
    .accessibilityText(`${group.name}，${group.models.length} 个模型`)
    .onClick(() => {
      if (this.focused !== group.instanceId) {
        lightEffects.tap();
        this.focused = group.instanceId;
      }
    })
  }

  @Builder
  modelItem(model: ModelEntry) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        // The harness is already chosen on the left, so the short name reads cleaner here.
        Text(model.shortName.length > 0 ? model.shortName : model.name)
          .fontSize(Type.body)
          .fontWeight(this.isCurrent(model) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor($r('app.color.fg'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (model.isDefault || model.isNew) {
          Text(model.isNew ? '新' : '默认')
            .fontSize(Type.caption)
            .fontColor($r('app.color.fg_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(15)
        .fontColor([$r('app.color.primary')])
        .opacity(this.isCurrent(model) ? 1 : 0)
    }
    .id(`runSettings.model.${model.instanceId}.${model.slug}`)
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding({ left: 12, right: 10, top: 6, bottom: 6 })
    .borderRadius(12)
    .backgroundColor(this.isCurrent(model) ? $r('app.color.grouped_card') : Color.Transparent)
    .onClick(() => this.pickModel(model))
  }

  /** One choice of a select setting (推理强度 低 / 中 / 高…), as a row with a check. */
  @Builder
  choiceItem(id: string, label: string, selected: boolean, onPick: () => void) {
    Row() {
      Text(label)
        .fontSize(Type.body)
        .fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(selected ? $r('app.color.fg') : $r('app.color.fg_secondary'))
        .layoutWeight(1)
        .maxLines(1)
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(14)
        .fontColor([$r('app.color.primary')])
        .opacity(selected ? 1 : 0)
    }
    .id(id)
    .width('100%')
    .height(40)
    .padding({ left: 10, right: 8 })
    .borderRadius(10)
    .backgroundColor(selected ? $r('app.color.grouped_card') : Color.Transparent)
    .onClick(onPick)
  }

  @Builder
  optionBlock(descriptor: ProviderOptionDescriptor) {
    Column() {
      if (descriptor.type === 'boolean' && isSpeed(descriptor)) {
        columnTitle('速度')
        ForEach(SPEEDS, (speed: SpeedChoice) => {
          this.choiceItem(`runSettings.option.${descriptor.id}.${speed.value ? 'on' : 'off'}`, speed.label,
            optionValue(this.settings, descriptor) === speed.value, () => {
              if (optionValue(this.settings, descriptor) !== speed.value) {
                lightEffects.tap();
                this.settings.setOption(descriptor.id, speed.value);
                this.onOptionChanged();
              }
            })
        }, (speed: SpeedChoice) => `${descriptor.id}:${speed.value}:${optionValue(this.settings, descriptor) === speed.value}`)
      } else if (descriptor.type === 'boolean') {
        Row({ space: 6 }) {
          Text(descriptorLabel(descriptor))
            .fontSize(Type.body)
            .fontColor($r('app.color.fg'))
            .layoutWeight(1)
            .maxLines(2)
          Toggle({ type: ToggleType.Switch, isOn: optionValue(this.settings, descriptor) === true })
            .id(`runSettings.option.${descriptor.id}.toggle`)
            .onChange((isOn: boolean) => {
              lightEffects.tap();
              this.settings.setOption(descriptor.id, isOn);
              this.onOptionChanged();
            })
        }
        .width('100%')
        .padding({ left: 10, right: 2, top: 12, bottom: 4 })
      } else {
        columnTitle(descriptorLabel(descriptor))
        ForEach(descriptor.options ?? [], (choice: ProviderOptionChoice) => {
          this.choiceItem(`runSettings.option.${descriptor.id}.${choice.id}`, choiceLabel(choice),
            optionValue(this.settings, descriptor) === choice.id, () => {
              if (optionValue(this.settings, descriptor) !== choice.id) {
                lightEffects.tap();
                this.settings.setOption(descriptor.id, choice.id);
                this.onOptionChanged();
              }
            })
        }, (choice: ProviderOptionChoice) => `${descriptor.id}:${choice.id}:${optionValue(this.settings, descriptor) === choice.id}`)
      }
    }
    .id(`runSettings.option.${descriptor.id}`)
    .width('100%')
  }

  @Builder
  columns() {
    Row() {
      // Harnesses
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.groups, (group: ProviderGroup) => {
            this.harnessItem(group)
          }, (group: ProviderGroup) =>
          `${group.instanceId}:${group.instanceId === this.focusedGroup?.instanceId}:${group.instanceId === this.settings.instanceId}`)
        }
        .padding({ top: 8, bottom: 16 })
      }
      .id('runSettings.harnesses')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .width(this.railWidth())
      .height('100%')

      Divider().vertical(true).strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 6, right: 6 })

      // Models of the browsed harness
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.focusedGroup?.models ?? [], (model: ModelEntry) => {
            this.modelItem(model)
          }, (model: ModelEntry) => `${model.key}:${this.isCurrent(model)}`)
        }
        .padding({ top: 8, bottom: 16 })
      }
      .id('runSettings.models')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .layoutWeight(1)
      .height('100%')

      Divider().vertical(true).strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 6, right: 6 })

      // The current model's reasoning effort and speed
      Scroll() {
        Column() {
          if (this.selectedModel !== null) {
            Text(this.selectedModel.shortName)
              .fontSize(Type.small)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 10, right: 6, top: 14 })
              .width('100%')
            if (this.selectedModel.descriptors.length === 0) {
              Text('这个模型没有可调的选项')
                .fontSize(Type.caption)
                .fontColor($r('app.color.fg_tertiary'))
                .padding({ left: 10, right: 6, top: 8 })
                .width('100%')
            }
            ForEach(this.selectedModel.descriptors, (descriptor: ProviderOptionDescriptor) => {
              this.optionBlock(descriptor)
            }, (descriptor: ProviderOptionDescriptor) =>
            `${this.settings.instanceId}/${this.settings.model}:${descriptor.id}:${String(optionValue(this.settings, descriptor))}`)
          }
        }
        .padding({ bottom: 16 })
      }
      .id('runSettings.options')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .width(this.optionsWidth())
      .height('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(VerticalAlign.Top)
  }

  /** Plan mode on the left, permission on the right. */
  @Builder
  modesBar() {
    Row({ space: 12 }) {
      Row({ space: 8 }) {
        Text('计划模式').fontSize(Type.body).fontColor($r('app.color.fg'))
        Toggle({ type: ToggleType.Switch, isOn: this.settings.interactionMode === 'plan' })
          .id('runSettings.mode')
          .onChange((isOn: boolean) => {
            lightEffects.tap();
            this.settings.interactionMode = isOn ? 'plan' : 'default';
            this.onModeChanged();
          })
      }
      Blank()
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.lock')).fontSize(15).fontColor([$r('app.color.fg_secondary')])
        Text(runtimeLabel(this.settings.runtimeMode))
          .id('runSettings.runtime.value')
          .fontSize(Type.body)
          .fontColor($r('app.color.fg'))
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.fg_tertiary')])
      }
      .id('runSettings.runtime')
      .height(36)
      .padding({ left: 12, right: 10 })
      .borderRadius(18)
      .backgroundColor($r('app.color.grouped_card'))
      .accessibilityText(`权限：${runtimeLabel(this.settings.runtimeMode)}`)
      .onClick(() => this.pickRuntime())
    }
    .width('100%')
    .height(56)
    .padding({ left: 6, right: 6 })
    .border({ width: { top: 0.5 }, color: $r('app.color.hairline') })
  }

  build() {
    Column() {
      if (this.groups.length === 0) {
        Text('这台电脑还没有上报可用的模型')
          .fontSize(Type.body)
          .fontColor($r('app.color.fg_secondary'))
          .padding(24)
          .layoutWeight(1)
      } else {
        this.columns()
      }
      if (this.showModes) {
        this.modesBar()
      }
      Column().height(this.app.bottomInset)
    }
    .id('runSettings.sheet')
    .padding({ left: 10, right: 10 })
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.panelWidth = Number(area.width);
    })
  }
}
