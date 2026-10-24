import { Fragment, useMemo } from 'react';
import { type Block, type Inline, parseMarkdown } from './markdown.ts';

function InlineView({ inlines }: { inlines: readonly Inline[] }) {
  return (
    <>
      {inlines.map((x, i) => {
        switch (x.type) {
          case 'text':
            return <Fragment key={i}>{x.text}</Fragment>;
          case 'bold':
            return (
              <strong key={i}>
                <InlineView inlines={x.children} />
              </strong>
            );
          case 'italic':
            return (
              <em key={i}>
                <InlineView inlines={x.children} />
              </em>
            );
          case 'strike':
            return (
              <del key={i}>
                <InlineView inlines={x.children} />
              </del>
            );
          case 'link':
            return (
              <a key={i} href={x.url} target="_blank" rel="noopener noreferrer">
                {x.url}
              </a>
            );
        }
      })}
    </>
  );
}

function BlockView({ block }: { block: Block }) {
  switch (block.type) {
    case 'heading': {
      // The dialog's own title is the h2, so a document's top heading is an h3.
      const Tag = `h${block.level + 2}` as 'h3' | 'h4' | 'h5';
      return (
        <Tag>
          <InlineView inlines={block.children} />
        </Tag>
      );
    }
    case 'paragraph':
      return (
        <p>
          <InlineView inlines={block.children} />
        </p>
      );
    case 'code':
      return (
        <pre>
          <code>{block.text}</code>
        </pre>
      );
  }
}

/**
 * A document from the backend, drawn as React elements. The text is parsed,
 * never injected as HTML, so a title or a model's reply cannot add markup, and
 * only http and https addresses become links.
 */
export function MarkdownView({ text }: { text: string }) {
  const blocks = useMemo(() => parseMarkdown(text), [text]);
  return (
    <div className="markdown">
      {blocks.map((b, i) => (
        <BlockView key={i} block={b} />
      ))}
    </div>
  );
}
