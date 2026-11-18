import { hdsEffect, hdsMaterial } from '@kit.UIDesignKit';
import { vibrator } from '@kit.SensorServiceKit';
import { appState } from '../model/AppState';
import { Log } from '../common/Log';
import { Prefs, PREF_LIGHT_EFFECTS } from '../common/Prefs';

const TAG = 'Light';

/**
 * HarmonyOS 6 "沉浸光感" (immersive light) helpers.
 *
 *  - Material: the floating tab bar and title bar use hdsMaterial.MaterialType.IMMERSIVE when the
 *    device reports it in getSystemMaterialTypes(); the system renders the glass and its light sheen.
 *  - Point light: prominent controls (new task, send) act as soft light sources; cards and the
 *    composer are illuminated on their borders, so they glow when a control moves close.
 *  - Edge flow light: the composer runs a dual edge flow light while the agent is working.
 */
class LightEffectsImpl {
  private sourceEffect: VisualEffect | null = null;
  private borderEffect: VisualEffect | null = null;

  start(): void {
    // Immersive light is part of the design, not an option.
    appState.lightEffects = true;
    try {
      const types = hdsMaterial.getSystemMaterialTypes();
      appState.immersiveMaterial = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
      Log.i(TAG, `system material types: ${JSON.stringify(types)}`);
    } catch (e) {
      appState.immersiveMaterial = false;
      Log.w(TAG, `material query failed ${JSON.stringify(e)}`);
    }
  }

  setEnabled(enabled: boolean): void {
    appState.lightEffects = enabled;
    Prefs.put(PREF_LIGHT_EFFECTS, enabled);
  }

  materialType(): hdsMaterial.MaterialType {
    if (!appState.lightEffects) {
      return hdsMaterial.MaterialType.NONE;
    }
    return appState.immersiveMaterial ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.ADAPTIVE;
  }

  /** A soft light source, for floating prominent buttons. */
  lightSource(): VisualEffect | undefined {
    if (!appState.lightEffects) {
      return undefined;
    }
    if (this.sourceEffect === null) {
      try {
        const options: hdsEffect.PointLightOptions = { color: '#FFFFFF', intensity: 0.6, height: 48, bloom: 0.4 };
        const light: hdsEffect.PointLightEffect = {
          sourceType: hdsEffect.PointLightSourceType.SOFT,
          illuminatedType: hdsEffect.PointLightIlluminatedType.NONE,
          options: options,
        };
        this.sourceEffect = new hdsEffect.HdsEffectBuilder().pointLight(light).buildEffect();
      } catch (e) {
        Log.w(TAG, `point light source unavailable ${JSON.stringify(e)}`);
        return undefined;
      }
    }
    return this.sourceEffect;
  }

  /** Border illumination for cards and the composer near a light source. */
  illuminatedBorder(): VisualEffect | undefined {
    if (!appState.lightEffects) {
      return undefined;
    }
    if (this.borderEffect === null) {
      try {
        const light: hdsEffect.PointLightEffect = {
          sourceType: hdsEffect.PointLightSourceType.NONE,
          illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER,
        };
        this.borderEffect = new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
          .pointLight(light)
          .buildEffect();
      } catch (e) {
        Log.w(TAG, `illuminated border unavailable ${JSON.stringify(e)}`);
        return undefined;
      }
    }
    return this.borderEffect;
  }

  /** Flowing light along the composer edges while the agent works. */
  workingFlow(controller: hdsEffect.ShaderEffectController, color: ResourceColor): VisualEffect | undefined {
    if (!appState.lightEffects) {
      return undefined;
    }
    try {
      const params: hdsEffect.DualEdgeFlowLightParam = {
        firstEdgeFlowLight: { startPos: 0, endPos: 0.35, color: color },
        secondEdgeFlowLight: { startPos: 0.5, endPos: 0.85, color: color },
      };
      const animation: hdsEffect.AnimationParams = { duration: 2400, iterations: -1, autoPlay: true };
      const shader: hdsEffect.ShaderEffectParams = {
        effectType: hdsEffect.EffectType.DUAL_EDGE_FLOW_LIGHT,
        animation: animation,
        params: params,
        controller: controller,
      };
      return new hdsEffect.HdsEffectBuilder().shaderEffect(shader).buildEffect();
    } catch (e) {
      Log.w(TAG, `edge flow light unavailable ${JSON.stringify(e)}`);
      return undefined;
    }
  }

  tap(): void {
    if (!appState.haptics) {
      return;
    }
    try {
      const effect: vibrator.VibratePreset = { type: 'preset', effectId: 'haptic.clock.timer', count: 1 };
      const attribute: vibrator.VibrateAttribute = { usage: 'touch' };
      vibrator.startVibration(effect, attribute).catch(() => {
      });
    } catch (e) {
      Log.d(TAG, 'haptics unavailable');
    }
  }
}

export const lightEffects: LightEffectsImpl = new LightEffectsImpl();
