// A small English association graph for the offline mock. It only has to
// make exploration feel plausible for a few levels; the real branch words
// come from the model pipeline (M2).

export const associations: Record<string, readonly string[]> = {
  tide: ['moon', 'ocean', 'rhythm', 'erosion', 'harbor', 'gravity', 'season', 'pull'],
  lantern: ['light', 'festival', 'paper', 'night', 'guide', 'flame', 'shadow', 'wish'],
  entropy: ['information', 'disorder', 'time', 'compression', 'decay', 'heat', 'chaos', 'probability'],
  orchard: ['apple', 'harvest', 'bee', 'season', 'blossom', 'cider', 'grafting', 'soil'],
  signal: ['noise', 'radio', 'meaning', 'pattern', 'wave', 'message', 'bandwidth', 'semaphore'],
  glacier: ['ice', 'climate', 'erosion', 'time', 'valley', 'meltwater', 'pressure', 'silence'],
  ritual: ['habit', 'ceremony', 'myth', 'repetition', 'community', 'meaning', 'season', 'mask'],
  velvet: ['texture', 'luxury', 'theater', 'darkness', 'touch', 'curtain', 'silk', 'revolution'],
  compass: ['north', 'magnet', 'navigation', 'direction', 'map', 'explorer', 'choice', 'needle'],
  fungus: ['network', 'decay', 'mycelium', 'symbiosis', 'forest', 'spore', 'fermentation', 'soil'],
  echo: ['sound', 'memory', 'canyon', 'repetition', 'myth', 'sonar', 'delay', 'feedback'],
  harbor: ['ship', 'shelter', 'trade', 'tide', 'lighthouse', 'migration', 'port', 'rest'],
  information: ['Shannon', 'noise', 'meaning', 'bits', 'DNA', 'attention', 'library', 'privacy', 'language'],
  noise: ['randomness', 'static', 'music', 'silence', 'dither', 'creativity', 'signal', 'city'],
  attention: ['focus', 'scarcity', 'transformer', 'mindfulness', 'economy', 'distraction', 'flow', 'curiosity'],
  flow: ['challenge', 'immersion', 'rhythm', 'timelessness', 'mastery', 'river', 'play', 'music'],
  music: ['rhythm', 'harmony', 'improvisation', 'memory', 'mathematics', 'dance', 'silence', 'emotion'],
  memory: ['forgetting', 'archive', 'nostalgia', 'neuron', 'story', 'echo', 'photograph', 'sleep'],
  time: ['clock', 'entropy', 'memory', 'season', 'rhythm', 'relativity', 'patience', 'history'],
  moon: ['gravity', 'phase', 'calendar', 'tide', 'night', 'Apollo', 'crater', 'werewolf'],
  ocean: ['tide', 'abyss', 'current', 'whale', 'storm', 'coral', 'salt', 'plankton'],
  network: ['mycelium', 'internet', 'graph', 'trust', 'neuron', 'city', 'trade', 'gossip'],
  creativity: ['play', 'boredom', 'accident', 'constraint', 'jazz', 'mutation', 'serendipity', 'curiosity'],
  curiosity: ['question', 'exploration', 'child', 'risk', 'science', 'wonder', 'cat', 'attention'],
  language: ['grammar', 'metaphor', 'translation', 'dialect', 'poetry', 'code', 'gesture', 'silence'],
  map: ['territory', 'navigation', 'border', 'scale', 'legend', 'compass', 'explorer', 'model'],
  light: ['shadow', 'photon', 'color', 'lantern', 'morning', 'lens', 'speed', 'plant'],
  decay: ['fungus', 'entropy', 'ruin', 'compost', 'memory', 'radioactivity', 'autumn', 'renewal'],
  pattern: ['rhythm', 'symmetry', 'fractal', 'habit', 'textile', 'prediction', 'music', 'noise'],
  silence: ['meditation', 'pause', 'music', 'snow', 'secret', 'library', 'listening', 'night'],
  play: ['game', 'child', 'improvisation', 'creativity', 'rules', 'theater', 'risk', 'learning'],
  city: ['network', 'noise', 'migration', 'architecture', 'night', 'market', 'transit', 'neighbor'],
  river: ['flow', 'delta', 'erosion', 'border', 'bridge', 'trade', 'myth', 'source'],
  rhythm: ['music', 'heartbeat', 'tide', 'poetry', 'dance', 'habit', 'season', 'clock'],
  habit: ['ritual', 'routine', 'brain', 'rhythm', 'discipline', 'addiction', 'pattern', 'morning'],
  myth: ['story', 'ritual', 'hero', 'echo', 'river', 'moon', 'origin', 'mask'],
  story: ['myth', 'memory', 'character', 'plot', 'campfire', 'language', 'identity', 'ending'],
  gravity: ['moon', 'orbit', 'weight', 'relativity', 'apple', 'falling', 'wave', 'tide'],
  bee: ['pollination', 'hive', 'dance', 'honey', 'orchard', 'swarm', 'flower', 'colony'],
  soil: ['fungus', 'roots', 'compost', 'farming', 'erosion', 'worm', 'carbon', 'orchard'],
};

/** Words for the initial cloud and for padding when the graph runs out. */
export const wordBank: readonly string[] = [
  ...new Set([
    'tide', 'lantern', 'entropy', 'orchard', 'signal', 'glacier', 'ritual', 'velvet', 'compass',
    'fungus', 'echo', 'harbor', 'mirror', 'thread', 'saffron', 'bridge', 'origami', 'comet',
    'labyrinth', 'archive', 'pendulum', 'moss', 'carnival', 'prism', 'migration', 'ember',
    ...Object.values(associations).flat(),
  ]),
];

/** Small seeded PRNG (mulberry32), so mock sessions are reproducible. */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function shuffle<T>(items: readonly T[], random: () => number): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [out[i], out[j]] = [out[j] as T, out[i] as T];
  }
  return out;
}

/**
 * Candidate branch words for `word`, nearest first. Low divergence stays with
 * direct associations; high divergence mixes in second-hop and random words.
 */
export function relatedWords(word: string, divergence: number, random: () => number): string[] {
  const direct = associations[word] ?? associations[word.toLowerCase()] ?? [];
  const secondHop = direct.flatMap((w) => associations[w] ?? []);
  const far = shuffle(wordBank, random);
  const nearShare = Math.round((1 - divergence) * 6);
  return [
    ...shuffle(direct, random).slice(0, Math.max(nearShare, direct.length === 0 ? 0 : 1)),
    ...shuffle(secondHop, random),
    ...shuffle(direct, random),
    ...far,
  ];
}
