import CaptainChatgptConnection from 'dashboard/api/captain/chatgptConnection';
import { throwErrorMessage } from 'dashboard/store/utils/api';

const SET_CONNECTION = 'SET_CAPTAIN_CHATGPT_CONNECTION';
const SET_UI_FLAG = 'SET_CAPTAIN_CHATGPT_CONNECTION_UI_FLAG';

const normalize = (data = {}) => ({
  status: 'disconnected',
  email: null,
  plan_type: null,
  model: null,
  user_code: null,
  verification_url: null,
  ...data,
  last_error: data.last_error || {},
  models: data.models || [],
});

export const state = {
  record: normalize(),
  uiFlags: { fetching: false, updating: false, loaded: false },
};

export const getters = {
  getConnection: $state => $state.record,
  getUIFlags: $state => $state.uiFlags,
};

export const mutations = {
  [SET_CONNECTION]($state, data) {
    $state.record = normalize(data);
    $state.uiFlags = { ...$state.uiFlags, loaded: true };
  },
  [SET_UI_FLAG]($state, data) {
    $state.uiFlags = { ...$state.uiFlags, ...data };
  },
};

const request = async (commit, flag, call) => {
  commit(SET_UI_FLAG, { [flag]: true });
  try {
    const response = await call();
    commit(SET_CONNECTION, response.data);
    return response.data;
  } catch (error) {
    // A failed connect still returns the status payload with last_error.
    if (error.response?.data?.status) {
      commit(SET_CONNECTION, error.response.data);
    }
    return throwErrorMessage(error);
  } finally {
    commit(SET_UI_FLAG, { [flag]: false });
  }
};

export const actions = {
  get: ({ commit }) =>
    request(commit, 'fetching', () => CaptainChatgptConnection.get()),
  connect: ({ commit }) =>
    request(commit, 'updating', () => CaptainChatgptConnection.connect()),
  update: ({ commit }, model) =>
    request(commit, 'updating', () => CaptainChatgptConnection.update(model)),
  disconnect: ({ commit }) =>
    request(commit, 'updating', () => CaptainChatgptConnection.disconnect()),
  // Silent refresh used by polling and the status notice; errors are ignored.
  refresh: async ({ commit }) => {
    try {
      const response = await CaptainChatgptConnection.get();
      commit(SET_CONNECTION, response.data);
    } catch {
      // Keep the previous state.
    }
  },
  // Status-only refresh for the status notice: keeps the model list the settings card loaded.
  refreshStatus: async ({ commit, state: $state }) => {
    try {
      const response = await CaptainChatgptConnection.getStatus();
      commit(SET_CONNECTION, {
        ...response.data,
        models: $state.record.models,
      });
    } catch {
      // Keep the previous state.
    }
  },
};

export default {
  namespaced: true,
  state,
  getters,
  mutations,
  actions,
};
