import { ref, watch, onWatcherCleanup, type Ref } from 'vue';

export type UserHit = { id: string; name: string };

export function useUserSearch(query: Ref<string>) {
  const results = ref<UserHit[]>([]);
  const error = ref<string | null>(null);

  watch(query, async (raw) => {
    const q = raw.trim();
    if (q.length < 2) {
      results.value = [];
      return;
    }
    const controller = new AbortController();
    onWatcherCleanup(() => controller.abort());
    try {
      const res = await fetch(`/api/users?q=${encodeURIComponent(q)}`, { signal: controller.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      results.value = await res.json();
      error.value = null;
    } catch (e) {
      if ((e as Error).name !== 'AbortError') error.value = 'Search is unavailable.';
    }
  });

  return { results, error };
}
