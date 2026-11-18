import { HdsNavigation, HdsNavigationTitleMode, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { appState, AppState, EnvironmentState } from '../model/AppState';
import { ProviderStatus, ServerConfig } from '../model/Types';
import {
  bucketTokens,
  formatTokens,
  formatUsd,
  localDay,
  paceLabel,
  paceRemainingPercent,
  ProviderUsageLimits,
  remainingPercent,
  resetsInLabel,
  UsageBucket,
  UsageSummary,
  UsageSummaryInput,
  usageProviderLabel,
  UsageWindow,
} from '../model/Workspace';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { symbolItem, tabTitleBar } from '../components/TitleBars';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { sectionTitle } from './GitPage';
import { Space, Type } from '../common/Typography';
import { animate, ENTER } from '../common/Motion';

const VIEW_COST = 0;
const VIEW_TOKENS = 1;
const VIEW_LIMITS = 2;
const WINDOWS: number[] = [1, 7, 30, 90];
const CHART_HEIGHT = 150;

class RefreshProvidersInput {
}

interface ProvidersPayload {
  providers?: ProviderStatus[];
}

/** One chart column: a day (or an hour for the past 24 hours), stacked by provider. */
class ChartColumn {
  key: string = '';
  label: string = '';
  claude: number = 0;
  codex: number = 0;
  other: number = 0;

  get total(): number {
    return this.claude + this.codex + this.other;
  }
}

class ProviderTotal {
  provider: string = '';
  cost: number = 0;
  tokens: number = 0;
  sessions: number = 0;
}

/** Limits of one provider account on one computer. */
class LimitCard {
  key: string = '';
  title: string = '';
  account: string = '';
  computer: string = '';
  limits: ProviderUsageLimits | null = null;
  driver: string = '';
}

function providerBucket(provider: string): string {
  if (provider === 'claude' || provider === 'claudeAgent') {
    return 'claude';
  }
  return provider === 'codex' ? 'codex' : 'other';
}

/**
 * Usage, as on iOS: spend and tokens over a window with a daily chart and a per-provider split,
 * and each provider's rate limits with how much is left and when it resets.
 */
@ComponentV2
export struct UsageView {
  @Local app: AppState = appState;
  @Local view: number = VIEW_LIMITS;
  @Local windowDays: number = 30;
  @Local buckets: UsageBucket[] = [];
  @Local loading: boolean = false;
  @Local error: string = '';
  @Local refreshing: boolean = false;
  /** '' = every computer. */
  @Local environmentFilter: string = '';
  @Local now: number = Date.now();
  private scroller: Scroller = new Scroller();
  private loadedKey: string = '';

  aboutToAppear(): void {
    this.load();
  }

  @Monitor('app.environments')
  onEnvironments(): void {
    this.load();
  }

  @Computed
  get selectedEnvironments(): EnvironmentState[] {
    return this.app.environments.filter((e: EnvironmentState) =>
    this.environmentFilter.length === 0 || e.id === this.environmentFilter);
  }

  private summaryInput(): UsageSummaryInput {
    const now = Date.now();
    const timeZone = i18n.getTimeZone().getID();
    if (this.windowDays === 1) {
      return {
        sinceDay: localDay(now - 86400000),
        untilDay: localDay(now),
        timeZone: timeZone,
        resolution: 'hour',
        sinceTime: new Date(now - 86400000).toISOString(),
        untilTime: new Date(now).toISOString(),
      };
    }
    return {
      sinceDay: localDay(now - (this.windowDays - 1) * 86400000),
      untilDay: localDay(now),
      timeZone: timeZone,
      resolution: 'day',
    };
  }

  async load(force: boolean = false): Promise<void> {
    const envs = this.selectedEnvironments.filter((e: EnvironmentState) => e.phase === 'connected');
    const key = `${this.windowDays}|${envs.map((e: EnvironmentState) => e.id).join(',')}`;
    if (!force && key === this.loadedKey && this.buckets.length > 0) {
      return;
    }
    this.loadedKey = key;
    this.loading = this.buckets.length === 0;
    this.error = '';
    const input = this.summaryInput();
    const all: UsageBucket[] = [];
    const errors: string[] = [];
    await Promise.all(envs.map(async (env: EnvironmentState) => {
      try {
        const summary = await connection.rpc(env.id, 'server.getUsageSummary', input) as UsageSummary;
        (summary.buckets ?? []).forEach((b: UsageBucket) => all.push(b));
      } catch (e) {
        errors.push(`${env.label}：${(e as Error).message}`);
      }
    }));
    this.buckets = all;
    this.error = errors.join('\n');
    this.loading = false;
    this.now = Date.now();
  }

  /** Re-reads provider limits (the server probes each account again). */
  private async refreshLimits(): Promise<void> {
    const envs = this.selectedEnvironments.filter((e: EnvironmentState) => e.phase === 'connected');
    await Promise.all(envs.map(async (env: EnvironmentState) => {
      try {
        const result = await connection.rpc(env.id, 'server.refreshProviders', new RefreshProvidersInput()) as ProvidersPayload;
        if (result !== null && result.providers !== undefined) {
          const old = env.config;
          const next: ServerConfig = {
            environment: old?.environment,
            hostname: old?.hostname,
            providers: result.providers,
          };
          env.config = next;
        }
      } catch (e) {
        await connection.reloadConfig(env.id).catch(() => {
        });
      }
    }));
    this.now = Date.now();
  }

  private async onRefresh(): Promise<void> {
    lightEffects.tap();
    if (this.view === VIEW_LIMITS) {
      await this.refreshLimits();
    } else {
      await this.load(true);
    }
    this.refreshing = false;
  }

  @Computed
  get totalCost(): number {
    return this.buckets.reduce((sum: number, b: UsageBucket) => sum + (b.costUsd ?? 0), 0);
  }

  @Computed
  get totalTokens(): number {
    return this.buckets.reduce((sum: number, b: UsageBucket) => sum + bucketTokens(b), 0);
  }

  @Computed
  get columns(): ChartColumn[] {
    const tokens = this.view === VIEW_TOKENS;
    const byKey: Map<string, ChartColumn> = new Map();
    const order: string[] = [];
    const now = Date.now();
    if (this.windowDays === 1) {
      for (let h = 23; h >= 0; h--) {
        const start = new Date(now - h * 3600000);
        start.setMinutes(0, 0, 0);
        const column = new ChartColumn();
        column.key = `${start.getTime()}`;
        column.label = `${start.getHours()}时`;
        byKey.set(column.key, column);
        order.push(column.key);
      }
    } else {
      for (let d = this.windowDays - 1; d >= 0; d--) {
        const day = localDay(now - d * 86400000);
        const column = new ChartColumn();
        column.key = day;
        column.label = `${Number(day.substring(5, 7))}/${Number(day.substring(8, 10))}`;
        byKey.set(day, column);
        order.push(day);
      }
    }
    this.buckets.forEach((b: UsageBucket) => {
      let key = b.day;
      if (this.windowDays === 1) {
        const t = Date.parse(b.hourStart ?? '');
        if (!Number.isFinite(t)) {
          return;
        }
        const start = new Date(t);
        start.setMinutes(0, 0, 0);
        key = `${start.getTime()}`;
      }
      const column = byKey.get(key);
      if (column === undefined) {
        return;
      }
      const value = tokens ? bucketTokens(b) : (b.costUsd ?? 0);
      const slot = providerBucket(b.provider);
      if (slot === 'claude') {
        column.claude += value;
      } else if (slot === 'codex') {
        column.codex += value;
      } else {
        column.other += value;
      }
    });
    return order.map((key: string) => byKey.get(key) as ChartColumn);
  }

  @Computed
  get chartMax(): number {
    let max = 0;
    this.columns.forEach((c: ChartColumn) => {
      max = Math.max(max, c.total);
    });
    return max;
  }

  @Computed
  get providerTotals(): ProviderTotal[] {
    const byProvider: Map<string, ProviderTotal> = new Map();
    this.buckets.forEach((b: UsageBucket) => {
      let total = byProvider.get(b.provider);
      if (total === undefined) {
        total = new ProviderTotal();
        total.provider = b.provider;
        byProvider.set(b.provider, total);
      }
      total.cost += b.costUsd ?? 0;
      total.tokens += bucketTokens(b);
      total.sessions += b.sessions ?? 0;
    });
    const list: ProviderTotal[] = [];
    byProvider.forEach((t: ProviderTotal) => list.push(t));
    const tokens = this.view === VIEW_TOKENS;
    return list.sort((a: ProviderTotal, b: ProviderTotal) => tokens ? b.tokens - a.tokens : b.cost - a.cost);
  }

  @Computed
  get limitCards(): LimitCard[] {
    const cards: LimitCard[] = [];
    this.selectedEnvironments.forEach((env: EnvironmentState) => {
      (env.config?.providers ?? []).forEach((provider: ProviderStatus) => {
        if (provider.usageLimits === undefined || provider.enabled === false) {
          return;
        }
        const card = new LimitCard();
        card.key = `${env.id}:${provider.instanceId ?? provider.driver ?? ''}`;
        card.title = provider.displayName ?? usageProviderLabel(provider.driver ?? '');
        card.account = provider.auth?.label ?? '';
        card.computer = this.app.multiEnv ? env.label : '';
        card.limits = provider.usageLimits;
        card.driver = provider.driver ?? '';
        cards.push(card);
      });
    });
    return cards;
  }

  private windowLabel(days: number): string {
    return days === 1 ? '24 小时' : `${days} 天`;
  }

  private seriesColor(slot: string): ResourceColor {
    if (slot === 'claude') {
      return $r('app.color.chart_claude');
    }
    return slot === 'codex' ? $r('app.color.chart_codex') : $r('app.color.chart_other');
  }

  private titleMenus(): HdsNavigationMenuItemOptions[] {
    const menus: HdsNavigationMenuItemOptions[] = [];
    if (this.app.multiEnv) {
      menus.push(symbolItem($r('sys.symbol.computer'), '选择电脑', 'usage.filter', () => this.showFilter()));
    }
    menus.push(symbolItem($r('sys.symbol.arrow_clockwise'), '刷新', 'usage.refresh', () => this.onRefresh()));
    return menus;
  }

  private showFilter(): void {
    const rows: ActionMenuRow[] = [
      ActionMenuRow.of('usage.filter.all', '全部电脑', '', () => {
        this.environmentFilter = '';
        this.load(true);
      }).withSymbol(this.environmentFilter.length === 0 ? $r('sys.symbol.checkmark') : $r('sys.symbol.computer')),
    ];
    this.app.environments.forEach((env: EnvironmentState) => {
      rows.push(ActionMenuRow.of(`usage.filter.${env.id}`, env.label, env.phase === 'connected' ? '' : '未连接', () => {
        this.environmentFilter = env.id;
        this.load(true);
      }).withSymbol(this.environmentFilter === env.id ? $r('sys.symbol.checkmark') : $r('sys.symbol.computer')));
    });
    showActionMenu(this.getUIContext(), 'usage.filter', rows);
  }

  @Builder
  windowPicker() {
    Row({ space: 6 }) {
      ForEach(WINDOWS, (days: number) => {
        Text(this.windowLabel(days))
          .id(`usage.window.${days}`)
          .fontSize(Type.small)
          .fontWeight(this.windowDays === days ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.windowDays === days ? $r('app.color.fg') : $r('app.color.fg_secondary'))
          .padding({ left: 12, right: 12 })
          .height(30)
          .borderRadius(15)
          .backgroundColor(this.windowDays === days ? $r('app.color.grouped_card') : Color.Transparent)
          .border({ width: this.windowDays === days ? 0.5 : 0, color: $r('app.color.border') })
          .onClick(() => {
            if (this.windowDays !== days) {
              this.windowDays = days;
              this.load(true);
            }
          })
      }, (days: number) => `${days}:${this.windowDays === days}`)
    }
    .padding({ left: Space.margin, right: Space.margin, top: 12 })
    .width('100%')
  }

  @Builder
  chart() {
    Column({ space: 6 }) {
      Row() {
        ForEach(this.columns, (column: ChartColumn) => {
          Column() {
            if (column.other > 0) {
              Column().width('100%').height(this.barHeight(column.other)).backgroundColor(this.seriesColor('other'))
            }
            if (column.codex > 0) {
              Column().width('100%').height(this.barHeight(column.codex)).backgroundColor(this.seriesColor('codex'))
            }
            if (column.claude > 0) {
              Column().width('100%').height(this.barHeight(column.claude)).backgroundColor(this.seriesColor('claude'))
            }
          }
          .justifyContent(FlexAlign.End)
          .layoutWeight(1)
          .height('100%')
          .borderRadius({ topLeft: 3, topRight: 3 })
          .clip(true)
          .margin({ left: this.columns.length > 40 ? 0.5 : 1.5, right: this.columns.length > 40 ? 0.5 : 1.5 })
        }, (column: ChartColumn) => `${column.key}:${column.total}`)
      }
      .id('usage.chart')
      .width('100%')
      .height(CHART_HEIGHT)
      .alignItems(VerticalAlign.Bottom)
      .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.border') } })
      Row() {
        Text(this.columns.length > 0 ? this.columns[0].label : '')
          .fontSize(Type.caption).fontColor($r('app.color.fg_tertiary'))
        Blank()
        Text(this.columns.length > 0 ? this.columns[this.columns.length - 1].label : '')
          .fontSize(Type.caption).fontColor($r('app.color.fg_tertiary'))
      }
      .width('100%')
      Row({ space: 14 }) {
        this.legend('claude', 'Claude')
        this.legend('codex', 'Codex')
        this.legend('other', '其他')
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.grouped_card'))
    .margin({ left: Space.margin, right: Space.margin, top: 12 })
  }

  private barHeight(value: number): number {
    if (this.chartMax <= 0) {
      return 0;
    }
    return Math.max(1, value / this.chartMax * (CHART_HEIGHT - 4));
  }

  @Builder
  legend(slot: string, label: string) {
    Row({ space: 5 }) {
      Circle().width(7).height(7).fill(this.seriesColor(slot))
      Text(label).fontSize(Type.caption).fontColor($r('app.color.fg_secondary'))
    }
  }

  @Builder
  totals() {
    Column({ space: 2 }) {
      Text(this.view === VIEW_TOKENS ? formatTokens(this.totalTokens) : formatUsd(this.totalCost))
        .id('usage.total')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontFeature('"tnum" on')
        .fontColor($r('app.color.fg'))
      Text(`过去 ${this.windowLabel(this.windowDays)}${this.selectedEnvironments.length > 1 ? ` · ${this.selectedEnvironments.length} 台电脑` : ''}${this.view === VIEW_TOKENS ? ' · Token' : ' · 估算费用'}`)
        .fontSize(Type.small)
        .fontColor($r('app.color.fg_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.margin, right: Space.margin, top: 16 })
    .width('100%')
  }

  @Builder
  providerRows() {
    Column() {
      ForEach(this.providerTotals, (total: ProviderTotal, index: number) => {
        Column() {
          Row({ space: 10 }) {
            Circle().width(8).height(8).fill(this.seriesColor(providerBucket(total.provider)))
            Text(usageProviderLabel(total.provider)).fontSize(Type.body).fontColor($r('app.color.fg')).layoutWeight(1)
            Column({ space: 1 }) {
              Text(this.view === VIEW_TOKENS ? formatTokens(total.tokens) : formatUsd(total.cost))
                .fontSize(Type.body).fontWeight(FontWeight.Medium).fontFeature('"tnum" on').fontColor($r('app.color.fg'))
              Text(this.shareLabel(total))
                .fontSize(Type.caption).fontColor($r('app.color.fg_tertiary'))
            }
            .alignItems(HorizontalAlign.End)
          }
          .id(`usage.provider.${total.provider}`)
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          if (index < this.providerTotals.length - 1) {
            Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 34 })
          }
        }
      }, (total: ProviderTotal) => `${total.provider}:${total.cost}:${total.tokens}:${this.view}`)
    }
    .borderRadius(16)
    .backgroundColor($r('app.color.grouped_card'))
    .margin({ left: Space.margin, right: Space.margin })
  }

  private shareLabel(total: ProviderTotal): string {
    const whole = this.view === VIEW_TOKENS ? this.totalTokens : this.totalCost;
    const part = this.view === VIEW_TOKENS ? total.tokens : total.cost;
    const share = whole > 0 ? Math.round(part / whole * 100) : 0;
    return `${share}% · ${total.sessions} 个会话`;
  }

  @Builder
  limitWindow(window: UsageWindow, driver: string) {
    Column({ space: 5 }) {
      Row() {
        Text(window.label).fontSize(Type.body).fontColor($r('app.color.fg')).layoutWeight(1)
        Text(`剩余 ${remainingPercent(window)}%`)
          .fontSize(Type.body)
          .fontWeight(FontWeight.Medium)
          .fontFeature('"tnum" on')
          .fontColor(remainingPercent(window) <= 10 ? $r('app.color.status_failed') : $r('app.color.fg'))
      }
      .width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.chip_bg'))
        Row()
          .width(`${remainingPercent(window)}%`)
          .height(6)
          .borderRadius(3)
          .backgroundColor(remainingPercent(window) <= 10 ? $r('app.color.status_failed')
            : remainingPercent(window) <= 30 ? $r('app.color.status_attention') : this.seriesColor(providerBucket(driver)))
        if (paceRemainingPercent(window, this.now) !== null) {
          Row()
            .width(2)
            .height(10)
            .borderRadius(1)
            .backgroundColor($r('app.color.fg_secondary'))
            .position({ x: `${paceRemainingPercent(window, this.now)}%`, y: -2 })
        }
      }
      .width('100%')
      .height(6)
      Row() {
        Text(paceLabel(window, this.now)).fontSize(Type.caption).fontColor($r('app.color.fg_tertiary')).layoutWeight(1)
        Text(resetsInLabel(window, this.now)).fontSize(Type.caption).fontColor($r('app.color.fg_tertiary'))
      }
      .width('100%')
    }
    .id(`usage.limit.${window.id}`)
    .width('100%')
  }

  @Builder
  limitCard(card: LimitCard) {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Text(card.title).fontSize(Type.barTitle).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg'))
        if (card.account.length > 0) {
          Text(card.account).fontSize(Type.small).fontColor($r('app.color.fg_tertiary')).maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Blank()
        }
        if (card.computer.length > 0) {
          Text(card.computer).fontSize(Type.caption).fontColor($r('app.color.fg_secondary'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8).backgroundColor($r('app.color.chip_bg'))
        }
      }
      .width('100%')
      if (card.limits?.unavailable !== undefined) {
        Text(card.limits.unavailable.message ?? (card.limits.unavailable.reason === 'unsupported' ? '这个账号不提供用量限额' : '暂时读不到限额'))
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_secondary'))
      } else if ((card.limits?.windows ?? []).length === 0) {
        Text('没有限额数据').fontSize(Type.small).fontColor($r('app.color.fg_secondary'))
      } else {
        ForEach(card.limits?.windows ?? [], (window: UsageWindow) => {
          this.limitWindow(window, card.driver)
        }, (window: UsageWindow) => `${window.id}:${window.usedPercent}:${window.resetsAt ?? ''}:${this.now}`)
      }
    }
    .id(`usage.card.${card.key}`)
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.grouped_card'))
    .margin({ left: Space.margin, right: Space.margin, top: 10 })
  }

  build() {
    HdsNavigation() {
      Refresh({ refreshing: this.refreshing!! }) {
        Scroll(this.scroller) {
          Column() {
            Column() {
              TabSegmentButtonV2({
                items: new SegmentButtonV2Items([{ text: '费用' }, { text: 'Token' }, { text: '限额' }]),
                selectedIndex: this.view,
                $selectedIndex: (index: number) => {
                  animate(this.getUIContext(), () => {
                    this.view = index;
                  });
                  lightEffects.tap();
                  if (index !== VIEW_LIMITS) {
                    this.load();
                  }
                },
              })
            }
            .id('usage.views')
            .padding({ left: Space.margin, right: Space.margin, top: 4 })
            .width('100%')

            if (!this.app.hasEnvironments) {
              Text('先连接一台电脑').fontSize(Type.body).fontColor($r('app.color.fg_secondary')).padding(32)
            } else if (this.view === VIEW_LIMITS) {
              if (this.limitCards.length === 0) {
                Text('还没有用量限额数据')
                  .id('usage.limitsEmpty')
                  .fontSize(Type.body)
                  .fontColor($r('app.color.fg_secondary'))
                  .textAlign(TextAlign.Center)
                  .padding(32)
                  .transition(ENTER)
              } else {
                Column() {
                  ForEach(this.limitCards, (card: LimitCard) => {
                    this.limitCard(card)
                  }, (card: LimitCard) => `${card.key}:${card.limits?.checkedAt ?? ''}:${this.now}`)
                }
                .padding({ top: 4 })
                .transition(ENTER)
              }
            } else {
              Column() {
                this.windowPicker()
                if (this.loading) {
                  LoadingProgress().width(28).height(28).color($r('app.color.fg_secondary')).margin({ top: 48 })
                    .transition(ENTER)
                } else {
                  Column() {
                    this.totals()
                    this.chart()
                    if (this.providerTotals.length > 0) {
                      sectionTitle('按服务商')
                      this.providerRows()
                    }
                  }
                  .width('100%')
                  .transition(ENTER)
                }
                if (this.error.length > 0) {
                  Text(this.error).fontSize(Type.small).fontColor($r('app.color.status_failed')).padding(16)
                }
              }
              .width('100%')
              .transition(ENTER)
            }
            Column().height(this.app.bottomInset + 180)
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .onRefreshing(() => this.onRefresh())
    }
    .titleBar(tabTitleBar('用量', this.titleMenus(), 'usage.title'))
    .titleMode(HdsNavigationTitleMode.FREE)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.screen'))
  }
}
