import { Graphics } from 'pixi.js';
import { createNoise2D } from 'simplex-noise';
import type { StoreApi } from 'zustand/vanilla';
import type { Engine, FrameInfo, Intent, Rect, Vec } from '../engine/api.ts';
import { springs } from '../engine/api.ts';
import type { Candidate, CandidateId, NodeId, SourceId } from '../protocol/index.ts';
import type { NodeState, SessionState, SourceState } from '../store/session.ts';
import type { SessionStore } from '../store/store.ts';
import { rng } from '../transport/wordbank.ts';
import { angleOf, cloudLayout, placeChild, placeSource, polar, RING_RADIUS, ringAngle } from './layout.ts';
import { SourceObject } from './SourceObject.ts';
import { onReducedMotionChange, reducedMotion, subscribePreferences } from '../a11y/preferences.ts';
import { readTheme, type DeskTheme } from './theme.ts';
import { WordTile } from './WordTile.ts';

/** Radians per second the ring of branch words turns. */
const ORBIT_SPEED = 0.07;
/** Ring slots assumed while branch words are still streaming in. */
const EXPECTED_RING = 6;
/** Visibility of words passed over: just now, one step ago; older ones vanish. */
const FADED_ALPHA = [0.3, 0.12] as const;
/** Visibility of the initial cloud after the first pick. */
const CLOUD_FADED_ALPHA = 0.16;
/** How far a passed-over word drifts away from the ring it left. */
const FADE_PUSH = 70;
/** Narrow screens start zoomed out so a whole ring fits. */
const NARROW_SCREEN_PX = 720;
const NARROW_ZOOM = 0.7;
const DRIFT_AMPLITUDE = 12;
const DRIFT_FREQUENCY = 0.06;
/** Seconds between sources that arrive in the same batch, so they land one by one. */
const SOURCE_STAGGER = 0.12;
/** The camera moves toward a focused source only this far, keeping the tree in view. */
const FOCUS_PULL = 0.6;
/** Focusing a source while zoomed out further than this zooms in to read it. */
const FOCUS_MIN_ZOOM = 0.8;

const candidateKey = (id: CandidateId) => `c${id}`;
const nodeKey = (id: NodeId) => `n${id}`;
const sourceKey = (id: SourceId) => `s${id}`;

/**
 * The word tree on the desk. It renders the session state through the engine
 * API and turns taps into commands. All state comes from the store; the scene
 * only owns positions and motion.
 */
export class DeskScene {
  private readonly engine: Engine;
  private readonly store: StoreApi<SessionStore>;
  private theme: DeskTheme = readTheme();
  private readonly noise = createNoise2D(rng(11));
  private readonly random = rng(5);

  private readonly cloud = new Map<CandidateId, WordTile>();
  private readonly nodes = new Map<NodeId, WordTile>();
  /** The orbiting ring of the node the user is growing from. */
  private ring = new Map<CandidateId, WordTile>();
  private ringOrder: CandidateId[] = [];
  private ringNode: NodeId | null = null;
  private ringPhase = 0;
  private ringSlots = EXPECTED_RING;
  /** Words passed over, with the generation (step) in which they were. */
  private faded: { tile: WordTile; generation: number }[] = [];
  private generation = 0;
  private readonly edges = new Graphics();
  /** World bounds of all edges, for the engine's culling. */
  private edgeBounds: Rect = { minX: 0, minY: 0, maxX: 0, maxY: 0 };
  private readonly sources = new Map<SourceId, SourceObject>();
  /** The source lifted toward the viewer; a second tap opens it. */
  private focusedSource: SourceId | null = null;
  /** Follows the system and app settings live; when set, nothing orbits or drifts. */
  private reducedMotion = reducedMotion();

  private readonly baseZoom: number;
  private prev: SessionState | null = null;
  private readonly disposers: (() => void)[] = [];

  constructor(engine: Engine, store: StoreApi<SessionStore>) {
    this.engine = engine;
    this.store = store;
    const screenWidth = (engine.camera.viewport.maxX - engine.camera.viewport.minX) * engine.camera.zoom;
    this.baseZoom = screenWidth < NARROW_SCREEN_PX ? NARROW_ZOOM : 1;
    engine.camera.glideTo(engine.camera.center, this.baseZoom);
    // Edges change shape every frame as nodes settle, so they count as moving.
    engine.add('edges', { id: 'edges', view: this.edges, bounds: () => this.edgeBounds, interactive: false, moving: true });
    this.disposers.push(
      engine.onFrame((f) => this.frame(f)),
      engine.onIntent((i) => this.intent(i)),
      store.subscribe((s) => this.sync(s.state)),
    );
    const scheme = window.matchMedia('(prefers-color-scheme: dark)');
    const retheme = () => {
      this.theme = readTheme();
      for (const t of this.allTiles()) t.setTheme(this.theme);
      for (const o of this.sources.values()) o.setTheme(this.theme);
    };
    scheme.addEventListener('change', retheme);
    this.disposers.push(() => scheme.removeEventListener('change', retheme));
    // High contrast and larger text change the theme tokens.
    this.disposers.push(subscribePreferences(retheme));
    this.disposers.push(
      onReducedMotionChange(() => {
        this.reducedMotion = reducedMotion();
      }),
    );
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') this.focusSource(null);
    };
    window.addEventListener('keydown', onKey);
    this.disposers.push(() => window.removeEventListener('keydown', onKey));
    this.sync(store.getState().state);
  }

  destroy(): void {
    this.disposers.forEach((d) => d());
    for (const t of this.allTiles()) {
      this.engine.remove(t.id);
      t.destroy();
    }
    for (const o of this.sources.values()) {
      this.engine.remove(o.id);
      o.destroy();
    }
    this.engine.remove('edges');
    this.edges.destroy();
  }

  // ---------------------------------------------------------------------------
  // State to scene

  private sync(s: SessionState): void {
    const prev = this.prev;
    this.prev = s;
    if (prev === s) return;

    if (s.cloud !== prev?.cloud && s.cloud.length > 0 && this.cloud.size === 0) this.spawnCloud(s.cloud, s.nodes.size > 0);

    const newNodes = [...s.nodes.values()].filter((n) => !this.nodes.has(n.id)).sort((a, b) => a.order - b.order);
    for (const node of newNodes) this.addNode(node);

    if (newNodes.length === 0 && s.current !== null && s.current !== this.ringNode) this.revisit(s.current);

    for (const node of s.nodes.values()) {
      const tile = this.nodes.get(node.id);
      if (tile === undefined) continue;
      if (node.revisited) tile.markRevisited();
      // Positions recorded earlier (after a reload, or by another client) win.
      const p = node.placement?.pos;
      if (p && (Math.abs(p.x - tile.target.x) > 0.5 || Math.abs(p.y - tile.target.y) > 0.5)) tile.moveTo(p);
    }

    if (this.ringNode !== null) {
      const streamed = s.streaming.get(this.ringNode) ?? [];
      const sealed = s.offers.get(this.ringNode);
      const sealedChanged = sealed !== undefined && sealed !== prev?.offers.get(this.ringNode);
      if (sealedChanged) {
        this.ringSlots = sealed.length;
        this.addCandidates(sealed, true);
      } else {
        this.addCandidates(streamed, false);
      }
    }

    // A source whose node was not on the desk yet is retried on later syncs.
    if (s.sources !== prev?.sources || this.sources.size < s.sources.size) this.syncSources(s);
  }

  private syncSources(s: SessionState): void {
    let batch = 0;
    for (const src of s.sources.values()) {
      const obj = this.sources.get(src.source.sourceId);
      if (obj === undefined) {
        if (this.addSource(src, batch)) batch++;
        continue;
      }
      // Placements recorded earlier (after a reload, or by another client) win.
      const p = src.placement;
      if (p && (Math.abs(p.pos.x - obj.target.x) > 0.5 || Math.abs(p.pos.y - obj.target.y) > 0.5 || p.angle !== obj.angle)) {
        obj.moveTo(p.pos, p.angle);
      }
    }
  }

  /**
   * Lands a new source behind the edge into its node. Returns false while that
   * node is not on the desk yet; the next sync tries again.
   */
  private addSource({ source, placement }: SourceState, batch: number): boolean {
    const nodeTile = this.nodes.get(source.node);
    if (nodeTile === undefined) return false;
    let pos: Vec;
    let angle: number;
    if (placement) {
      ({ pos, angle } = placement);
    } else {
      const parent = this.prev?.nodes.get(source.node)?.parent;
      const parentTile = parent == null ? undefined : this.nodes.get(parent);
      ({ pos, angle } = placeSource(
        nodeTile.target,
        parentTile?.target ?? null,
        [...this.nodes.values()].map((t) => t.target),
        [...this.sources.values()].map((o) => o.target),
        this.random,
      ));
    }
    const obj = new SourceObject(sourceKey(source.sourceId), source, pos, angle, this.theme, placement === null, this.reducedMotion);
    obj.appear(batch * SOURCE_STAGGER);
    this.sources.set(source.sourceId, obj);
    this.engine.add('sources', obj);
    if (placement === null) this.store.getState().send({ type: 'PlaceSource', sourceId: source.sourceId, pos, angle });
    return true;
  }

  /** Lifts one source toward the viewer (or none), putting any other back. */
  private focusSource(id: SourceId | null): void {
    if (id === this.focusedSource) return;
    const prev = this.focusedSource === null ? undefined : this.sources.get(this.focusedSource);
    if (prev) {
      prev.setFocused(false);
      this.engine.remove(prev.id);
      this.engine.add('sources', prev);
    }
    this.focusedSource = id;
    const next = id === null ? undefined : this.sources.get(id);
    if (next) {
      next.setFocused(true);
      // Above the words while it is lifted.
      this.engine.remove(next.id);
      this.engine.add('focus', next);
      const { center: c, zoom } = this.engine.camera;
      const t = next.target;
      if (zoom < FOCUS_MIN_ZOOM) this.engine.camera.glideTo(t, FOCUS_MIN_ZOOM);
      else this.engine.camera.glideTo({ x: c.x + (t.x - c.x) * FOCUS_PULL, y: c.y + (t.y - c.y) * FOCUS_PULL });
    }
  }

  /** Brings a source into view and focuses it (the sidebar's fallback list). */
  locateSource(id: SourceId): void {
    const obj = this.sources.get(id);
    if (obj === undefined) return;
    this.focusSource(null);
    this.focusSource(id);
    this.engine.camera.glideTo(obj.target);
  }

  private spawnCloud(candidates: readonly Candidate[], alreadyStarted: boolean): void {
    // Size the cloud for the zoom the camera is heading to, not the current one.
    const vp = this.engine.camera.viewport;
    const scale = this.engine.camera.zoom / this.baseZoom;
    const radius = Math.min(vp.maxX - vp.minX, vp.maxY - vp.minY) * scale * 0.36;
    const points = cloudLayout(candidates.length, this.engine.camera.center, radius, this.random);
    candidates.forEach((c, i) => {
      const tile = this.addTile(candidateKey(c.candidateId), c.word, alreadyStarted ? 'faded' : 'cloud', points[i] ?? { x: 0, y: 0 });
      tile.appear(0.05 + i * 0.06);
      this.cloud.set(c.candidateId, tile);
    });
  }

  private addNode(node: NodeState): void {
    const key = nodeKey(node.id);
    const parentTile = node.parent === null ? undefined : this.nodes.get(node.parent);
    const fromRing = node.fromCandidate === null ? undefined : this.ring.get(node.fromCandidate);
    const fromCloud = node.fromCandidate === null ? undefined : this.cloud.get(node.fromCandidate);
    const reused = fromRing ?? fromCloud;

    // Decide where the node lives.
    let pos: Vec;
    let placed = false;
    if (node.placement) {
      pos = node.placement.pos;
    } else if (parentTile === undefined) {
      pos = reused ? reused.position : this.engine.camera.center;
      placed = true;
    } else {
      const from = parentTile.target;
      const preferred = reused ? angleOf(from, reused.position) : this.growthAngle(node.parent);
      pos = placeChild(from, preferred, [...this.nodes.values()].map((t) => t.target)).pos;
      placed = true;
    }

    let tile: WordTile;
    if (reused) {
      // The picked word itself leaves the ring (or cloud) and becomes the node.
      if (fromRing) {
        this.ring.delete(node.fromCandidate as CandidateId);
        this.ringOrder = this.ringOrder.filter((id) => id !== node.fromCandidate);
      } else {
        this.cloud.delete(node.fromCandidate as CandidateId);
      }
      this.engine.remove(reused.id);
      // Registered as a static node, so the engine indexes it instead of
      // checking it every frame.
      reused.setVariant('node');
      tile = this.retag(reused, key);
      tile.drift.x = tile.drift.y = 0;
      tile.x.snap(reused.position.x);
      tile.y.snap(reused.position.y);
    } else {
      const start = parentTile ? parentTile.target : pos;
      tile = this.addTile(key, node.word, 'node', start);
      tile.appear(0.05);
    }
    tile.moveTo(pos, springs.smooth);

    this.nodes.get(this.ringNode ?? -1)?.setVariant('node');
    this.fadeRing();
    if (node.parent === null) {
      for (const t of this.cloud.values()) {
        t.setVariant('faded');
        t.dim(CLOUD_FADED_ALPHA);
      }
    }

    tile.setVariant('current');
    this.nodes.set(node.id, tile);
    this.startRing(node.id, node.parent === null ? this.random() * Math.PI * 2 : angleOf(parentTile?.target ?? pos, pos));
    this.engine.camera.glideTo(pos);

    if (placed) this.store.getState().send({ type: 'PlaceNode', node: node.id, pos, angle: 0 });
  }

  private revisit(nodeId: NodeId): void {
    const tile = this.nodes.get(nodeId);
    if (tile === undefined) return;
    this.nodes.get(this.ringNode ?? -1)?.setVariant('node');
    this.fadeRing();
    tile.setVariant('current');
    tile.markRevisited();
    const parent = this.prev?.nodes.get(nodeId)?.parent;
    this.startRing(nodeId, this.growthAngle(parent ?? null) + Math.PI / 2);
    this.engine.camera.glideTo(tile.target);
  }

  private startRing(nodeId: NodeId, phase: number): void {
    this.ringNode = nodeId;
    this.ring = new Map();
    this.ringOrder = [];
    this.ringSlots = EXPECTED_RING;
    this.ringPhase = phase;
  }

  private addCandidates(candidates: readonly Candidate[], sealed: boolean): void {
    const center = this.nodes.get(this.ringNode ?? -1)?.target;
    if (center === undefined) return;
    candidates.forEach((c, i) => {
      if (this.ring.has(c.candidateId)) return;
      const tile = this.addTile(candidateKey(c.candidateId), c.word, 'candidate', center);
      // A sealed ring that arrives all at once (a prefetch hit) grows in staggered.
      tile.appear(sealed ? i * 0.05 : 0);
      this.ring.set(c.candidateId, tile);
      this.ringOrder.push(c.candidateId);
    });
    if (sealed) {
      // Drop anything streamed that did not make the final ring.
      const keep = new Set(candidates.map((c) => c.candidateId));
      for (const id of this.ringOrder.filter((id) => !keep.has(id))) {
        const t = this.ring.get(id);
        if (t) this.fade(t);
        this.ring.delete(id);
      }
      this.ringOrder = this.ringOrder.filter((id) => keep.has(id));
    }
  }

  /** Passes over the current ring: one more generation of faded words. */
  private fadeRing(): void {
    this.generation++;
    for (const t of this.ring.values()) this.fade(t);
    this.ring = new Map();
    this.ringOrder = [];
    for (const f of this.faded) {
      const age = this.generation - f.generation;
      const alpha = FADED_ALPHA[age];
      if (alpha === undefined) f.tile.vanish();
      else f.tile.dim(alpha);
    }
  }

  private fade(tile: WordTile): void {
    tile.setVariant('faded');
    // Drift outward, away from the ring it belonged to.
    const center = this.nodes.get(this.ringNode ?? -1)?.target ?? tile.position;
    tile.moveTo(polar(tile.position, angleOf(center, tile.position), FADE_PUSH), springs.smooth);
    this.faded.push({ tile, generation: this.generation });
  }

  /** Direction a branch was growing in when it reached `nodeId`. */
  private growthAngle(nodeId: NodeId | null): number {
    if (nodeId === null) return this.random() * Math.PI * 2;
    const node = this.prev?.nodes.get(nodeId);
    const tile = this.nodes.get(nodeId);
    const parent = node?.parent == null ? undefined : this.nodes.get(node.parent);
    return tile && parent ? angleOf(parent.target, tile.target) : this.random() * Math.PI * 2;
  }

  // ---------------------------------------------------------------------------
  // Frame

  private frame({ dt, time }: FrameInfo): void {
    // With reduced motion the ring holds still and nothing drifts.
    if (!this.reducedMotion) this.ringPhase += ORBIT_SPEED * dt;
    const drift = this.reducedMotion ? 0 : 1;
    const center = this.nodes.get(this.ringNode ?? -1)?.target;
    if (center) {
      const n = Math.max(this.ringSlots, this.ringOrder.length);
      this.ringOrder.forEach((id, i) => {
        this.ring.get(id)?.moveTo(polar(center, ringAngle(i, n, this.ringPhase), RING_RADIUS), springs.smooth);
      });
    }

    for (const t of this.cloud.values()) this.applyDrift(t, time, drift);
    for (const f of this.faded) this.applyDrift(f.tile, time, 0.7 * drift);
    for (const t of this.allTiles()) {
      // Static tiles (nodes) live in the engine's spatial index: re-index them
      // while they fly to their place or change size, and once as they settle.
      const settling = !t.moving && t.animating;
      t.update(dt);
      if (settling) this.engine.moved(t.id);
    }
    for (const o of this.sources.values()) {
      const moving = o.moving;
      o.update(dt);
      // Re-index while it falls or changes size, and once more as it comes to rest.
      if (moving) this.engine.moved(o.id);
    }

    // Remove faded tiles that have vanished.
    const gone = this.faded.filter((f) => f.tile.gone);
    if (gone.length > 0) {
      this.faded = this.faded.filter((f) => !f.tile.gone);
      for (const { tile } of gone) {
        this.engine.remove(tile.id);
        tile.destroy();
      }
    }

    this.drawEdges();
  }

  private applyDrift(t: WordTile, time: number, amount: number): void {
    const f = time * DRIFT_FREQUENCY;
    t.drift.x = this.noise(t.noiseSeed, f) * DRIFT_AMPLITUDE * amount;
    t.drift.y = this.noise(t.noiseSeed + 50, f) * DRIFT_AMPLITUDE * amount;
    t.view.rotation = this.noise(t.noiseSeed + 100, f * 0.7) * 0.04 * amount;
  }

  private drawEdges(): void {
    const s = this.prev;
    const g = this.edges.clear();
    if (s === null) return;
    const box = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    // Edges on the path from the root to the current node are emphasized.
    const onPath = new Set<NodeId>();
    for (let id = s.current; id !== null; id = s.nodes.get(id)?.parent ?? null) onPath.add(id);

    for (const node of s.nodes.values()) {
      if (node.parent === null) continue;
      const a = this.nodes.get(node.parent)?.position;
      const b = this.nodes.get(node.id)?.position;
      if (!a || !b) continue;
      // A gentle curve: the control point is pushed sideways from the midpoint.
      const mx = (a.x + b.x) / 2;
      const my = (a.y + b.y) / 2;
      const k = 0.12;
      const cx = mx - (b.y - a.y) * k;
      const cy = my + (b.x - a.x) * k;
      const path = onPath.has(node.id);
      // The curve stays inside the triangle of its end and control points.
      box.minX = Math.min(box.minX, a.x, b.x, cx);
      box.minY = Math.min(box.minY, a.y, b.y, cy);
      box.maxX = Math.max(box.maxX, a.x, b.x, cx);
      box.maxY = Math.max(box.maxY, a.y, b.y, cy);
      g.moveTo(a.x, a.y)
        .quadraticCurveTo(cx, cy, b.x, b.y)
        .stroke({ width: path ? 2 : 1.25, color: path ? this.theme.accent : this.theme.muted, alpha: path ? 0.55 : 0.3 });
    }
    if (box.minX <= box.maxX) this.edgeBounds = box;
  }

  // ---------------------------------------------------------------------------
  // Input

  private intent(i: Intent): void {
    if (i.type === 'background') {
      this.focusSource(null);
      return;
    }
    const send = this.store.getState().send;
    const id = Number(i.id.slice(1));
    if (i.id.startsWith('s')) {
      // First tap lifts it, a second tap opens the original material. The
      // desk's own focus decides, not the intent type: focus also changes
      // through Escape and the sidebar, which the engine does not see.
      if (this.focusedSource === id) this.openSource(id);
      else this.focusSource(id);
      return;
    }
    // A repeated tap on a word (`open`) means the same as the first one.
    this.focusSource(null);
    if (i.id.startsWith('c')) {
      const tile = this.ring.get(id) ?? this.cloud.get(id);
      if (tile && tile.variant !== 'faded') send({ type: 'Pick', candidateId: id });
    } else if (i.id.startsWith('n') && id !== this.ringNode) {
      send({ type: 'Backtrack', node: id });
    }
  }

  private openSource(id: SourceId): void {
    const obj = this.sources.get(id);
    if (obj === undefined) return;
    this.focusSource(id);
    // Runs inside the tap's pointer handler, so popup blockers allow it.
    window.open(obj.source.url, '_blank', 'noopener,noreferrer');
  }

  // ---------------------------------------------------------------------------

  private addTile(id: string, word: string, variant: WordTile['variant'], at: Vec): WordTile {
    const tile = new WordTile(id, word, variant, at, this.theme);
    this.engine.add('words', tile);
    return tile;
  }

  /** Re-registers a tile under a new id (a candidate becoming a node). */
  private retag(tile: WordTile, id: string): WordTile {
    tile.id = id;
    this.engine.add('words', tile);
    return tile;
  }

  /** For tests and debugging: every tile with its screen position. */
  debugTiles(): { id: string; word: string; variant: WordTile['variant']; x: number; y: number }[] {
    return [...this.allTiles()].map((t) => {
      const p = this.engine.camera.worldToScreen(t.position);
      return { id: t.id, word: t.word, variant: t.variant, x: p.x, y: p.y };
    });
  }

  /** For tests and debugging: every source object with its screen position. */
  debugSources(): { id: string; kind: string; title: string; focused: boolean; x: number; y: number }[] {
    return [...this.sources.values()].map((o) => {
      const p = this.engine.camera.worldToScreen(o.position);
      return { id: o.id, kind: o.source.kind, title: o.source.title, focused: o.focused, x: p.x, y: p.y };
    });
  }

  private *allTiles(): Iterable<WordTile> {
    yield* this.cloud.values();
    yield* this.nodes.values();
    yield* this.ring.values();
    for (const f of this.faded) yield f.tile;
  }
}
