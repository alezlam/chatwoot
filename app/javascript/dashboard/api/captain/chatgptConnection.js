/* global axios */
import ApiClient from '../ApiClient';

class CaptainChatgptConnection extends ApiClient {
  constructor() {
    super('captain/chatgpt_connection', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  connect() {
    return axios.post(this.url);
  }

  update(model) {
    return axios.patch(this.url, { model });
  }

  disconnect() {
    return axios.delete(this.url);
  }
}

export default new CaptainChatgptConnection();
