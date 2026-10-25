import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { icons } from '../icons.tsx';

/**
 * The help button and its popover: how Driftwords works, and (as children)
 * the accessibility settings. It closes on Escape, on a click outside, and
 * returns focus to the button.
 */
export function HelpPopover({ children }: { children?: ReactNode }) {
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const id = useId();

  useEffect(() => {
    if (!open) return;
    panel.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        setOpen(false);
        button.current?.focus();
      }
    };
    const onDown = (e: PointerEvent) => {
      const t = e.target as Node;
      if (!panel.current?.contains(t) && !button.current?.contains(t)) setOpen(false);
    };
    window.addEventListener('keydown', onKey, true);
    window.addEventListener('pointerdown', onDown, true);
    return () => {
      window.removeEventListener('keydown', onKey, true);
      window.removeEventListener('pointerdown', onDown, true);
    };
  }, [open]);

  return (
    <div className="help">
      <button
        ref={button}
        type="button"
        className="icon-button"
        aria-label="Help and accessibility"
        title="Help and accessibility"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen((o) => !o)}
      >
        <icons.help />
      </button>
      {open && (
        <div ref={panel} id={id} className="help-panel material material-strong" role="dialog" aria-label="Help" tabIndex={-1}>
          <section>
            <h2>How it works</h2>
            <ol className="help-steps">
              <li>
                <strong>Pick a word</strong> that catches your eye. It grows a ring of related words.
              </li>
              <li>
                <strong>Keep picking.</strong> Your path becomes a tree; click an earlier word to go back.
              </li>
              <li>
                <strong>Sources land</strong> behind the words they explain. Click one to lift it, again to open it.
              </li>
              <li>
                <strong>Wrap up</strong> for a decision tree, a draft and a final document.
              </li>
            </ol>
            <p className="help-tip">
              Drag to pan, scroll or pinch to zoom. The slider sets how far new words jump.
            </p>
          </section>
          {children}
        </div>
      )}
    </div>
  );
}
