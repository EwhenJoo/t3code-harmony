import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationMenuItemOptions, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { appState, AppState, ConnectionPhase, EnvironmentState, HomeRow, isSettled, isSnoozed } from '../model/AppState';
import { confirmDialog, promptDialog } from '../components/Dialogs';
import { immersiveMaterial, MaterialStyle, systemMaterialOn } from '../common/Material';
import { animate, FADE, REVEAL, SPRING } from '../common/Motion';
import { ProjectShell, ThreadShell } from '../model/Types';
import { BrandTitle, ProjectBadge, SectionHeader, StatusDot, ThreadTrailing } from '../components/Common';
import { brandTitleBar, symbolItem } from '../components/TitleBars';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { modelLabel, providerLabel } from '../common/Format';
import { openPairing, openThread } from '../common/Nav';
import { Prefs, PREF_SHOW_SETTLED } from '../common/Prefs';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { userSettings } from '../services/UserSettings';
import { Space, Type } from '../common/Typography';

/** Page margin per HarmonyOS breakpoints: 16vp on phones and narrow panes. */
const MARGIN = Space.margin;
const BADGE = Space.badge;
/** Sidebar rows are cards inset from the pane edge; padding brings their content back to MARGIN. */
const CARD_INSET = Space.cardInset;
const ROW_PAD = MARGIN - CARD_INSET;

class SnoozeChoice {
  key: string = '';
  label: string = '';
  detail: string = '';
  until: Date = new Date();

  static of(key: string, label: string, detail: string, until: Date): SnoozeChoice {
    const choice = new SnoozeChoice();
    choice.key = key;
    choice.label = label;
    choice.detail = detail;
    choice.until = until;
    return choice;
  }
}

function hhmm(date: Date): string {
  return `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
}

function at(base: Date, dayOffset: number, hour: number): Date {
  const date = new Date(base.getFullYear(), base.getMonth(), base.getDate() + dayOffset, hour, 0, 0, 0);
  return date;
}

/** Snooze presets: an hour, this evening (while it is still ahead), tomorrow morning, next Monday. */
export function snoozeChoices(now: Date): SnoozeChoice[] {
  const choices: SnoozeChoice[] = [];
  const hour = new Date(now.getTime() + 60 * 60 * 1000);
  choices.push(SnoozeChoice.of('hour', '1 小时后', `今天 ${hhmm(hour)}`, hour));
  if (now.getHours() < 18) {
    choices.push(SnoozeChoice.of('evening', '今晚', '今天 20:00', at(now, 0, 20)));
  }
  choices.push(SnoozeChoice.of('tomorrow', '明天上午', '明天 09:00', at(now, 1, 9)));
  const toMonday = ((8 - now.getDay()) % 7) || 7;
  const monday = at(now, toMonday, 9);
  choices.push(SnoozeChoice.of('week', '下周', `${monday.getMonth() + 1}月${monday.getDate()}日 周一 09:00`, monday));
  return choices;
}

/**
 * The thread list. Structure follows the official T3 Code mobile list (project glyph, title,
 * state on the right, one quiet metadata line, settled threads as slim rows); spacing, type
 * scale and hit targets follow HarmonyOS. Colour appears only where a thread needs the reader.
 */
@ComponentV2
export struct HomeView {
  @Local app: AppState = appState;
  @Local query: string = '';
  @Local projectFilter: string = '';
  @Local settledLimit: number = 25;
  /** Project groups opened past their first few conversations (this session only). */
  @Local expandedProjects: string[] = [];
  /** Projects whose conversations are all settled, shown after tapping the row at the end. */
  @Local searching: boolean = false;
  @Local refreshing: boolean = false;
  private scroller: Scroller = new Scroller();

  /** Sidebar look (rounded cards on the drawer) when list and conversation sit side by side. */
  private get sidebar(): boolean {
    return this.app.isWide;
  }

  private isSelected(threadId: string): boolean {
    return this.app.isWide && this.app.selectedThreadId === threadId;
  }

  @Computed
  get rows(): HomeRow[] {
    // Reading these keeps the computed value in sync with the shell stream and filters.
    const threads: ThreadShell[] = this.app.threads;
    const projects: ProjectShell[] = this.app.projects;
    const settled: boolean = this.app.showSettled;
    const folded: string[] = this.app.collapsedProjects;
    if (threads.length < 0 || projects.length < 0 || settled === undefined || folded.length < 0) {
      return [];
    }
    return this.app.buildHomeRows(this.query, this.projectFilter, this.settledLimit, this.app.groupBy, this.expandedProjects);
  }

  @Computed
  get filterProjects(): ProjectShell[] {
    const counts: Map<string, number> = new Map();
    this.app.threads.forEach((t: ThreadShell) => counts.set(t.projectId, (counts.get(t.projectId) ?? 0) + 1));
    return this.app.projects
      .filter((p: ProjectShell) => (counts.get(p.id) ?? 0) > 0 && !p.archivedAt)
      .sort((a: ProjectShell, b: ProjectShell) => (counts.get(b.id) ?? 0) - (counts.get(a.id) ?? 0));
  }

  private connectionText(phase: ConnectionPhase): string {
    switch (phase) {
      case 'connected':
        return '已连接';
      case 'connecting':
        return '正在连接…';
      case 'reconnecting':
        return '正在重新连接…';
      case 'offline':
        return '离线';
      default:
        return '未配对';
    }
  }

  private connectionColor(phase: ConnectionPhase): ResourceColor {
    switch (phase) {
      case 'connected':
        return $r('app.color.success_fg');
      case 'offline':
        return $r('app.color.status_failed');
      default:
        return $r('app.color.status_attention');
    }
  }

  /** Short words for the header, only while some computer is not connected. */
  private connectionProblem(): string {
    const envs = this.app.environments;
    if (envs.length === 0) {
      return '未配对';
    }
    const offline = envs.filter((e: EnvironmentState) => e.phase === 'offline').length;
    if (envs.some((e: EnvironmentState) => e.phase === 'reconnecting')) {
      return '正在重新连接…';
    }
    if (envs.some((e: EnvironmentState) => e.phase === 'connecting')) {
      return '正在连接…';
    }
    if (offline > 0) {
      return envs.length === 1 ? '离线' : `${offline} 台离线`;
    }
    return '';
  }

  /** What a screen reader says for the dots. */
  private computersDescription(): string {
    const envs = this.app.environments;
    const connected = envs.filter((e: EnvironmentState) => e.phase === 'connected').length;
    const problem = this.connectionProblem();
    return connected === envs.length ? `${envs.length} 台电脑，均已连接` : `${envs.length} 台电脑，${connected} 台已连接，${problem}`;
  }

  /** Computers that dropped and say why, so a banner can name them. */
  @Computed
  get offlineEnvironments(): EnvironmentState[] {
    return this.app.environments.filter((e: EnvironmentState) => e.phase === 'offline' && e.phaseDetail.length > 0);
  }

  private summaryText(): string {
    const parts: string[] = [];
    if (this.app.attentionCount > 0) {
      parts.push(`${this.app.attentionCount} 待处理`);
    }
    if (this.app.workingCount > 0) {
      parts.push(`${this.app.workingCount} 运行中`);
    }
    return parts.join(' · ');
  }

  /** Dot colors of the desktop sidebar: amber approval, indigo input, red failed, sky working, green done. */
  private stateColor(state: string): ResourceColor {
    switch (state) {
      case 'approval':
        return $r('app.color.status_attention');
      case 'input':
        return $r('app.color.status_input');
      case 'failed':
        return $r('app.color.status_failed');
      case 'working':
        return $r('app.color.status_working');
      default:
        return $r('app.color.status_unread');
    }
  }

  private stateWords(state: string): string {
    switch (state) {
      case 'approval':
        return '，有对话等待批准';
      case 'input':
        return '，有对话等待回答';
      case 'failed':
        return '，有对话失败';
      case 'working':
        return '，有对话运行中';
      case 'done':
        return '，有对话已完成待查看';
      default:
        return '';
    }
  }

  /** Under a project header (`grouped`) the project and computer are left out: the thread shows them. */
  private metaText(thread: ThreadShell, project: ProjectShell | null, grouped: boolean = false): string {
    const parts: string[] = [];
    if (this.app.multiEnv && !grouped) {
      // With several computers the first thing to know is where it runs.
      const env = this.app.environmentFor(thread.environmentId);
      if (env !== null) {
        parts.push(env.label);
      }
    }
    if (project !== null) {
      parts.push(project.title);
    }
    const model = thread.modelSelection?.model ?? '';
    parts.push(model.length > 0 ? modelLabel(model) : providerLabel(thread.providerInstanceId));
    if (thread.branch) {
      parts.push(thread.branch);
    }
    return parts.join(' · ');
  }

  private filterTitle(): string {
    if (this.projectFilter.length === 0) {
      return '';
    }
    if (this.projectFilter.startsWith('env:')) {
      return `电脑：${this.app.environmentFor(this.projectFilter.substring(4))?.label ?? ''}`;
    }
    const project = this.app.projectFor(this.projectFilter);
    return `项目：${project?.title ?? ''}`;
  }

  private projectsOf(environmentId: string): ProjectShell[] {
    return this.filterProjects.filter((p: ProjectShell) => p.environmentId === environmentId);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
  }

  private async runCommand(type: string, thread: ThreadShell, done: string): Promise<void> {
    try {
      await connection.simpleThreadCommand(type, thread.id);
      lightEffects.tap();
      this.toast(done);
    } catch (e) {
      this.toast(`操作失败：${(e as Error).message}`);
    }
  }

  private toggleSearch(): void {
    animate(this.getUIContext(), () => {
      this.searching = !this.searching;
      if (!this.searching) {
        this.query = '';
      }
    });
    if (this.searching) {
      setTimeout(() => {
        this.getUIContext().getFocusController().requestFocus('home.searchField');
      }, 80);
    }
  }

  private toggleSettled(): void {
    animate(this.getUIContext(), () => {
      this.app.showSettled = !this.app.showSettled;
    });
    Prefs.put(PREF_SHOW_SETTLED, this.app.showSettled);
    lightEffects.tap();
  }

  /** Filtering reshapes the list: rows that stay slide to their new places. */
  private setFilter(filter: string): void {
    animate(this.getUIContext(), () => {
      this.projectFilter = filter;
    });
  }

  private async onRefresh(): Promise<void> {
    lightEffects.tap();
    await connection.refresh();
    setTimeout(() => {
      this.refreshing = false;
    }, 300);
  }

  private projectRow(project: ProjectShell): ActionMenuRow {
    return ActionMenuRow.of(`home.filter.${project.id}`, project.title, '', () => {
      this.setFilter(project.id);
    }).withSymbol(this.projectFilter === project.id ? $r('sys.symbol.checkmark') : $r('sys.symbol.folder'));
  }

  /** Filter by computer or project; with several computers, projects are grouped under theirs. */
  private showFilterMenu(): void {
    const byProject = this.app.groupBy === 'project';
    const rows: ActionMenuRow[] = [
      ActionMenuRow.of('home.group.project', '按项目分组', '', () => {
        userSettings.setGroupBy('project');
      }).withSymbol(byProject ? $r('sys.symbol.checkmark') : $r('sys.symbol.folder')),
      ActionMenuRow.of('home.group.status', '按状态分组', '', () => {
        userSettings.setGroupBy('status');
      }).withSymbol(!byProject ? $r('sys.symbol.checkmark') : $r('sys.symbol.list_bullet')),
      ActionMenuRow.of('home.filter.all', this.app.multiEnv ? '全部电脑' : '全部项目', '', () => {
        this.setFilter('');
      }).withSymbol(this.projectFilter.length === 0 ? $r('sys.symbol.checkmark') : $r('sys.symbol.ellipsis_message')),
    ];
    if (this.app.multiEnv) {
      this.app.environments.forEach((env: EnvironmentState) => {
        rows.push(ActionMenuRow.of(`home.filter.env.${env.id}`, env.label, '', () => {
          this.setFilter(`env:${env.id}`);
        }).withSymbol(this.projectFilter === `env:${env.id}` ? $r('sys.symbol.checkmark') : $r('sys.symbol.computer')));
        this.projectsOf(env.id).forEach((project: ProjectShell) => rows.push(this.projectRow(project)));
      });
    } else {
      this.filterProjects.forEach((project: ProjectShell) => rows.push(this.projectRow(project)));
    }
    showActionMenu(this.getUIContext(), 'home.filterMenu', rows);
  }

  private titleMenus(): HdsNavigationMenuItemOptions[] {
    const menus: HdsNavigationMenuItemOptions[] = [];
    menus.push(symbolItem($r('sys.symbol.line_3_horizontal'), '分组与筛选', 'home.filterMenu', () => this.showFilterMenu()));
    menus.push(symbolItem(this.searching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
      this.searching ? '关闭搜索' : '搜索', 'home.searchToggle', () => this.toggleSearch()));
    return menus;
  }

  /** The brand sits in the title bar's left slot, aligned with the page margin. */
  @Builder
  brand() {
    Row() {
      BrandTitle({ markHeight: 15 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: MARGIN })
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * Which computers are reachable, without naming them: a laptop glyph and one dot per computer
   * (green connected, amber connecting, red offline). Words appear only when something is wrong.
   */
  @Builder
  computersIndicator() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.matebook'))
        .fontSize(15)
        .fontColor([$r('app.color.fg_tertiary')])
        .margin({ right: 2 })
      ForEach(this.app.environments, (env: EnvironmentState) => {
        Column() {
          Column()
            .id(`home.computerState.${env.id}.${env.phase}`)
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.connectionColor(env.phase))
        }
        .id(`home.computer.${env.id}`)
        .width(8)
        .height(20)
        .justifyContent(FlexAlign.Center)
      }, (env: EnvironmentState) => `${env.id}:${env.phase}`)
      if (this.connectionProblem().length > 0) {
        Text(this.connectionProblem())
          .id('home.connection')
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_secondary'))
          .maxLines(1)
          .margin({ left: 4 })
      }
    }
    .id('home.computers')
    .height(20)

    .accessibilityText(this.computersDescription())
  }

  @Builder
  header() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        this.computersIndicator()
        Blank()
        Text(this.summaryText())
          .id('home.summary')
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_tertiary'))
          .maxLines(1)
      }
      .width('100%')
      .height(20)
      .padding({ left: MARGIN, right: MARGIN })

      if (this.projectFilter.length > 0) {
        Row() {
          Row({ space: 4 }) {
            Text(this.filterTitle()).fontSize(Type.small).fontColor($r('app.color.fg'))
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(Type.small).fontColor([$r('app.color.fg_secondary')])
          }
          .id('home.filterTag')
          .height(26)
          .padding({ left: 10, right: 8 })
          // Visually compact, but the touch target meets the 40vp minimum.
          .responseRegion({ x: 0, y: -7, width: '100%', height: 40 })
          .borderRadius(13)
          .backgroundColor($r('app.color.grouped_card'))
          .onClick(() => {
            this.setFilter('');
          })
        }
        .width('100%')
        .padding({ left: MARGIN, right: MARGIN, top: 4 })
        .transition(REVEAL)
      }

      if (this.searching) {
        Row() {
          Search({ value: this.query, placeholder: '搜索对话、项目或消息' })
            .id('home.searchField')
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('app.color.grouped_card'))
            .placeholderColor($r('app.color.fg_tertiary'))
            .placeholderFont({ size: Type.body })
            .textFont({ size: Type.body })
            .layoutWeight(1)
            .onChange((value: string) => {
              this.query = value;
            })
        }
        .width('100%')
        .padding({ left: MARGIN, right: MARGIN, top: 6 })
        .transition(REVEAL)
      }

      ForEach(this.offlineEnvironments, (env: EnvironmentState, index: number) => {
        Row() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.wifi_slash')).fontSize(Type.body).fontColor([$r('app.color.warning_fg')])
            Text(this.app.multiEnv ? `${env.label}：${env.phaseDetail}` : env.phaseDetail)
              .fontSize(Type.small)
              .fontColor($r('app.color.warning_fg'))
              .layoutWeight(1)
              .maxLines(3)
            Text('重试')
              .id(index === 0 ? 'home.retry' : `home.retry.${env.id}`)
              .fontSize(Type.small)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => connection.reconnect(env.id))
          }
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor($r('app.color.warning_bg'))
        }
        .width('100%')
        .padding({ left: MARGIN, right: MARGIN, top: 6 })
        .transition(REVEAL)
      }, (env: EnvironmentState) => `${env.id}:${env.phaseDetail}`)
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 2, bottom: 2 })
    .width('100%')
  }

  /** Active threads: glyph, title (two lines), state on the right, one line of quiet context. */
  @Builder
  threadRow(row: HomeRow) {
    if (row.thread !== null) {
      Column() {
        Row({ space: 10 }) {
          if (row.groupKey.length > 0) {
            // Grouped by project: the header carries the icon; keep the column so titles line up.
            Column().width(BADGE).height(BADGE)
          } else {
            ProjectBadge({ project: row.project, badgeSize: BADGE, dim: row.section === 'settled' })
              .margin({ top: 1 })
          }
          Column({ space: 2 }) {
            Row({ space: 8 }) {
              if (row.thread.pinnedAt) {
                SymbolGlyph($r('sys.symbol.pin_fill')).fontSize(Type.caption).fontColor([$r('app.color.fg_tertiary')])
                  .margin({ top: 4 })
              }
              Text(row.thread.title.length > 0 ? row.thread.title : '新对话')
                .fontSize(Type.body)
                .lineHeight(20)
                // Finished work reads quieter, but keeps the same row shape so everything lines up.
                .fontWeight(row.section === 'settled' ? FontWeight.Regular : FontWeight.Medium)
                .fontColor(row.section === 'settled' && !this.isSelected(row.thread.id) ? $r('app.color.fg_secondary') : $r('app.color.fg'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              ThreadTrailing({ thread: row.thread })
                .margin({ top: 2 })
            }
            .alignItems(VerticalAlign.Top)
            .width('100%')
            if (row.thread.status === 'failed' && (row.thread.lastError ?? '').length > 0) {
              Text(row.thread.lastError ?? '')
                .fontSize(Type.small)
                .lineHeight(Type.smallLine)
                .fontColor($r('app.color.status_failed'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              // Under a project header the project name would only repeat.
              Text(this.metaText(row.thread, row.groupKey.length > 0 ? null : row.project, row.groupKey.length > 0))
                .fontSize(Type.small)
                .lineHeight(Type.smallLine)
                .fontColor($r('app.color.fg_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .id(`home.thread.${row.thread.id}`)
        .alignItems(VerticalAlign.Top)
        .padding({ left: this.sidebar ? ROW_PAD : MARGIN, right: this.sidebar ? ROW_PAD : MARGIN, top: 9, bottom: 9 })
        .width('100%')
        .borderRadius(this.sidebar ? 10 : 0)
        .backgroundColor(this.rowBackground(row.thread.id))
        .stateStyles({
          pressed: {
            .backgroundColor($r('app.color.row_pressed'))
          },
          normal: {
            .backgroundColor(this.rowBackground((row.thread as ThreadShell).id))
          }
        })
        .bindContextMenu(this.rowMenu(row.thread), ResponseType.LongPress, {
          systemMaterial: immersiveMaterial(MaterialStyle.THICK),
          backgroundBlurStyle: systemMaterialOn() ? undefined : BlurStyle.COMPONENT_ULTRA_THICK,
        })
        .onClick(() => openThread((row.thread as ThreadShell).id))

        if (!this.sidebar && !row.lastInSection) {
          Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: MARGIN + BADGE + 10, right: MARGIN })
        }
      }
      .width('100%')
      .padding({ left: this.sidebar ? CARD_INSET : 0, right: this.sidebar ? CARD_INSET : 0 })
    }
  }

  private rowBackground(threadId: string): ResourceColor {
    if (this.isSelected(threadId)) {
      return $r('app.color.row_selected');
    }
    return this.sidebar ? $r('app.color.drawer') : $r('app.color.screen');
  }

  @Builder
  rowMenu(thread: ThreadShell) {
    Menu() {
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.ellipsis_message')), content: '打开' })
        .onClick(() => openThread(thread.id))
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier(thread.pinnedAt ? $r('sys.symbol.pin_slash') : $r('sys.symbol.pin')),
        content: thread.pinnedAt ? '取消置顶' : '置顶'
      })
        .onClick(() => this.runCommand(thread.pinnedAt ? 'thread.unpin' : 'thread.pin', thread, thread.pinnedAt ? '已取消置顶' : '已置顶'))
      if (isSnoozed(thread, Date.now())) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.bell_slash')), content: '取消稍后提醒' })
          .id('home.menu.unsnooze')
          .onClick(() => this.runCommand('thread.unsnooze', thread, '已取消稍后提醒'))
      } else {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.alarm')),
          content: '稍后提醒',
          builder: (): void => this.snoozeMenu(thread),
        })
          .id('home.menu.snooze')
      }
      if (isSettled(thread)) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_counterclockwise_clock')), content: '恢复为进行中' })
          .id('home.menu.unsettle')
          .onClick(() => this.runCommand('thread.unsettle', thread, '已恢复'))
      } else {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')), content: '标记为完成' })
          .id('home.menu.settle')
          .onClick(() => this.runCommand('thread.settle', thread, '已标记为完成'))
      }
      MenuItemGroup() {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')), content: '重命名' })
          .id('home.menu.rename')
          .onClick(() => this.rename(thread))
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.archivebox')), content: '归档' })
          .id('home.menu.archive')
          .onClick(() => this.runCommand('thread.archive', thread, '已归档'))
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([$r('sys.color.warning')]),
          content: '删除',
        })
          .id('home.menu.delete')
          .contentFontColor($r('sys.color.warning'))
          .onClick(() => this.remove(thread))
      }
    }
    .subMenuExpandingMode(SubMenuExpandingMode.EMBEDDED_EXPAND)
  }

  /** The same choices as iOS: soon, this evening, tomorrow morning, next week. */
  @Builder
  snoozeMenu(thread: ThreadShell) {
    Menu() {
      ForEach(snoozeChoices(new Date()), (choice: SnoozeChoice) => {
        MenuItem({ content: choice.label, labelInfo: choice.detail })
          .id(`home.menu.snooze.${choice.key}`)
          .onClick(() => this.snooze(thread, choice))
      }, (choice: SnoozeChoice) => choice.key)
    }
  }

  private async snooze(thread: ThreadShell, choice: SnoozeChoice): Promise<void> {
    try {
      await connection.snoozeThread(thread.id, choice.until);
      lightEffects.tap();
      this.toast(`将于 ${choice.detail} 提醒`);
    } catch (e) {
      this.toast(`操作失败：${(e as Error).message}`);
    }
  }

  private async rename(thread: ThreadShell): Promise<void> {
    const title = await promptDialog(this.getUIContext(), '重命名对话', '留空则由代理重新生成标题。', '对话标题', '保存',
      thread.title);
    if (title === null || title.trim() === thread.title) {
      return;
    }
    try {
      await connection.renameThread(thread.id, title);
      lightEffects.tap();
      this.toast(title.trim().length > 0 ? '已重命名' : '正在重新生成标题');
    } catch (e) {
      this.toast(`操作失败：${(e as Error).message}`);
    }
  }

  private async remove(thread: ThreadShell): Promise<void> {
    const ok = await confirmDialog(this.getUIContext(), '删除这个对话？', `“${thread.title}”及其消息将被删除，无法恢复。`,
      '删除', true);
    if (ok) {
      await this.runCommand('thread.delete', thread, '已删除');
    }
  }

  /** A project group's header, like the desktop sidebar: icon, name, count, fold chevron. */
  @Builder
  projectHeader(row: HomeRow) {
    Row({ space: 10 }) {
      ProjectBadge({ project: row.project, badgeSize: BADGE })
      Text(row.title)
        .fontSize(Type.body)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
      Blank()
      // Folded, the header stands in for its conversations: one dot for the most pressing state.
      if (row.collapsed && row.state.length > 0) {
        Circle()
          .width(7)
          .height(7)
          .fill(this.stateColor(row.state))
          .id(`home.projectState.${row.project?.id ?? row.groupKey}.${row.state}`)
      }
      Text(`${row.count}`)
        .fontSize(Type.small)
        .fontColor($r('app.color.fg_tertiary'))
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor([$r('app.color.fg_tertiary')])
        .rotate({ angle: row.collapsed ? -90 : 0 })
        .animation({ curve: SPRING })
    }
    .id(`home.project.${row.project?.id ?? row.groupKey}`)
    .width('100%')
    .height(44)
    .padding({ left: this.sidebar ? ROW_PAD + CARD_INSET : MARGIN, right: MARGIN, top: 6 })
    .accessibilityText(`${row.title}，${row.count} 个对话${row.collapsed ? `，已折叠${this.stateWords(row.state)}` : ''}`)
    .onClick(() => {
      lightEffects.tap();
      animate(this.getUIContext(), () => {
        userSettings.toggleProject(row.groupKey);
      });
    })
  }

  @Builder
  swipeAction(id: string, symbol: Resource, label: string, bg: ResourceColor, width: number, action: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(symbol).fontSize(18).fontColor([Color.White])
      Text(label).fontSize(11).fontColor(Color.White)
    }
    .id(id)
    .justifyContent(FlexAlign.Center)
    .width(width)
    .height('100%')
    .backgroundColor(bg)
    .onClick(action)
  }

  @Builder
  swipeEnd(thread: ThreadShell) {
    Row() {
      this.swipeAction(`home.swipe.settle.${thread.id}`, $r('sys.symbol.checkmark'), '完成', $r('app.color.prominent'), 72,
        () => this.runCommand('thread.settle', thread, '已标记为完成'))
      this.swipeAction(`home.swipe.archive.${thread.id}`, $r('sys.symbol.archivebox'), '归档', $r('app.color.fg_secondary'), 72,
        () => this.runCommand('thread.archive', thread, '已归档'))
    }
    .height('100%')
  }

  @Builder
  swipeStart(thread: ThreadShell) {
    this.swipeAction(`home.swipe.pin.${thread.id}`, thread.pinnedAt ? $r('sys.symbol.pin_slash') : $r('sys.symbol.pin_fill'),
      thread.pinnedAt ? '取消置顶' : '置顶', $r('app.color.primary'), 80,
      () => this.runCommand(thread.pinnedAt ? 'thread.unpin' : 'thread.pin', thread, thread.pinnedAt ? '已取消置顶' : '已置顶'))
  }

  @Builder
  skeleton() {
    Column() {
      ForEach([0, 1, 2, 3, 4, 5, 6, 7], (index: number) => {
        SkeletonRow({ widthRatio: 0.5 + (index % 3) * 0.14 })
      }, (index: number) => `sk${index}`)
    }
    .padding({ top: 8 })
    .width('100%')
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      if (!this.app.hasEnvironments) {
        Text('连接你的电脑').fontSize(Type.barTitle).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg'))
        Button('开始').fontSize(Type.body).onClick(() => openPairing()).backgroundColor($r('app.color.prominent')).fontColor($r('app.color.prominent_fg'))
      } else if (this.query.length > 0 || this.projectFilter.length > 0) {
        Text('没有匹配的对话').id('home.emptySearch').fontSize(Type.body).fontColor($r('app.color.fg_secondary'))
      } else {
        Text('还没有对话').fontSize(Type.body).fontColor($r('app.color.fg_secondary'))
      }
    }
    .width('100%')
    .padding({ top: 56, left: 32, right: 32 })
  }

  build() {
    HdsNavigation() {
      Refresh({ refreshing: this.refreshing!! }) {
        List({ scroller: this.scroller }) {
          ListItem() {
            this.header()
          }

          if (!this.app.anyShellLoaded && this.app.hasEnvironments) {
            ListItem() {
              this.skeleton()
            }
            .transition(FADE)
          } else {
            ForEach(this.rows, (row: HomeRow) => {
              if (row.kind === 'header' && row.groupKey.length > 0) {
                ListItem() {
                  this.projectHeader(row)
                }
              } else if (row.kind === 'header') {
                ListItem() {
                  SectionHeader({
                    title: row.title,
                    count: row.count,
                    inset: MARGIN,
                    collapsible: row.section === 'settled',
                    collapsed: row.collapsed,
                    onToggle: () => this.toggleSettled()
                  })
                    .id(`home.section.${row.section}`)
                }
              } else if (row.kind === 'thread' && row.thread !== null) {
                ListItem() {
                  this.threadRow(row)
                }
                .swipeAction({
                  end: { builder: () => this.swipeEnd(row.thread as ThreadShell) },
                  start: { builder: () => this.swipeStart(row.thread as ThreadShell) },
                  edgeEffect: SwipeEdgeEffect.Spring,
                })
              } else if (row.kind === 'more') {
                ListItem() {
                  Text(`再显示 ${row.groupKey.length > 0 ? row.count : Math.min(row.count, 50)} 个`)
                    .id(`home.more.${row.section}`)
                    .fontSize(Type.small)
                    .fontColor($r('app.color.fg_secondary'))
                    .textAlign(TextAlign.Center)
                    .width('100%')
                    .height(Space.hit)
                    .borderRadius(10)
                    .backgroundColor($r('app.color.grouped_card'))
                    .margin({ top: 8 })
                    .onClick(() => {
                      animate(this.getUIContext(), () => {
                        if (row.groupKey.length > 0) {
                          this.expandedProjects = this.expandedProjects.concat([row.groupKey]);
                        } else {
                          this.settledLimit += 50;
                        }
                      });
                    })
                }
                .padding({ left: MARGIN, right: MARGIN })
              } else {
                ListItem() {
                  this.emptyState()
                }
              }
            }, (row: HomeRow) => row.kind === 'thread' && row.thread !== null
              ? `${row.key}:${row.section}:${row.lastInSection}:${row.thread.updatedAt}:${row.thread.status}:${row.thread.pinnedAt ?? ''}:${row.thread.pendingRuntimeRequest?.id ?? ''}:${row.thread.latestVisibleMessage?.updatedAt ?? ''}`
              : `${row.key}:${row.count}:${row.collapsed}:${row.state}:${row.project?.id ?? ''}:${row.project?.title ?? ''}:${JSON.stringify(row.project?.projectIcon ?? null)}`)
          }

          ListItem() {
            Column().height(this.app.bottomInset + 180)
          }
        }
        .id('home.list')
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .onRefreshing(() => this.onRefresh())
      // New conversations start from the button beside the floating tab bar, in every layout.
    }
    .titleBar(brandTitleBar(() => this.brand(), this.titleMenus()))
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .bindToScrollable([this.scroller])
    .backgroundColor(this.sidebar ? $r('app.color.drawer') : $r('app.color.screen'))
    .width('100%')
    .height('100%')
  }
}

/** Static placeholder rows while the first shell snapshot loads (no shimmer animation). */
@ComponentV2
struct SkeletonRow {
  @Param widthRatio: number = 0.6;

  build() {
    Row({ space: 10 }) {
      Row().width(20).height(20).borderRadius(6).backgroundColor($r('app.color.skeleton'))
      Column({ space: 8 }) {
        Row()
          .width(`${Math.round(this.widthRatio * 100)}%`)
          .height(12)
          .borderRadius(6)
          .backgroundColor($r('app.color.skeleton'))
        Row()
          .width('36%')
          .height(10)
          .borderRadius(5)
          .backgroundColor($r('app.color.skeleton'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .padding({ left: MARGIN, right: MARGIN, top: 12, bottom: 12 })
    .width('100%')
  }
}
