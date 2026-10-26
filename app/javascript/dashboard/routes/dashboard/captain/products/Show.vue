<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const { isAdmin } = useAdmin();

const assistantId = computed(() => Number(route.params.assistantId));
const productId = computed(() => Number(route.params.productId));
const indexRoute = computed(() => ({
  name: 'captain_assistants_products_index',
  params: { accountId: route.params.accountId, assistantId: assistantId.value },
}));

const product = ref({});
const isFetching = ref(false);
const isSaving = ref(false);
const deleteDialog = ref(null);
const form = reactive({
  name: '',
  shopee_item_id: '',
  description: '',
  prompt: '',
  context: '',
  enabled: true,
  confirmed: false,
});

const defaultFor = key => (key === 'confirmed' ? false : '');

const canSave = computed(() => isAdmin.value && form.name.trim().length > 0);

const loadProduct = async () => {
  isFetching.value = true;
  try {
    product.value = await store.dispatch('captainProducts/show', {
      id: productId.value,
      assistantId: assistantId.value,
    });
    Object.keys(form).forEach(key => {
      form[key] =
        product.value[key] ?? (key === 'enabled' ? true : defaultFor(key));
    });
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.PRODUCTS.LOAD_ERROR'));
    router.replace(indexRoute.value);
  } finally {
    isFetching.value = false;
  }
};

const saveProduct = async () => {
  if (!canSave.value || isSaving.value) return;
  isSaving.value = true;
  try {
    await store.dispatch('captainProducts/update', {
      id: productId.value,
      assistantId: assistantId.value,
      ...form,
      name: form.name.trim(),
    });
    useAlert(t('CAPTAIN.PRODUCTS.UPDATE.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.PRODUCTS.UPDATE.ERROR_MESSAGE'));
  } finally {
    isSaving.value = false;
  }
};

watch(productId, loadProduct, { immediate: true });
</script>

<template>
  <PageLayout
    :header-title="product.name || t('CAPTAIN.PRODUCTS.TITLE')"
    :back-url="indexRoute"
    :is-fetching="isFetching"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :show-know-more="false"
    :show-pagination-footer="false"
  >
    <template #body>
      <form
        class="flex flex-col max-w-2xl gap-6 pb-8"
        @submit.prevent="saveProduct"
      >
        <Input
          v-model="form.name"
          :label="t('CAPTAIN.PRODUCTS.FORM.NAME.LABEL')"
          :placeholder="t('CAPTAIN.PRODUCTS.FORM.NAME.PLACEHOLDER')"
          :disabled="!isAdmin"
        />
        <Input
          v-model="form.shopee_item_id"
          :label="t('CAPTAIN.PRODUCTS.FORM.SHOPEE_ITEM_ID.LABEL')"
          :placeholder="t('CAPTAIN.PRODUCTS.FORM.SHOPEE_ITEM_ID.PLACEHOLDER')"
          :disabled="!isAdmin"
        />
        <TextArea
          v-model="form.description"
          :label="t('CAPTAIN.PRODUCTS.FORM.DESCRIPTION.LABEL')"
          :placeholder="t('CAPTAIN.PRODUCTS.FORM.DESCRIPTION.PLACEHOLDER')"
          :max-length="1000"
          :disabled="!isAdmin"
          auto-height
        />
        <TextArea
          v-model="form.prompt"
          :label="t('CAPTAIN.PRODUCTS.FORM.PROMPT.LABEL')"
          :placeholder="t('CAPTAIN.PRODUCTS.FORM.PROMPT.PLACEHOLDER')"
          :max-length="5000"
          :disabled="!isAdmin"
          auto-height
        />
        <TextArea
          v-model="form.context"
          :label="t('CAPTAIN.PRODUCTS.FORM.CONTEXT.LABEL')"
          :placeholder="t('CAPTAIN.PRODUCTS.FORM.CONTEXT.PLACEHOLDER')"
          :max-length="20000"
          :disabled="!isAdmin"
          auto-height
        />
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <Switch v-model="form.enabled" :disabled="!isAdmin" />
          {{ t('CAPTAIN.PRODUCTS.FORM.ENABLED') }}
        </label>
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <Switch v-model="form.confirmed" :disabled="!isAdmin" />
          {{ t('CAPTAIN.PRODUCTS.FORM.CONFIRMED') }}
        </label>
        <p v-if="!isAdmin" class="text-sm text-n-slate-11">
          {{ t('CAPTAIN.PRODUCTS.FORM.ADMIN_ONLY') }}
        </p>
        <div class="flex items-center gap-3">
          <Button
            type="submit"
            :label="t('CAPTAIN.PRODUCTS.FORM.SAVE')"
            :is-loading="isSaving"
            :disabled="!canSave || isSaving"
          />
          <Button
            type="button"
            variant="faded"
            color="ruby"
            :label="t('CAPTAIN.PRODUCTS.FORM.DELETE')"
            :disabled="!isAdmin"
            @click="deleteDialog.dialogRef.open()"
          />
        </div>
      </form>
      <DeleteDialog
        ref="deleteDialog"
        type="Products"
        translation-key="PRODUCTS"
        :entity="product"
        :delete-payload="{ id: productId, assistantId }"
        @delete-success="router.replace(indexRoute)"
      />
    </template>
  </PageLayout>
</template>
