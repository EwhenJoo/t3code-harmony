import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { immersiveMaterial, MaterialStyle, systemMaterialOn } from '../common/Material';
import { SPRING_SOFT } from '../common/Motion';
import { notifier } from '../services/Notifier';
import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode, SymbolGlyphModifier } from '@kit.ArkUI';
import { appState, AppState, EnvironmentState } from '../model/AppState';
import { appNav, detailNav, openDraftThread, openNewTask, relocateForWidth } from '../common/Nav';
import { HomeView } from '../views/HomeView';
import { PullRequestsView } from '../views/PullRequestsView';
import { UsageView } from '../views/UsageView';
import { SettingsView } from '../views/SettingsView';
import { ThreadPage } from '../views/ThreadPage';
import { ProjectPicker } from '../components/ProjectPicker';
import { PairContent, PairPage } from '../views/PairPage';
import { ConnectPage } from '../views/ConnectPage';
import { DetailPlaceholder } from '../views/DetailPlaceholder';
import { TerminalPage } from '../views/TerminalPage';
import { FilesPage, FileViewerPage } from '../views/FilesPage';
import { DiffPage, GitPage } from '../views/GitPage';
import { PullRequestPage } from '../views/PullRequestPage';
import { VoicePage } from '../views/VoicePage';
import { lightEffects } from '../services/LightEffects';

/** The floating tab bar: four icons, 64vp each, centred on every screen. */
const TAB_BAR_WIDTH = 256;
/** HDS floating bar height; the compose button matches it. */
const TAB_BAR_HEIGHT = 56;
const COMPOSE_SIZE = 56;
/** Space between the compose button and the bar below it. */
const COMPOSE_LIFT = 14;

/** A tab's page: shown, it settles in with a short fade and lift; hidden, it waits faded out. */
@Extend(Column)
function tabPage(shown: boolean) {
  .width('100%')
  .height('100%')
  .opacity(shown ? 1 : 0)
  .translate({ y: shown ? 0 : 10 })
  .animation({ curve: SPRING_SOFT })
}

@Entry
@ComponentV2
struct Index {
  @Local app: AppState = appState;
  @Local currentTab: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();
  private wasWide: boolean = false;
  private environmentKey: string = '';

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.wasWide = this.app.isWide;
    this.environmentKey = this.computersKey();
  }

  /** Width the tabs get: the list pane beside a conversation, or the whole window. */
  @Computed
  get tabsWidth(): number {
    return this.app.isWide ? this.app.listPaneWidth : this.app.windowWidth;
  }

  /** Page margin the compose button keeps from the screen edge (HDS: 16vp, 24vp from 600vp). */
  @Computed
  get composeSideMargin(): number {
    return this.tabsWidth >= 600 ? 24 : 16;
  }

  private barBottom(): number {
    return Math.max(12, this.app.bottomInset);
  }

  /** Which computers are connected, and how; token renewals leave it unchanged. */
  private computersKey(): string {
    return this.app.environments.map((e: EnvironmentState) => `${e.id}|${e.env.kind ?? 'direct'}`).join(',');
  }

  /** Folding / unfolding: move the open conversation between the phone stack and the detail pane. */
  @Monitor('app.windowWidth')
  onWindowWidth(): void {
    const wide = this.app.isWide;
    if (wide !== this.wasWide) {
      this.wasWide = wide;
      relocateForWidth(wide);
    }
  }

  /** Messages raised outside the UI (e.g. binding the push helper from a scanned link). */
  @Monitor('app.notice')
  onNotice(): void {
    if (this.app.notice.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: this.app.notice, duration: 2500 });
    this.app.notice = '';
  }

  /** After adding a computer (or reaching one a new way), land on the thread list rather than Settings. */
  @Monitor('app.environments')
  onEnvironmentsChanged(): void {
    const before = this.environmentKey;
    const key = this.computersKey();
    if (key === before) {
      return;
    }
    this.environmentKey = key;
    const added = key.split(',').some((part: string) => part.length > 0 && before.split(',').indexOf(part) < 0);
    if (added && before.length === 0 && this.app.notify) {
      notifier.requestPermission(this.getUIContext().getHostContext() as common.UIAbilityContext);
    }
    if (added && this.currentTab !== 0) {
      this.currentTab = 0;
      this.tabsController.changeIndex(0);
    }
  }

  /** The floating bar's light color reports agent activity: amber needs you, blue is working. */
  private barLightColor(): ResourceColor {
    // Immersive light stays quiet: it only warms up when something is waiting for the user.
    if (!this.app.lightEffects || this.app.attentionCount === 0) {
      return '#00FFFFFF';
    }
    return $r('app.color.status_attention');
  }

  @Builder
  routes(name: string, param: Object) {
    if (name === 'thread') {
      ThreadPage()
    } else if (name === 'pair') {
      PairPage()
    } else if (name === 'connect') {
      ConnectPage()
    } else if (name === 'terminal') {
      TerminalPage()
    } else if (name === 'files') {
      FilesPage()
    } else if (name === 'file') {
      FileViewerPage()
    } else if (name === 'git') {
      GitPage()
    } else if (name === 'diff') {
      DiffPage()
    } else if (name === 'pullRequest') {
      PullRequestPage()
    } else if (name === 'voice') {
      VoicePage()
    }
  }

  /**
   * New conversation: a one-button floating bar. It is the same HDS bar as the tabs below, so it gets
   * the very same system material (custom components only get it inside the tab bar or title bar).
   */
  @Builder
  composeButton() {
    HdsTabs({ index: 0, barPosition: BarPosition.End }) {
      TabContent() {
      }
      .backgroundColor(Color.Transparent)
      .tabBar(new BottomTabBarStyle({
        normal: this.composeIcon(),
        selected: this.composeIcon(),
      }, '').layoutMode(LayoutMode.HORIZONTAL).id('home.newTask'))
    }
    .barOverlap(true)
    .scrollable(false)
    .barFloatingStyle({
      barBottomMargin: 0,
      barSideMargin: 0,
      barWidth: { smallWidth: COMPOSE_SIZE, mediumWidth: COMPOSE_SIZE, largeWidth: COMPOSE_SIZE },
      lightColor: this.barLightColor(),
      systemMaterialEffect: {
        materialType: lightEffects.materialType(),
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
      gradientMask: { maskColor: '#00FFFFFF', maskHeight: 1 },
    })
    .onTabBarClick(() => {
      lightEffects.tap();
      openNewTask();
    })
    .width(COMPOSE_SIZE)
    .height(COMPOSE_SIZE)
    .backgroundColor(Color.Transparent)
    // The bar's shadow reaches past its own box.
    .clip(false)
    .margin({
      left: this.composeSideMargin,
      right: this.composeSideMargin,
      bottom: this.barBottom() + TAB_BAR_HEIGHT + COMPOSE_LIFT,
    })
  }

  private composeIcon(): SymbolGlyphModifier {
    return new SymbolGlyphModifier($r('sys.symbol.square_and_pencil'))
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([$r('app.color.fg')]);
  }

  /** One ink for every tab icon, system symbol or drawn: secondary at rest, the accent when chosen. */
  private symbolIcon(symbol: Resource, selected: boolean, badged: boolean = false): SymbolGlyphModifier {
    const icon = new SymbolGlyphModifier(symbol);
    if (badged) {
      // The badge layer takes the "needs you" amber; the bubble keeps the tab ink.
      icon.renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
        .fontColor([selected ? $r('app.color.primary') : $r('app.color.fg_secondary'), $r('app.color.status_attention')]);
    } else {
      icon.fontColor([selected ? $r('app.color.primary') : $r('app.color.fg_secondary')]);
    }
    return icon;
  }

  private tabStyle(id: string, normal: SymbolGlyphModifier, selected: SymbolGlyphModifier): BottomTabBarStyle {
    return new BottomTabBarStyle({ normal: normal, selected: selected }, '')
      .layoutMode(LayoutMode.HORIZONTAL)
      .id(id);
  }

  private imageTabStyle(id: string, icon: Resource): BottomTabBarStyle {
    return new BottomTabBarStyle(icon, '')
      .layoutMode(LayoutMode.HORIZONTAL)
      .iconStyle({ unselectedColor: $r('app.color.fg_secondary'), selectedColor: $r('app.color.primary') })
      .id(id);
  }

  @Builder
  tabs() {
    // Unfolded: the list column's bottom-right corner. One screen: the holding hand's corner.
    Stack({ alignContent: !this.app.isWide && this.app.layoutHand === 'left' ? Alignment.BottomStart : Alignment.BottomEnd }) {
      this.tabView()
      this.composeButton()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  tabView() {
    HdsTabs({ controller: this.tabsController, index: this.currentTab, barPosition: BarPosition.End }) {
      TabContent() {
        Column() {
          HomeView()
        }
        .tabPage(this.currentTab === 0)
      }
      // Icons only: the four symbols read on their own, and the bar stays light.
      // A conversation waiting for you swaps in the message-with-badge symbol.
      .tabBar(this.tabStyle('tab.chats', this.symbolIcon(this.app.attentionCount > 0
        ? $r('sys.symbol.ellipsis_message_badge_circle') : $r('sys.symbol.ellipsis_message'), false, this.app.attentionCount > 0),
        this.symbolIcon(this.app.attentionCount > 0
          ? $r('sys.symbol.ellipsis_message_badge_circle_fill') : $r('sys.symbol.ellipsis_message_fill'), true,
          this.app.attentionCount > 0)))

      TabContent() {
        Column() {
          PullRequestsView()
        }
        .tabPage(this.currentTab === 1)
      }
      .tabBar(this.imageTabStyle('tab.pulls', $r('app.media.ic_pull_request')))

      TabContent() {
        Column() {
          UsageView()
        }
        .tabPage(this.currentTab === 2)
      }
      .tabBar(this.imageTabStyle('tab.usage', $r('app.media.ic_usage')))

      TabContent() {
        Column() {
          SettingsView()
        }
        .tabPage(this.currentTab === 3)
      }
      .tabBar(this.tabStyle('tab.settings', this.symbolIcon($r('sys.symbol.gearshape'), false),
        this.symbolIcon($r('sys.symbol.gearshape_fill'), true)))
    }
    .barOverlap(true)
    .scrollable(false)
    // No slide through the tabs in between: the chosen page fades through in place (see tabPage).
    .animationDuration(0)
    .barFloatingStyle({
      barBottomMargin: this.barBottom(),
      barWidth: { smallWidth: TAB_BAR_WIDTH, mediumWidth: TAB_BAR_WIDTH, largeWidth: TAB_BAR_WIDTH },
      lightColor: this.barLightColor(),
      systemMaterialEffect: {
        materialType: lightEffects.materialType(),
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
      gradientMask: { maskColor: '#00FFFFFF', maskHeight: 1 },
    })
    .onChange((index: number) => {
      this.currentTab = index;
      lightEffects.tap();
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Navigation(appNav) {
      if (!this.app.hasEnvironments) {
        PairContent({ embedded: false })
      } else {
        // One tree for both layouts, so folding keeps the list's search, filters and scroll position.
        Row() {
          Column() {
            this.tabs()
          }
          .width(this.app.isWide ? this.app.listPaneWidth : '100%')
          .height('100%')
          // The list's only field is search at the top: let the keyboard cover the floating tab bar
          // instead of lifting it into the middle of the results.
          .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

          if (this.app.isWide) {
            if (this.app.paneGap > 0) {
              // Split on the fold crease: the gap is the crease itself, so nothing is drawn across it.
              Column()
                .width(this.app.paneGap)
                .height('100%')
                .backgroundColor($r('app.color.drawer'))
            } else {
              Divider()
                .vertical(true)
                .strokeWidth(0.5)
                .color($r('app.color.hairline'))
                .height('100%')
            }
            Navigation(detailNav) {
              DetailPlaceholder()
            }
            .hideTitleBar(true)
            .hideToolBar(true)
            .mode(NavigationMode.Stack)
            .navDestination(this.routes)
            .backgroundColor($r('app.color.screen'))
            .layoutWeight(1)
            .height('100%')
          }
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        // No shared status-bar band: each pane (list, settings, conversation) runs its own colour under it.
      }
    }
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.routes)
    .backgroundColor($r('app.color.screen'))
    .width('100%')
    .height('100%')
    // New conversation: pick the project first, then the empty conversation page opens in it.
    .bindSheet(this.app.newChatPickerShown, this.newChatSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      title: { title: '新建对话' },
      systemMaterial: immersiveMaterial(MaterialStyle.ULTRA_THICK),
      backgroundColor: systemMaterialOn() ? undefined : $r('app.color.glass'),
      blurStyle: systemMaterialOn() ? undefined : BlurStyle.COMPONENT_ULTRA_THICK,
      onDisappear: () => {
        this.app.newChatPickerShown = false;
      },
    })
  }

  @Builder
  newChatSheet() {
    ProjectPicker({
      onPick: (key: string) => {
        this.app.newChatPickerShown = false;
        openDraftThread(key);
      }
    })
  }
}
