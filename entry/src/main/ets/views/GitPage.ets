import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { appState, AppState } from '../model/AppState';
import {
  changeRequestLabel,
  DiffFile,
  DiffLine,
  GitStatus,
  GitWorkingFile,
  gitStatusSummary,
  needsDefaultBranchConfirmation,
  parseUnifiedDiff,
  ReviewDiffPreviewInput,
  ReviewDiffPreviewResult,
  VcsListRefsInput,
  VcsListRefsResult,
  VcsRef,
  VcsSwitchRefInput,
} from '../model/Workspace';
import { openWorkspacePage, WorkspaceRouteParam } from '../common/Nav';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { cwdForThread, ThreadWorkspace, workspaces } from '../services/Workspace';
import { symbolItem, titleBar } from '../components/TitleBars';
import { confirmDialog, promptDialog } from '../components/Dialogs';
import { Space, Type } from '../common/Typography';

class GitActionRow {
  id: string;
  title: string;
  subtitle: string;
  symbol: Resource;
  enabled: boolean;
  run: () => void;

  constructor(id: string, title: string, subtitle: string, symbol: Resource, enabled: boolean, run: () => void) {
    this.id = id;
    this.title = title;
    this.subtitle = subtitle;
    this.symbol = symbol;
    this.enabled = enabled;
    this.run = run;
  }
}

/** Grouped card section title, shared by the git, usage and pull request pages. */
@Builder
export function sectionTitle(title: string) {
  Text(title)
    .fontSize(Type.small)
    .fontWeight(FontWeight.Medium)
    .fontColor($r('app.color.fg_tertiary'))
    .padding({ left: Space.margin + 4, top: 18, bottom: 6 })
    .width('100%')
}

/** Git for one conversation's folder: branch, changes and actions (iOS "Git controls → More"). */
@ComponentV2
export struct GitPage {
  @Local app: AppState = appState;
  @Local workspace: ThreadWorkspace | null = null;
  @Local refs: VcsRef[] = [];
  @Local refsLoading: boolean = false;
  private stack: NavPathStack | null = null;
  private threadId: string = '';
  private environmentId: string = '';

  @Computed
  get status(): GitStatus | null {
    return this.workspace?.git ?? null;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private async loadRefs(): Promise<void> {
    const cwd = this.workspace?.cwd ?? '';
    if (cwd.length === 0) {
      return;
    }
    this.refsLoading = true;
    const input: VcsListRefsInput = { cwd: cwd, refKind: 'local', limit: 50 };
    try {
      const result = await connection.rpc(this.environmentId, 'vcs.listRefs', input) as VcsListRefsResult;
      this.refs = (result.refs ?? []).filter((ref: VcsRef) => !ref.isRemote);
    } catch (e) {
      this.toast(`读取分支失败：${(e as Error).message}`);
    } finally {
      this.refsLoading = false;
    }
  }

  private async switchTo(ref: VcsRef): Promise<void> {
    if (ref.current || this.workspace === null) {
      return;
    }
    const ok = await confirmDialog(this.getUIContext(), `切换到 ${ref.name}？`,
      this.status?.hasWorkingTreeChanges ? '工作区有未提交的改动，切换时会一起带过去。' : '', '切换');
    if (!ok) {
      return;
    }
    const input: VcsSwitchRefInput = { cwd: this.workspace.cwd, refName: ref.name };
    try {
      await connection.rpc(this.environmentId, 'vcs.switchRef', input);
      lightEffects.tap();
      this.toast(`已切换到 ${ref.name}`);
      this.loadRefs();
    } catch (e) {
      this.toast(`切换失败：${(e as Error).message}`);
    }
  }

  private async run(action: string, askMessage: boolean, label: string): Promise<void> {
    const workspace = this.workspace;
    if (workspace === null) {
      return;
    }
    let message = '';
    if (askMessage) {
      const entered = await promptDialog(this.getUIContext(), label, '留空则由代理生成提交说明。', '提交说明（可选）', label);
      if (entered === null) {
        return;
      }
      message = entered;
    }
    const status = this.status;
    if (status !== null && needsDefaultBranchConfirmation(action, status.isDefaultRef)) {
      const ok = await confirmDialog(this.getUIContext(), `推送到 ${status.refName ?? '默认分支'}？`,
        '这会直接推送到默认分支。', '直接推送');
      if (!ok) {
        return;
      }
    }
    try {
      this.toast(await workspace.runAction(action, message));
    } catch (e) {
      this.toast(`Git 操作失败：${(e as Error).message}`);
    }
  }

  private async pull(): Promise<void> {
    try {
      this.toast(await (this.workspace as ThreadWorkspace).pull());
    } catch (e) {
      this.toast(`拉取失败：${(e as Error).message}`);
    }
  }

  private openPr(): void {
    const url = this.status?.pr?.url ?? '';
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

  @Computed
  get actions(): GitActionRow[] {
    const status = this.status;
    const busy = (this.workspace?.gitBusy ?? '').length > 0;
    const pr = changeRequestLabel(status);
    const repo = status !== null && status.isRepo;
    const changes = status?.hasWorkingTreeChanges ?? false;
    const hasBranch = (status?.refName ?? null) !== null;
    const ahead = (status?.aheadCount ?? 0) > 0;
    const hasOpenPr = status?.pr?.state === 'open';
    const rows: GitActionRow[] = [
      new GitActionRow('git.commit', '提交', changes ? `${status?.files.length ?? 0} 个文件有改动` : '工作区没有改动',
        $r('sys.symbol.checkmark_circle'), repo && changes && !busy, () => this.run('commit', true, '提交')),
      new GitActionRow('git.commitPush', '提交并推送', '提交后推送到远程分支',
        $r('sys.symbol.arrow_up_circle'), repo && changes && hasBranch && !busy, () => this.run('commit_push', true, '提交并推送')),
      new GitActionRow('git.push', '推送', ahead ? `领先 ${status?.aheadCount} 个提交` : '没有需要推送的提交',
        $r('sys.symbol.arrow_up_circle'), repo && ahead && hasBranch && !busy, () => this.run('push', false, '推送')),
      new GitActionRow('git.pull', '拉取', (status?.behindCount ?? 0) > 0 ? `落后 ${status?.behindCount} 个提交` : '从远程拉取最新提交',
        $r('sys.symbol.arrow_down_circle'), repo && (status?.hasUpstream ?? false) && !busy, () => this.pull()),
    ];
    if (hasOpenPr) {
      rows.push(new GitActionRow('git.openPr', `查看 ${pr} #${status?.pr?.number}`, status?.pr?.title ?? '',
        $r('sys.symbol.arrow_up_right'), true, () => this.openPr()));
    } else {
      rows.push(new GitActionRow('git.createPr', `推送并创建 ${pr}`, '把当前分支推送并发起合并请求',
        $r('sys.symbol.arrow_triangle_merge'), repo && hasBranch && !(status?.isDefaultRef ?? true) && (ahead || changes) && !busy,
        () => this.run(changes ? 'commit_push_pr' : 'create_pr', changes, `推送并创建 ${pr}`)));
    }
    return rows;
  }

  @Builder
  actionRow(row: GitActionRow, last: boolean) {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph(row.symbol).fontSize(Space.icon).fontColor([$r('app.color.fg')])
        Column({ space: 2 }) {
          Text(row.title).fontSize(Type.body).fontColor($r('app.color.fg'))
          if (row.subtitle.length > 0) {
            Text(row.subtitle).fontSize(Type.small).fontColor($r('app.color.fg_tertiary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .id(row.id)
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .opacity(row.enabled ? 1 : 0.4)
      .onClick(() => {
        if (row.enabled) {
          lightEffects.tap();
          row.run();
        }
      })
      if (!last) {
        Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 48 })
      }
    }
  }

  @Builder
  fileRow(file: GitWorkingFile, last: boolean) {
    Column() {
      Row({ space: 8 }) {
        Text(file.path)
          .fontSize(Type.small)
          .fontFamily('monospace')
          .fontColor($r('app.color.fg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(`+${file.insertions}`).fontSize(Type.small).fontColor($r('app.color.diff_add_fg'))
        Text(`−${file.deletions}`).fontSize(Type.small).fontColor($r('app.color.diff_del_fg'))
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      if (!last) {
        Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 16 })
      }
    }
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          sectionTitle('分支')
          Column() {
            Row({ space: 12 }) {
              Image($r('app.media.ic_git')).width(Space.icon).height(Space.icon).fillColor($r('app.color.fg'))
              Column({ space: 2 }) {
                Text(this.status?.refName ?? '分离的 HEAD')
                  .id('git.branch')
                  .fontSize(Type.body)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.fg'))
                Text((this.workspace?.gitBusy ?? '').length > 0 ? this.workspace?.gitBusy : gitStatusSummary(this.status))
                  .id('git.summary')
                  .fontSize(Type.small)
                  .fontColor($r('app.color.fg_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              if ((this.workspace?.gitBusy ?? '').length > 0) {
                LoadingProgress().width(20).height(20).color($r('app.color.fg_secondary'))
              }
            }
            .width('100%')
            .padding(16)
            ForEach(this.refs, (ref: VcsRef) => {
              Column() {
                Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 48 })
                Row({ space: 12 }) {
                  if (ref.current) {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.primary')])
                  } else {
                    Column().width(16)
                  }
                  Text(ref.name).fontSize(Type.body).fontColor($r('app.color.fg')).maxLines(1).layoutWeight(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (ref.isDefault) {
                    Text('默认').fontSize(Type.caption).fontColor($r('app.color.fg_tertiary'))
                  }
                }
                .id(`git.ref.${ref.name}`)
                .width('100%')
                .height(44)
                .padding({ left: 16 + 4, right: 16 })
                .onClick(() => this.switchTo(ref))
              }
            }, (ref: VcsRef) => `${ref.name}:${ref.current}`)
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.grouped_card'))
          .margin({ left: Space.margin, right: Space.margin })

          sectionTitle('操作')
          Column() {
            ForEach(this.actions, (row: GitActionRow, index: number) => {
              this.actionRow(row, index === this.actions.length - 1)
            }, (row: GitActionRow) => `${row.id}:${row.enabled}:${row.title}:${row.subtitle}`)
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.grouped_card'))
          .margin({ left: Space.margin, right: Space.margin })

          if ((this.status?.files.length ?? 0) > 0) {
            Row() {
              Text(`改动 ${this.status?.files.length}`)
                .fontSize(Type.small)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.fg_tertiary'))
                .layoutWeight(1)
              Text('查看差异')
                .id('git.viewDiff')
                .fontSize(Type.small)
                .fontColor($r('app.color.primary'))
                .padding({ top: 6, bottom: 6, left: 8 })
                .onClick(() => openWorkspacePage(this.stack, 'diff', new WorkspaceRouteParam(this.threadId, '')))
            }
            .padding({ left: Space.margin + 4, right: Space.margin + 4, top: 12, bottom: 0 })
            .width('100%')
            Column() {
              ForEach(this.status?.files ?? [], (file: GitWorkingFile, index: number) => {
                this.fileRow(file, index === (this.status?.files.length ?? 0) - 1)
              }, (file: GitWorkingFile) => `${file.path}:${file.insertions}:${file.deletions}`)
            }
            .borderRadius(16)
            .backgroundColor($r('app.color.grouped_card'))
            .margin({ left: Space.margin, right: Space.margin, top: 6 })
          }
          Column().height(this.app.bottomInset + 32)
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar(titleBar('Git', this.workspace?.cwd ?? '', [
      symbolItem($r('sys.symbol.doc_text'), '查看差异', 'git.diff', () => openWorkspacePage(this.stack, 'diff', new WorkspaceRouteParam(this.threadId, ''))),
    ], 'git.title', 'page.back', () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      const param = context.pathInfo.param as WorkspaceRouteParam;
      this.threadId = param?.threadId ?? '';
      this.environmentId = this.app.environmentOfThread(this.threadId)?.id ?? '';
      this.workspace = workspaces.acquire(this.threadId);
      this.loadRefs();
    })
    .onWillDisappear(() => {
      workspaces.release(this.workspace);
      this.workspace = null;
    })
  }
}

/** Working-tree diff, file by file, like iOS "Review changes". */
@ComponentV2
export struct DiffPage {
  @Local app: AppState = appState;
  @Local files: DiffFile[] = [];
  @Local loading: boolean = true;
  @Local error: string = '';
  @Local truncated: boolean = false;
  private stack: NavPathStack | null = null;
  private threadId: string = '';
  private environmentId: string = '';
  private cwd: string = '';

  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    const input: ReviewDiffPreviewInput = { cwd: this.cwd, sourceKind: 'working-tree' };
    try {
      const result = await connection.rpc(this.environmentId, 'review.getDiffPreview', input) as ReviewDiffPreviewResult;
      const source = (result.sources ?? []).length > 0 ? result.sources[0] : null;
      this.files = source !== null ? parseUnifiedDiff(source.diff ?? '') : [];
      this.truncated = source?.truncated ?? false;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private lineBg(line: DiffLine): ResourceColor {
    switch (line.kind) {
      case 'add':
        return $r('app.color.diff_add_bg');
      case 'del':
        return $r('app.color.diff_del_bg');
      case 'hunk':
        return $r('app.color.chip_bg');
      default:
        return Color.Transparent;
    }
  }

  @Builder
  fileBlock(file: DiffFile) {
    Column() {
      Row({ space: 8 }) {
        Text(file.path)
          .fontSize(Type.small)
          .fontWeight(FontWeight.Medium)
          .fontFamily('monospace')
          .fontColor($r('app.color.fg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(`+${file.additions}`).fontSize(Type.small).fontColor($r('app.color.diff_add_fg'))
        Text(`−${file.deletions}`).fontSize(Type.small).fontColor($r('app.color.diff_del_fg'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      Scroll() {
        Column() {
          ForEach(file.lines, (line: DiffLine, index: number) => {
            Row({ space: 8 }) {
              Text(line.kind === 'hunk' || line.kind === 'meta' ? '' : `${line.kind === 'add' ? '' : line.oldNo}`)
                .fontSize(11).fontFamily('monospace').fontColor($r('app.color.fg_tertiary'))
                .textAlign(TextAlign.End).width(28)
              Text(line.kind === 'hunk' || line.kind === 'meta' ? '' : `${line.kind === 'del' ? '' : line.newNo}`)
                .fontSize(11).fontFamily('monospace').fontColor($r('app.color.fg_tertiary'))
                .textAlign(TextAlign.End).width(28)
              Text(line.kind === 'add' ? `+ ${line.text}` : line.kind === 'del' ? `- ${line.text}` : line.kind === 'ctx' ? `  ${line.text}` : line.text)
                .fontSize(Type.code)
                .lineHeight(Type.codeLine)
                .fontFamily('monospace')
                .fontColor(line.kind === 'hunk' || line.kind === 'meta' ? $r('app.color.fg_tertiary') : $r('app.color.fg'))
                .maxLines(1)
            }
            .padding({ right: 12 })
            .constraintSize({ minWidth: '100%' })
            .backgroundColor(this.lineBg(line))
          }, (line: DiffLine, index: number) => `${index}`)
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ minWidth: '100%' })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ bottom: 6 })
    }
    .id(`diff.file.${file.path}`)
    .borderRadius(14)
    .clip(true)
    .backgroundColor($r('app.color.grouped_card'))
    .margin({ left: Space.margin, right: Space.margin, top: 12 })
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          if (this.loading) {
            LoadingProgress().width(28).height(28).color($r('app.color.fg_secondary')).margin({ top: 48 })
          } else if (this.error.length > 0) {
            Text(this.error).fontSize(Type.body).fontColor($r('app.color.fg_secondary')).padding(32)
          } else if (this.files.length === 0) {
            Text('工作区没有改动')
              .id('diff.empty')
              .fontSize(Type.body)
              .fontColor($r('app.color.fg_secondary'))
              .padding(32)
          } else {
            ForEach(this.files, (file: DiffFile) => {
              this.fileBlock(file)
            }, (file: DiffFile) => file.path)
            if (this.truncated) {
              Text('差异太大，只显示了一部分').fontSize(Type.small).fontColor($r('app.color.fg_tertiary')).padding(16)
            }
          }
          Column().height(this.app.bottomInset + 32)
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar(titleBar('改动', this.files.length > 0 ? `${this.files.length} 个文件` : '工作区',
      [symbolItem($r('sys.symbol.arrow_clockwise'), '刷新', 'diff.refresh', () => this.load())], 'diff.title',
      'page.back', () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      const param = context.pathInfo.param as WorkspaceRouteParam;
      this.threadId = param?.threadId ?? '';
      this.environmentId = this.app.environmentOfThread(this.threadId)?.id ?? '';
      this.cwd = cwdForThread(this.app.threadFor(this.threadId));
      this.load();
    })
  }
}
