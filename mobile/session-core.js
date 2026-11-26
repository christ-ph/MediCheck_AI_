// MediCheck: stockage de session et renouvellement JWT partagé.
export function createSession(storage, refreshUrl) {
  let current = null;
  let generation = 0;
  let refreshJob = null;
  let writes = Promise.resolve();
  let invalidHandler = null;
  function persist(value) {
    const job = writes.catch(() => {}).then(() => value ? storage.set(JSON.stringify(value)) : storage.remove());
    writes = job;
    return job;
  }
  async function restore() {
    await writes.catch(() => {});
    const raw = await storage.get();
    if (!raw) return null;
    let value;
    try { value = JSON.parse(raw); } catch { await clear(); return null; }
    if (typeof value?.access !== 'string' || !value.access || typeof value.refresh !== 'string' || !value.refresh) {
      await clear(); return null;
    }
    current = value;
    return current;
  }
  async function save(value) {
    if (!value?.access || !value?.refresh) throw new Error('Jetons JWT manquants.');
    const epoch = ++generation;
    const next = {access: value.access, refresh: value.refresh};
    await persist(next);
    if (epoch !== generation) throw httpError('Session modifiée.', 401);
    current = next;
    return current;
  }
  async function clear() {
    generation++;
    current = null;
    await persist(null);
  }
  async function invalidate() {
    const deletion = clear();
    invalidHandler?.();
    await deletion;
  }
  function httpError(message, status) {
    const e = new Error(message); e.status = status; return e;
  }
  async function renew(previous) {
    if (!current) throw httpError('Session terminée.', 401);
    if (current !== previous) return current;
    if (refreshJob?.previous === previous) return refreshJob.promise;
    const job = (async () => {
      const res = await fetch(refreshUrl, {method:'POST', headers:{Accept:'application/json','Content-Type':'application/json'}, body:JSON.stringify({refresh:previous.refresh})});
      const data = await res.json().catch(() => null);
      if (current !== previous) throw httpError('Session modifiée.', 401);
      if (res.status === 401 || res.status === 403 || res.status === 400) {
        await invalidate();
        throw httpError('Session expirée. Veuillez vous reconnecter.', 401);
      }
      if (!res.ok || !data?.access) throw httpError('Renouvellement indisponible. Réessayez.', res.status);
      const next = {access:data.access, refresh:data.refresh || previous.refresh};
      // Publish synchronously, then persist; a subsequent logout queues deletion.
      current = next;
      await persist(next);
      if (current !== next) throw httpError('Session modifiée.', 401);
      return next;
    })();
    refreshJob = {previous, promise:job};
    try { return await job; } finally { if (refreshJob?.promise === job) refreshJob = null; }
  }
  async function request(url, options={}, authenticated=false) {
    if (!authenticated) return fetch(url, options);
    const previous = current;
    const epoch = generation;
    if (!previous) throw httpError('Session terminée.', 401);
    const send = value => fetch(url, {...options, headers:{...options.headers, Authorization:`Bearer ${value.access}`}});
    let response = await send(previous);
    if (epoch !== generation) throw httpError('Session modifiée.', 401);
    if (response.status !== 401) return response;
    const next = await renew(previous);
    if (epoch !== generation) throw httpError('Session modifiée.', 401);
    response = await send(next);
    if (response.status === 401 && current === next) await invalidate();
    return response;
  }
  return {restore, save, clear, request, onInvalid(fn) { invalidHandler = fn; return () => { if (invalidHandler === fn) invalidHandler = null; }; }};
}
