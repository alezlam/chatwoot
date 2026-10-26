<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { debounce } from '@chatwoot/utils';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import ProductCard from 'dashboard/components-next/captain/pageComponents/product/ProductCard.vue';
import CreateProductDialog from 'dashboard/components-next/captain/pageComponents/product/CreateProductDialog.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const { isAdmin } = useAdmin();

const uiFlags = useMapGetter('captainProducts/getUIFlags');
const products = useMapGetter('captainProducts/getRecords');
const isFetching = computed(() => uiFlags.value.fetchingList);
const assistantId = computed(() => Number(route.params.assistantId));

const searchQuery = ref('');
const createDialog = ref(null);
const pendingToggleIds = ref(new Set());

const sortedProducts = computed(() =>
  [...products.value].sort((a, b) => a.name.localeCompare(b.name))
);
const isEmpty = computed(
  () => !searchQuery.value && !isFetching.value && products.value.length === 0
);

const fetchProducts = async () => {
  try {
    await store.dispatch('captainProducts/get', {
      assistantId: assistantId.value,
      searchKey: searchQuery.value.trim() || undefined,
    });
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.PRODUCTS.LOAD_ERROR'));
  }
};

const onSearch = debounce(fetchProducts, 300, false);

const openProduct = productId => {
  router.push({
    name: 'captain_assistants_products_show',
    params: { ...route.params, productId },
  });
};

const toggleProduct = async ({ id, ...changes }) => {
  if (pendingToggleIds.value.has(id)) return;
  pendingToggleIds.value = new Set(pendingToggleIds.value).add(id);
  try {
    await store.dispatch('captainProducts/update', {
      id,
      assistantId: assistantId.value,
      ...changes,
    });
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.PRODUCTS.TOGGLE.ERROR_MESSAGE'));
  } finally {
    const next = new Set(pendingToggleIds.value);
    next.delete(id);
    pendingToggleIds.value = next;
  }
};

onMounted(fetchProducts);
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.PRODUCTS.TITLE')"
    :button-label="t('CAPTAIN.PRODUCTS.ADD_NEW')"
    :button-policy="['administrator']"
    :is-fetching="isFetching"
    :is-empty="isEmpty"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :show-know-more="false"
    :show-pagination-footer="false"
    @click="createDialog.dialogRef.open()"
  >
    <template #search>
      <div class="w-full max-w-[22.5rem] min-w-0">
        <Input
          v-model="searchQuery"
          :placeholder="t('CAPTAIN.PRODUCTS.SEARCH_PLACEHOLDER')"
          @input="onSearch"
        />
      </div>
    </template>
    <template #emptyState>
      <span class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.PRODUCTS.EMPTY_MESSAGE') }}
      </span>
    </template>
    <template #body>
      <span v-if="sortedProducts.length === 0" class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.PRODUCTS.SEARCH_EMPTY_MESSAGE') }}
      </span>
      <div v-else class="flex flex-col gap-2">
        <ProductCard
          v-for="product in sortedProducts"
          :key="product.id"
          :product="product"
          :can-edit="isAdmin"
          :is-updating="pendingToggleIds.has(product.id)"
          @open="openProduct"
          @toggle="toggleProduct"
        />
      </div>
    </template>
    <CreateProductDialog ref="createDialog" />
  </PageLayout>
</template>
