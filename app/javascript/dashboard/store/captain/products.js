import CaptainProducts from 'dashboard/api/captain/products';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainProduct',
  API: CaptainProducts,
  actions: mutations => ({
    show: async ({ commit }, { id, assistantId }) => {
      commit(mutations.SET_UI_FLAG, { fetchingItem: true });
      try {
        const response = await CaptainProducts.show({ id, assistantId });
        commit(mutations.UPSERT, response.data);
        return response.data;
      } catch (error) {
        return throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { fetchingItem: false });
      }
    },

    update: async ({ commit }, { id, assistantId, ...updateObj }) => {
      commit(mutations.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainProducts.update(
          { id, assistantId },
          updateObj
        );
        commit(mutations.EDIT, response.data);
        commit(mutations.SET_UI_FLAG, { updatingItem: false });
        return response.data;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { updatingItem: false });
        return throwErrorMessage(error);
      }
    },

    delete: async ({ commit }, { id, assistantId }) => {
      commit(mutations.SET_UI_FLAG, { deletingItem: true });
      try {
        await CaptainProducts.delete({ id, assistantId });
        commit(mutations.DELETE, id);
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
        return id;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
        return throwErrorMessage(error);
      }
    },
  }),
});
