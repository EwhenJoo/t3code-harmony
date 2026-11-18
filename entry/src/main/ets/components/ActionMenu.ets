import { ComponentContent } from '@kit.ArkUI';
import { immersiveMaterial, MaterialStyle, systemMaterialOn } from '../common/Material';
import { Log } from '../common/Log';
import { Type } from '../common/Typography';
import { lightEffects } from '../services/LightEffects';

/** One row of a title-bar menu: icon, title and an optional second line, as in the iOS menus. */
export class ActionMenuRow {
  id: string = '';
  title: string = '';
  subtitle: string = '';
  symbol: Resource | null = null;
  image: Resource | null = null;
  enabled: boolean = true;
  /** A status row: shown, not tappable, and not dimmed. */
  info: boolean = false;
  destructive: boolean = false;
  action: () => void = () => {
  };

  static of(id: string, title: string, subtitle: string, action: () => void): ActionMenuRow {
    const row = new ActionMenuRow();
    row.id = id;
    row.title = title;
    row.subtitle = subtitle;
    row.action = action;
    return row;
  }

  withSymbol(symbol: Resource): ActionMenuRow {
    this.symbol = symbol;
    return this;
  }

  withImage(image: Resource): ActionMenuRow {
    this.image = image;
    return this;
  }

  disabled(value: boolean = true): ActionMenuRow {
    this.enabled = !value;
    return this;
  }

  asInfo(): ActionMenuRow {
    this.info = true;
    return this;
  }

  asDestructive(): ActionMenuRow {
    this.destructive = true;
    return this;
  }
}

export class ActionMenuParams {
  key: string = '';
  rows: ActionMenuRow[] = [];
}

const closers: Map<string, () => void> = new Map();

function rowColor(row: ActionMenuRow): ResourceColor {
  return row.destructive ? $r('app.color.danger_fg') : $r('app.color.fg');
}

@Builder
function actionMenuBuilder(params: ActionMenuParams) {
  Scroll() {
    Column() {
      ForEach(params.rows, (row: ActionMenuRow, index: number) => {
        Row({ space: 12 }) {
          if (row.symbol !== null) {
            SymbolGlyph(row.symbol)
              .fontSize(18)
              .fontColor([row.info ? $r('app.color.fg_secondary') : rowColor(row)])
          } else if (row.image !== null) {
            Image(row.image)
              .width(18)
              .height(18)
              .fillColor(row.info ? $r('app.color.fg_secondary') : rowColor(row))
          }
          Column({ space: 2 }) {
            Text(row.title)
              .fontSize(Type.body)
              .fontWeight(row.info ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(rowColor(row))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (row.subtitle.length > 0) {
              Text(row.subtitle)
                .fontSize(Type.small)
                .fontColor($r('app.color.fg_tertiary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .id(row.id)
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .opacity(row.enabled || row.info ? 1 : 0.4)
        .borderRadius(12)
        .stateStyles({
          pressed: {
            .backgroundColor(row.enabled && !row.info ? $r('app.color.row_pressed') : Color.Transparent)
          },
          normal: {
            .backgroundColor(Color.Transparent)
          }
        })
        .onClick(() => {
          if (!row.enabled || row.info) {
            return;
          }
          lightEffects.tap();
          closers.get(params.key)?.();
          row.action();
        })
        if (index < params.rows.length - 1 && params.rows[index].info) {
          Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: 16, right: 16 })
        }
      }, (row: ActionMenuRow) => row.id)
    }
    .width(296)
    .padding(4)
  }
  .scrollBar(BarState.Off)
  .constraintSize({ maxHeight: 520 })
}

/** Opens a menu anchored to a component, e.g. a title-bar button (HdsNavigation componentId). */
export function showActionMenu(uiContext: UIContext, targetId: string, rows: ActionMenuRow[]): void {
  const params = new ActionMenuParams();
  params.key = `${targetId}:${Date.now()}`;
  params.rows = rows;
  const content = new ComponentContent(uiContext, wrapBuilder(actionMenuBuilder), params);
  const promptAction = uiContext.getPromptAction();
  closers.set(params.key, () => {
    closers.delete(params.key);
    promptAction.closeMenu(content).catch(() => {
    });
  });
  promptAction.openMenu(content, { id: targetId }, {
    placement: Placement.BottomRight,
    enableArrow: false,
    // HarmonyOS 7 renders the menu on the immersive system material; older systems blur.
    systemMaterial: immersiveMaterial(MaterialStyle.THICK),
    backgroundBlurStyle: systemMaterialOn() ? undefined : BlurStyle.COMPONENT_ULTRA_THICK,
    onDisappear: () => {
      closers.delete(params.key);
    },
  }).catch((e: Error) => {
    closers.delete(params.key);
    Log.w('ActionMenu', `openMenu failed ${JSON.stringify(e)}`);
  });
}
