/* global axios */
import ApiClient from '../ApiClient';

class CaptainProducts extends ApiClient {
  constructor() {
    super('captain/assistants', { accountScoped: true });
  }

  get({ assistantId, page = 1, searchKey } = {}) {
    return axios.get(`${this.url}/${assistantId}/products`, {
      params: { page, searchKey },
    });
  }

  show({ assistantId, id }) {
    return axios.get(`${this.url}/${assistantId}/products/${id}`);
  }

  create({ assistantId, ...data } = {}) {
    return axios.post(`${this.url}/${assistantId}/products`, {
      product: data,
    });
  }

  update({ assistantId, id }, data = {}) {
    return axios.put(`${this.url}/${assistantId}/products/${id}`, {
      product: data,
    });
  }

  delete({ assistantId, id }) {
    return axios.delete(`${this.url}/${assistantId}/products/${id}`);
  }
}

export default new CaptainProducts();
