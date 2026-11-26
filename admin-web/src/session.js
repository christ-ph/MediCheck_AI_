import { createSession } from './session-core';
const key = 'medicheck.admin.session.v1';
export const session = createSession({
  get: async () => sessionStorage.getItem(key),
  set: async value => sessionStorage.setItem(key,value),
  remove: async () => sessionStorage.removeItem(key)
}, '/api/token/refresh/');
