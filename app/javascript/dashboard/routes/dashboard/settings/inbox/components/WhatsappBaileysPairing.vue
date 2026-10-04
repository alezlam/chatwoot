<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useIntervalFn } from '@vueuse/core';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  inboxId: { type: [Number, String], required: true },
});

const POLL_INTERVAL = 3000;
const PENDING_STATUSES = ['connecting', 'qr'];

const { t } = useI18n();
const session = ref(null);
const isLoading = ref(false);

const status = computed(() => session.value?.status);
const isConnected = computed(() => status.value === 'connected');
const isPending = computed(() => PENDING_STATUSES.includes(status.value));
const isReconnecting = computed(
  () => status.value === 'disconnected' && Boolean(session.value?.phone_number)
);

const { pause, resume } = useIntervalFn(
  async () => {
    // eslint-disable-next-line no-use-before-define
    await fetchSession();
  },
  POLL_INTERVAL,
  { immediate: false }
);

const applySession = data => {
  session.value = data;
  if (PENDING_STATUSES.includes(data.status) || isReconnecting.value) resume();
  else pause();
};

const withErrorAlert = async request => {
  isLoading.value = true;
  try {
    const { data } = await request();
    return data;
  } catch {
    pause();
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.ERROR'));
    return null;
  } finally {
    isLoading.value = false;
  }
};

async function fetchSession() {
  const data = await withErrorAlert(() =>
    InboxesAPI.getWhatsappBaileysSession(props.inboxId)
  );
  if (data) applySession(data);
}

const startSession = async () => {
  const data = await withErrorAlert(() =>
    InboxesAPI.startWhatsappBaileysSession(props.inboxId)
  );
  if (data) applySession(data);
};

const unlink = async () => {
  const data = await withErrorAlert(() =>
    InboxesAPI.logoutWhatsappBaileysSession(props.inboxId)
  );
  if (data === null) return;
  useAlert(t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.UNLINK_SUCCESS'));
  await fetchSession();
};

onMounted(fetchSession);
</script>

<template>
  <div class="flex flex-col gap-4">
    <div>
      <h3 class="mb-1 text-base font-medium text-n-slate-12">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.TITLE') }}
      </h3>
      <p class="text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.WARNING') }}
      </p>
    </div>

    <div v-if="isConnected" class="flex items-center gap-4">
      <span class="text-sm font-medium text-n-teal-11">
        {{
          $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.CONNECTED', {
            phoneNumber: `+${session.phone_number}`,
          })
        }}
      </span>
      <Button
        :label="$t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.UNLINK')"
        color="ruby"
        variant="outline"
        size="sm"
        :is-loading="isLoading"
        @click="unlink"
      />
    </div>

    <p v-else-if="isReconnecting" class="text-sm text-n-slate-11">
      {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.RECONNECTING') }}
    </p>

    <div v-else-if="isPending" class="flex flex-col gap-3">
      <p class="text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.DESCRIPTION') }}
      </p>
      <img
        v-if="session.qr"
        :src="session.qr"
        alt=""
        class="size-64 rounded-lg border border-n-weak bg-white"
      />
      <p v-else class="text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.WAITING') }}
      </p>
    </div>

    <div v-else class="flex items-center gap-4">
      <p class="text-sm text-n-slate-11">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.DISCONNECTED') }}
      </p>
      <Button
        :label="$t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.PAIRING.GENERATE')"
        size="sm"
        :is-loading="isLoading"
        @click="startSession"
      />
    </div>
  </div>
</template>
