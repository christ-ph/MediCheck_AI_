import { Platform } from 'react-native';
import * as SecureStore from 'expo-secure-store';
import { createSession } from './session-core';
const base = process.env.EXPO_PUBLIC_API_URL || (Platform.OS === 'android' ? 'http://10.0.2.2:8000' : 'http://localhost:8000');
const key = 'medicheck.mobile.session.v1';
const storage = Platform.OS === 'web' ? {
  get: async () => sessionStorage.getItem(key),
  set: async value => sessionStorage.setItem(key,value),
  remove: async () => sessionStorage.removeItem(key)
} : {
  get: () => SecureStore.getItemAsync(key),
  set: value => SecureStore.setItemAsync(key,value),
  remove: () => SecureStore.deleteItemAsync(key)
};
export const session = createSession(storage, base.replace(/\/+$/, '') + '/api/token/refresh/');
