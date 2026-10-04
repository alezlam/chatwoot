<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { isPhoneE164OrEmpty } from 'shared/helpers/Validators';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();
const store = useStore();
const router = useRouter();
const uiFlags = useMapGetter('inboxes/getUIFlags');

const inboxName = ref('');
const phoneNumber = ref('');

const rules = computed(() => ({
  inboxName: { required },
  phoneNumber: { required, isPhoneE164OrEmpty },
}));
const v$ = useVuelidate(rules, { inboxName, phoneNumber });

const createChannel = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  try {
    const inbox = await store.dispatch('inboxes/createChannel', {
      name: inboxName.value.trim(),
      channel: {
        type: 'whatsapp',
        phone_number: phoneNumber.value,
        provider: 'baileys',
        provider_config: {},
      },
    });
    router.replace({
      name: 'settings_inboxes_add_agents',
      params: { page: 'new', inbox_id: inbox.id },
    });
  } catch (error) {
    useAlert(error.message || t('INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE'));
  }
};
</script>

<template>
  <form class="flex flex-col flex-wrap mx-0" @submit.prevent="createChannel">
    <Banner color="amber" class="mb-6">
      {{ $t('INBOX_MGMT.ADD.WHATSAPP.BAILEYS.WARNING') }}
    </Banner>

    <div class="flex-grow-0 flex-shrink-0">
      <label :class="{ error: v$.inboxName.$error }">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.INBOX_NAME.LABEL') }}
        <input
          v-model="inboxName"
          type="text"
          :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.INBOX_NAME.PLACEHOLDER')"
          @blur="v$.inboxName.$touch"
        />
        <span v-if="v$.inboxName.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.INBOX_NAME.ERROR') }}
        </span>
      </label>
    </div>

    <div class="flex-grow-0 flex-shrink-0">
      <label :class="{ error: v$.phoneNumber.$error }">
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.PHONE_NUMBER.LABEL') }}
        <input
          v-model="phoneNumber"
          type="text"
          :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.PHONE_NUMBER.PLACEHOLDER')"
          @blur="v$.phoneNumber.$touch"
        />
        <span v-if="v$.phoneNumber.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.PHONE_NUMBER.ERROR') }}
        </span>
      </label>
    </div>

    <div class="w-full">
      <NextButton
        type="submit"
        :label="$t('INBOX_MGMT.ADD.WHATSAPP.SUBMIT_BUTTON')"
        :is-loading="uiFlags.isCreating"
      />
    </div>
  </form>
</template>
