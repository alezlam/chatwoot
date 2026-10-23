<script setup>
import { computed, ref } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  conversationId: { type: Number, required: true },
});

const store = useStore();
const { t } = useI18n();

const getByConversationId = useMapGetter(
  'captainReplyDrafts/getByConversationId'
);

// Keys are `${id}:${updated_at}` so a newer version of the draft shows again.
const editedKeys = ref(new Set());
const isBusy = ref(false);

const draft = computed(() => getByConversationId.value(props.conversationId));
const isVisible = computed(
  () =>
    !!draft.value &&
    !editedKeys.value.has(`${draft.value.id}:${draft.value.updated_at}`)
);

const sendDraft = async () => {
  isBusy.value = true;
  try {
    await store.dispatch('captainReplyDrafts/sendReply', {
      id: draft.value.id,
      content: draft.value.content,
    });
  } catch {
    useAlert(t('CAPTAIN.REPLY_DRAFT.SEND_ERROR'));
  } finally {
    isBusy.value = false;
  }
};

const editDraft = () => {
  emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, draft.value.content);
  editedKeys.value = new Set(editedKeys.value).add(
    `${draft.value.id}:${draft.value.updated_at}`
  );
};

const discardDraft = async () => {
  isBusy.value = true;
  try {
    await store.dispatch('captainReplyDrafts/delete', draft.value.id);
  } catch {
    useAlert(t('CAPTAIN.REPLY_DRAFT.DISCARD_ERROR'));
  } finally {
    isBusy.value = false;
  }
};
</script>

<template>
  <div>
    <div
      v-if="isVisible"
      class="flex flex-col gap-2 p-3 mx-4 mb-2 border rounded-xl border-n-weak bg-n-alpha-1"
    >
      <div class="flex items-center gap-2 text-xs font-medium text-n-slate-11">
        <span>{{ $t('CAPTAIN.REPLY_DRAFT.LABEL') }}</span>
        <span v-if="draft.product_name" class="truncate text-n-slate-12">
          {{ draft.product_name }}
        </span>
      </div>
      <p class="m-0 text-sm whitespace-pre-wrap break-words text-n-slate-12">
        {{ draft.content }}
      </p>
      <div class="flex items-center justify-end gap-2">
        <Button
          sm
          ghost
          slate
          :label="$t('CAPTAIN.REPLY_DRAFT.DISCARD')"
          :disabled="isBusy"
          @click="discardDraft"
        />
        <Button
          sm
          faded
          slate
          :label="$t('CAPTAIN.REPLY_DRAFT.EDIT')"
          :disabled="isBusy"
          @click="editDraft"
        />
        <Button
          sm
          :label="$t('CAPTAIN.REPLY_DRAFT.SEND')"
          :disabled="isBusy"
          :is-loading="isBusy"
          @click="sendDraft"
        />
      </div>
    </div>
  </div>
</template>
