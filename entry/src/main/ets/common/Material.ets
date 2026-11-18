import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { appState } from '../model/AppState';
import { Log } from './Log';

/**
 * HarmonyOS 7 (API 26) system material — the real 沉浸光感 surface for menus, dialogs, sheets and
 * floating controls. On older systems (the API 24 emulator) nothing here touches the uiMaterial
 * module, and callers keep their frosted-glass fallback.
 */

/** uiMaterial.ImmersiveStyle values, so callers never reference the module on old systems. */
export class MaterialStyle {
  static readonly ULTRA_THIN: number = 0;
  static readonly THIN: number = 1;
  static readonly REGULAR: number = 2;
  static readonly THICK: number = 3;
  static readonly ULTRA_THICK: number = 4;
}

let supported: boolean | null = null;

/** True when the device renders the immersive system material and light effects are on. */
export function systemMaterialOn(): boolean {
  if (!appState.lightEffects || deviceInfo.sdkApiVersion < 26) {
    return false;
  }
  if (supported === null) {
    try {
      supported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      supported = false;
      Log.w('Material', `immersive material query failed ${JSON.stringify(e)}`);
    }
  }
  return supported === true;
}

function styleOf(style: number): uiMaterial.ImmersiveStyle {
  switch (style) {
    case 0:
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    case 1:
      return uiMaterial.ImmersiveStyle.THIN;
    case 3:
      return uiMaterial.ImmersiveStyle.THICK;
    case 4:
      return uiMaterial.ImmersiveStyle.ULTRA_THICK;
    default:
      return uiMaterial.ImmersiveStyle.REGULAR;
  }
}

/** An immersive material, or undefined where the system has none (use the fallback styling). */
export function immersiveMaterial(style: number, interactive: boolean = false): uiMaterial.Material | undefined {
  if (!systemMaterialOn()) {
    return undefined;
  }
  try {
    const options: uiMaterial.ImmersiveOptions = { style: styleOf(style), interactive: interactive };
    return new uiMaterial.ImmersiveMaterial(options);
  } catch (e) {
    Log.w('Material', `immersive material unavailable ${JSON.stringify(e)}`);
    return undefined;
  }
}

/**
 * Applied last in an attribute chain: on API 26 it replaces the component's background, border
 * and shadow with the system material; elsewhere it leaves the fallback styling alone.
 */
export class ColumnMaterial implements AttributeModifier<ColumnAttribute> {
  private style: number;
  private interactive: boolean;

  constructor(style: number, interactive: boolean = false) {
    this.style = style;
    this.interactive = interactive;
  }

  applyNormalAttribute(instance: ColumnAttribute): void {
    const material = immersiveMaterial(this.style, this.interactive);
    if (material !== undefined) {
      instance.systemMaterial(material);
    }
  }
}

export class RowMaterial implements AttributeModifier<RowAttribute> {
  private style: number;
  private interactive: boolean;

  constructor(style: number, interactive: boolean = false) {
    this.style = style;
    this.interactive = interactive;
  }

  applyNormalAttribute(instance: RowAttribute): void {
    const material = immersiveMaterial(this.style, this.interactive);
    if (material !== undefined) {
      instance.systemMaterial(material);
    }
  }
}

export class ButtonMaterial implements AttributeModifier<ButtonAttribute> {
  private style: number;

  constructor(style: number) {
    this.style = style;
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    const material = immersiveMaterial(this.style, true);
    if (material !== undefined) {
      instance.systemMaterial(material);
    }
  }
}

export class ScrollMaterial implements AttributeModifier<ScrollAttribute> {
  private style: number;

  constructor(style: number) {
    this.style = style;
  }

  applyNormalAttribute(instance: ScrollAttribute): void {
    const material = immersiveMaterial(this.style);
    if (material !== undefined) {
      instance.systemMaterial(material);
    }
  }
}
