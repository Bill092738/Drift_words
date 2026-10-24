import { seededRandom } from '../engine/motion.ts';

export type SceneKind = 'small' | 'desktop' | 'mobile';

export interface SceneInfo {
  label: string;
  count: number;
}

/** Object counts from the performance budgets in TECH_ROADMAP.md section 5.8. */
export const SCENES: Record<SceneKind, SceneInfo> = {
  small: { label: 'Small (50)', count: 50 },
  desktop: { label: 'Desktop stress (2000)', count: 2000 },
  mobile: { label: 'Phone stress (600)', count: 600 },
};

/** One in this many tiles moves continuously. */
export const MOVING_EVERY = 10;

export type TileMotion =
  | { kind: 'static' }
  | { kind: 'drift'; phase: number }
  | { kind: 'orbit'; center: { x: number; y: number }; radius: number; angle: number; speed: number };

export interface TileSpec {
  id: string;
  label: string;
  /** Home position (the orbit's starting point for orbiting tiles). */
  x: number;
  y: number;
  motion: TileMotion;
}

const SYLLABLES = ['dri', 'ft', 'wor', 'ra', 'lo', 'mi', 'san', 'tu', 'ne', 'qua', 'bel', 'ion'];
const CJK = ['漂流', '词语', '海', '光', '记忆'];

function makeWord(rand: () => number): string {
  if (rand() < 0.08) return CJK[Math.floor(rand() * CJK.length)]!;
  const n = 1 + Math.floor(rand() * 3);
  let s = '';
  for (let i = 0; i < n; i++) s += SYLLABLES[Math.floor(rand() * SYLLABLES.length)]!;
  return s;
}

/**
 * A deterministic scene: tiles scattered over a square whose side grows with
 * the count, a tenth of them moving, two thirds of those drifting and the rest
 * orbiting.
 */
export function generateScene(kind: SceneKind, seed = 7): TileSpec[] {
  const { count } = SCENES[kind];
  const rand = seededRandom(seed);
  const half = Math.sqrt(count) * 90;
  const specs: TileSpec[] = [];
  for (let i = 0; i < count; i++) {
    const label = makeWord(rand);
    const x = (rand() * 2 - 1) * half;
    const y = (rand() * 2 - 1) * half;
    let motion: TileMotion = { kind: 'static' };
    let home = { x, y };
    if (i % MOVING_EVERY === 0) {
      if ((i / MOVING_EVERY) % 3 === 2) {
        const radius = 50 + rand() * 70;
        const angle = rand() * Math.PI * 2;
        const speed = (0.4 + rand() * 0.6) * (rand() < 0.5 ? 1 : -1);
        motion = { kind: 'orbit', center: { x, y }, radius, angle, speed };
        home = { x: x + Math.cos(angle) * radius, y: y + Math.sin(angle) * radius };
      } else {
        motion = { kind: 'drift', phase: i };
      }
    }
    specs.push({ id: `w${i}`, label, x: home.x, y: home.y, motion });
  }
  return specs;
}
