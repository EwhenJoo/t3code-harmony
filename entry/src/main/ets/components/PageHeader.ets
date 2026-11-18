import { appState, AppState } from '../model/AppState';
import { appNav } from '../common/Nav';
import { Space, Type } from '../common/Typography';

/** Page header matching the conversation header: plain back chevron, title on the same baseline grid. */
@ComponentV2
export struct PageHeader {
  @Local app: AppState = appState;
  @Param title: string = '';
  /** Pages hosted outside the root stack (the detail pane) pass their own back action. */
  @Event onBack: () => void = () => {
    appNav.pop();
  };

  build() {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(Space.icon).fontColor([$r('app.color.fg')])
      }
      .id('page.back')
      .width(Space.hit)
      .height(Space.hit)
      .backgroundColor(Color.Transparent)
      .accessibilityText('返回')
      .onClick(() => this.onBack())

      Text(this.title)
        .fontSize(Type.barTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
        .maxLines(1)
        .layoutWeight(1)
    }
    .width('100%')
    .height(this.app.topInset + 52)
    .padding({ left: Space.margin - Space.iconOverhang - 4, right: Space.margin, top: this.app.topInset })
    .backgroundColor($r('app.color.screen'))
  }
}
