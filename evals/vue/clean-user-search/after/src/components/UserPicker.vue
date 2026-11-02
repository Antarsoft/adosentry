<script setup lang="ts">
import { ref } from 'vue';
import { storeToRefs } from 'pinia';
import { useUserSearch } from '@/composables/useUserSearch';
import { useSelectionStore } from '@/stores/selection';

const query = ref('');
const { results, error } = useUserSearch(query);
const selection = useSelectionStore();
const { selectedIds } = storeToRefs(selection);
</script>

<template>
  <div>
    <label for="user-q">Find a user</label>
    <input id="user-q" v-model="query" />
    <p v-if="error" role="alert">{{ error }}</p>
    <ul>
      <li v-for="u in results" :key="u.id">
        <button type="button" :aria-pressed="selectedIds.includes(u.id)" @click="selection.toggle(u.id)">{{ u.name }}</button>
      </li>
    </ul>
  </div>
</template>
