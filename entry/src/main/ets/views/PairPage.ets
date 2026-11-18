import { scanBarcode, scanCore } from '@kit.ScanKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { appNav, openConnect } from '../common/Nav';
import { connection } from '../services/Connection';
import { lightEffects } from '../services/LightEffects';
import { appState, AppState } from '../model/AppState';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { titleBar } from '../components/TitleBars';

@ComponentV2
export struct PairContent {
  @Local app: AppState = appState;
  @Local link: string = '';
  @Local localError: string = '';
  @Param embedded: boolean = false;
  @Event onPaired: () => void = () => {
  };

  private get errorText(): string {
    return this.localError.length > 0 ? this.localError : this.app.pairingError;
  }

  private async scan(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = { scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true };
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(context, options);
      this.link = result.originalValue;
      await this.pair();
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== 1000500002) {
        this.localError = `无法打开扫码（${err.code}），请改用粘贴链接`;
      }
    }
  }

  private async pair(): Promise<void> {
    if (this.link.trim().length === 0) {
      return;
    }
    this.localError = '';
    this.getUIContext().getFocusController().clearFocus();
    const ok = await connection.pairFromLink(this.link);
    if (ok) {
      lightEffects.tap();
      this.onPaired();
    }
  }

  private pasteFromClipboard(): void {
    try {
      const board = pasteboard.getSystemPasteboard();
      board.getData().then((data: pasteboard.PasteData) => {
        const text = data.getPrimaryText()?.trim() ?? '';
        if (text.length === 0) {
          this.localError = '剪贴板里没有配对链接';
          return;
        }
        this.link = text;
        this.pair();
      }).catch((e: BusinessError) => {
        this.localError = `无法读取剪贴板（${e.code}）`;
      });
    } catch (e) {
      this.localError = '无法读取剪贴板';
    }
  }

  @Builder
  step(index: string, text: string) {
    Row({ space: 12 }) {
      Text(index)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.prominent_fg'))
        .textAlign(TextAlign.Center)
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor($r('app.color.prominent'))
      Text(text)
        .fontSize(14)
        .lineHeight(20)
        .fontColor($r('app.color.fg_secondary'))
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 10 }) {
          Image($r('app.media.app_icon'))
            .width(76)
            .height(76)
            .borderRadius(20)
            .shadow({ radius: 28, color: '#33000000', offsetY: 10 })
          Text('连接到 T3 Code')
            .id('pair.title')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.fg'))
            .margin({ top: 8 })
        }
        .padding({ top: this.embedded ? 12 : this.app.topInset + 48 })

        // T3 Connect works from any network, so it leads; direct pairing follows for LAN / Tailscale.
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.icloud')).fontSize(20).fontColor([$r('app.color.fg')])
            Text('T3 Connect').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg'))
            Text('推荐')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(8)
              .backgroundColor($r('app.color.primary_soft'))
          }
          Button({ type: ButtonType.Capsule, stateEffect: true }) {
            Text('使用 T3 账号登录').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.prominent_fg'))
          }
          .id('pair.connectSignIn')
          .width('100%')
          .height(48)
          .backgroundColor($r('app.color.prominent'))
          .visualEffect(lightEffects.lightSource())
          .onClick(() => openConnect())
        }
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .borderRadius(20)
        .backgroundColor($r('app.color.grouped_card'))

        Text('或者在同一网络下直接配对（局域网 / Tailscale）')
          .fontSize(13)
          .fontColor($r('app.color.fg_tertiary'))
          .margin({ top: 4 })

        Column({ space: 14 }) {
          // Non-breaking spaces keep the menu path and the command on one line each.
          this.step('1', '在电脑的 T3 Code 中打开 Settings → Sharing & access，或在终端运行 t3 pair。')
          this.step('2', '扫描出现的二维码，或复制配对链接后回到这里粘贴。')
          this.step('3', '手机和电脑需在同一网络，或通过 Tailscale 互通。')
        }
        .padding(18)
        .borderRadius(20)
        .backgroundColor($r('app.color.grouped_card'))

        if (this.app.pairingBusy) {
          Row({ space: 10 }) {
            LoadingProgress().width(22).height(22).color($r('app.color.fg_secondary'))
            Text('正在配对…').id('pair.busy').fontSize(14).fontColor($r('app.color.fg_secondary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(50)
        } else {
          Column({ space: 10 }) {
            Button({ type: ButtonType.Capsule, stateEffect: true }) {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.line_viewfinder')).fontSize(20).fontColor([$r('app.color.fg')])
                Text('扫描配对二维码').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg'))
              }
            }
            .id('pair.scan')
            .width('100%')
            .height(50)
            .backgroundColor($r('app.color.grouped_card'))
            .onClick(() => this.scan())

            // System paste control: reads the clipboard once with the user's tap, no permission prompt.
            PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
              .id('pair.paste')
              .width('100%')
              .height(50)
              .fontSize(15)
              .fontColor($r('app.color.fg'))
              .iconColor($r('app.color.fg'))
              .backgroundColor($r('app.color.grouped_card'))
              .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                if (result === PasteButtonOnClickResult.SUCCESS) {
                  this.pasteFromClipboard();
                }
              })
          }
        }

        Column({ space: 8 }) {
          Text('或者手动输入链接')
            .fontSize(13)
            .fontColor($r('app.color.fg_tertiary'))
          Row({ space: 8 }) {
            TextInput({ text: this.link, placeholder: 'http://192.168.1.10:3773/pair#token=…' })
              .id('pair.input')
              .fontSize(14)
              .height(44)
              .layoutWeight(1)
              .backgroundColor($r('app.color.grouped_card'))
              .borderRadius(14)
              .enterKeyType(EnterKeyType.Go)
              .onChange((value: string) => {
                this.link = value;
              })
              .onSubmit(() => this.pair())
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(18).fontColor([$r('app.color.prominent_fg')])
            }
            .id('pair.connect')
            .width(44)
            .height(44)
            .enabled(!this.app.pairingBusy && this.link.trim().length > 0)
            .opacity(this.link.trim().length > 0 ? 1 : 0.35)
            .backgroundColor($r('app.color.prominent'))
            .onClick(() => this.pair())
          }
        }
        .alignItems(HorizontalAlign.Start)

        if (this.errorText.length > 0) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(15).fontColor([$r('app.color.danger_fg')])
            Text(this.errorText)
              .id('pair.error')
              .fontSize(13)
              .fontColor($r('app.color.danger_fg'))
              .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          .padding(12)
          .borderRadius(14)
          .backgroundColor($r('app.color.danger_bg'))
          .width('100%')
        }
      }
      .padding({ left: 24, right: 24, bottom: 48 })
      .width('100%')
      .constraintSize({ maxWidth: 560 })
    }
    .id('pair.scroll')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.screen'))
  }
}

@ComponentV2
export struct PairPage {
  build() {
    HdsNavDestination() {
      Column() {
        PairContent({ embedded: true, onPaired: () => appNav.pop() })
          .layoutWeight(1)
      }
    }
    .titleBar(titleBar('配对', '', [], '', 'page.back', () => appNav.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
  }
}
