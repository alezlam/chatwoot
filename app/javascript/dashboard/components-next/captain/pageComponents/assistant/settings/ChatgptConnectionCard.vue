<script setup>
import { computed, onMounted, onUnmounted, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const POLL_INTERVAL_MS = 5000;

const { t } = useI18n();
const store = useStore();

const connection = useMapGetter('captainChatgptConnection/getConnection');
const uiFlags = useMapGetter('captainChatgptConnection/getUIFlags');

const status = computed(() => connection.value.status);
const isPending = computed(() => status.value === 'pending');
const isConnected = computed(() => status.value === 'connected');
const isBusy = computed(() => uiFlags.value.updating);

const defaultModel = computed(() =>
  connection.value.model ? '' : connection.value.models[0] || ''
);

const errorMessages = computed(() => ({
  device_login_disabled: t('CAPTAIN.CHATGPT.ERRORS.DEVICE_LOGIN_DISABLED'),
  device_code_expired: t('CAPTAIN.CHATGPT.ERRORS.DEVICE_CODE_EXPIRED'),
  device_code_failed: t('CAPTAIN.CHATGPT.ERRORS.DEVICE_CODE_FAILED'),
  usage_limit: t('CAPTAIN.CHATGPT.ERRORS.USAGE_LIMIT'),
  unauthorized: t('CAPTAIN.CHATGPT.ERRORS.UNAUTHORIZED'),
  refresh_rejected: t('CAPTAIN.CHATGPT.ERRORS.REFRESH_REJECTED'),
  refresh_failed: t('CAPTAIN.CHATGPT.ERRORS.REFRESH_FAILED'),
  rate_limited: t('CAPTAIN.CHATGPT.ERRORS.RATE_LIMITED'),
  no_models: t('CAPTAIN.CHATGPT.ERRORS.NO_MODELS'),
}));

const errorText = computed(() => {
  const { type, message } = connection.value.last_error;
  if (!type && !message) return '';
  return errorMessages.value[type] || t('CAPTAIN.CHATGPT.ERRORS.GENERIC');
});

const connectedLabel = computed(() =>
  connection.value.plan_type
    ? t('CAPTAIN.CHATGPT.CONNECTED_AS_PLAN', {
        email: connection.value.email,
        plan: connection.value.plan_type,
      })
    : t('CAPTAIN.CHATGPT.CONNECTED_AS', { email: connection.value.email })
);

const run = async (action, payload, fallbackMessage) => {
  try {
    await store.dispatch(`captainChatgptConnection/${action}`, payload);
  } catch (error) {
    useAlert(error?.message || fallbackMessage);
  }
};

const connect = () =>
  run('connect', undefined, t('CAPTAIN.CHATGPT.CONNECT_ERROR'));
const disconnect = () =>
  run('disconnect', undefined, t('CAPTAIN.CHATGPT.UPDATE_ERROR'));
const changeModel = event =>
  run('update', event.target.value, t('CAPTAIN.CHATGPT.UPDATE_ERROR'));

let pollTimer = null;
const stopPolling = () => {
  clearInterval(pollTimer);
  pollTimer = null;
};

// Poll only while the device login is pending.
watch(
  isPending,
  pending => {
    stopPolling();
    if (pending) {
      pollTimer = setInterval(
        () => store.dispatch('captainChatgptConnection/refresh'),
        POLL_INTERVAL_MS
      );
    }
  },
  { immediate: true }
);

onMounted(() => run('get', undefined, t('CAPTAIN.CHATGPT.UPDATE_ERROR')));
onUnmounted(stopPolling);
</script>

<template>
  <div
    class="flex flex-col gap-4 p-4 border rounded-xl border-n-weak bg-n-solid-2"
  >
    <div class="flex flex-col gap-1">
      <h6 class="text-base font-medium text-n-slate-12">
        {{ t('CAPTAIN.CHATGPT.TITLE') }}
      </h6>
      <span class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.CHATGPT.DESCRIPTION') }}
      </span>
    </div>

    <div
      v-if="uiFlags.fetching && !uiFlags.loaded"
      class="flex items-center text-n-slate-11"
    >
      <Spinner />
    </div>

    <template v-else-if="isPending">
      <span class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.CHATGPT.PENDING_STEPS') }}
      </span>
      <span
        class="font-mono text-3xl font-semibold tracking-widest text-n-slate-12"
        data-testid="chatgpt-user-code"
      >
        {{ connection.user_code }}
      </span>
      <a
        :href="connection.verification_url"
        target="_blank"
        rel="noopener noreferrer"
        class="text-sm text-n-brand hover:underline w-fit"
      >
        {{ t('CAPTAIN.CHATGPT.OPEN_VERIFICATION') }}
      </a>
      <div class="flex items-center gap-2 text-sm text-n-slate-11">
        <Spinner :size="16" />
        {{ t('CAPTAIN.CHATGPT.WAITING') }}
      </div>
      <div>
        <Button
          variant="faded"
          color="slate"
          size="sm"
          :label="t('CAPTAIN.CHATGPT.DISCONNECT')"
          :disabled="isBusy"
          @click="disconnect"
        />
      </div>
    </template>

    <template v-else-if="isConnected">
      <span class="text-sm text-n-slate-12">{{ connectedLabel }}</span>
      <label class="flex flex-col gap-1 text-sm text-n-slate-11">
        {{ t('CAPTAIN.CHATGPT.MODEL') }}
        <select
          class="w-full max-w-xs !mb-0 !py-1 text-sm"
          :value="connection.model || ''"
          :disabled="isBusy || !connection.models.length"
          @change="changeModel"
        >
          <option v-if="!connection.model" value="" disabled>
            {{ defaultModel }}
          </option>
          <option
            v-for="model in connection.models"
            :key="model"
            :value="model"
          >
            {{ model }}
          </option>
        </select>
        <span v-if="defaultModel" class="text-xs">
          {{ t('CAPTAIN.CHATGPT.MODEL_DEFAULT', { model: defaultModel }) }}
        </span>
      </label>
      <span v-if="errorText" class="text-sm text-n-ruby-11">
        {{ errorText }}
      </span>
      <div>
        <Button
          variant="faded"
          color="ruby"
          size="sm"
          :label="t('CAPTAIN.CHATGPT.DISCONNECT')"
          :disabled="isBusy"
          @click="disconnect"
        />
      </div>
    </template>

    <template v-else>
      <span v-if="errorText" class="text-sm text-n-ruby-11">
        {{ errorText }}
      </span>
      <div>
        <Button
          size="sm"
          :label="t('CAPTAIN.CHATGPT.CONNECT')"
          :is-loading="isBusy"
          :disabled="isBusy"
          @click="connect"
        />
      </div>
    </template>
  </div>
</template>
