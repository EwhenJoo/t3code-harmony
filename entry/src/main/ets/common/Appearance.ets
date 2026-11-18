import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { appState } from '../model/AppState';
import { Prefs, PREF_APPEARANCE } from './Prefs';
import { Log } from './Log';

/** Applies system / light / dark to the whole app; resources switch via resources/dark. */
export function applyAppearance(context: common.Context, value: string): void {
  appState.appearance = value;
  Prefs.put(PREF_APPEARANCE, value);
  let mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  if (value === 'light') {
    mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  } else if (value === 'dark') {
    mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  try {
    context.getApplicationContext().setColorMode(mode);
  } catch (e) {
    Log.w('Appearance', `setColorMode failed ${JSON.stringify(e)}`);
  }
}
