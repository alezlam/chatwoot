<script setup>
import { ref, reactive, computed } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();

const dialogRef = ref(null);
const isCreating = ref(false);
const state = reactive({ name: '', description: '' });

const canSubmit = computed(() => state.name.trim().length > 0);

const reset = () => {
  state.name = '';
  state.description = '';
};

const handleSubmit = async () => {
  if (!canSubmit.value || isCreating.value) return;
  isCreating.value = true;
  try {
    const product = await store.dispatch('captainProducts/create', {
      assistantId: route.params.assistantId,
      name: state.name.trim(),
      description: state.description,
    });
    useAlert(t('CAPTAIN.PRODUCTS.CREATE.SUCCESS_MESSAGE'));
    dialogRef.value.close();
    router.push({
      name: 'captain_assistants_products_show',
      params: { ...route.params, productId: product.id },
    });
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.PRODUCTS.CREATE.ERROR_MESSAGE'));
  } finally {
    isCreating.value = false;
  }
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="t('CAPTAIN.PRODUCTS.CREATE.TITLE')"
    :description="t('CAPTAIN.PRODUCTS.CREATE.DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="reset"
  >
    <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
      <Input
        v-model="state.name"
        :label="t('CAPTAIN.PRODUCTS.FORM.NAME.LABEL')"
        :placeholder="t('CAPTAIN.PRODUCTS.FORM.NAME.PLACEHOLDER')"
      />
      <TextArea
        v-model="state.description"
        :label="t('CAPTAIN.PRODUCTS.FORM.DESCRIPTION.LABEL')"
        :placeholder="t('CAPTAIN.PRODUCTS.FORM.DESCRIPTION.PLACEHOLDER')"
        :max-length="1000"
        auto-height
      />
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          type="button"
          variant="faded"
          color="slate"
          :label="t('CAPTAIN.PRODUCTS.CREATE.CANCEL')"
          class="w-full bg-n-alpha-3 hover:bg-n-alpha-4 text-n-slate-11"
          @click="dialogRef.close()"
        />
        <Button
          type="submit"
          :label="t('CAPTAIN.PRODUCTS.CREATE.SUBMIT')"
          class="w-full"
          :is-loading="isCreating"
          :disabled="!canSubmit || isCreating"
        />
      </div>
    </form>
    <template #footer />
  </Dialog>
</template>
