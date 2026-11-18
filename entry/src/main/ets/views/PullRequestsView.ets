import { HdsNavigation, HdsNavigationMenuItemOptions, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import { appState, AppState, EnvironmentState } from '../model/AppState';
import {
  checksLabel,
  PullRequestEntry,
  PullRequestListInput,
  PullRequestListResult,
  PullRequestListError,
  prStateLabel,
  repoName,
  reviewLabel,
} from '../model/Workspace';
import { openPullRequest, PullRequestRouteParam } from '../common/Nav';
import { relativeTime } from '../common/Format';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { symbolItem, tabTitleBar } from '../components/TitleBars';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { Space, Type } from '../common/Typography';
import { ENTER, STATE_CHANGE } from '../common/Motion';

const INVOLVEMENTS: string[] = ['all', 'reviewing', 'authored'];

class StateChip {
  value: string;
  label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const STATES: StateChip[] = [
  new StateChip('open', '打开'),
  new StateChip('merged', '已合并'),
  new StateChip('closed', '已关闭'),
  new StateChip('all', '全部'),
];

export function prStateColor(state: string, isDraft: boolean): ResourceColor {
  if (state === 'open') {
    return isDraft ? $r('app.color.fg_tertiary') : $r('app.color.success_fg');
  }
  if (state === 'merged') {
    return $r('app.color.pr_merged');
  }
  return $r('app.color.status_failed');
}

export function checksColor(state: string | undefined): ResourceColor {
  if (state === 'passing') {
    return $r('app.color.success_fg');
  }
  if (state === 'failing') {
    return $r('app.color.status_failed');
  }
  return $r('app.color.status_attention');
}

class ListError {
  key: string;
  text: string;

  constructor(key: string, text: string) {
    this.key = key;
    this.text = text;
  }
}

/** Pull requests across every connected computer's repositories, as on the iOS PRs tab. */
@ComponentV2
export struct PullRequestsView {
  @Local app: AppState = appState;
  @Local entries: PullRequestEntry[] = [];
  @Local errors: ListError[] = [];
  @Local loading: boolean = false;
  @Local refreshing: boolean = false;
  @Local involvement: number = 0;
  @Local stateFilter: string = 'open';
  @Local searching: boolean = false;
  @Local query: string = '';
  @Local environmentFilter: string = '';
  private scroller: Scroller = new Scroller();
  private loadedKey: string = '';
  private generation: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  @Monitor('app.environments')
  onEnvironments(): void {
    this.load();
  }

  @Computed
  get connectedEnvironments(): EnvironmentState[] {
    return this.app.environments.filter((e: EnvironmentState) => e.phase === 'connected' &&
      (this.environmentFilter.length === 0 || e.id === this.environmentFilter));
  }

  async load(force: boolean = false): Promise<void> {
    const envs = this.connectedEnvironments;
    const key = `${INVOLVEMENTS[this.involvement]}|${this.stateFilter}|${this.query}|${envs.map((e: EnvironmentState) => e.id).join(',')}`;
    if (!force && key === this.loadedKey) {
      return;
    }
    this.loadedKey = key;
    const generation = ++this.generation;
    this.loading = this.entries.length === 0;
    const input: PullRequestListInput = {
      state: this.stateFilter,
      involvement: INVOLVEMENTS[this.involvement],
      limit: 60,
    };
    if (this.query.trim().length > 0) {
      input.query = this.query.trim();
    }
    const all: PullRequestEntry[] = [];
    const errors: ListError[] = [];
    await Promise.all(envs.map(async (env: EnvironmentState) => {
      try {
        const result = await connection.rpc(env.id, 'pullRequests.list', input) as PullRequestListResult;
        (result.entries ?? []).forEach((entry: PullRequestEntry) => {
          entry.environmentId = env.id;
          // The same repository checked out on two computers lists the same pull request twice.
          if (!all.some((e: PullRequestEntry) => e.url === entry.url)) {
            all.push(entry);
          }
        });
        (result.errors ?? []).forEach((error: PullRequestListError) => {
          errors.push(new ListError(`${env.id}:${error.projectId}`, `${error.projectTitle}：${error.message}`));
        });
      } catch (e) {
        errors.push(new ListError(env.id, `${env.label}：${(e as Error).message}`));
      }
    }));
    if (generation !== this.generation) {
      return;
    }
    this.entries = all.sort((a: PullRequestEntry, b: PullRequestEntry) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt));
    this.errors = errors;
    this.loading = false;
  }

  private async onRefresh(): Promise<void> {
    lightEffects.tap();
    await this.load(true);
    this.refreshing = false;
  }

  private titleMenus(): HdsNavigationMenuItemOptions[] {
    const menus: HdsNavigationMenuItemOptions[] = [
      symbolItem(this.searching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'), this.searching ? '关闭搜索' : '搜索',
        'prs.search', () => {
          this.searching = !this.searching;
          if (!this.searching && this.query.length > 0) {
            this.query = '';
            this.load(true);
          }
        }),
    ];
    if (this.app.multiEnv) {
      menus.push(symbolItem($r('sys.symbol.computer'), '选择电脑', 'prs.filter', () => this.showFilter()));
    }
    return menus;
  }

  private showFilter(): void {
    const rows: ActionMenuRow[] = [
      ActionMenuRow.of('prs.filter.all', '全部电脑', '', () => {
        this.environmentFilter = '';
        this.load(true);
      }).withSymbol(this.environmentFilter.length === 0 ? $r('sys.symbol.checkmark') : $r('sys.symbol.computer')),
    ];
    this.app.environments.forEach((env: EnvironmentState) => {
      rows.push(ActionMenuRow.of(`prs.filter.${env.id}`, env.label, env.phase === 'connected' ? '' : '未连接', () => {
        this.environmentFilter = env.id;
        this.load(true);
      }).withSymbol(this.environmentFilter === env.id ? $r('sys.symbol.checkmark') : $r('sys.symbol.computer')));
    });
    showActionMenu(this.getUIContext(), 'prs.filter', rows);
  }

  private open(entry: PullRequestEntry): void {
    openPullRequest(new PullRequestRouteParam(entry.environmentId ?? '', entry.projectId, entry.host, entry.repository, entry.number, entry.title));
  }

  private meta(entry: PullRequestEntry): string {
    const parts: string[] = [`${repoName(entry.repository)} #${entry.number}`];
    if (entry.author !== null) {
      parts.push(entry.author.login);
    }
    if (this.app.multiEnv) {
      const env = this.app.environmentFor(entry.environmentId ?? '');
      if (env !== null) {
        parts.push(env.label);
      }
    }
    parts.push(relativeTime(entry.updatedAt, this.app.now));
    return parts.join(' · ');
  }

  @Builder
  row(entry: PullRequestEntry, last: boolean) {
    Column() {
      Row({ space: 10 }) {
        Image($r('app.media.ic_pull_request'))
          .width(18)
          .height(18)
          .fillColor(prStateColor(entry.state, entry.isDraft))
          .margin({ top: 2 })
        Column({ space: 4 }) {
          Text(entry.title)
            .fontSize(Type.body)
            .lineHeight(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.fg'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.meta(entry))
            .fontSize(Type.small)
            .fontColor($r('app.color.fg_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 10 }) {
            Row({ space: 10 }) {
            if (entry.isDraft || entry.state !== 'open') {
              Text(prStateLabel(entry.state, entry.isDraft)).fontSize(Type.caption).fontColor(prStateColor(entry.state, entry.isDraft))
            }
            if (checksLabel(entry.checksState).length > 0) {
              Text(checksLabel(entry.checksState)).fontSize(Type.caption).fontColor(checksColor(entry.checksState))
            }
            if (reviewLabel(entry.reviewDecision).length > 0) {
              Text(reviewLabel(entry.reviewDecision)).fontSize(Type.caption).fontColor($r('app.color.fg_secondary'))
            }
            if (entry.viewerReviewRequested) {
              Text('请你审查').fontSize(Type.caption).fontColor($r('app.color.status_attention'))
            }
            }
            .layoutWeight(1)
            .clip(true)
            if (entry.additions + entry.deletions > 0) {
              Text(`+${entry.additions}`).fontSize(Type.caption).fontColor($r('app.color.diff_add_fg'))
              Text(`−${entry.deletions}`).fontSize(Type.caption).fontColor($r('app.color.diff_del_fg'))
            }
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .id(`prs.row.${entry.number}`)
      .alignItems(VerticalAlign.Top)
      .width('100%')
      .padding({ left: Space.margin, right: Space.margin, top: 10, bottom: 10 })
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.row_pressed'))
        },
        normal: {
          .backgroundColor(Color.Transparent)
        }
      })
      .onClick(() => this.open(entry))
      if (!last) {
        Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: Space.margin + 28, right: Space.margin })
      }
    }
  }

  build() {
    HdsNavigation() {
      Refresh({ refreshing: this.refreshing!! }) {
        List({ scroller: this.scroller }) {
          ListItem() {
            Column({ space: 10 }) {
              if (this.searching) {
                Search({ value: this.query, placeholder: '搜索标题或编号' })
                  .id('prs.searchField')
                  .height(36)
                  .borderRadius(18)
                  .backgroundColor($r('app.color.grouped_card'))
                  .textFont({ size: Type.body })
                  .placeholderFont({ size: Type.body })
                  .onSubmit((value: string) => {
                    this.query = value;
                    this.load(true);
                  })
              }
              TabSegmentButtonV2({
                items: new SegmentButtonV2Items([{ text: '全部' }, { text: '待我审查' }, { text: '我创建的' }]),
                selectedIndex: this.involvement,
                $selectedIndex: (index: number) => {
                  this.involvement = index;
                  lightEffects.tap();
                  this.load();
                },
              })
              Row({ space: 6 }) {
                ForEach(STATES, (chip: StateChip) => {
                  Text(chip.label)
                    .id(`prs.state.${chip.value}`)
                    .fontSize(Type.small)
                    .fontWeight(this.stateFilter === chip.value ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(this.stateFilter === chip.value ? $r('app.color.fg') : $r('app.color.fg_secondary'))
                    .padding({ left: 12, right: 12 })
                    .height(30)
                    .borderRadius(15)
                    .backgroundColor(this.stateFilter === chip.value ? $r('app.color.grouped_card') : Color.Transparent)
                    .border({ width: this.stateFilter === chip.value ? 0.5 : 0, color: $r('app.color.border') })
                    .animation(STATE_CHANGE)
                    .onClick(() => {
                      if (this.stateFilter !== chip.value) {
                        this.stateFilter = chip.value;
                        this.load();
                      }
                    })
                }, (chip: StateChip) => chip.value)
              }
              .width('100%')
            }
            .padding({ left: Space.margin, right: Space.margin, top: 4, bottom: 6 })
          }

          ForEach(this.errors, (error: ListError) => {
            ListItem() {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(Type.body).fontColor([$r('app.color.warning_fg')])
                Text(error.text).fontSize(Type.small).fontColor($r('app.color.warning_fg')).layoutWeight(1).maxLines(3)
              }
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('app.color.warning_bg'))
              .margin({ left: Space.margin, right: Space.margin, top: 6 })
            }
          }, (error: ListError) => error.key)

          if (this.loading) {
            ListItem() {
              LoadingProgress().width(28).height(28).color($r('app.color.fg_secondary')).margin({ top: 48 })
            }
            .width('100%')
            .transition(ENTER)
          } else if (!this.app.hasEnvironments || this.connectedEnvironments.length === 0) {
            ListItem() {
              Text(this.app.hasEnvironments ? '电脑未连接' : '先连接一台电脑')
                .fontSize(Type.body).fontColor($r('app.color.fg_secondary')).textAlign(TextAlign.Center).padding(32).width('100%')
            }
          } else if (this.entries.length === 0) {
            ListItem() {
              Text(this.query.length > 0 ? '没有匹配的 PR' : '没有符合条件的 PR')
                .id('prs.empty')
                .fontSize(Type.body).fontColor($r('app.color.fg_secondary')).textAlign(TextAlign.Center).padding(32).width('100%')
            }
            .transition(ENTER)
          } else {
            ForEach(this.entries, (entry: PullRequestEntry, index: number) => {
              ListItem() {
                this.row(entry, index === this.entries.length - 1)
              }
              .transition(ENTER)
            }, (entry: PullRequestEntry) => `${entry.url}:${entry.updatedAt}:${entry.state}:${entry.isDraft}:${entry.checksState ?? ''}`)
          }

          ListItem() {
            Column().height(this.app.bottomInset + 180)
          }
        }
        .id('prs.list')
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .onRefreshing(() => this.onRefresh())
    }
    .titleBar(tabTitleBar('拉取请求', this.titleMenus(), 'prs.title'))
    .titleMode(HdsNavigationTitleMode.FREE)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .bindToScrollable([this.scroller])
    .backgroundColor(this.app.isWide ? $r('app.color.drawer') : $r('app.color.screen'))
  }
}
