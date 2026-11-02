<script setup lang="ts">
import type { Ticket } from '@/types';

const props = defineProps<{ ticket: Ticket }>();

function markTriaged() {
  props.ticket.labels.push('triaged');
}
</script>

<template>
  <article>
    <h2>{{ props.ticket.title }}</h2>
    <div class="description" v-html="props.ticket.descriptionHtml"></div>
    <button type="button" @click="markTriaged">Mark as triaged</button>
  </article>
</template>
