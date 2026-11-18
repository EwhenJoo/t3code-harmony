import { appState, AppState, needsAttention } from '../model/AppState';
import { ThreadShell } from '../model/Types';
import { openNewTask, openThread } from '../common/Nav';
import { lightEffects } from '../services/LightEffects';

/** What the right-hand pane shows before a thread is picked: a calm prompt and the next useful step. */
@ComponentV2
export struct DetailPlaceholder {
  @Local app: AppState = appState;

  @Computed
  get firstWaiting(): ThreadShell | null {
    for (const thread of this.app.threads) {
      if (needsAttention(thread) && !thread.archivedAt) {
        return thread;
      }
    }
    return null;
  }

  build() {
    Column({ space: 10 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.ellipsis_message')).fontSize(26).fontColor([$r('app.color.fg_tertiary')])
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .margin({ bottom: 4 })
      .backgroundColor($r('app.color.grouped_card'))

      Text('未选择对话')
        .id('detail.placeholder')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))

      Row({ space: 10 }) {
        if (this.firstWaiting !== null) {
          Button({ type: ButtonType.Capsule, stateEffect: true }) {
            Text(`去处理「${(this.firstWaiting as ThreadShell).title}」`)
              .fontSize(13)
              .fontColor($r('app.color.prominent_fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 220 })
          }
          .id('detail.openWaiting')
          .height(36)
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.prominent'))
          .onClick(() => {
            lightEffects.tap();
            openThread((this.firstWaiting as ThreadShell).id);
          })
        }
        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Text('新建对话').fontSize(13).fontColor($r('app.color.fg'))
        }
        .id('detail.newTask')
        .height(36)
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.grouped_card'))
        .onClick(() => {
          lightEffects.tap();
          openNewTask();
        })
      }
      .margin({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
    .backgroundColor($r('app.color.screen'))
  }
}
