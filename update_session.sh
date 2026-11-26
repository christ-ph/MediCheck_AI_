#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/Bureau/MediCheck}"
cd "$ROOT"
for f in mobile/App.js mobile/package.json admin-web/src/main.jsx backend/config/urls.py; do
  [[ -f "$f" ]] || { echo "Fichier manquant : $f" >&2; exit 1; }
done
for f in mobile/session.js mobile/session-core.js admin-web/src/session.js admin-web/src/session-core.js; do
  [[ ! -e "$f" ]] || { echo "Fichier déjà présent : $f. Arrêt pour ne rien écraser." >&2; exit 1; }
done
command -v python3 >/dev/null
command -v npx >/dev/null
grep -q 'api/token/refresh/' backend/config/urls.py || { echo 'Route JWT refresh introuvable dans config/urls.py.' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/patch.py" <<'MEDIPATCH'
from pathlib import Path
import sys
root=Path(sys.argv[1])
def replace(s, old, new):
    if s.count(old)!=1:
        raise SystemExit(f'Version inattendue : {old[:100]!r}. Appliquer d’abord update_professional.sh. Aucun fichier source modifié par ce patch.')
    return s.replace(old,new,1)
m=root/'mobile/App.js'; a=root/'admin-web/src/main.jsx'
x=m.read_text(); y=a.read_text()
x=replace(x,"import * as DocumentPicker from 'expo-document-picker';", "import * as DocumentPicker from 'expo-document-picker';\nimport { session } from './session';")
x=replace(x,'const response = await fetch(url, {','const response = await session.request(url, {')
x=replace(x,'    });\n    const raw = await response.text();','    }, Boolean(token));\n    const raw = await response.text();')
x=replace(x,'        throw new Error(result?.detail || JSON.stringify(result) || `HTTP ${response.status}`);','        const e = new Error(result?.detail || JSON.stringify(result) || `HTTP ${response.status}`);\n        e.status = response.status; throw e;')
x=replace(x,"    const [token, setToken] = useState('');", "    const [token, setToken] = useState('');\n    const [boot, setBoot] = useState('loading');\n    const [retryBoot, setRetryBoot] = useState(0);")
x=replace(x,"        setToken(result.access); setPassword(''); setQuery('');", "        await session.save(result);\n        setToken(result.access); setPassword(''); setQuery('');")
x=replace(x,"    useEffect(() => {\n        if (!token) return;",'''    useEffect(() => session.onInvalid(() => {
        resetSession();
        setError('Session expirée. Veuillez vous reconnecter.');
    }), []);

    useEffect(() => {
        let alive = true;
        setBoot('loading'); setError('');
        (async () => {
            try {
                const saved = await session.restore();
                if (!alive) return;
                if (!saved) { setBoot('ready'); return; }
                const info = await api('me', 'GET', null, saved.access);
                if (!alive) return;
                setUser(info.username || ''); setProfile(info); setToken(saved.access);
                try { await loadMedicines('', saved.access, 1); }
                catch (e) { if (alive) setError(e.message); }
                if (alive) setBoot('ready');
            } catch (e) {
                if (!alive) return;
                if (e.status === 401 || e.status === 403) {
                    await session.clear().catch(() => {});
                    resetSession(); setBoot('ready');
                    setError('Session expirée ou compte inaccessible.');
                } else { setError(e.message); setBoot('error'); }
            }
        })();
        return () => { alive = false; };
    }, [retryBoot]);

    useEffect(() => {
        if (!token) return;''')
x=replace(x,"    function logout() {\n        setToken(''); setCatalog(null); setQuery(''); setPassword('');\n        setMode('login'); setProfile(null); setApplication({}); setProof(null); changeScreen('catalog');\n    }",'''    function resetSession() {
        setToken(''); setCatalog(null); setQuery(''); setPassword(''); setUser(''); setEmail('');
        setMode('login'); setProfile(null); setApplication({}); setProof(null); changeScreen('catalog');
    }

    async function logout() {
        try { await session.clear(); resetSession(); }
        catch (e) { resetSession(); setError('Impossible de supprimer la session stockée. Vérifiez le stockage.'); }
    }''')
x=replace(x,'    return <ScrollView ref={scroll} contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">','''    if (boot !== 'ready') return <View style={[s.page, {justifyContent:'center', alignItems:'center'}]}>
        <Text style={s.brand}>MediCheck AI</Text>
        {boot === 'loading' ? <><ActivityIndicator size="large" color={c.primary}/><Text style={s.muted}>Restauration de la session…</Text></> : <>
            <Text style={s.errorText}>{error || 'Connexion au serveur indisponible.'}</Text>
            <Button title="Réessayer" onPress={() => setRetryBoot(n => n + 1)}/>
            <Button title="Se déconnecter" variant="danger" onPress={async () => { await logout(); setBoot('ready'); }}/>
        </>}
    </View>;
    return <ScrollView ref={scroll} contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">''')
y=replace(y,"import './style.css';","import './style.css';\nimport { session } from './session';")
y=replace(y,"const res = await fetch('/api/'+path,", "const res = await session.request('/api/'+path,")
y=replace(y,"...(data!==null?{body:JSON.stringify(data)}:{})});", "...(data!==null?{body:JSON.stringify(data)}:{})}, Boolean(token));")
y=replace(y,"  function logout(){T('');P('');D(null);Stats(null);S('overview');Q('');Search('');F('');Page(1);M('');E('');}\n  function fail(e){if(e.status===401||e.status===403){logout();E('Session expirée ou accès administrateur refusé.');}else E(e.message);}\n  async function login(e){e.preventDefault();B(true);E('');try{const j=await api('token/','','POST',{username,password});const info=await api('admin/overview/',j.access);Stats(info);P('');T(j.access);}catch(e){E(e.message);}finally{B(false);}}",'''  const [boot,Boot]=useState('loading'), [retryBoot,RetryBoot]=useState(0);
  function resetSession(){T('');P('');U('');D(null);Stats(null);S('overview');Q('');Search('');F('');Page(1);M('');E('');}
  async function logout(){try{await session.clear();resetSession();}catch(e){resetSession();E('Impossible de supprimer la session stockée.');}}
  function fail(e){if(e.status===401||e.status===403){logout().then(()=>E('Session expirée ou accès administrateur refusé.'));}else E(e.message);}
  async function login(e){e.preventDefault();B(true);E('');try{const j=await api('token/','','POST',{username,password});await session.save(j);const info=await api('admin/overview/',j.access);Stats(info);P('');T(j.access);}catch(e){await session.clear().catch(()=>{});E(e.message);}finally{B(false);}}
  useEffect(()=>session.onInvalid(()=>{resetSession();E('Session expirée. Veuillez vous reconnecter.');}),[]);
  useEffect(()=>{
    let alive=true;Boot('loading');E('');
    (async()=>{try{
      const saved=await session.restore();if(!alive)return;
      if(!saved){Boot('ready');return;}
      const info=await api('admin/overview/',saved.access);if(!alive)return;
      Stats(info);U(info.username||'');T(saved.access);Boot('ready');
    }catch(e){if(!alive)return;if(e.status===401||e.status===403){await session.clear().catch(()=>{});resetSession();Boot('ready');E('Session expirée ou accès administrateur refusé.');}else{E(e.message);Boot('error');}}})();
    return()=>{alive=false;};
  },[retryBoot]);''')
y=replace(y,'const res=await fetch(`/api/admin/professionals/${id}/proof/`,{headers:{Authorization:`Bearer ${token}`}});','const res=await session.request(`/api/admin/professionals/${id}/proof/`,{},true);')
y=replace(y,'  if(!token)return <main className="login">','''  if(boot!=='ready')return <main className="login"><div className="login-art"><div className="mark">M+</div><h1>MediCheck AI</h1><p>Portail administrateur</p></div><div className="login-form"><h1>{boot==='loading'?'Restauration de la session…':'Serveur indisponible'}</h1>{boot==='error'&&<><p role="alert">{error}</p><button onClick={()=>RetryBoot(n=>n+1)}>Réessayer</button><button className="secondary" onClick={async()=>{await logout();Boot('ready');}}>Se déconnecter</button></>}</div></main>;
  if(!token)return <main className="login">''')
# Prepare outputs before touching either source.
out=Path(sys.argv[2]); out.mkdir(parents=True,exist_ok=True)
(out/'App.js').write_text(x); (out/'main.jsx').write_text(y)
MEDIPATCH
cat > "$tmp/session-core.js" <<'MEDICORE'
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
MEDICORE
cat > "$tmp/mobile-session.js" <<'MEDIMOBILE'
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
MEDIMOBILE
cat > "$tmp/admin-session.js" <<'MEDIADMIN'
import { createSession } from './session-core';
const key = 'medicheck.admin.session.v1';
export const session = createSession({
  get: async () => sessionStorage.getItem(key),
  set: async value => sessionStorage.setItem(key,value),
  remove: async () => sessionStorage.removeItem(key)
}, '/api/token/refresh/');
MEDIADMIN
# Valider les deux patchs avant toute modification des sources.
python3 "$tmp/patch.py" "$PWD" "$tmp/output"
backup=".backup-session-$(date +%Y%m%d-%H%M%S)-$$"
for f in mobile/App.js mobile/package.json mobile/package-lock.json admin-web/src/main.jsx; do
  if [[ -f "$f" ]]; then mkdir -p "$backup/$(dirname "$f")"; cp -p "$f" "$backup/$f"; fi
done
printf 'Sauvegarde : %s\n' "$backup"
# Expo sélectionne une version de SecureStore compatible avec le SDK installé.
(cd mobile && npx expo install expo-secure-store)
cp "$tmp/session-core.js" mobile/session-core.js
cp "$tmp/mobile-session.js" mobile/session.js
cp "$tmp/session-core.js" admin-web/src/session-core.js
cp "$tmp/admin-session.js" admin-web/src/session.js
cp "$tmp/output/App.js" mobile/App.js
cp "$tmp/output/main.jsx" admin-web/src/main.jsx
printf '\nMise à jour terminée. Relancez Expo et Vite, puis connectez-vous une fois.\nAucune migration Django ni modification de la base de données.\n'
