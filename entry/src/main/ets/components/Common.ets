import { ProjectShell, ThreadShell } from '../model/Types';
import { SPRING } from '../common/Motion';
import { appState, AppState, isSettled, isUnreadDone, isWorking, needsAttention } from '../model/AppState';
import { parseTime, relativeTime } from '../common/Format';
import { Space, Type } from '../common/Typography';
import { common } from '@kit.AbilityKit';
import { deriveProjectIdentity, isProjectColor } from '../common/ProjectIdentity';
import { ProjectIconService, projectIcons } from '../services/ProjectIcons';

export function threadStatusColor(thread: ThreadShell): Resource {
  if (needsAttention(thread)) {
    return (thread.pendingRuntimeRequest?.kind ?? '') === 'user_input' ? $r('app.color.status_input') : $r('app.color.status_attention');
  }
  if (isWorking(thread)) {
    return $r('app.color.status_working');
  }
  if (thread.status === 'failed') {
    return $r('app.color.status_failed');
  }
  if (!isSettled(thread) && thread.status === 'completed') {
    return $r('app.color.status_done');
  }
  return $r('app.color.status_idle');
}

export function threadStatusLabel(thread: ThreadShell): string {
  if (needsAttention(thread)) {
    const kind = thread.pendingRuntimeRequest?.kind ?? '';
    return kind === 'user_input' ? '等待回答' : '等待批准';
  }
  if (isWorking(thread)) {
    const status = thread.activityRunStatus ?? thread.status;
    switch (status) {
      case 'preparing':
        return '准备中';
      case 'queued':
        return '排队中';
      case 'starting':
        return '启动中';
      case 'waiting':
        return '等待中';
      default:
        return '运行中';
    }
  }
  switch (thread.status) {
    case 'completed':
      return '已完成';
    case 'failed':
      return '失败';
    case 'interrupted':
      return '已中断';
    case 'cancelled':
      return '已取消';
    default:
      return '空闲';
  }
}

/** mm:ss / h:mm:ss, tabular like the desktop app's run timers. */
export function clockDuration(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

/** Static status dot. No breathing animation: a list of them would repaint the GPU forever. */
@ComponentV2
export struct StatusDot {
  @Param color: ResourceColor = Color.Gray;
  @Param pulsing: boolean = false;
  @Param dotSize: number = 8;

  build() {
    Circle()
      .width(this.dotSize)
      .height(this.dotSize)
      .fill(this.color)
  }
}

/** Monochrome project initial; colour is reserved for states that need the reader. */
/**
 * A project's icon, the way the desktop draws it: its lucide / emoji / monogram override, else
 * its favicon, else a monogram and color derived from its name (same algorithm as the desktop).
 */
@ComponentV2
export struct ProjectBadge {
  @Param project: ProjectShell | null = null;
  @Param badgeSize: number = Space.badge;
  @Param dim: boolean = false;
  @Local icons: ProjectIconService = projectIcons;

  /** Hex of a palette color in the current light / dark mode (resources project_<color>). */
  private hexOf(color: string): string {
    try {
      const name = `project_${isProjectColor(color) ? color : 'gray'}`;
      const value = (this.getUIContext().getHostContext() as common.Context).resourceManager.getColorByNameSync(name);
      return `#${(value & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase()}`;
    } catch (e) {
      return '#6B7280';
    }
  }

  private kind(): string {
    const icon = this.project?.projectIcon;
    if (icon?.kind === 'lucide' && (icon.name ?? '').length > 0 && this.icons.hasLucide(icon.name ?? '')) {
      return 'lucide';
    }
    if (icon?.kind === 'emoji' && (icon.emoji ?? '').length > 0) {
      return 'emoji';
    }
    if (icon?.kind === 'monogram' && (icon.text ?? '').length > 0) {
      return 'monogram';
    }
    // Reading `version` re-renders the badge when a favicon download lands.
    if (this.icons.version >= 0 && this.project !== null && projectIcons.faviconUri(this.project).length > 0) {
      return 'favicon';
    }
    return 'derived';
  }

  private lucideSrc(): string {
    const icon = this.project?.projectIcon;
    return projectIcons.lucideUri(icon?.name ?? '', this.hexOf(icon?.color ?? 'gray'));
  }

  private monogramText(): string {
    const icon = this.project?.projectIcon;
    if (icon?.kind === 'monogram' && (icon.text ?? '').length > 0) {
      return icon.text ?? '';
    }
    return deriveProjectIdentity(this.project?.title ?? '').monogram;
  }

  private monogramColor(): string {
    const icon = this.project?.projectIcon;
    if (icon?.kind === 'monogram' && isProjectColor(icon.color)) {
      return icon.color ?? 'gray';
    }
    return deriveProjectIdentity(this.project?.title ?? '').color;
  }

  @Builder
  monogram() {
    Text(this.monogramText())
      .fontSize(Math.round(this.badgeSize * (this.monogramText().length > 1 ? 0.46 : 0.56)))
      .fontWeight(FontWeight.Bold)
      .fontFamily('monospace')
      .fontColor(this.hexOf(this.monogramColor()))
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .width(this.badgeSize)
      .height(this.badgeSize)
      .borderRadius(Math.round(this.badgeSize * 0.25))
      // The desktop tints the tile with 14% of the icon color.
      .backgroundColor(`#24${this.hexOf(this.monogramColor()).substring(1)}`)
  }

  build() {
    Stack() {
      if (this.kind() === 'lucide') {
        Image(this.lucideSrc())
          .width(Math.round(this.badgeSize * 0.86))
          .height(Math.round(this.badgeSize * 0.86))
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else if (this.kind() === 'emoji') {
        Text(this.project?.projectIcon?.emoji ?? '')
          .fontSize(Math.round(this.badgeSize * 0.78))
          .textAlign(TextAlign.Center)
      } else if (this.kind() === 'favicon' && this.project !== null) {
        Image(projectIcons.faviconUri(this.project))
          .width(this.badgeSize)
          .height(this.badgeSize)
          .objectFit(ImageFit.Contain)
          .borderRadius(Math.round(this.badgeSize * 0.2))
          .draggable(false)
          .onError(() => {
            if (this.project !== null) {
              projectIcons.markBroken(this.project);
            }
          })
      } else {
        this.monogram()
      }
    }
    .width(this.badgeSize)
    .height(this.badgeSize)
    .opacity(this.dim ? 0.5 : 1)
    .accessibilityText(this.project?.title ?? '')
  }
}

/**
 * Right edge of a thread row: what needs the reader (approval, a question, a failure), a live
 * timer while the agent works, otherwise just when it last moved.
 */
@ComponentV2
export struct ThreadTrailing {
  @Local app: AppState = appState;
  @Param thread: ThreadShell | null = null;
  @Local tick: number = Date.now();
  private timer: number = -1;

  aboutToAppear(): void {
    this.syncTimer();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  @Monitor('thread')
  onThread(): void {
    this.syncTimer();
  }

  private syncTimer(): void {
    const working = this.thread !== null && isWorking(this.thread) && !needsAttention(this.thread);
    if (working && this.timer < 0) {
      this.tick = Date.now();
      this.timer = setInterval(() => {
        this.tick = Date.now();
      }, 1000);
    } else if (!working) {
      this.stopTimer();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    if (this.thread !== null) {
      if (needsAttention(this.thread)) {
        Row({ space: 3 }) {
          SymbolGlyph((this.thread.pendingRuntimeRequest?.kind ?? '') === 'user_input'
            ? $r('sys.symbol.questionmark_circle') : $r('sys.symbol.exclamationmark_shield_fill'))
            .fontSize(Type.small)
            .fontColor([threadStatusColor(this.thread)])
          Text((this.thread.pendingRuntimeRequest?.kind ?? '') === 'user_input' ? '待回答' : '审批')
            .fontSize(Type.small)
            .fontWeight(FontWeight.Medium)
            .fontColor(threadStatusColor(this.thread))
        }
      } else if (this.thread.status === 'waiting') {
        // Waiting on something else (another thread, a background task), like the desktop's Waiting.
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.hourglass')).fontSize(Type.small).fontColor([$r('app.color.fg_secondary')])
          Text('等待').fontSize(Type.small).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg_secondary'))
        }
      } else if (isWorking(this.thread)) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.circle_dashed')).fontSize(Type.small).fontColor([$r('app.color.status_working')])
          Text(clockDuration(this.tick - parseTime(this.thread.latestUserMessageAt ?? this.thread.updatedAt)))
            .fontSize(Type.small)
            .fontWeight(FontWeight.Medium)
            .fontFeature('"tnum" on')
            .fontColor($r('app.color.status_working'))
        }
      } else if (this.thread.status === 'failed' && !isSettled(this.thread)) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.xmark_circle')).fontSize(Type.small).fontColor([$r('app.color.status_failed')])
          Text('失败').fontSize(Type.small).fontWeight(FontWeight.Medium).fontColor($r('app.color.status_failed'))
        }
      } else if (this.app.draftThreadIds.indexOf(this.thread.id) >= 0) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.pencil_line')).fontSize(Type.small).fontColor([$r('app.color.fg_secondary')])
          Text('草稿').fontSize(Type.small).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg_secondary'))
        }
        .id(`home.draft.${this.thread.id}`)
      } else if (isUnreadDone(this.thread)) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(Type.small).fontColor([$r('app.color.status_unread')])
          Text('完成').fontSize(Type.small).fontWeight(FontWeight.Medium).fontColor($r('app.color.status_unread'))
        }
      } else {
        Text(relativeTime(this.thread.latestVisibleMessage?.updatedAt ?? this.thread.updatedAt, this.app.now))
          .fontSize(Type.small)
          .fontFeature('"tnum" on')
          .fontColor($r('app.color.fg_tertiary'))
      }
    }
  }
}

/**
 * Plain header icon button like the system title-bar icons: a 40vp target with no fill. Callers
 * pull the row in by `Space.iconOverhang` so the glyph, not the target, lines up with the margin.
 */
@ComponentV2
export struct GlassIconButton {
  @Param symbol: Resource = $r('sys.symbol.plus');
  @Param buttonSize: number = Space.hit;
  @Param tint: ResourceColor = $r('app.color.fg');
  @Param filled: boolean = false;
  @Param label: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(this.symbol)
        .fontSize(this.filled ? Math.round(this.buttonSize * 0.46) : Space.icon)
        .fontColor([this.filled ? $r('app.color.prominent_fg') : this.tint])
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .backgroundColor(this.filled ? $r('app.color.prominent') : Color.Transparent)
    .accessibilityText(this.label)
    .onClick(() => this.onTap())
  }
}

/** The T3 Code brand in a title bar: the T3 wordmark, "Code" and the stage chip, as on iOS. */
@ComponentV2
export struct BrandTitle {
  @Param markHeight: number = 15;

  build() {
    Row({ space: 5 }) {
      Image($r('app.media.t3_wordmark'))
        .height(this.markHeight)
        .aspectRatio(94.3941 / 56.96)
        .fillColor($r('app.color.fg'))
        .objectFit(ImageFit.Contain)
      Text('Code')
        .fontSize(Math.round(this.markHeight * 1.4))
        .fontWeight(FontWeight.Medium)
        .letterSpacing(-0.5)
        .fontColor($r('app.color.fg_secondary'))
      Text('BETA')
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(0.9)
        .fontColor($r('app.color.fg_secondary'))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(8)
        .backgroundColor($r('app.color.chip_bg'))
        // Visible on the sidebar drawer too, where chip_bg is close to the background.
        .border({ width: 0.5, color: $r('app.color.border') })
        .margin({ left: 2 })
    }
    .id('brand.title')
    .accessibilityGroup(true)
    .accessibilityText('T3 Code')
  }
}

/** Section label followed by a hairline, like the official list shelves. */
@ComponentV2
export struct SectionHeader {
  @Param title: string = '';
  @Param count: number = 0;
  @Param inset: number = 16;
  @Param collapsible: boolean = false;
  @Param collapsed: boolean = false;
  @Event onToggle: () => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      Text(this.count > 0 ? `${this.title} ${this.count}` : this.title)
        .fontSize(Type.small)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg_tertiary'))
      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.border'))
        .layoutWeight(1)
      if (this.collapsible) {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([$r('app.color.fg_tertiary')])
          .rotate({ angle: this.collapsed ? -90 : 0 })
          .animation({ curve: SPRING })
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: this.inset, right: this.inset, top: 10 })
    .onClick(() => {
      if (this.collapsible) {
        this.onToggle();
      }
    })
  }
}

@ComponentV2
export struct Pill {
  @Param text: string = '';
  @Param color: ResourceColor = $r('app.color.fg_secondary');
  @Param bg: ResourceColor = $r('app.color.chip_bg');

  build() {
    Text(this.text)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.color)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(6)
      .backgroundColor(this.bg)
      .maxLines(1)
  }
}
