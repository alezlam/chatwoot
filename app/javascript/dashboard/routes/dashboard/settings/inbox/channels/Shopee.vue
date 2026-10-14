<script setup>
import { ref, onMounted } from 'vue';
import shopeeClient from 'dashboard/api/channel/shopeeClient';
import Button from 'dashboard/components-next/button/Button.vue';

const errorMessage = ref('');
const isRequestingAuthorization = ref(false);

onMounted(() => {
  errorMessage.value =
    new URLSearchParams(window.location.search).get('error_message') || '';
  // Drop the error from the URL so a reload lets the user try again.
  window.history.replaceState({}, document.title, window.location.pathname);
});

const requestAuthorization = async () => {
  isRequestingAuthorization.value = true;
  const {
    data: { url },
  } = await shopeeClient.generateAuthorization();
  window.location.href = url;
};
</script>

<template>
  <div class="h-full p-6 w-full max-w-full flex-shrink-0 flex-grow-0">
    <div
      class="flex flex-col items-center justify-center w-full px-8 py-10 text-center rounded-2xl outline outline-1 outline-n-weak"
    >
      <div class="flex flex-col items-center w-full max-w-2xl">
        <h6 class="text-2xl font-medium">
          {{ $t('INBOX_MGMT.ADD.SHOPEE.CONNECT_YOUR_SHOP') }}
        </h6>
        <p class="max-w-xl py-6 text-sm text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.SHOPEE.HELP') }}
        </p>
        <p v-if="errorMessage" class="max-w-xl pb-6 text-sm text-n-ruby-11">
          {{ $t('INBOX_MGMT.ADD.SHOPEE.ERROR_MESSAGE') }} {{ errorMessage }}
        </p>
        <Button
          lg
          icon="i-ri-shopping-bag-3-line"
          :disabled="isRequestingAuthorization"
          :is-loading="isRequestingAuthorization"
          :label="$t('INBOX_MGMT.ADD.SHOPEE.CONTINUE_WITH_SHOPEE')"
          @click="requestAuthorization()"
        />
      </div>
    </div>
  </div>
</template>
