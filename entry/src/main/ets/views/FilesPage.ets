import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { appState, AppState } from '../model/AppState';
import {
  baseName,
  fileExtension,
  formatBytes,
  ProjectEntry,
  ProjectListEntriesInput,
  ProjectListEntriesResult,
  ProjectReadFileInput,
  ProjectReadFileResult,
} from '../model/Workspace';
import { openWorkspacePage, WorkspaceRouteParam } from '../common/Nav';
import { connection } from '../services/Connection';
import { cwdForThread } from '../services/Workspace';
import { symbolItem, titleBar } from '../components/TitleBars';
import { MarkdownView } from '../components/Markdown';
import { Space, Type } from '../common/Typography';

function entrySymbol(entry: ProjectEntry): Resource {
  if (entry.kind === 'directory') {
    return $r('sys.symbol.folder');
  }
  const ext = fileExtension(entry.path);
  if (ext === 'md' || ext === 'txt') {
    return $r('sys.symbol.doc_text');
  }
  if (ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'gif' || ext === 'svg' || ext === 'webp') {
    return $r('sys.symbol.picture');
  }
  return $r('sys.symbol.doc_plaintext');
}

class CodeLine {
  no: number;
  text: string;

  constructor(no: number, text: string) {
    this.no = no;
    this.text = text;
  }
}

/** A folder of the conversation's workspace, like the iOS file navigator. */
@ComponentV2
export struct FilesPage {
  @Local app: AppState = appState;
  @Local entries: ProjectEntry[] = [];
  @Local loading: boolean = true;
  @Local error: string = '';
  @Local truncated: boolean = false;
  @Local path: string = '';
  @Local rootTitle: string = '';
  private stack: NavPathStack | null = null;
  private threadId: string = '';
  private environmentId: string = '';
  private cwd: string = '';

  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    const input: ProjectListEntriesInput = { cwd: this.cwd, directoryPath: this.path };
    try {
      const result = await connection.rpc(this.environmentId, 'projects.listEntries', input) as ProjectListEntriesResult;
      this.entries = (result.entries ?? []).slice().sort((a: ProjectEntry, b: ProjectEntry) => {
        if (a.kind !== b.kind) {
          return a.kind === 'directory' ? -1 : 1;
        }
        return baseName(a.path).localeCompare(baseName(b.path));
      });
      this.truncated = result.truncated ?? false;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private open(entry: ProjectEntry): void {
    openWorkspacePage(this.stack, entry.kind === 'directory' ? 'files' : 'file', new WorkspaceRouteParam(this.threadId, entry.path));
  }

  @Builder
  row(entry: ProjectEntry, last: boolean) {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph(entrySymbol(entry))
          .fontSize(Space.icon)
          .fontColor([entry.kind === 'directory' ? $r('app.color.primary') : $r('app.color.fg_secondary')])
        Text(baseName(entry.path))
          .fontSize(Type.body)
          .fontColor(entry.ignored ? $r('app.color.fg_tertiary') : $r('app.color.fg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (entry.kind === 'directory') {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.fg_tertiary')])
        }
      }
      .id(`files.entry.${entry.path}`)
      .width('100%')
      .height(48)
      .padding({ left: Space.margin, right: Space.margin })
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
        Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: Space.margin + Space.icon + 12, right: Space.margin })
      }
    }
  }

  build() {
    HdsNavDestination() {
      List() {
        if (this.loading) {
          ListItem() {
            LoadingProgress().width(28).height(28).color($r('app.color.fg_secondary')).margin({ top: 48 })
          }
          .width('100%')
        } else if (this.error.length > 0) {
          ListItem() {
            Text(this.error)
              .id('files.error')
              .fontSize(Type.body)
              .fontColor($r('app.color.fg_secondary'))
              .textAlign(TextAlign.Center)
              .padding(32)
              .width('100%')
          }
        } else if (this.entries.length === 0) {
          ListItem() {
            Text('这个文件夹是空的')
              .fontSize(Type.body)
              .fontColor($r('app.color.fg_secondary'))
              .textAlign(TextAlign.Center)
              .padding(32)
              .width('100%')
          }
        } else {
          ForEach(this.entries, (entry: ProjectEntry, index: number) => {
            ListItem() {
              this.row(entry, index === this.entries.length - 1)
            }
          }, (entry: ProjectEntry) => entry.path)
          if (this.truncated) {
            ListItem() {
              Text('条目太多，只显示了一部分')
                .fontSize(Type.small)
                .fontColor($r('app.color.fg_tertiary'))
                .padding(16)
            }
          }
        }
        ListItem() {
          Column().height(this.app.bottomInset + 24)
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar(titleBar(this.path.length > 0 ? baseName(this.path) : this.rootTitle, this.path.length > 0 ? this.path : '工作区',
      [symbolItem($r('sys.symbol.arrow_clockwise'), '刷新', 'files.refresh', () => this.load())], 'files.title',
      'page.back', () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      const param = context.pathInfo.param as WorkspaceRouteParam;
      this.threadId = param?.threadId ?? '';
      this.path = param?.target ?? '';
      const thread = this.app.threadFor(this.threadId);
      this.environmentId = this.app.environmentOfThread(this.threadId)?.id ?? '';
      this.cwd = cwdForThread(thread);
      this.rootTitle = this.cwd.length > 0 ? baseName(this.cwd) : '文件';
      this.load();
    })
  }
}

/** One file of the workspace: rendered Markdown, or source with line numbers. */
@ComponentV2
export struct FileViewerPage {
  @Local app: AppState = appState;
  @Local file: ProjectReadFileResult | null = null;
  @Local loading: boolean = true;
  @Local error: string = '';
  @Local path: string = '';
  @Local showSource: boolean = false;
  private stack: NavPathStack | null = null;
  private threadId: string = '';
  private environmentId: string = '';
  private cwd: string = '';

  @Computed
  get lines(): CodeLine[] {
    const text = this.file?.contents ?? '';
    const parts = text.split('\n');
    if (parts.length > 0 && parts[parts.length - 1].length === 0) {
      parts.pop();
    }
    return parts.map((line: string, index: number) => new CodeLine(index + 1, line.replace(/\t/g, '  ')));
  }

  private get isMarkdown(): boolean {
    const ext = fileExtension(this.path);
    return ext === 'md' || ext === 'markdown';
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    const input: ProjectReadFileInput = { cwd: this.cwd, relativePath: this.path };
    try {
      this.file = await connection.rpc(this.environmentId, 'projects.readFile', input) as ProjectReadFileResult;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private subtitle(): string {
    const parts: string[] = [];
    const slash = this.path.lastIndexOf('/');
    if (slash > 0) {
      parts.push(this.path.substring(0, slash));
    }
    if (this.file !== null) {
      parts.push(formatBytes(this.file.byteLength));
      parts.push(`${this.lines.length} 行`);
    }
    return parts.join(' · ');
  }

  @Builder
  source() {
    Scroll() {
      Column() {
        ForEach(this.lines, (line: CodeLine) => {
          Row({ space: 12 }) {
            Text(`${line.no}`)
              .fontSize(Type.code)
              .lineHeight(Type.codeLine)
              .fontFamily('monospace')
              .fontColor($r('app.color.fg_tertiary'))
              .textAlign(TextAlign.End)
              .width(this.lines.length >= 1000 ? 36 : 26)
            Text(line.text.length > 0 ? line.text : ' ')
              .fontSize(Type.code)
              .lineHeight(Type.codeLine)
              .fontFamily('monospace')
              .fontColor($r('app.color.fg'))
              .maxLines(1)
          }
          .alignItems(VerticalAlign.Top)
        }, (line: CodeLine) => `${line.no}`)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, right: Space.margin, top: 8, bottom: 8 })
    }
    .id('file.source')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          if (this.loading) {
            LoadingProgress().width(28).height(28).color($r('app.color.fg_secondary')).margin({ top: 48 })
          } else if (this.error.length > 0) {
            Text(this.error)
              .id('file.error')
              .fontSize(Type.body)
              .fontColor($r('app.color.fg_secondary'))
              .textAlign(TextAlign.Center)
              .padding(32)
          } else if (this.isMarkdown && !this.showSource) {
            Column() {
              MarkdownView({ text: this.file?.contents ?? '', fontSize: Type.body })
            }
            .id('file.markdown')
            .padding({ left: Space.margin, right: Space.margin, top: 8 })
            .width('100%')
          } else {
            this.source()
          }
          if (this.file?.truncated) {
            Text('文件太大，只显示了开头部分')
              .fontSize(Type.small)
              .fontColor($r('app.color.fg_tertiary'))
              .padding(16)
          }
          Column().height(this.app.bottomInset + 24)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar(titleBar(baseName(this.path), this.subtitle(), this.isMarkdown ? [
      symbolItem(this.showSource ? $r('sys.symbol.doc_text') : $r('sys.symbol.doc_plaintext'), this.showSource ? '预览' : '源码',
        'file.toggleSource', () => {
          this.showSource = !this.showSource;
        }),
    ] : [], 'file.title', 'page.back', () => this.stack?.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
    .onReady((context: NavDestinationContext) => {
      this.stack = context.pathStack;
      const param = context.pathInfo.param as WorkspaceRouteParam;
      this.threadId = param?.threadId ?? '';
      this.path = param?.target ?? '';
      this.environmentId = this.app.environmentOfThread(this.threadId)?.id ?? '';
      this.cwd = cwdForThread(this.app.threadFor(this.threadId));
      this.load();
    })
  }
}
