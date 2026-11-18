import { lightEffects } from '../services/LightEffects';
import { STATE_CHANGE } from '../common/Motion';

/** Full-width prominent capsule with a busy state. A component so `active`/`busy` stay reactive. */
@ComponentV2
export struct PrimaryButton {
  @Param label: string = '';
  @Param buttonId: string = '';
  @Param active: boolean = true;
  @Param busy: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: this.active && !this.busy }) {
      if (this.busy) {
        LoadingProgress().width(24).height(24).color($r('app.color.prominent_fg'))
      } else {
        Text(this.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.prominent_fg'))
      }
    }
    .id(this.buttonId)
    .width('100%')
    .height(44)
    .backgroundColor($r('app.color.prominent'))
    .opacity(this.active || this.busy ? 1 : 0.35)
    .enabled(this.active && !this.busy)
    .visualEffect(lightEffects.lightSource())
    .animation({ duration: 160, curve: Curve.EaseOut })
    .onClick(() => this.onTap())
  }
}

/** Selectable capsule chip. A component (not a @Builder) so `selected` stays reactive. */
@ComponentV2
export struct ChoiceChip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Event onSelect: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.selected ? $r('app.color.prominent_fg') : $r('app.color.fg'))
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.selected ? $r('app.color.prominent') : $r('app.color.grouped_card'))
      .animation({ duration: 160, curve: Curve.EaseOut })
      .onClick(() => {
        lightEffects.tap();
        this.onSelect();
      })
  }
}

/** iOS-style segmented control. */
@ComponentV2
export struct Segmented {
  @Param options: string[] = [];
  @Param labels: string[] = [];
  @Param selected: string = '';
  @Param idPrefix: string = 'segment';
  @Event onSelect: (value: string) => void = () => {
  };

  build() {
    Row({ space: 4 }) {
      ForEach(this.options, (option: string, index: number) => {
        Text(this.labels[index] ?? option)
          .id(`${this.idPrefix}.${option}`)
          .fontSize(13)
          .fontWeight(option === this.selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(option === this.selected ? $r('app.color.fg') : $r('app.color.fg_secondary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(9)
          .backgroundColor(option === this.selected ? $r('app.color.card') : Color.Transparent)
          .shadow(option === this.selected ? { radius: 4, color: '#14000000', offsetY: 1 } : { radius: 0, color: Color.Transparent })
          .animation(STATE_CHANGE)
          .onClick(() => {
            lightEffects.tap();
            this.onSelect(option);
          })
      }, (option: string) => option)
    }
    .padding(3)
    .borderRadius(12)
    .backgroundColor($r('app.color.chip_bg'))
    .width('100%')
  }
}
