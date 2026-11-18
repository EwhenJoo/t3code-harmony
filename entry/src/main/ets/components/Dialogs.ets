import { ComponentContent } from '@kit.ArkUI';
import { ColumnMaterial, MaterialStyle, systemMaterialOn } from '../common/Material';
import { Type } from '../common/Typography';
import { lightEffects } from '../services/LightEffects';

/**
 * Dialogs on the immersive light material: a frosted glass card whose border catches the light,
 * the same surface the title bars and the floating tab bar use.
 */
export class DialogParams {
  key: string = '';
  title: string = '';
  message: string = '';
  confirmLabel: string = '确定';
  cancelLabel: string = '取消';
  destructive: boolean = false;
  /** Text input dialogs only. */
  input: boolean = false;
  placeholder: string = '';
  text: string = '';
}

class DialogHandle {
  close: () => void;
  resolve: (confirmed: boolean, text: string) => void;

  constructor(close: () => void, resolve: (confirmed: boolean, text: string) => void) {
    this.close = close;
    this.resolve = resolve;
  }
}

const handles: Map<string, DialogHandle> = new Map();
const drafts: Map<string, string> = new Map();

function finish(key: string, confirmed: boolean): void {
  const handle = handles.get(key);
  if (handle === undefined) {
    return;
  }
  handles.delete(key);
  const text = drafts.get(key) ?? '';
  drafts.delete(key);
  handle.close();
  handle.resolve(confirmed, text);
}

@Builder
function dialogBuilder(params: DialogParams) {
  // Margins like system dialogs: 16vp from the screen edges, at most 400vp wide.
  Column() {
    dialogCard(params)
  }
  .width('100%')
  .padding({ left: 16, right: 16 })
}

@Builder
function dialogCard(params: DialogParams) {
  Column({ space: 14 }) {
    Text(params.title)
      .id('dialog.title')
      .fontSize(17)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.fg'))
      .width('100%')
    if (params.message.length > 0) {
      Text(params.message)
        .fontSize(Type.body)
        .lineHeight(Type.bodyLine)
        .fontColor($r('app.color.fg_secondary'))
        .width('100%')
    }
    if (params.input) {
      TextArea({ text: params.text, placeholder: params.placeholder })
        .id('dialog.input')
        .fontSize(Type.body)
        .placeholderFont({ size: Type.body })
        .constraintSize({ minHeight: 88, maxHeight: 200 })
        .borderRadius(14)
        .backgroundColor($r('app.color.grouped_card'))
        .onChange((value: string) => {
          drafts.set(params.key, value);
        })
    }
    Row({ space: 12 }) {
      Button(params.cancelLabel)
        .id('dialog.cancel')
        .fontSize(Type.body)
        .fontColor($r('app.color.fg'))
        .backgroundColor($r('app.color.chip_bg'))
        .height(40)
        .layoutWeight(1)
        .onClick(() => finish(params.key, false))
      Button(params.confirmLabel)
        .id('dialog.confirm')
        .fontSize(Type.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(params.destructive ? Color.White : $r('app.color.prominent_fg'))
        .backgroundColor(params.destructive ? $r('app.color.danger_fg') : $r('app.color.prominent'))
        .height(40)
        .layoutWeight(1)
        .onClick(() => finish(params.key, true))
    }
    .width('100%')
    .margin({ top: 4 })
  }
  .width('100%')
  .constraintSize({ maxWidth: 400 })
  .padding({ left: 24, right: 24, top: 22, bottom: 18 })
  .borderRadius(28)
  .backgroundColor($r('app.color.glass'))
  .backgroundBlurStyle(systemMaterialOn() ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THICK)
  .border({ width: 0.5, color: $r('app.color.border') })
  .shadow({ radius: 24, color: '#29000000', offsetY: 8 })
  .visualEffect(systemMaterialOn() ? undefined : lightEffects.illuminatedBorder())
  // HarmonyOS 7: the system immersive material replaces the fallback glass above.
  .attributeModifier(new ColumnMaterial(MaterialStyle.ULTRA_THICK))
}

function open(uiContext: UIContext, params: DialogParams): Promise<string | null> {
  return new Promise<string | null>((resolve) => {
    params.key = `dialog:${Date.now()}:${Math.random()}`;
    drafts.set(params.key, params.text);
    const content = new ComponentContent(uiContext, wrapBuilder(dialogBuilder), params);
    const promptAction = uiContext.getPromptAction();
    handles.set(params.key, new DialogHandle(() => {
      promptAction.closeCustomDialog(content).catch(() => {
      });
    }, (confirmed: boolean, text: string) => resolve(confirmed ? text : null)));
    promptAction.openCustomDialog(content, {
      alignment: DialogAlignment.Center,
      maskColor: '#33000000',
      autoCancel: true,
      offset: { dx: 0, dy: 0 },
      onWillDismiss: (action: DismissDialogAction) => {
        finish(params.key, false);
        action.dismiss();
      },
    }).catch(() => {
      handles.delete(params.key);
      resolve(null);
    });
  });
}

/** Resolves true when confirmed. */
export async function confirmDialog(uiContext: UIContext, title: string, message: string, confirmLabel: string,
  destructive: boolean = false): Promise<boolean> {
  const params = new DialogParams();
  params.title = title;
  params.message = message;
  params.confirmLabel = confirmLabel;
  params.destructive = destructive;
  const result = await open(uiContext, params);
  return result !== null;
}

/** Resolves with the entered text, or null when cancelled. */
export async function promptDialog(uiContext: UIContext, title: string, message: string, placeholder: string,
  confirmLabel: string, initial: string = ''): Promise<string | null> {
  const params = new DialogParams();
  params.title = title;
  params.message = message;
  params.placeholder = placeholder;
  params.confirmLabel = confirmLabel;
  params.input = true;
  params.text = initial;
  return await open(uiContext, params);
}
