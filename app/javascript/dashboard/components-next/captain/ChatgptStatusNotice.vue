<script setup>
import { computed, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { isToday } from 'date-fns';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { messageStamp } from 'shared/helpers/timeHelper';
import ConversationApi from 'dashboard/api/inbox/conversation';

const props = defineProps({
  // When set, the notice shows only if this conversation's inbox has an assistant.
  conversationId: { type: Number, default: null },
});

const TICK_INTERVAL_MS = 60000;
// The notice re-reads the status on every mount (it remounts per conversation) and then on this interval.
const REFRESH_INTERVAL_MS = 5 * 60 * 1000;

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const { isAdmin } = useAdmin();

const connection = useMapGetter('captainChatgptConnection/getConnection');
const uiFlags = useMapGetter('captainChatgptConnection/getUIFlags');

const now = ref(Date.now());
const hasAssistant = ref(props.conversationId === null);
const assistantId = ref(route.params.assistantId || null);

const resetsAtMs = computed(() => {
  const value = connection.value.last_error.resets_at;
  if (!value) return null;
  const ms = typeof value === 'number' ? value * 1000 : Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
});

const isRateLimited = computed(
  () => resetsAtMs.value !== null && now.value <= resetsAtMs.value
);

// A connected row keeps last_error only when the last run failed (a successful run clears it).
// An expired usage limit is not a failure, so it does not count.
const isFailing = computed(() => {
  const { type } = connection.value.last_error;
  return (
    connection.value.status === 'connected' &&
    !!type &&
    type !== 'usage_limit' &&
    !isRateLimited.value
  );
});

const message = computed(() => {
  if (isRateLimited.value) {
    const format = isToday(resetsAtMs.value) ? 'h:mm a' : 'MMM d, h:mm a';
    return t('CAPTAIN.CHATGPT.NOTICE.RATE_LIMITED', {
      time: messageStamp(resetsAtMs.value / 1000, format),
    });
  }
  if (isFailing.value) {
    return t('CAPTAIN.CHATGPT.NOTICE.FAILING');
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

const settingsRoute = computed(() =>
  isFailing.value && assistantId.value
    ? {
        name: 'captain_assistants_settings_index',
        params: {
          accountId: route.params.accountId,
          assistantId: assistantId.value,
        },
      }
    : null
);

let tickTimer = null;
let refreshTimer = null;
const refresh = () => store.dispatch('captainChatgptConnection/refreshStatus');

// The connection API is admin-only; start once the role is known.
const start = async () => {
  if (tickTimer) return;
  tickTimer = setInterval(() => {
    now.value = Date.now();
  }, TICK_INTERVAL_MS);
  refresh();
  refreshTimer = setInterval(refresh, REFRESH_INTERVAL_MS);
  if (props.conversationId !== null) {
    try {
      const { data } = await ConversationApi.getInboxAssistant(
        props.conversationId
      );
      hasAssistant.value = !!data.assistant;
      assistantId.value = data.assistant?.id || null;
    } catch {
      hasAssistant.value = false;
    }
  }
};

watch(isAdmin, admin => admin && start(), { immediate: true });

onUnmounted(() => {
  clearInterval(tickTimer);
  clearInterval(refreshTimer);
});
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
      <router-link
        v-if="settingsRoute"
        :to="settingsRoute"
        class="ms-auto font-medium underline"
      >
        {{ t('CAPTAIN.CHATGPT.NOTICE.OPEN_SETTINGS') }}
      </router-link>
    </div>
  </div>
</template>
