<script setup lang="ts">
import type { Ticket } from '@/types';

const props = defineProps<{ ticket: Ticket }>();
const emit = defineEmits<{ addLabel: [label: string] }>();
</script>

<template>
  <article>
    <h2>{{ props.ticket.title }}</h2>
    <p class="description">{{ props.ticket.description }}</p>
    <button type="button" @click="emit('addLabel', 'triaged')">Mark as triaged</button>
  </article>
</template>
