import { SymbolGlyphModifier } from '@kit.ArkUI';
import { appState, AppState, EnvironmentState, Hand } from '../model/AppState';
import { ThreadShell } from '../model/Types';
import { connection } from '../services/Connection';
import { gripService } from '../services/GripService';
import { lightEffects } from '../services/LightEffects';
import { openConnect, openPairing, openVoiceSettings } from '../common/Nav';
import { voice } from '../services/Voice';
import { cloudAccount } from '../services/CloudAccount';
import { Prefs, PREF_SHOW_SETTLED } from '../common/Prefs';
import { StatusDot } from '../components/Common';
import { userSettings } from '../services/UserSettings';
import { notifier } from '../services/Notifier';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { symbolItem, tabTitleBar } from '../components/TitleBars';
import { ActionMenuRow, showActionMenu } from '../components/ActionMenu';
import { confirmDialog, promptDialog } from '../components/Dialogs';
import { pushHelper } from '../services/PushHelper';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { applyAppearance } from '../common/Appearance';
import { common } from '@kit.AbilityKit';
import { Space, Type } from '../common/Typography';

const HAND_OPTIONS: string[] = ['auto', 'left', 'right'];
const APPEARANCE_OPTIONS: string[] = ['system', 'light', 'dark'];

@ComponentV2
export struct SettingsView {
  @Local app: AppState = appState;
  private scroller: Scroller = new Scroller();

  /** Cards need contrast with the page: white on the sidebar drawer, light grey on the phone screen. */
  private cardColor(): ResourceColor {
    return $r('app.color.grouped_card');
  }

  private handLabel(hand: Hand): string {
    switch (hand) {
      case 'left':
        return '左手';
      case 'right':
        return '右手';
      case 'both':
        return '双手';
      case 'none':
        return '未握持';
      default:
        return '未知';
    }
  }

  private handSourceLabel(): string {
    switch (this.app.handSource) {
      case 'grip':
        return '握持感知（holdingHandChanged）';
      case 'touch':
        return '触控识别（operatingHandChanged）';
      case 'simulated':
        return '模拟';
      default:
        return '此设备不支持，使用手动设置';
    }
  }

  @Builder
  groupTitle(title: string) {
    Text(title)
      .fontSize(Type.small)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.fg_tertiary'))
      .padding({ left: Space.margin, top: 16, bottom: 2 })
  }

  @Builder
  row(title: string, value: string) {
    Row() {
      Text(title).fontSize(Type.body).fontColor($r('app.color.fg'))
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.fg_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '62%' })
    }
    .width('100%')
    .constraintSize({ minHeight: 48 })
    .padding({ left: Space.margin, right: Space.margin, top: 12, bottom: 12 })
  }

  @Builder
  actionRow(title: string, danger: boolean, action: () => void) {
    Text(title)
      .fontSize(Type.body)
      .fontColor(danger ? $r('app.color.danger_fg') : $r('app.color.primary'))
      .width('100%')
      .constraintSize({ minHeight: 48 })
      .padding({ left: Space.margin, right: Space.margin, top: 12, bottom: 12 })
      .onClick(action)
  }

  @Builder
  divider() {
    Divider().strokeWidth(0.5).color($r('app.color.hairline')).margin({ left: Space.margin })
  }

  private statusText(env: EnvironmentState): string {
    switch (env.phase) {
      case 'connected':
        return '已连接';
      case 'offline':
        return '离线';
      default:
        return '连接中';
    }
  }

  /** "通过 T3 Connect · 0.1.10 nightly" or "http://… · 0.1.10". */
  private routeText(env: EnvironmentState): string {
    const route = env.isConnect ? '通过 T3 Connect' : env.env.baseUrl.replace(/^https?:\/\//, '');
    const version = (env.config?.environment?.serverVersion ?? env.env.serverVersion).replace(/-nightly\.\d{8}\.\d+$/, ' nightly');
    return version.length > 0 ? `${route} · ${version}` : route;
  }

  private threadCount(env: EnvironmentState): number {
    return this.app.threads.filter((t: ThreadShell) => t.environmentId === env.id && !t.archivedAt).length;
  }

  private showComputerMenu(env: EnvironmentState): void {
    const rows: ActionMenuRow[] = [
      ActionMenuRow.of(`settings.computer.reconnect.${env.id}`, '重新连接', '', () => connection.reconnect(env.id))
        .withSymbol($r('sys.symbol.arrow_clockwise')),
      env.isConnect
        ? ActionMenuRow.of(`settings.computer.reconnectCloud.${env.id}`, '在 T3 Connect 里重新连接', '', () => openConnect())
          .withSymbol($r('sys.symbol.icloud'))
        : ActionMenuRow.of(`settings.computer.repair.${env.id}`, '重新配对', '', () => openPairing())
          .withSymbol($r('sys.symbol.qrcode')),
      ActionMenuRow.of(`settings.computer.remove.${env.id}`, '移除这台电脑', '', () => this.removeComputer(env))
        .withSymbol($r('sys.symbol.trash')).asDestructive(),
    ];
    showActionMenu(this.getUIContext(), `settings.computer.${env.id}`, rows);
  }

  private async removeComputer(env: EnvironmentState): Promise<void> {
    const ok = await confirmDialog(this.getUIContext(), `移除“${env.label}”？`,
      '这台电脑的对话会从列表中消失。电脑上的数据不受影响，之后可以重新添加。', '移除', true);
    if (ok) {
      connection.forget(env.id);
    }
  }

  /** One computer: name, how it is reached, live status; tap for reconnect / re-pair / remove. */
  @Builder
  computerRow(env: EnvironmentState) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.computer')).fontSize(Space.icon).fontColor([$r('app.color.fg_secondary')])
      Column({ space: 2 }) {
        Text(env.label)
          .fontSize(Type.body)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.fg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.routeText(env))
          .id('settings.computerRoute')
          .fontSize(Type.small)
          .fontColor($r('app.color.fg_tertiary'))
          .maxLines(1)
          // Addresses are one long "word"; cut by character so the host stays readable.
          .wordBreak(WordBreak.BREAK_ALL)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Column({ space: 2 }) {
        Row({ space: 5 }) {
          StatusDot({
            color: env.phase === 'connected' ? $r('app.color.success_fg')
              : (env.phase === 'offline' ? $r('app.color.status_failed') : $r('app.color.status_attention')),
            dotSize: 6
          })
          Text(this.statusText(env)).fontSize(Type.small).fontColor($r('app.color.fg_secondary'))
        }
        Text(`${this.threadCount(env)} 个对话`).fontSize(Type.small).fontColor($r('app.color.fg_tertiary'))
      }
      .alignItems(HorizontalAlign.End)
    }
    .id(`settings.computer.${env.id}`)
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: Space.margin, right: Space.margin, top: 10, bottom: 10 })
    .onClick(() => this.showComputerMenu(env))
  }

  @Builder
  computerGroup() {
    Column() {
      ForEach(this.app.environments, (env: EnvironmentState, index: number) => {
        if (index > 0) {
          this.divider()
        }
        this.computerRow(env)
      }, (env: EnvironmentState) => `${env.id}:${env.env.kind ?? ''}:${env.phase}:${env.label}`)
      if (this.app.hasEnvironments) {
        this.divider()
      }
      // Another computer joins the same list; it never replaces the ones already here.
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(Space.icon).fontColor([$r('app.color.primary')])
        Text(this.app.hasEnvironments ? '添加电脑' : '配对一台电脑')
          .fontSize(Type.body)
          .fontColor($r('app.color.primary'))
      }
      .id('settings.addComputer')
      .width('100%')
      .constraintSize({ minHeight: 48 })
      .padding({ left: Space.margin, right: Space.margin, top: 12, bottom: 12 })
      .onClick(() => openPairing())
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  accountGroup() {
    Column() {
      if (this.app.cloudEmail.length > 0) {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.icloud')).fontSize(Space.icon).fontColor([$r('app.color.fg_secondary')])
          Column({ space: 2 }) {
            Text(this.app.cloudEmail)
              .id('settings.cloudEmail')
              .fontSize(Type.body)
              .fontColor($r('app.color.fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('T3 Connect 已登录').fontSize(12).fontColor($r('app.color.fg_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .padding(16)
        this.divider()
        this.actionRow('添加账号下的其他电脑', false, () => openConnect())
        this.divider()
        this.actionRow('退出 T3 账号', true, () => cloudAccount.signOut())
      } else {
        Column({ space: 4 }) {
          Text('登录 T3 账号')
            .id('settings.cloudSignIn')
            .fontSize(Type.body)
            .fontColor($r('app.color.primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
        .onClick(() => openConnect())
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  gripGroup() {
    Column() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.phone_and_hand')).fontSize(Space.icon).fontColor([$r('app.color.fg_secondary')])
            Column({ space: 2 }) {
              Text(`当前：${this.handLabel(this.app.hand)} · 布局按${this.app.layoutHand === 'left' ? '左手' : '右手'}`)
                .fontSize(Type.body)
                .fontColor($r('app.color.fg'))
              Text(this.handSourceLabel()).fontSize(12).fontColor($r('app.color.fg_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          Row() {
            Text('布局跟随').fontSize(Type.body).fontColor($r('app.color.fg')).layoutWeight(1)
            Text(['自动', '左手', '右手'][Math.max(0, HAND_OPTIONS.indexOf(this.app.handOverride))])
              .fontSize(Type.body).fontColor($r('app.color.fg_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.fg_tertiary')]).margin({ left: 12 })
          }
          .id('settings.hand')
          .width('100%')
          .height(36)
          .onClick(() => {
            lightEffects.tap();
            this.pick('settings.hand', HAND_OPTIONS, ['自动', '左手', '右手'], this.app.handOverride,
              (value: string) => gripService.setOverride(value));
          })
          if (this.app.handSource === 'unavailable' || this.app.handSource === 'simulated') {
            Row({ space: 8 }) {
              Button('模拟左手', { type: ButtonType.Capsule }).id('settings.simulateLeft').fontSize(Type.small).height(32)
                .backgroundColor($r('app.color.card')).fontColor($r('app.color.fg'))
                .onClick(() => gripService.simulate('left'))
              Button('模拟右手', { type: ButtonType.Capsule }).id('settings.simulateRight').fontSize(Type.small).height(32)
                .backgroundColor($r('app.color.card')).fontColor($r('app.color.fg'))
                .onClick(() => gripService.simulate('right'))
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding(16)
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  switchRow(id: string, title: string, detail: string, isOn: boolean, enabled: boolean, onChange: (isOn: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(Type.body).fontColor($r('app.color.fg'))
        if (detail.length > 0) {
          Text(detail).fontSize(Type.small).lineHeight(Type.smallLine).fontColor($r('app.color.fg_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .id(id)
        .enabled(enabled)
        .onChange((value: boolean) => onChange(value))
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .opacity(enabled ? 1 : 0.45)
  }

  /** "Title … value ⌄": opens a light-material menu of the choices. */
  @Builder
  choiceRow(id: string, title: string, detail: string, value: string, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(Type.body).fontColor($r('app.color.fg'))
        if (detail.length > 0) {
          Text(detail).fontSize(Type.small).lineHeight(Type.smallLine).fontColor($r('app.color.fg_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(value).fontSize(Type.body).fontColor($r('app.color.fg_secondary')).maxLines(1)
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.fg_tertiary')])
    }
    .id(id)
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.row_pressed'))
      },
      normal: {
        .backgroundColor(Color.Transparent)
      }
    })
    .onClick(() => {
      lightEffects.tap();
      onTap();
    })
  }

  private pick(anchorId: string, values: string[], labels: string[], current: string, apply: (value: string) => void): void {
    const rows: ActionMenuRow[] = values.map((value: string, index: number) =>
    ActionMenuRow.of(`${anchorId}.${value}`, labels[index], '', () => apply(value))
      .withSymbol(value === current ? $r('sys.symbol.checkmark') : $r('sys.symbol.circle')));
    showActionMenu(this.getUIContext(), anchorId, rows);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
  }

  private async scanPushHelper(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = { scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true };
      const result = await scanBarcode.startScanForResult(this.getUIContext().getHostContext() as common.UIAbilityContext, options);
      await this.bindPushHelper(result.originalValue);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== 1000500002) {
        this.toast(`无法打开扫码（${err.code}），请改用粘贴链接`);
      }
    }
  }

  private async pastePushHelper(): Promise<void> {
    const link = await promptDialog(this.getUIContext(), '粘贴绑定链接', '在电脑上运行 t3-push bind，复制它打印的 t3code://push 链接。',
      't3code://push?url=…', '绑定');
    if (link !== null && link.trim().length > 0) {
      await this.bindPushHelper(link);
    }
  }

  private async bindPushHelper(link: string): Promise<void> {
    notifier.requestPermission(this.getUIContext().getHostContext() as common.UIAbilityContext);
    try {
      this.toast(await pushHelper.bind(link));
      lightEffects.tap();
    } catch (e) {
      this.toast(`绑定失败：${(e as Error).message}`);
    }
  }

  private pushHelperMenu(): void {
    const rows: ActionMenuRow[] = [
      ActionMenuRow.of('settings.pushHelper.scan', this.app.pushHelperName.length > 0 ? '重新扫码绑定' : '扫码绑定', '',
        () => { this.scanPushHelper(); }).withSymbol($r('sys.symbol.qrcode')),
      ActionMenuRow.of('settings.pushHelper.paste', '粘贴绑定链接', '', () => { this.pastePushHelper(); })
        .withSymbol($r('sys.symbol.link')),
    ];
    if (this.app.pushHelperName.length > 0) {
      rows.push(ActionMenuRow.of('settings.pushHelper.test', '发送测试通知', '', () => {
        pushHelper.sendTest().then(() => this.toast('已发送，稍后看通知栏'))
          .catch((e: Error) => this.toast(`发送失败：${e.message}`));
      }).withSymbol($r('sys.symbol.paperplane')));
      rows.push(ActionMenuRow.of('settings.pushHelper.unbind', '解除绑定', '', () => {
        pushHelper.unbind().then(() => this.toast('已解除绑定'));
      }).withSymbol($r('sys.symbol.link_slash')).asDestructive());
    }
    showActionMenu(this.getUIContext(), 'settings.pushHelper', rows);
  }

  /** How sending behaves, like the iOS Chat and Keyboard settings. */
  @Builder
  chatGroup() {
    Column() {
      this.choiceRow('settings.followUp', '代理运行时发送', '',
        this.app.followUp === 'queue' ? '排队' : '引导', () => this.pick('settings.followUp', ['steer', 'queue'], ['引导', '排队'],
          this.app.followUp, (value: string) => userSettings.setFollowUp(value)))
      this.divider()
      this.choiceRow('settings.returnKey', '回车键', '', this.app.returnKey === 'send' ? '发送' : '换行',
        () => this.pick('settings.returnKey', ['newline', 'send'], ['换行', '发送'], this.app.returnKey,
          (value: string) => userSettings.setReturnKey(value)))
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  /** Voice input lives on its own page, like the desktop's Settings › Voice. */
  @Builder
  voiceGroup() {
    Column() {
      Row({ space: 12 }) {
        Text('语音输入').fontSize(Type.body).fontColor($r('app.color.fg')).layoutWeight(1)
        Text(voice.destinationLabel())
          .id('settings.voice.value')
          .fontSize(Type.body)
          .fontColor($r('app.color.fg_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '62%' })
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.fg_tertiary')])
      }
      .id('settings.voice')
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.row_pressed'))
        },
        normal: {
          .backgroundColor(Color.Transparent)
        }
      })
      .onClick(() => {
        lightEffects.tap();
        openVoiceSettings();
      })
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  notifyGroup() {
    Column() {
      this.switchRow('settings.notify', '通知', '',
        this.app.notify, true, (isOn: boolean) => {
        userSettings.setNotify(isOn);
        if (isOn) {
          notifier.requestPermission(this.getUIContext().getHostContext() as common.UIAbilityContext);
        }
      })
      this.divider()
      this.choiceRow('settings.pushHelper', '推送小助手',
        this.app.pushHelperName.length > 0
          ? [this.app.pushHelperName, this.app.pushHelperDetail].filter((s: string) => s.length > 0).join(' · ')
          : '在电脑上运行 t3-push bind，扫码后 App 关闭也能收到',
        this.app.pushHelperName.length > 0 ? '已绑定' : '未绑定', () => this.pushHelperMenu())
      this.divider()
      this.switchRow('settings.notifyAttention', '需要你处理', '', this.app.notifyAttention, this.app.notify,
        (isOn: boolean) => userSettings.setNotifyAttention(isOn))
      this.divider()
      this.switchRow('settings.notifyDone', '任务完成', '', this.app.notifyDone, this.app.notify,
        (isOn: boolean) => userSettings.setNotifyDone(isOn))
      this.divider()
      this.switchRow('settings.notifyFailed', '任务失败', '', this.app.notifyFailed, this.app.notify,
        (isOn: boolean) => userSettings.setNotifyFailed(isOn))
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  feedbackGroup() {
    Column() {
      this.switchRow('settings.haptics', '触感反馈', '', this.app.haptics, true, (isOn: boolean) => {
        userSettings.setHaptics(isOn);
        lightEffects.tap();
      })
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  listGroup() {
    Column() {
        Row() {
          Text('显示已完成的对话').fontSize(Type.body).fontColor($r('app.color.fg'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.app.showSettled })
            .selectedColor($r('app.color.primary'))
            .onChange((isOn: boolean) => {
              this.app.showSettled = isOn;
              Prefs.put(PREF_SHOW_SETTLED, isOn);
            })
        }
        .width('100%')
        .padding(16)
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  @Builder
  aboutGroup() {
    Column() {
        this.row('T3 Code for HarmonyOS', '0.1.0')
      this.divider()
      this.row('已连接的电脑', `${this.app.environments.filter((e: EnvironmentState) => e.phase === 'connected').length} / ${this.app.environments.length}`)
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(this.cardColor())
    .clip(true)
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 6 }) {
          this.groupTitle('电脑')
          this.computerGroup()

          this.groupTitle('T3 账号')
          this.accountGroup()

          this.groupTitle('对话')
          this.chatGroup()
          this.voiceGroup()

          this.groupTitle('通知')
          this.notifyGroup()

          this.groupTitle('握持手识别')
          this.gripGroup()

          this.groupTitle('反馈')
          this.feedbackGroup()

          this.groupTitle('显示')
          Column() {
            this.choiceRow('settings.appearance', '外观', '', ['跟随系统', '浅色', '深色'][Math.max(0, APPEARANCE_OPTIONS.indexOf(this.app.appearance))],
              () => this.pick('settings.appearance', APPEARANCE_OPTIONS, ['跟随系统', '浅色', '深色'], this.app.appearance,
                (value: string) => applyAppearance(this.getUIContext().getHostContext() as common.Context, value)))
            this.divider()
            this.switchRow('settings.showSettled', '显示已完成的对话', '', this.app.showSettled, true, (isOn: boolean) => {
              this.app.showSettled = isOn;
              Prefs.put(PREF_SHOW_SETTLED, isOn);
            })
          }
          .width('100%')
          .borderRadius(12)
          .backgroundColor(this.cardColor())
          .clip(true)

          this.groupTitle('关于')
          this.aboutGroup()
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, bottom: this.app.bottomInset + 190 })
        .width('100%')
      }
      .id('settings.scroll')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
    }
    .titleBar(tabTitleBar('设置', [
      symbolItem($r('sys.symbol.plus'), '添加电脑', 'settings.addComputerBar', () => openPairing()),
    ], 'settings.title'))
    .titleMode(HdsNavigationTitleMode.FREE)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .bindToScrollable([this.scroller])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.screen'))
  }
}
