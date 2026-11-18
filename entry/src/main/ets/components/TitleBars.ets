import {
  DividerShowType,
  hdsMaterial,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleBarOptions,
  ScrollEffectType,
  TitleSize,
} from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { lightEffects } from '../services/LightEffects';

/**
 * HDS title bars with the immersive light material (沉浸光感). Every page uses these, so titles,
 * back buttons and the round glass action buttons look and behave like system apps.
 */
export function titleBar(title: string, subtitle: string, menus: HdsNavigationMenuItemOptions[],
  titleId: string = '', backId: string = '', onBack?: () => void): HdsNavigationTitleBarOptions {
  const options: HdsNavigationTitleBarOptions = {
    style: {
      scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.COMMON_BLUR },
      systemMaterialEffect: {
        materialType: lightEffects.materialType(),
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    },
    content: {
      title: {
        mainTitle: title,
        subTitle: subtitle.length > 0 ? subtitle : undefined,
        mainTitleId: titleId.length > 0 ? titleId : undefined,
        subTitleId: titleId.length > 0 ? `${titleId}.sub` : undefined,
        // Pages opened from a list (a conversation, files, git…) take the compact title; tab roots
        // keep the system's large one.
        mainTitleSize: backId.length > 0 ? TitleSize.TITLE_S : undefined,
      },
      menu: { value: menus, maxCount: 3 },
      divider: { showType: DividerShowType.AUTO },
    },
    // The window is edge-to-edge: the bar pads itself below the status bar, and content is laid
    // out under it so rows scroll beneath the frosted material.
    avoidLayoutSafeArea: true,
    enableComponentSafeArea: true,
  };
  if (backId.length > 0 && options.content !== undefined) {
    // Same glass back button; the id lets UI tests find it.
    options.content.backIcon = { componentId: backId, action: onBack };
  }
  return options;
}

/**
 * A page bar whose title is drawn by the page (a conversation: a compact title and its context line),
 * with the same back button, glass menus and material as every other bar.
 */
export function compactTitleBar(content: CustomBuilder, menus: HdsNavigationMenuItemOptions[], backId: string,
  onBack?: () => void): HdsNavigationTitleBarOptions {
  const options = titleBar('', '', menus, '', backId, onBack);
  if (options.content !== undefined) {
    options.content.stackBuilder = content;
  }
  return options;
}

/** A bar whose left side is custom content (the T3 Code brand) instead of a text title. */
export function brandTitleBar(brand: CustomBuilder, menus: HdsNavigationMenuItemOptions[]): HdsNavigationTitleBarOptions {
  const options = titleBar('', '', menus);
  if (options.content !== undefined) {
    options.content.stackBuilder = brand;
  }
  return options;
}

/** A tab's root bar: large title that tucks into the bar as the page scrolls. */
export function tabTitleBar(title: string, menus: HdsNavigationMenuItemOptions[], titleId: string): HdsNavigationTitleBarOptions {
  return titleBar(title, '', menus, titleId);
}

export function symbolItem(symbol: Resource, label: string, id: string, action: () => void,
  enabled: boolean = true): HdsNavigationMenuItemOptions {
  const item: HdsNavigationMenuItemOptions = {
    content: {
      icon: new SymbolGlyphModifier(symbol),
      label: label,
      componentId: id,
      isEnabled: enabled,
      action: action,
    },
  };
  return item;
}

export function imageItem(image: Resource, label: string, id: string, action: () => void,
  enabled: boolean = true): HdsNavigationMenuItemOptions {
  const item: HdsNavigationMenuItemOptions = {
    content: {
      icon: image,
      label: label,
      componentId: id,
      isEnabled: enabled,
      action: action,
    },
  };
  return item;
}
