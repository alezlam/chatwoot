<script setup>
import { computed, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { messageStamp } from 'shared/helpers/timeHelper';
import ConversationApi from 'dashboard/api/inbox/conversation';

const props = defineProps({
  // When set, the notice shows only if this conversation's inbox has an assistant.
  conversationId: { type: Number, default: null },
});

const TICK_INTERVAL_MS = 60000;

const { t } = useI18n();
const store = useStore();
const { isAdmin } = useAdmin();

const connection = useMapGetter('captainChatgptConnection/getConnection');
const uiFlags = useMapGetter('captainChatgptConnection/getUIFlags');

const now = ref(Date.now());
const hasAssistant = ref(props.conversationId === null);

const resetsAtMs = computed(() => {
  const value = connection.value.last_error.resets_at;
  if (!value) return null;
  const ms = typeof value === 'number' ? value * 1000 : Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
});

const isRateLimited = computed(
  () => resetsAtMs.value !== null && now.value <= resetsAtMs.value
);

const message = computed(() => {
  if (isRateLimited.value) {
    return t('CAPTAIN.CHATGPT.NOTICE.RATE_LIMITED', {
      time: messageStamp(resetsAtMs.value / 1000, 'h:mm a'),
    });
  }
  if (connection.value.status === 'pending') {
    return t('CAPTAIN.CHATGPT.NOTICE.PENDING');
  }
  if (connection.value.status === 'disconnected') {
    return t('CAPTAIN.CHATGPT.NOTICE.DISCONNECTED');
  }
  return '';
});

// The connection API is admin-only, so agents never see the notice.
const isVisible = computed(
  () =>
    isAdmin.value &&
    uiFlags.value.loaded &&
    hasAssistant.value &&
    !!message.value
);

let tickTimer = null;

// The connection API is admin-only; start once the role is known.
const start = async () => {
  if (tickTimer) return;
  tickTimer = setInterval(() => {
    now.value = Date.now();
  }, TICK_INTERVAL_MS);
  if (!uiFlags.value.loaded) {
    store.dispatch('captainChatgptConnection/refresh');
  }
  if (props.conversationId !== null) {
    try {
      const { data } = await ConversationApi.getInboxAssistant(
        props.conversationId
      );
      hasAssistant.value = !!data.assistant;
    } catch {
      hasAssistant.value = false;
    }
  }
};

watch(isAdmin, admin => admin && start(), { immediate: true });

onUnmounted(() => clearInterval(tickTimer));
</script>

<template>
  <div>
    <div
      v-if="isVisible"
      class="flex items-center gap-2 px-4 py-2 text-sm border rounded-lg border-n-amber-6 bg-n-amber-3 text-n-amber-11"
      data-testid="chatgpt-status-notice"
    >
      <span class="i-lucide-triangle-alert size-4 flex-shrink-0" />
      {{ message }}
    </div>
  </div>
</template>
