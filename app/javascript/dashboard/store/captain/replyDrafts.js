import CaptainReplyDrafts from 'dashboard/api/captain/replyDrafts';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainReplyDraft',
  API: CaptainReplyDrafts,
  getters: {
    getByConversationId: state => conversationId =>
      state.records.find(draft => draft.conversation_id === conversationId),
  },
  actions: mutations => ({
    // The index response has no pagination meta, so skip SET_META.
    get: async ({ commit }) => {
      commit(mutations.SET_UI_FLAG, { fetchingList: true });
      try {
        const response = await CaptainReplyDrafts.get();
        commit(mutations.SET, response.data.payload);
      } catch (error) {
        throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { fetchingList: false });
      }
    },

    upsert: ({ state, commit }, draft) => {
      const existing = state.records.find(
        record => record.conversation_id === draft.conversation_id
      );
      if (existing) commit(mutations.DELETE, existing.id);
      commit(mutations.ADD, draft);
    },

    removeByConversation: ({ state, commit }, conversationId) => {
      const existing = state.records.find(
        record => record.conversation_id === conversationId
      );
      if (existing) commit(mutations.DELETE, existing.id);
    },

    sendReply: async ({ commit }, { id, content }) => {
      commit(mutations.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainReplyDrafts.sendReply(id, content);
        commit(mutations.DELETE, id);
        return response.data;
      } catch (error) {
        return throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { updatingItem: false });
      }
    },
  }),
});
