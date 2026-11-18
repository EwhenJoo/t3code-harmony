import { appState, AppState } from '../model/AppState';
import { CloudComputer } from '../model/Types';
import { cloudAccount } from '../services/CloudAccount';
import { lightEffects } from '../services/LightEffects';
import { appNav } from '../common/Nav';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { titleBar } from '../components/TitleBars';
import { PrimaryButton } from '../components/Controls';
import { relativeTime } from '../common/Format';

const RESEND_COOLDOWN_S = 30;

/** T3 Connect: sign in with the T3 account (email code), then pick a linked computer. */
@ComponentV2
export struct ConnectContent {
  @Local app: AppState = appState;
  @Local email: string = '';
  @Local code: string = '';
  @Local resendIn: number = 0;
  private resendTimer: number = -1;

  aboutToAppear(): void {
    if (cloudAccount.signedIn && !this.app.cloudComputersLoaded) {
      cloudAccount.refreshComputers();
    }
  }

  aboutToDisappear(): void {
    this.stopCooldown();
    cloudAccount.cancelApproval();
  }

  private linkedLabel(computer: CloudComputer): string {
    const when = relativeTime(computer.linkedAt, this.app.now);
    return when.length > 0 ? `T3 Connect · ${when}关联` : 'T3 Connect';
  }

  private get emailLooksValid(): boolean {
    return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(this.email.trim());
  }

  private startCooldown(): void {
    this.stopCooldown();
    this.resendIn = RESEND_COOLDOWN_S;
    this.resendTimer = setInterval(() => {
      this.resendIn = Math.max(0, this.resendIn - 1);
      if (this.resendIn === 0) {
        this.stopCooldown();
      }
    }, 1000);
  }

  private stopCooldown(): void {
    if (this.resendTimer >= 0) {
      clearInterval(this.resendTimer);
      this.resendTimer = -1;
    }
  }

  private async sendCode(): Promise<void> {
    if (!this.emailLooksValid || this.app.cloudBusy) {
      return;
    }
    this.getUIContext().getFocusController().clearFocus();
    if (await cloudAccount.sendCode(this.email)) {
      this.code = '';
      this.startCooldown();
    }
  }

  private async verify(): Promise<void> {
    if (this.code.trim().length < 6 || this.app.cloudBusy) {
      return;
    }
    this.getUIContext().getFocusController().clearFocus();
    if (await cloudAccount.verifyCode(this.code)) {
      lightEffects.tap();
    } else {
      this.code = '';
    }
  }

  private async connect(computer: CloudComputer): Promise<void> {
    if (await cloudAccount.connectTo(computer)) {
      lightEffects.tap();
      appNav.clear();
    }
  }

  @Builder
  hero(title: string, subtitle: string) {
    Column({ space: 10 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.icloud')).fontSize(34).fontColor([$r('app.color.prominent_fg')])
      }
      .width(64)
      .height(64)
      .borderRadius(18)
      .backgroundColor($r('app.color.prominent'))
      .shadow({ radius: 24, color: '#26000000', offsetY: 8 })
      Text(title)
        .id('connect.title')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.fg'))
        .margin({ top: 6 })
      Text(subtitle)
        .fontSize(14)
        .lineHeight(21)
        .fontColor($r('app.color.fg_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 8, bottom: 6 })
  }

  @Builder
  errorBanner() {
    if (this.app.cloudError.length > 0) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(15).fontColor([$r('app.color.danger_fg')])
        Text(this.app.cloudError)
          .id('connect.error')
          .fontSize(13)
          .lineHeight(18)
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

  @Builder
  emailStep() {
    Column({ space: 16 }) {
      this.hero('登录 T3 账号', '用电脑上 T3 Code 登录的同一个账号，验证码会发到你的邮箱。')
      TextInput({ text: this.email, placeholder: '邮箱地址' })
        .id('connect.email')
        .type(InputType.Email)
        .enterKeyType(EnterKeyType.Next)
        .fontSize(14)
        .height(52)
        .borderRadius(16)
        .backgroundColor($r('app.color.grouped_card'))
        .onChange((value: string) => {
          this.email = value;
        })
        .onSubmit(() => this.sendCode())
      PrimaryButton({
        label: '发送验证码', buttonId: 'connect.sendCode', active: this.emailLooksValid, busy: this.app.cloudBusy,
        onTap: () => this.sendCode()
      })
      this.errorBanner()
    }
  }

  @Builder
  codeStep() {
    Column({ space: 16 }) {
      this.hero('输入验证码', `已发送到 ${this.app.cloudCodeSentTo}`)
      TextInput({ text: this.code, placeholder: '6 位数字' })
        .id('connect.code')
        .type(InputType.Number)
        .maxLength(6)
        .enterKeyType(EnterKeyType.Done)
        .fontSize(28)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .letterSpacing(8)
        .height(64)
        .borderRadius(18)
        .backgroundColor($r('app.color.grouped_card'))
        .defaultFocus(true)
        .onChange((value: string) => {
          this.code = value.replace(/\D/g, '');
          if (this.code.length === 6) {
            this.verify();
          }
        })
        .onSubmit(() => this.verify())
      PrimaryButton({
        label: '验证并登录', buttonId: 'connect.verify', active: this.code.length === 6, busy: this.app.cloudBusy,
        onTap: () => this.verify()
      })
      this.errorBanner()
      Row() {
        Text(this.resendIn > 0 ? `${this.resendIn} 秒后可重新发送` : '重新发送验证码')
          .id('connect.resend')
          .fontSize(14)
          .fontColor(this.resendIn > 0 ? $r('app.color.fg_tertiary') : $r('app.color.primary'))
          .onClick(() => {
            if (this.resendIn === 0 && !this.app.cloudBusy) {
              cloudAccount.resendCode();
              this.startCooldown();
            }
          })
        Blank()
        Text('换个邮箱')
          .id('connect.changeEmail')
          .fontSize(14)
          .fontColor($r('app.color.primary'))
          .onClick(() => cloudAccount.changeEmail())
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
    }
  }

  @Builder
  computerRow(computer: CloudComputer, last: boolean) {
    Column() {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(22).fontColor([$r('app.color.fg')])
        }
        .width(40)
        .height(40)
        .borderRadius(12)
        .backgroundColor($r('app.color.chip_bg'))
        Column({ space: 3 }) {
          Text(computer.label)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.fg'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.linkedLabel(computer))
            .fontSize(12)
            .fontColor($r('app.color.fg_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.app.cloudConnectingId === computer.environmentId) {
          LoadingProgress().width(22).height(22).color($r('app.color.fg_secondary'))
        } else if (this.app.environmentFor(computer.environmentId)?.isConnect === true) {
          // Already in the list; tapping again refreshes its connection.
          Text('已添加')
            .fontSize(12)
            .fontColor($r('app.color.success_fg'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor($r('app.color.chip_bg'))
        } else {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.fg_tertiary')])
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      if (!last) {
        Divider().color($r('app.color.separator')).margin({ left: 66 })
      }
    }
    .id(`connect.env.${computer.environmentId}`)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.row_pressed')) },
      normal: { .backgroundColor(Color.Transparent) },
    })
    .onClick(() => this.connect(computer))
  }

  @Builder
  computersStep() {
    Column({ space: 16 }) {
      this.hero('选择电脑', this.app.cloudEmail)
      Row() {
        Text('已开启 T3 Connect 的电脑')
          .fontSize(13)
          .fontColor($r('app.color.fg_secondary'))
        Blank()
        if (this.app.cloudBusy && this.app.cloudConnectingId.length === 0) {
          LoadingProgress().width(18).height(18).color($r('app.color.fg_secondary'))
        } else {
          Text('刷新')
            .id('connect.refresh')
            .fontSize(13)
            .fontColor($r('app.color.primary'))
            .onClick(() => cloudAccount.refreshComputers())
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      if (this.app.cloudComputers.length > 0) {
        Column() {
          ForEach(this.app.cloudComputers, (computer: CloudComputer, index: number) => {
            this.computerRow(computer, index === this.app.cloudComputers.length - 1)
          }, (computer: CloudComputer) => computer.environmentId)
        }
        .width('100%')
        .borderRadius(18)
        .backgroundColor($r('app.color.grouped_card'))
        .clip(true)
      } else if (this.app.cloudComputersLoaded) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(30).fontColor([$r('app.color.fg_tertiary')])
          Text('这个账号下还没有电脑')
            .id('connect.empty')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.fg'))
          Text('在电脑的 T3 Code 设置里开启 T3 Connect，或在终端运行 t3 connect，然后点刷新。')
            .fontSize(13)
            .lineHeight(19)
            .fontColor($r('app.color.fg_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding(24)
        .borderRadius(18)
        .backgroundColor($r('app.color.grouped_card'))
      }
      this.errorBanner()
      Text('退出 T3 账号')
        .id('connect.signOut')
        .fontSize(14)
        .fontColor($r('app.color.fg_secondary'))
        .padding(8)
        .onClick(() => cloudAccount.signOut())
    }
  }

  @Builder
  approvalOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text(`在「${this.app.cloudApprovalHost}」上批准这台设备`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.fg'))
          .textAlign(TextAlign.Center)
        Text('电脑上的 T3 Code 会弹出连接请求。确认它显示的代码和下面一致，再点批准。')
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('app.color.fg_secondary'))
          .textAlign(TextAlign.Center)
        Text(this.app.cloudApprovalCode)
          .id('connect.approvalCode')
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .letterSpacing(4)
          .fontColor($r('app.color.fg'))
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .borderRadius(16)
          .backgroundColor($r('app.color.code_bg'))
        Row({ space: 8 }) {
          LoadingProgress().width(20).height(20).color($r('app.color.fg_secondary'))
          Text('等待批准…').fontSize(14).fontColor($r('app.color.fg_secondary'))
        }
        Button('取消', { type: ButtonType.Capsule })
          .id('connect.cancelApproval')
          .fontSize(14)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.chip_bg'))
          .width(140)
          .height(42)
          .onClick(() => cloudAccount.cancelApproval())
      }
      .padding(24)
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .borderRadius(28)
      .backgroundColor($r('app.color.card'))
      .shadow({ radius: 40, color: '#33000000', offsetY: 12 })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.scrim'))
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          if (this.app.cloudEmail.length > 0) {
            this.computersStep()
          } else if (this.app.cloudStep === 'code') {
            this.codeStep()
          } else {
            this.emailStep()
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 480 })
        .padding({ left: 24, right: 24, top: 8, bottom: 48 })
      }
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .width('100%')
      .height('100%')

      if (this.app.cloudApprovalCode.length > 0) {
        this.approvalOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.screen'))
  }
}

@ComponentV2
export struct ConnectPage {
  build() {
    HdsNavDestination() {
      Column() {
        ConnectContent()
          .layoutWeight(1)
      }
    }
    .titleBar(titleBar('T3 Connect', '', [], '', 'page.back', () => appNav.pop()))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('app.color.screen'))
  }
}
