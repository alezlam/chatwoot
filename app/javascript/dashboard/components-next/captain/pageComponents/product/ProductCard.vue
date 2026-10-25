<script setup>
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';

defineProps({
  product: { type: Object, required: true },
  isUpdating: { type: Boolean, default: false },
  canEdit: { type: Boolean, default: false },
});

const emit = defineEmits(['open', 'toggle']);

const { t } = useI18n();
</script>

<template>
  <div
    class="flex items-center justify-between gap-4 px-4 py-3 border rounded-xl cursor-pointer border-n-weak bg-n-solid-2 hover:bg-n-alpha-2"
    @click="emit('open', product.id)"
  >
    <div class="flex flex-col min-w-0 gap-1">
      <span class="text-sm font-medium truncate text-n-slate-12">
        {{ product.name }}
      </span>
      <span class="text-sm truncate text-n-slate-11">
        {{ product.description }}
      </span>
    </div>
    <div class="flex items-center flex-shrink-0 gap-3" @click.stop>
      <span
        v-if="product.shopee_item_id"
        class="px-2 py-0.5 text-xs rounded-md bg-n-alpha-2 text-n-slate-11"
      >
        {{ t('CAPTAIN.PRODUCTS.SHOPEE_ITEM', { id: product.shopee_item_id }) }}
      </span>
      <label class="flex items-center gap-1.5 text-xs text-n-slate-11">
        <Switch
          :model-value="product.confirmed"
          :disabled="isUpdating || !canEdit"
          @update:model-value="
            emit('toggle', { id: product.id, confirmed: $event })
          "
        />
        {{ t('CAPTAIN.PRODUCTS.CONFIRMED_SHORT') }}
      </label>
      <Switch
        :model-value="product.enabled"
        :disabled="isUpdating || !canEdit"
        @update:model-value="
          emit('toggle', { id: product.id, enabled: $event })
        "
      />
    </div>
  </div>
</template>
