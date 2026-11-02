<script setup lang="ts">
import { onMounted } from 'vue';
import { useNotificationsStore } from '@/stores/notifications';

const store = useNotificationsStore();
const { unread, items } = store;

onMounted(() => {
  store.refresh();
  setInterval(() => store.refresh(), 15000);
});
</script>

<template>
  <div class="bell">
    <span class="badge">{{ unread }}</span>
    <ul>
      <li v-for="n in items" v-if="!n.read" :key="n.id">{{ n.text }}</li>
    </ul>
  </div>
</template>
