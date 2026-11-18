import { appState, AppState, ProjectChoice } from '../model/AppState';
import { ProjectShell } from '../model/Types';
import { ProjectBadge } from './Common';
import { lightEffects } from '../services/LightEffects';
import { shortPath } from '../common/Format';
import { Space, Type } from '../common/Typography';

/**
 * Where a new conversation starts, as on the desktop: pick a project (most recently used first). A name
 * found on several computers is one entry; the conversation page then shows and switches the computer.
 */
@ComponentV2
export struct ProjectPicker {
  @Local app: AppState = appState;
  @Local query: string = '';
  @Event onPick: (key: string) => void = () => {
  };

  @Computed
  get choices(): ProjectChoice[] {
    const all = this.app.newChatProjects();
    const q = this.query.trim().toLowerCase();
    if (q.length === 0) {
      return all;
    }
    return all.filter((c: ProjectChoice) => c.title.toLowerCase().indexOf(q) >= 0 ||
      c.projects.some((p: ProjectShell) => (p.workspaceRoot ?? '').toLowerCase().indexOf(q) >= 0));
  }

  /** Under the name: which computers have it (several computers), else where it lives. */
  private detail(choice: ProjectChoice): string {
    if (this.app.multiEnv) {
      return choice.projects
        .map((p: ProjectShell) => this.app.environmentFor(p.environmentId)?.label ?? '')
        .filter((label: string) => label.length > 0)
        .join(' · ');
    }
    return shortPath(choice.project?.workspaceRoot);
  }

  build() {
    Column() {
      Search({ value: this.query, placeholder: '搜索项目' })
        .id('newChat.search')
        .height(40)
        .margin({ left: Space.margin, right: Space.margin, bottom: 6 })
        .onChange((value: string) => {
          this.query = value;
        })
      List() {
        ForEach(this.choices, (choice: ProjectChoice) => {
          ListItem() {
            Row({ space: 12 }) {
              ProjectBadge({ project: choice.project, badgeSize: 28 })
              Column({ space: 2 }) {
                Text(choice.title)
                  .fontSize(Type.body)
                  .fontColor($r('app.color.fg'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.detail(choice).length > 0) {
                  Text(this.detail(choice))
                    .fontSize(Type.small)
                    .fontColor($r('app.color.fg_tertiary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.CENTER)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .id(`newChat.project.${choice.project?.id ?? choice.key}`)
            .width('100%')
            .padding({ left: Space.margin + 4, right: Space.margin + 4, top: 11, bottom: 11 })
            .stateStyles({
              pressed: {
                .backgroundColor($r('app.color.row_pressed'))
              },
              normal: {
                .backgroundColor(Color.Transparent)
              }
            })
            .onClick(() => {
              lightEffects.tap();
              this.onPick(choice.key);
            })
          }
        }, (choice: ProjectChoice) => `${choice.key}:${choice.projects.length}`)
        if (this.choices.length === 0) {
          ListItem() {
            Text(this.query.length > 0 ? '没有匹配的项目' : '电脑上还没有项目')
              .fontSize(Type.small)
              .fontColor($r('app.color.fg_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(24)
          }
        }
      }
      .id('newChat.list')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ bottom: 16 })
    }
    .width('100%')
    .height('100%')
  }
}
