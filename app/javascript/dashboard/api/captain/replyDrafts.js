/* global axios */
import ApiClient from '../ApiClient';

class CaptainReplyDrafts extends ApiClient {
  constructor() {
    super('captain/reply_drafts', { accountScoped: true });
  }

  sendReply(id, content) {
    return axios.post(`${this.url}/${id}/send_reply`, { content });
  }
}

export default new CaptainReplyDrafts();
