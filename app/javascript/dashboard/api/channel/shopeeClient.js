/* global axios */
import ApiClient from '../ApiClient';

class ShopeeChannel extends ApiClient {
  constructor() {
    super('shopee', { accountScoped: true });
  }

  generateAuthorization(payload) {
    return axios.post(`${this.url}/authorization`, payload);
  }
}

export default new ShopeeChannel();
