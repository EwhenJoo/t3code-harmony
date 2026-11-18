import { HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { appState, AppState } from '../model/AppState';
import {
  checkStatusLabel,
  checksLabel,
  PullRequestActionInput,
  PullRequestCheck,
  PullRequestDetail,
  PullRequestLabel,
  PullRequestRef,
  prStateLabel,
  repoName,
  reviewLabel,
} from '../model/Workspace';
import { detailNav, PullRequestRouteParam } from '../common/Nav';
import { relativeTime } from '../common/Format';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { symbolItem, titleBar } from '../components/TitleBars';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { confirmDialog } from '../components/Dialogs';
import { MarkdownView } from '../components/Markdown';
import { prStateColor } from './PullRequestsView';
import { sectionTitle } from './GitPage';
import { Space, Type } from '../common/Typography';

function checkColor(status: string): ResourceColor {
  if (status === 'success') {
    return $r('app.color.success_fg');
  }
  if (status === 'failure' || status === 'action-required') {
    return $r('app.color.status_failed');
  }
  if (status === 'pending') {
    return $r('app.color.status_attention');
  }
  return $r('app.color.fg_tertiary');
}

function checkSymbol(status: string): Resource {
  if (status === 'success') {
    return $r('sys.symbol.checkmark_circle');
  }
  if (status === 'failure' || status === 'action-required') {
    return $r('sys.symbol.xmark_circle');
  }
  return $r('sys.symbol.clock');
}

function overallChecks(d: PullRequestDetail): string {
  if (d.checks.length === 0) {
    return '';
  }
  if (d.checks.some((c: PullRequestCheck) => c.status === 'failure' || c.status === 'action-required')) {
    return 'failing';
  }
  return d.checks.some((c: PullRequestCheck) => c.status === 'pending') ? 'pending' : 'passing';
}

/** One pull request: status, checks, description and the merge / ready / close actions. */
@ComponentV2
export struct PullRequestPage {
  @Local app: AppState = appState;
  @Local detail: PullRequestDetail | null = null;
  @Local loading: boolean = true;
  @Local error: string = '';
  @Local busy: string = '';
  @Local inDetailPane: boolean = false;
  @Local title: string = '';
  private param: PullRequestRouteParam | null = null;
  private stack: NavPathStack | null = null;

  private ref(): PullRequestRef {
    const p = this.param as PullRequestRouteParam;
    const ref: PullRequestRef = { projectId: p.projectId, repository: p.repository, number: p.number };
    if (p.host.length > 0) {
      ref.host = p.host;
    }
    return ref;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private async load(): Promise<void> {
    if (this.param === null) {
      return;
    }
    this.error = '';
    try {
      this.detail = await connection.rpc(this.param.environmentId, 'pullRequests.detail', this.ref()) as PullRequestDetail;
      this.title = this.detail.title;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private async runAction(action: string, label: string, mergeMethod: string = ''): Promise<void> {
    if (this.param === null) {
      return;
    }
    const ref = this.ref();
    const input: PullRequestActionInput = {
      projectId: ref.projectId,
      repository: ref.repository,
      number: ref.number,
      action: action,
    };
    if (ref.host !== undefined) {
      input.host = ref.host;
    }
    if (mergeMethod.length > 0) {
      input.mergeMethod = mergeMethod;
    }
    this.busy = label;
    try {
      await connection.rpc(this.param.environmentId, 'pullRequests.runAction', input);
      lightEffects.tap();
      this.toast(`${label}完成`);
      await this.load();
    } catch (e) {
      this.toast(`${label}失败：${(e as Error).message}`);
    } finally {
      this.busy = '';
    }
  }

  private async merge(method: string, label: string): Promise<void> {
    const d = this.detail;
    if (d === null) {
      return;
    }
    const ok = await confirmDialog(this.getUIContext(), `${label} #${d.number}？`,
      `把 ${d.headBranch} 合并进 ${d.baseBranch}。`, label);
    if (ok) {
      await this.runAction('merge', label, method);
    }
  }

  private showMergeMenu(): void {
    const caps = this.detail?.mergeCapabilities;
    const rows: ActionMenuRow[] = [];
    if (caps === undefined || caps.squash) {
      rows.push(ActionMenuRow.of('pr.merge.squash', '压缩合并', '', () => this.merge('squash', '压缩合并'))
        .withSymbol($r('sys.symbol.arrow_triangle_merge')));
    }
    if (caps === undefined || caps.merge) {
      rows.push(ActionMenuRow.of('pr.merge.merge', '创建合并提交', '', () => this.merge('merge', '合并'))
        .withSymbol($r('sys.symbol.arrow_triangle_merge')));
    }
    if (caps === undefined || caps.rebase) {
      rows.push(ActionMenuRow.of('pr.merge.rebase', '变基合并', '', () => this.merge('rebase', '变基合并'))
        .withSymbol($r('sys.symbol.arrow_triangle_merge')));
    }
    showActionMenu(this.getUIContext(), 'pr.merge', rows);
  }

  private openInBrowser(): void {
    const url = this.detail?.url ?? '';
    if (url.length === 0) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.openLink(url).catch(() => this.toast('无法打开链接'));
    } catch (e) {
      this.toast('无法打开链接');
    }
  }

  private menus(): HdsNavigationMenuItemOptions[] {
    return [
      symbolItem($r('sys.symbol.arrow_up_right'), '在浏览器中打开', 'pr.open', () => this.openInBrowser(), this.detail !== null),
      symbolItem($r('sys.symbol.arrow_clockwise'), '刷新', 'pr.refresh', () => this.load()),
    ];
  }

  @Builder
  pill(text: string, color: ResourceColor) {
    Text(text)
      .fontSize(Type.small)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(10)
      .backgroundColor($r('app.color.chip_bg'))
  }

  @Builder
  headerBody(d: PullRequestDetail) {
    Column({ space: 10 }) {
      Text(d.title)
        .id('pr.detailTitle')
        .fontSize(Type.pageTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.fg'))
      Row({ space: 8 }) {
        Row({ space: 4 }) {
          Image($r('app.media.ic_pull_request')).width(14).height(14).fillColor(prStateColor(d.state, d.isDraft))
          Text(prStateLabel(d.state, d.isDraft)).fontSize(Type.small).fontWeight(FontWeight.Medium).fontColor(prStateColor(d.state, d.isDraft))
        }
        .id('pr.state')
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(10)
        .backgroundColor($r('app.color.chip_bg'))
        if (overallChecks(d).length > 0) {
          this.pill(checksLabel(overallChecks(d)), $r('app.color.fg_secondary'))
        }
        if (reviewLabel(d.reviewDecision).length > 0) {
          this.pill(reviewLabel(d.reviewDecision), $r('app.color.fg_secondary'))
        }
      }
      Text(`${repoName(d.repository)} #${d.number} · ${d.author?.login ?? '未知'} · ${relativeTime(d.updatedAt, this.app.now)}更新`)
        .fontSize(Type.small)
        .fontColor($r('app.color.fg_tertiary'))
      Row({ space: 6 }) {
        Text(d.headBranch).fontSize(Type.small).fontFamily('monospace').fontColor($r('app.color.fg_secondary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
        SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(12).fontColor([$r('app.color.fg_tertiary')])
        Text(d.baseBranch).fontSize(Type.small).fontFamily('monospace').fontColor($r('app.color.fg_secondary'))
        Blank()
        Text(`+${d.additions}`).fontSize(Type.small).fontColor($r('app.color.diff_add_fg'))
        Text(`−${d.deletions}`).fontSize(Type.small).fontColor($r('app.color.diff_del_fg'))
        Text(`${d.changedFiles} 个文件`).fontSize(Type.small).fontColor($r('app.color.fg_tertiary'))
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.margin, right: Space.margin, top: 8 })
    .width('100%')
  }

  @Builder
  actionsBody(d: PullRequestDetail) {
    Row({ space: 10 }) {
      if (d.state === 'open' && !d.isDraft) {
        Button(this.busy.length > 0 ? `${this.busy}…` : '合并')
          .id('pr.merge')
          .fontSize(Type.body)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.prominent_fg'))
          .backgroundColor($r('app.color.prominent'))
          .height(40)
          .layoutWeight(1)
          .enabled(this.busy.length === 0 && d.mergeability !== 'conflicting')
          .onClick(() => this.showMergeMenu())
      }
      if (d.state === 'open' && d.isDraft) {
        Button('标记为可审查')
          .id('pr.ready')
          .fontSize(Type.body)
          .fontColor($r('app.color.prominent_fg'))
          .backgroundColor($r('app.color.prominent'))
          .height(40)
          .layoutWeight(1)
          .enabled(this.busy.length === 0)
          .onClick(() => this.runAction('ready', '标记为可审查'))
      }
      if (d.state === 'open') {
        Button('关闭')
          .id('pr.close')
          .fontSize(Type.body)
          .fontColor($r('app.color.danger_fg'))
          .backgroundColor($r('app.color.chip_bg'))
          .height(40)
          .layoutWeight(d.isDraft ? 1 : 0.6)
          .enabled(this.busy.length === 0)
          .onClick(async () => {
            const ok = await confirmDialog(this.getUIContext(), `关闭 #${d.number}？`, '不会删除分支，之后可以重新打开。', '关闭', true);
            if (ok) {
              await this.runAction('close', '关闭');
            }
          })
      }
      if (d.state === 'closed') {
        Button('重新打开')
          .id('pr.reopen')
          .fontSize(Type.body)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.chip_bg'))
          .height(40)
          .layoutWeight(1)
          .enabled(this.busy.length === 0)
          .onClick(() => this.runAction('reopen', '重新打开'))
      }
    }
    .width('100%')
    .padding({ left: Space.margin, right: Space.margin, top: 14 })
  }

  @Builder
  checksBody(d: PullRequestDetail) {
    Column() {
      ForEach(d.checks, (check: PullRequestCheck, index: number) => {
        Column() {
          Row({ space: 10 }) {
            SymbolGlyph(checkSymbol(check.status)).fontSize(18).fontColor([checkColor(check.status)])
            Column({ space: 1 }) {
              Text(check.name).fontSize(Type.body).fontColor($r('app.color.fg')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if ((check.description ?? '').length > 0) {
                Text(check.description ?? '').fontSize(Type.small).fontColor($r('app.color.fg_tertiary')).maxLines(1)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text(`${checkStatusLabel(check.status)}${check.required ? ' · 必需' : ''}`)
              .fontSize(Type.small).fontColor(checkColor(check.status))
          }
          .id(`pr.check.${check.name}`)
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          if (index < d.checks.length - 1) {
            Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 44 })
          }
        }
      }, (check: PullRequestCheck) => `${check.name}:${check.status}`)
    }
    .borderRadius(16)
    .backgroundColor($r('app.color.grouped_card'))
    .margin({ left: Space.margin, right: Space.margin })
  }

  @Computed
  get detailList(): PullRequestDetail[] {
    return this.detail !== null ? [this.detail] : [];
  }

  @Builder
  body(d: PullRequestDetail) {
    Column() {
      this.headerBody(d)
      this.actionsBody(d)
      if (d.labels.length > 0) {
        Row({ space: 6 }) {
          ForEach(d.labels, (label: PullRequestLabel) => {
            Text(label.name).fontSize(Type.caption).fontColor($r('app.color.fg_secondary'))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10)
              .border({ width: 0.5, color: $r('app.color.border') })
          }, (label: PullRequestLabel) => label.name)
        }
        .padding({ left: Space.margin, right: Space.margin, top: 12 })
        .width('100%')
      }
      if (d.checks.length > 0) {
        sectionTitle(`检查 ${d.checks.length}`)
        this.checksBody(d)
      }
      sectionTitle('描述')
      Column() {
        Column() {
          if (d.body.trim().length > 0) {
            MarkdownView({ text: d.body, fontSize: Type.body })
          } else {
            Text('没有描述').fontSize(Type.body).fontColor($r('app.color.fg_tertiary'))
          }
        }
        .id('pr.body')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.grouped_card'))
        .width('100%')
      }
      .padding({ left: Space.margin, right: Space.margin })
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          if (this.loading) {
            LoadingProgress().width(28).height(28).color($r('app.color.fg_secondary')).margin({ top: 48 })
          } else if (this.detail === null) {
            Text(this.error.length > 0 ? this.error : '读不到这个 PR')
              .id('pr.error')
              .fontSize(Type.body).fontColor($r('app.color.fg_secondary')).padding(32)
          } else {
            // Keyed on what can change, so a merge / close / refresh rebuilds the page body.
            ForEach(this.detailList, (d: PullRequestDetail) => {
              this.body(d)
            }, (d: PullRequestDetail) => `${d.number}:${d.state}:${d.isDraft}:${d.updatedAt}:${d.mergedAt ?? ''}:${this.busy}`)
          }
          Column().height(this.app.bottomInset + 32)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar(titleBar(this.param !== null ? `${repoName(this.param.repository)} #${this.param.number}` : 'PR',
      this.detail !== null ? prStateLabel(this.detail.state, this.detail.isDraft) : '', this.menus(), 'pr.title',
      'page.back', () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(this.inDetailPane)
    .backgroundColor($r('app.color.screen'))
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      this.inDetailPane = context.pathStack === detailNav;
      this.param = context.pathInfo.param as PullRequestRouteParam;
      this.title = this.param?.title ?? '';
      this.load();
    })
  }
}
