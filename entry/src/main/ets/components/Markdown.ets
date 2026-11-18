/**
 * Lightweight Markdown renderer for assistant messages: headings, paragraphs, lists, quotes,
 * fenced code, tables (monospace), and inline bold / italic / code / links.
 */

export class InlineSpan {
  text: string;
  bold: boolean = false;
  italic: boolean = false;
  code: boolean = false;
  link: string = '';

  constructor(text: string) {
    this.text = text;
  }
}

export class MdBlock {
  key: string;
  kind: string; // p | h | li | ol | quote | code | table | hr
  level: number = 0;
  marker: string = '';
  text: string = '';
  lang: string = '';
  spans: InlineSpan[] = [];

  constructor(key: string, kind: string) {
    this.key = key;
    this.kind = kind;
  }
}

export function parseInline(text: string): InlineSpan[] {
  const spans: InlineSpan[] = [];
  const pattern = /(`[^`]+`)|(\*\*[^*]+\*\*)|(__[^_]+__)|(\[[^\]]+\]\([^)]+\))|(\*[^*\s][^*]*\*)/g;
  let last = 0;
  let match: RegExpExecArray | null = pattern.exec(text);
  while (match !== null) {
    if (match.index > last) {
      spans.push(new InlineSpan(text.substring(last, match.index)));
    }
    const token = match[0];
    if (token.startsWith('`')) {
      const span = new InlineSpan(token.substring(1, token.length - 1));
      span.code = true;
      spans.push(span);
    } else if (token.startsWith('**') || token.startsWith('__')) {
      const span = new InlineSpan(token.substring(2, token.length - 2));
      span.bold = true;
      spans.push(span);
    } else if (token.startsWith('[')) {
      const close = token.indexOf('](');
      const span = new InlineSpan(token.substring(1, close));
      span.link = token.substring(close + 2, token.length - 1);
      spans.push(span);
    } else {
      const span = new InlineSpan(token.substring(1, token.length - 1));
      span.italic = true;
      spans.push(span);
    }
    last = match.index + token.length;
    match = pattern.exec(text);
  }
  if (last < text.length) {
    spans.push(new InlineSpan(text.substring(last)));
  }
  if (spans.length === 0) {
    spans.push(new InlineSpan(''));
  }
  return spans;
}

export function parseMarkdown(source: string): MdBlock[] {
  const lines = source.replace(/\r\n/g, '\n').split('\n');
  const blocks: MdBlock[] = [];
  let i = 0;
  let paragraph: string[] = [];
  const flushParagraph = (): void => {
    if (paragraph.length > 0) {
      const block = new MdBlock(`p${blocks.length}`, 'p');
      block.text = paragraph.join('\n');
      block.spans = parseInline(block.text);
      blocks.push(block);
      paragraph = [];
    }
  };
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      flushParagraph();
      const block = new MdBlock(`c${blocks.length}`, 'code');
      block.lang = trimmed.substring(3).trim();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.push(lines[i]);
        i++;
      }
      block.text = body.join('\n');
      blocks.push(block);
      i++;
      continue;
    }
    if (trimmed.length === 0) {
      flushParagraph();
      i++;
      continue;
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (heading !== null) {
      flushParagraph();
      const block = new MdBlock(`h${blocks.length}`, 'h');
      block.level = heading[1].length;
      block.text = heading[2];
      block.spans = parseInline(block.text);
      blocks.push(block);
      i++;
      continue;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      flushParagraph();
      blocks.push(new MdBlock(`r${blocks.length}`, 'hr'));
      i++;
      continue;
    }
    if (trimmed.startsWith('|')) {
      flushParagraph();
      const rows: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        const row = lines[i].trim();
        if (!/^\|?\s*:?-{2,}/.test(row)) {
          rows.push(row.replace(/^\|/, '').replace(/\|$/, '').split('|').map((c: string) => c.trim()).join('   '));
        }
        i++;
      }
      const block = new MdBlock(`t${blocks.length}`, 'table');
      block.text = rows.join('\n');
      blocks.push(block);
      continue;
    }
    const bullet = /^(\s*)[-*+]\s+(.*)$/.exec(line);
    const ordered = /^(\s*)(\d+)[.)]\s+(.*)$/.exec(line);
    if (bullet !== null || ordered !== null) {
      flushParagraph();
      const block = new MdBlock(`l${blocks.length}`, 'li');
      if (bullet !== null) {
        block.level = Math.floor(bullet[1].length / 2);
        block.marker = '•';
        block.text = bullet[2];
      } else if (ordered !== null) {
        block.level = Math.floor(ordered[1].length / 2);
        block.marker = `${ordered[2]}.`;
        block.text = ordered[3];
      }
      block.spans = parseInline(block.text);
      blocks.push(block);
      i++;
      continue;
    }
    if (trimmed.startsWith('>')) {
      flushParagraph();
      const quote: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        quote.push(lines[i].trim().replace(/^>\s?/, ''));
        i++;
      }
      const block = new MdBlock(`q${blocks.length}`, 'quote');
      block.text = quote.join('\n');
      block.spans = parseInline(block.text);
      blocks.push(block);
      continue;
    }
    paragraph.push(line);
    i++;
  }
  flushParagraph();
  return blocks;
}

@ComponentV2
export struct MarkdownView {
  @Param text: string = '';
  @Param fontSize: number = 16;
  @Param color: ResourceColor = $r('app.color.fg');
  @Local blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.blocks = parseMarkdown(this.text);
  }

  @Monitor('text')
  onTextChange(): void {
    this.blocks = parseMarkdown(this.text);
  }

  @Builder
  spansText(spans: InlineSpan[], size: number, weight: number | FontWeight) {
    Text() {
      ForEach(spans, (span: InlineSpan) => {
        if (span.code) {
          Span(span.text)
            .fontFamily('monospace')
            .fontSize(size - 2)
            .fontColor(this.color)
            .textBackgroundStyle({ color: $r('app.color.code_bg'), radius: 4 })
        } else if (span.link.length > 0) {
          Span(span.text)
            .fontSize(size)
            .fontColor($r('app.color.primary'))
            .decoration({ type: TextDecorationType.Underline, color: $r('app.color.primary') })
        } else {
          Span(span.text)
            .fontSize(size)
            .fontColor(this.color)
            .fontWeight(span.bold ? 600 : weight)
            .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
        }
      }, (span: InlineSpan, index: number) => `${index}:${span.text.length}`)
    }
    .lineHeight(size * 1.5)
    .copyOption(CopyOptions.LocalDevice)
  }

  build() {
    Column({ space: 8 }) {
      ForEach(this.blocks, (block: MdBlock) => {
        if (block.kind === 'p') {
          this.spansText(block.spans, this.fontSize, FontWeight.Normal)
        } else if (block.kind === 'h') {
          this.spansText(block.spans, block.level <= 1 ? this.fontSize + 3 : (block.level === 2 ? this.fontSize + 1 : this.fontSize), 600)
        } else if (block.kind === 'li') {
          Row({ space: 6 }) {
            Text(block.marker)
              .fontSize(this.fontSize)
              .fontColor($r('app.color.fg_secondary'))
              .lineHeight(this.fontSize * 1.5)
              .constraintSize({ minWidth: 14 })
            Column() {
              this.spansText(block.spans, this.fontSize, FontWeight.Normal)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          .padding({ left: block.level * 16 })
          .width('100%')
        } else if (block.kind === 'quote') {
          // A left border hugs the quote's own height; a 100%-tall divider stretched to the list height.
          Column() {
            this.spansText(block.spans, this.fontSize, FontWeight.Normal)
          }
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, top: 2, bottom: 2 })
          .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
          .width('100%')
        } else if (block.kind === 'code' || block.kind === 'table') {
          Column() {
            if (block.lang.length > 0) {
              Text(block.lang)
                .fontSize(11)
                .fontColor($r('app.color.fg_tertiary'))
                .padding({ left: 12, top: 8 })
            }
            Scroll() {
              Text(block.text)
                .fontFamily('monospace')
                .fontSize(12)
                .lineHeight(18)
                .fontColor(this.color)
                .copyOption(CopyOptions.LocalDevice)
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .align(Alignment.Start)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .backgroundColor($r('app.color.code_bg'))
          .borderRadius(10)
          .border({ width: 0.5, color: $r('app.color.border') })
        } else if (block.kind === 'hr') {
          Divider().color($r('app.color.border'))
        }
      }, (block: MdBlock) => `${block.key}:${block.text.length}`)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
