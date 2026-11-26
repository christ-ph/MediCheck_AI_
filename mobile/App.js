import React, { useRef, useState, useEffect } from 'react';
import {
    View, Text, TextInput, Pressable, Image, ScrollView, StyleSheet,
    useWindowDimensions, Platform, ActivityIndicator, Linking, KeyboardAvoidingView, Keyboard
} from 'react-native';
import { colors as c, radius } from './theme';
import Ionicons from '@expo/vector-icons/Ionicons';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import * as DocumentPicker from 'expo-document-picker';
import * as ImagePicker from 'expo-image-picker';
import { session } from './session';
import BillingPanel from './BillingPanel';
import ReviewPanel from './ReviewPanel';
import IntelligencePanel, {ReferenceDetails} from './IntelligencePanel';

const PAGE_SIZE = 20;
const applicationFields = [
    ['full_name', 'Nom et prénom(s)'], ['profession', 'Profession'],
    ['registration_number', 'Numéro professionnel / matricule'], ['issuer', 'Ordre ou organisme émetteur'],
    ['institution', 'Établissement de santé'], ['location', 'Ville et pays'], ['phone', 'Téléphone professionnel']
];
const statusLabels = {none: 'Aucun dossier déposé', incomplete: 'Ancienne demande : dossier complet requis', pending: 'Dossier en attente de validation', approved: 'Dossier accepté', rejected: 'Dossier refusé : vous pouvez corriger et soumettre à nouveau', revoked: 'Validation retirée : nouveau dossier possible'};
const base = process.env.EXPO_PUBLIC_API_URL ||
    (Platform.OS === 'android' ? 'http://10.0.2.2:8000' : 'http://localhost:8000');

// Construit une URL avec un seul slash final, avant les paramètres.
async function api(path, method = 'GET', data = null, token = null) {
    const [endpoint, ...params] = path.split('?');
    const query = params.join('?');
    const url = base.replace(/\/+$/, '') + '/api/' +
        endpoint.replace(/^\/+|\/+$/g, '') + '/' + (query ? '?' + query : '');
    const response = await session.request(url, {
        method,
        headers: {
            Accept: 'application/json',
            ...(data !== null && !(data instanceof FormData) ? { 'Content-Type': 'application/json' } : {}),
            ...(token ? { Authorization: `Bearer ${token}` } : {})
        },
        ...(data !== null ? { body: data instanceof FormData ? data : JSON.stringify(data) } : {})
    }, Boolean(token));
    const raw = await response.text();
    let result;
    try { result = raw ? JSON.parse(raw) : null; }
    catch { throw new Error(`Réponse non JSON du serveur (HTTP ${response.status}).`); }
    if (!response.ok) {
        const e = new Error(result?.detail || JSON.stringify(result) || `HTTP ${response.status}`);
        e.status = response.status; throw e;
    }
    return result;
}

function Field({ label, style, ...props }) {
    return <View style={{ gap: 6 }}>
        <Text style={s.label}>{label}</Text>
        <TextInput accessibilityLabel={label} style={[s.input, style]}
            placeholderTextColor={c.muted} {...props} />
    </View>;
}

function Button({ title, onPress, variant = 'primary', disabled = false }) {
    return <Pressable accessibilityRole="button" accessibilityState={{ disabled }}
        disabled={disabled} onPress={onPress}
        style={({ pressed }) => [s.button, {
            backgroundColor: c[variant], opacity: disabled ? 0.45 : pressed ? 0.8 : 1
        }]}>
        <Text style={[s.buttonText, {
            color: ['secondary', 'tertiary'].includes(variant) ? c.text : '#FFFFFF'
        }]}>{title}</Text>
    </Pressable>;
}

function AppContent() {
    const { width } = useWindowDimensions();
    const scroll = useRef(null);
    const pending = useRef(false);
    const [mode, setMode] = useState('login');
    const [user, setUser] = useState('');
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [profile, setProfile] = useState(null);
    const [application, setApplication] = useState({});
    const [proof, setProof] = useState(null);
    const [showApplication, setShowApplication] = useState(false);
    const canPropose = profile?.professional_verified === true;
    const [token, setToken] = useState('');
    const [boot, setBoot] = useState('loading');
    const [retryBoot, setRetryBoot] = useState(0);
    const [error, setError] = useState('');
    const [success, setSuccess] = useState('');
    const [busy, setBusy] = useState(false);
    const [screen, setScreen] = useState('catalog');
    const [searchOpen, setSearchOpen] = useState(false);
    const [pendingImage, setPendingImage] = useState(null);
    const recoveredImage = useRef(false);
    useEffect(() => {
        if (Platform.OS !== 'android' || boot !== 'ready' || recoveredImage.current) return;
        recoveredImage.current = true;
        if (!token) { ImagePicker.getPendingResultAsync().catch(() => {}); return; }
        let alive = true;
        ImagePicker.getPendingResultAsync().then(result => {
            if (alive && result && !result.canceled) { setPendingImage(result); setScreen('scanner'); }
        }).catch(() => {});
        return () => { alive = false; };
    }, [boot, token]);
    const [selectedMedicine, setSelectedMedicine] = useState(null);
    const [keyboardVisible, setKeyboardVisible] = useState(false);
    useEffect(() => {
        const a = Keyboard.addListener('keyboardDidShow', () => setKeyboardVisible(true));
        const b = Keyboard.addListener('keyboardDidHide', () => setKeyboardVisible(false));
        return () => { a.remove(); b.remove(); };
    }, []);
    useEffect(() => { scroll.current?.scrollTo({y:0,animated:false}); }, [screen, mode]);
    function switchMode(next) { setMode(next); setPassword(''); setError(''); setSuccess(''); }


    // Catalogue : query = saisie courante, activeQuery = recherche exécutée.
    const [query, setQuery] = useState('');
    const [catalog, setCatalog] = useState(null);
    const items = catalog?.results || [];
    const total = catalog?.count || 0;
    const page = catalog?.page || 1;
    const activeQuery = catalog?.query || '';
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

    const [name, setName] = useState('');
    const [details, setDetails] = useState('');
    const [source, setSource] = useState('');
    const [kind, setKind] = useState('expired');

    async function run(fn) {
        if (pending.current) return;
        pending.current = true;
        setBusy(true);
        setError('');
        setSuccess('');
        try { await fn(); }
        catch (e) { setError(e.message || 'Une erreur est survenue.'); }
        finally { pending.current = false; setBusy(false); }
    }

    // Pagination réelle côté serveur. Aucun téléchargement des 500 fiches.
    async function loadMedicines(search = '', accessToken = token, pageNumber = 1) {
        const cleanSearch = search.trim();
        const result = await api(
            `medicines?q=${encodeURIComponent(cleanSearch)}&page=${pageNumber}&page_size=${PAGE_SIZE}`,
            'GET', null, accessToken
        );
        if (!result || !Array.isArray(result.results) || !Number.isInteger(result.count) ||
            typeof result.next === 'undefined' || typeof result.previous === 'undefined') {
            throw new Error('Le backend doit activer MedicinePagination dans la vue Catalog.');
        }
        setCatalog({ ...result, page: pageNumber, query: cleanSearch });
        scroll.current?.scrollTo({ y: 0, animated: false });
    }

    async function auth() {
        if (!user.trim() || !password) throw new Error('Renseignez vos identifiants.');
        if (mode === 'register') {
            if (!email.trim()) throw new Error('Renseignez votre adresse email.');
            await api('register', 'POST', {
                username: user.trim(), email: email.trim(), password,
                professional_requested: false
            });
            setMode('login'); setPassword('');
            setSuccess('Compte créé. Vous pouvez vous connecter.');
            return;
        }
        const result = await api('token', 'POST', { username: user.trim(), password });
        await session.save(result);
        setToken(result.access); setPassword(''); setQuery('');
        setScreen('catalog'); setCatalog(null);
        await refreshProfile(result.access);
        await loadMedicines('', result.access, 1);
    }

    async function refreshProfile(accessToken = token) {
        const result = await api('me', 'GET', null, accessToken);
        setProfile(result);
        if (!result.professional_verified) setScreen(old => ['professional','proposal','validations','myproposals'].includes(old) ? 'catalog' : old);
        return result;
    }

    useEffect(() => session.onInvalid(() => {
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
        if (!token) return;
        let active = true;
        const timer = setInterval(async () => {
            try {
                const result = await api('me', 'GET', null, token);
                if (!active) return;
                setProfile(result);
                if (!result.professional_verified) setScreen(old => ['professional','proposal','validations','myproposals'].includes(old) ? 'catalog' : old);
            } catch { /* Le serveur contrôle toujours les droits. */ }
        }, 15000);
        return () => { active = false; clearInterval(timer); };
    }, [token]);

    async function pickProof() {
        const result = await DocumentPicker.getDocumentAsync({type: ['application/pdf', 'image/jpeg', 'image/png'], copyToCacheDirectory: true, multiple: false});
        if (result.canceled) return;
        const asset = result.assets[0];
        if (asset.size > 5 * 1024 * 1024) throw new Error('Justificatif limité à 5 Mo.');
        setProof(asset);
    }

    async function sendApplication() {
        const form = new FormData();
        for (const [key] of applicationFields) {
            const value = (application[key] || '').trim();
            if (!value) throw new Error('Tous les champs du dossier sont obligatoires.');
            form.append(key, value);
        }
        if (!proof) throw new Error('Ajoutez un justificatif professionnel.');
        if (Platform.OS === 'web') {
            const file = proof.file || await (await fetch(proof.uri)).blob();
            form.append('proof', file, proof.name);
        } else {
            form.append('proof', {uri: proof.uri, name: proof.name, type: proof.mimeType || 'application/octet-stream'});
        }
        const result = await api('professional/application', 'POST', form, token);
        setProfile(result); setShowApplication(false); setApplication({}); setProof(null);
        setSuccess('Dossier transmis à l’administration.');
    }

    function changeScreen(key) {
        if (['professional','proposal','validations','myproposals'].includes(key) && !canPropose) return;
        setSearchOpen(false); setSelectedMedicine(null);
        setShowApplication(false);
        setScreen(key); setName(''); setDetails(''); setSource(''); setKind('expired');
        setError(''); setSuccess('');
        scroll.current?.scrollTo({ y: 0, animated: false });
    }

    async function submitForm() {
        if (!name.trim() || !details.trim()) throw new Error('Remplissez les champs obligatoires.');
        if (screen === 'report') {
            await api('reports', 'POST', { medicine: name.trim(), kind, details: details.trim() }, token);
            setSuccess('Signalement enregistré avec succès.');
        } else {
            if (!(await refreshProfile()).professional_verified) throw new Error('Compte professionnel non validé.');
            if (!source.trim()) throw new Error('Renseignez une source officielle.');
            await api('proposals', 'POST', {
                name: name.trim(), description: details.trim(), source: source.trim()
            }, token);
            setSuccess('Proposition enregistrée. Retrouvez son état dans Mes propositions.');
            setScreen('myproposals');
        }
        setName(''); setDetails(''); setSource('');
    }

    function resetSession() {
        setToken(''); setCatalog(null); setQuery(''); setPassword(''); setUser(''); setEmail('');
        setMode('login'); setProfile(null); setPendingImage(null); setApplication({}); setProof(null); setSearchOpen(false); setSelectedMedicine(null); changeScreen('catalog');
    }

    async function logout() {
        try { await session.clear(); resetSession(); }
        catch (e) { resetSession(); setError('Impossible de supprimer la session stockée. Vérifiez le stockage.'); }
    }

    const messages = <>
        {!!error && <View style={s.errorBox}><Ionicons name="alert-circle-outline" size={20} color={c.danger}/><Text accessibilityRole="alert" style={s.errorText}>{error}</Text></View>}
        {!!success && <View style={s.successBox}><Ionicons name="checkmark-circle-outline" size={20} color={c.primary}/><Text accessibilityLiveRegion="polite" style={s.successText}>{success}</Text></View>}
    </>;
    const tabs = [
        ['catalog', 'Catalogue', 'grid-outline', 'grid'],
        ['scanner', 'Scanner', 'scan-outline', 'scan'],
        ['assistant', 'Assistant', 'chatbubble-ellipses-outline', 'chatbubble-ellipses'],
        ['report', 'Signaler', 'flag-outline', 'flag'],
        ...(canPropose ? [['professional', 'Pro', 'medkit-outline', 'medkit']] : [])
    ];
    const titles = {catalog:'Catalogue',detail:'Fiche médicament',report:'Signalement',proposal:'Nouvelle proposition',professional:'Espace professionnel',validations:'Validations',myproposals:'Mes propositions',notifications:'Notifications',scanner:'Scanner',assistant:'Assistant IA',account:'Mon compte',billing:'Abonnements et points'};
    const current = ['proposal','validations','myproposals'].includes(screen) ? 'professional' : screen === 'detail' ? 'catalog' : screen;
    const unread = Math.max(0, Number(profile?.notification_unread ?? profile?.review_unread) || 0);
    const wide = width >= 760;
    const searchNow = (value = query) => {
        Keyboard.dismiss();
        setSearchOpen(false);
        changeScreen('catalog');
        run(() => loadMedicines(value, token, 1));
    };
    const pager = total > 0 && <View style={s.pagination}>
        <Text style={s.mutedCenter}>{(page - 1) * PAGE_SIZE + 1}–{Math.min(page * PAGE_SIZE, total)} sur {total}</Text>
        <View style={s.paginationControls}>
            <IconAction icon="chevron-back" label="Page précédente" disabled={busy || !catalog?.previous} onPress={() => run(() => loadMedicines(activeQuery, token, page - 1))}/>
            <Text style={s.pageNumber}>{page} / {totalPages}</Text>
            <IconAction icon="chevron-forward" label="Page suivante" disabled={busy || !catalog?.next} onPress={() => run(() => loadMedicines(activeQuery, token, page + 1))}/>
        </View>
    </View>;
    const linkSource = medicine => !!medicine.source && <Pressable accessibilityRole="link" style={s.sourceBox} onPress={() => {
        if (/^https?:\/\//i.test(medicine.source)) Linking.openURL(medicine.source).catch(() => setError('Impossible d’ouvrir la source.'));
    }}><Ionicons name="open-outline" color={c.primary} size={20}/><Text style={s.source} numberOfLines={3}>Consulter la source officielle</Text></Pressable>;

    if (boot !== 'ready') return <SafeAreaView style={s.shell}><View style={s.boot}>
        <Text style={s.brand}>MediCheck<Text style={{color:c.tertiary}}> AI</Text></Text>
        {boot === 'loading' ? <><ActivityIndicator size="large" color={c.primary}/><Text style={s.muted}>Restauration de la session…</Text></> : <>
            <Text style={s.errorText}>{error || 'Connexion au serveur indisponible.'}</Text>
            <Button title="Réessayer" onPress={() => setRetryBoot(n => n + 1)}/>
            <Button title="Se déconnecter" variant="danger" onPress={async () => { await logout(); setBoot('ready'); }}/>
        </>}
    </View></SafeAreaView>;

    return <SafeAreaView style={s.shell} edges={['top','left','right','bottom']}>
        <KeyboardAvoidingView style={s.flex} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
            <View style={s.header}>
                <View style={s.headerInner}>
                    <Pressable accessibilityRole="button" accessibilityLabel="Accueil MediCheck" style={s.brandRow} disabled={busy} onPress={() => token ? changeScreen('catalog') : switchMode('login')}>
                        {(!token || width >= 390) && <View style={s.logo}><Ionicons name="medical" size={19} color="#fff"/></View>}
                        <View style={{minWidth:0,flexShrink:1}}><Text style={[s.brand,width < 350 && {fontSize:16}]} numberOfLines={1}>MediCheck<Text style={{color:c.tertiary}}> AI</Text></Text>{wide && <Text style={s.eyebrow}>Information pharmaceutique</Text>}</View>
                    </Pressable>
                    <View style={s.headerActions}>
                        {token ? <>
                            <IconAction icon={searchOpen ? 'close-outline' : 'search-outline'} label={searchOpen ? 'Fermer la recherche' : 'Rechercher un médicament'} active={searchOpen} disabled={busy} onPress={() => {if(searchOpen) Keyboard.dismiss();setSearchOpen(v => !v);}}/>
                            {<IconAction icon="notifications-outline" label={`Notifications, ${unread} non lues`} count={unread} active={screen === 'notifications'} disabled={busy} onPress={() => {changeScreen('notifications'); refreshProfile().catch(()=>{});}}/>}
                            <IconAction icon="person-circle-outline" label="Mon compte" active={['account','billing'].includes(screen)} disabled={busy} onPress={() => changeScreen('account')}/>
                            <IconAction icon="log-out-outline" label="Se déconnecter" disabled={busy} onPress={() => run(logout)} danger/>
                        </> : <Pressable style={s.authSwitch} disabled={busy} onPress={() => switchMode(mode === 'login' ? 'register' : 'login')} accessibilityRole="button"><Text style={s.authSwitchText}>{mode === 'login' ? 'Inscription' : 'Connexion'}</Text><Ionicons name="arrow-forward" color={c.primary} size={16}/></Pressable>}
                    </View>
                </View>
                {!!token && searchOpen && <View style={s.searchRow}>
                    <Ionicons name="search-outline" size={22} color={c.muted}/>
                    <TextInput style={s.searchInput} accessibilityLabel="Rechercher dans le catalogue" autoFocus placeholder="Nom du médicament…" placeholderTextColor={c.muted} value={query} onChangeText={setQuery} returnKeyType="search" onSubmitEditing={() => searchNow()} editable={!busy}/>
                    {!!query && <IconAction icon="close-circle-outline" label="Effacer" onPress={() => setQuery('')}/>}
                    <IconAction icon="arrow-forward" label="Lancer la recherche" active disabled={busy} onPress={() => searchNow()}/>
                </View>}
            </View>

            <ScrollView ref={scroll} style={s.flex} contentContainerStyle={[s.content, !token && s.authContent]} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
                {!token ? <View style={[s.authCard, wide && s.authWide]}>
                    <View style={[s.hero, wide ? s.heroWide : s.heroSmall]}>
                        <Image source={require('./assets/medicine.png')} resizeMode="contain" style={wide ? s.heroImageWide : s.heroImageSmall}/>
                        <View style={s.heroCopy}><Text style={wide ? s.heroTitle : s.heroTitleSmall}>Comprendre avant de prendre.</Text><Text style={s.heroText}>Votre espace d’information pharmaceutique.</Text></View>
                    </View>
                    <View style={[s.authForm, wide && s.authFormWide]}>
                        <View style={{gap:5}}><Text style={s.eyebrow}>BIENVENUE SUR MEDICHECK</Text><Text style={s.authTitle}>{mode === 'login' ? 'Connexion' : 'Créer un compte'}</Text><Text style={s.muted}>{mode === 'login' ? 'Accédez à votre espace personnel.' : 'Inscrivez-vous pour accéder au catalogue.'}</Text></View>
                        {messages}
                        <Field label="Identifiant" placeholder="Votre identifiant" value={user} onChangeText={setUser} autoCapitalize="none" autoCorrect={false} editable={!busy} autoComplete="username"/>
                        {mode === 'register' && <Field label="Adresse email" placeholder="exemple@email.com" value={email} onChangeText={setEmail} keyboardType="email-address" autoCapitalize="none" editable={!busy} autoComplete="email"/>}
                        <Field label="Mot de passe" placeholder="Votre mot de passe" value={password} onChangeText={setPassword} secureTextEntry autoCapitalize="none" editable={!busy} autoComplete={mode === 'login' ? 'current-password' : 'new-password'} onSubmitEditing={() => run(auth)}/>
                        <Button title={busy ? 'Veuillez patienter…' : mode === 'login' ? 'Se connecter' : 'Créer mon compte'} disabled={busy} onPress={() => run(auth)}/>
                        <Pressable disabled={busy} onPress={() => switchMode(mode === 'login' ? 'register' : 'login')}><Text style={s.link}>{mode === 'login' ? 'Pas encore de compte ? Inscrivez-vous' : 'Déjà un compte ? Connectez-vous'}</Text></Pressable>
                    </View>
                </View> : <View style={s.screen}>
                    <View style={s.screenHeading}>
                        {['detail','billing','proposal','validations','myproposals','notifications'].includes(screen) && <IconAction icon="arrow-back" label="Retour" disabled={busy} onPress={() => changeScreen(screen==='detail'?'catalog':screen==='billing'?'account':screen==='notifications'?'catalog':'professional')}/>}
                        <View style={{flex:1,minWidth:0}}><Text style={s.eyebrow}>{canPropose ? 'ESPACE PROFESSIONNEL' : 'ESPACE USAGER'}</Text><Text style={s.title}>{titles[screen] || 'Catalogue'}</Text></View>
                    </View>
                    {messages}
                    {screen === 'catalog' ? <>
                        <View style={s.catalogMeta}><View style={{flex:1,gap:3}}><Text style={s.counter}>{catalog ? `${total} médicament(s)` : 'Catalogue pharmaceutique'}</Text><Text style={s.muted} numberOfLines={2}>{activeQuery ? `Recherche : ${activeQuery}` : 'Références et fiches disponibles'}</Text></View>
                        {activeQuery ? <IconAction icon="close-circle-outline" label="Effacer la recherche" disabled={busy} onPress={() => {setQuery('');searchNow('');}}/> : <IconAction icon="refresh-outline" label="Actualiser le catalogue" disabled={busy} onPress={() => run(() => loadMedicines('',token,1))}/>}</View>
                        <Text style={s.notice}>Données documentaires de démonstration. Ne remplacent pas un avis médical.</Text>
                        {busy && <ActivityIndicator size="large" color={c.primary}/>}
                        {!busy && catalog && !items.length && <View style={s.empty}><Ionicons name="search-outline" size={32} color={c.muted}/><Text style={s.label}>Aucun médicament trouvé</Text><Text style={s.muted}>Essayez une autre recherche.</Text></View>}
                        <View style={[s.catalogGrid, wide && s.catalogGridWide]}>{items.map(medicine => <Pressable accessibilityRole="button" accessibilityLabel={`Consulter ${medicine.name}`} key={medicine.id} style={({pressed})=>[s.medicineRow,wide && s.medicineRowWide,pressed&&{opacity:.75}]} disabled={busy} onPress={() => {changeScreen('detail');setSelectedMedicine(medicine);}}>
                            <View style={s.medicineIcon}><Ionicons name="medkit-outline" size={25} color={c.primary}/></View>
                            <View style={{flex:1,minWidth:0,gap:4}}><Text style={s.medicineName} numberOfLines={2}>{medicine.name}</Text><Text style={s.muted} numberOfLines={1}>{medicine.reference?.form || 'Consulter la fiche'}</Text></View><Ionicons name="chevron-forward" size={19} color={c.muted}/>
                        </Pressable>)}</View>
                        {pager}
                    </> : screen === 'detail' && selectedMedicine ? <View style={s.surface}>
                        <View style={s.detailHero}><View style={s.medicineIcon}><Ionicons name="medkit-outline" size={30} color={c.primary}/></View><Text style={[s.title,{flex:1}]}>{selectedMedicine.name}</Text></View>
                        <Text style={s.description}>{selectedMedicine.description || 'Description indisponible.'}</Text><ReferenceDetails reference={selectedMedicine.reference}/>{linkSource(selectedMedicine)}
                        <Button title="Signaler ce médicament" variant="secondary" disabled={busy} onPress={() => {const n=selectedMedicine.name;changeScreen('report');setName(n);}}/>
                    </View> : screen === 'account' ? <>
                        <View style={s.surface}><View style={s.detailHero}><View style={s.medicineIcon}><Ionicons name="person-outline" size={27} color={c.primary}/></View><View style={{flex:1}}><Text style={s.title}>{profile?.username || user}</Text><Text style={s.muted}>{canPropose?'Professionnel de santé validé':'Usager'}</Text></View></View><Text style={s.label}>{statusLabels[profile?.professional_status] || 'Statut en cours de chargement'}</Text>{!!profile?.reason && <Text style={s.muted}>Motif : {profile.reason}</Text>}<Button title="Actualiser mon statut" variant="secondary" disabled={busy} onPress={() => run(() => refreshProfile())}/></View>
                        <MenuRow icon="card-outline" title="Mes abonnements" subtitle={canPropose?'Offres et portefeuille de points':'Consulter et gérer les offres'} disabled={busy} onPress={() => changeScreen('billing')}/>
                        {canPropose && <MenuRow icon="medkit-outline" title="Espace professionnel" subtitle="Propositions et validations" disabled={busy} onPress={() => changeScreen('professional')}/>}
                        {profile && !canPropose && profile.professional_status !== 'pending' && <MenuRow icon="document-text-outline" title={showApplication?'Fermer mon dossier':'Devenir professionnel'} subtitle="Justificatifs et informations professionnelles" disabled={busy} onPress={() => setShowApplication(v => !v)}/>}
                        {showApplication && !canPropose && profile?.professional_status !== 'pending' && <View style={s.surface}><Text style={s.title}>Dossier professionnel</Text><Text style={s.muted}>Tous les champs et un justificatif sont obligatoires.</Text>
                            {applicationFields.map(([key,label])=><Field key={key} label={label} value={application[key]||''} onChangeText={value=>setApplication(old=>({...old,[key]:value}))} editable={!busy} keyboardType={key==='phone'?'phone-pad':'default'}/>)}
                            <Text style={s.label}>Justificatif (PDF, JPG ou PNG, 5 Mo maximum)</Text><Text style={s.muted}>{proof?.name || 'Aucun fichier sélectionné'}</Text><Button title="Choisir un justificatif" variant="secondary" disabled={busy} onPress={()=>run(pickProof)}/><Text style={s.muted}>Accessible uniquement aux administrateurs autorisés. N’envoyez pas de dossier patient.</Text><Button title="Soumettre mon dossier" disabled={busy} onPress={()=>run(sendApplication)}/>
                        </View>}
                    </> : screen === 'billing' ? <View style={s.surface}><BillingPanel api={api} token={token} verified={canPropose}/></View> : canPropose && screen === 'professional' ? <>
                        <View style={s.proBanner}><Ionicons name="shield-checkmark-outline" size={32} color="#fff"/><Text style={s.bannerTitle}>Contribuer au catalogue</Text><Text style={s.bannerText}>Proposez et examinez les fiches pharmaceutiques.</Text></View>
                        <MenuRow icon="add-circle-outline" title="Proposer un médicament" subtitle="Soumettre une nouvelle fiche" disabled={busy} onPress={()=>changeScreen('proposal')}/>
                        <MenuRow icon="clipboard-outline" title="Validations" subtitle="Examiner les demandes affectées" disabled={busy} onPress={()=>changeScreen('validations')}/>
                        <MenuRow icon="documents-outline" title="Mes propositions" subtitle="Suivre les cycles de validation" disabled={busy} onPress={()=>changeScreen('myproposals')}/>
                        <MenuRow icon="wallet-outline" title="Mes points et abonnements" subtitle="Consulter mon portefeuille" disabled={busy} onPress={()=>changeScreen('billing')}/>
                    </> : ['scanner','assistant'].includes(screen) ? <View style={s.surface}><IntelligencePanel key={screen} api={api} token={token} section={screen} pendingImage={pendingImage} onPendingConsumed={()=>setPendingImage(null)}/></View> : (screen === 'notifications' || (canPropose && ['validations','myproposals'].includes(screen))) ? <View style={s.surface}><ReviewPanel key={screen} api={api} token={token} section={screen} onChanged={()=>refreshProfile().catch(()=>{})}/></View> : (screen === 'report' || (screen === 'proposal' && canPropose)) ? <View style={s.surface}>
                        <Text style={s.muted}>{screen==='report'?'Décrivez le problème rencontré.':'Renseignez les informations et la source officielle du médicament.'}</Text>
                        <Field label="Nom du médicament" value={name} onChangeText={setName} editable={!busy}/>
                        {screen==='report'?<View style={{gap:8}}><Text style={s.label}>Type de signalement</Text>{[['expired','Médicament périmé'],['suspect','Médicament suspect'],['adverse','Effet indésirable']].map(([key,label])=><Pressable key={key} accessibilityRole="radio" accessibilityState={{checked:kind===key}} disabled={busy} style={[s.choice,kind===key&&s.choiceActive]} onPress={()=>setKind(key)}><Ionicons name={kind===key?'radio-button-on':'radio-button-off'} size={21} color={c.primary}/><Text style={s.label}>{label}</Text></Pressable>)}</View>:<Field label="Source officielle (URL)" placeholder="https://…" value={source} onChangeText={setSource} autoCapitalize="none" keyboardType="url" editable={!busy}/>}
                        <Field label="Description" value={details} onChangeText={setDetails} multiline style={{minHeight:130,textAlignVertical:'top'}} editable={!busy}/><Button title={busy?'Envoi…':'Envoyer'} disabled={busy} onPress={()=>run(submitForm)}/>
                    </View> : <View style={s.empty}><Text style={s.muted}>Cet espace n'est pas disponible pour votre compte.</Text><Button title="Retour au catalogue" onPress={()=>changeScreen('catalog')}/></View>}
                </View>}
            </ScrollView>
            {!!token && !keyboardVisible && <View style={s.bottom}><View style={s.bottomInner} accessibilityRole="tablist">{tabs.map(([key,label,outline,filled]) => {
                const selected=current===key;
                return <Pressable key={key} accessibilityRole="tab" accessibilityState={{selected,disabled:busy}} disabled={busy} onPress={()=>changeScreen(key)} style={({pressed})=>[s.tab,pressed&&{opacity:.7}]}><View style={[s.tabIcon,selected&&s.tabIconActive]}><Ionicons name={selected?filled:outline} size={23} color={selected?c.primary:c.muted}/></View><Text style={[s.tabLabel,selected&&s.tabLabelActive]} numberOfLines={1}>{label}</Text></Pressable>;
            })}</View></View>}
        </KeyboardAvoidingView>
    </SafeAreaView>;
}

export default function App() { return <SafeAreaProvider style={{flex:1}}><AppContent/></SafeAreaProvider>; }

function IconAction({icon,label,onPress,count=0,active=false,disabled=false,danger=false}) {
    return <Pressable accessibilityRole="button" accessibilityLabel={label} accessibilityState={{disabled}} disabled={disabled} onPress={onPress} style={({pressed})=>[s.iconAction,active&&s.iconActionActive,{opacity:disabled ? 0.45 : pressed ? 0.7 : 1}]}><View style={s.iconGlyph}><Ionicons name={icon} size={24} color={danger?c.danger:c.primary}/>{count>0&&<View pointerEvents="none" style={s.badge}><Text allowFontScaling={false} style={s.badgeText}>{count>99?'99+':count}</Text></View>}</View></Pressable>;
}
function MenuRow({icon,title,subtitle,onPress,disabled=false}) {
    return <Pressable accessibilityRole="button" disabled={disabled} onPress={onPress} style={({pressed})=>[s.menuRow,{opacity:disabled ? 0.5 : pressed ? 0.75 : 1}]}><View style={s.medicineIcon}><Ionicons name={icon} size={24} color={c.primary}/></View><View style={{flex:1,minWidth:0,gap:4}}><Text style={s.medicineName}>{title}</Text><Text style={s.muted}>{subtitle}</Text></View><Ionicons name="chevron-forward" size={20} color={c.muted}/></Pressable>;
}
const s = StyleSheet.create({
    shell:{flex:1,backgroundColor:'#F3FAFA'},flex:{flex:1},boot:{flex:1,justifyContent:'center',alignItems:'center',padding:24,gap:16},
    header:{backgroundColor:c.surface,borderBottomWidth:1,borderBottomColor:c.border,zIndex:2},headerInner:{width:'100%',maxWidth:1120,alignSelf:'center',minHeight:66,paddingHorizontal:10,flexDirection:'row',alignItems:'center',justifyContent:'space-between',gap:4},brandRow:{flex:1,minWidth:0,flexDirection:'row',alignItems:'center',gap:6},logo:{width:28,height:28,borderRadius:9,backgroundColor:c.primary,alignItems:'center',justifyContent:'center'},brand:{fontSize:19,fontWeight:'800',color:c.primary,letterSpacing:-.7},eyebrow:{fontSize:10,fontWeight:'800',letterSpacing:.7,color:c.muted},headerActions:{flexDirection:'row',alignItems:'center',gap:0},iconAction:{width:42,height:44,borderRadius:12,alignItems:'center',justifyContent:'center',position:'relative'},iconActionActive:{backgroundColor:'#DDF5F4'},iconGlyph:{width:26,height:26,alignItems:'center',justifyContent:'center',position:'relative',overflow:'visible'},badge:{position:'absolute',right:-7,top:-7,minWidth:18,height:18,paddingHorizontal:3,backgroundColor:'#D82738',borderColor:'#fff',borderWidth:1.5,borderRadius:10,alignItems:'center',justifyContent:'center',zIndex:3},badgeText:{color:'#fff',fontSize:10,lineHeight:13,includeFontPadding:false,fontWeight:'800',textAlign:'center'},authSwitch:{flexDirection:'row',alignItems:'center',gap:5,padding:10,backgroundColor:'#DDF5F4',borderRadius:10},authSwitchText:{color:c.primary,fontSize:13,fontWeight:'700'},searchRow:{maxWidth:1096,width:'95%',alignSelf:'center',flexDirection:'row',alignItems:'center',gap:6,backgroundColor:'#F2FAFA',borderWidth:1,borderColor:c.border,borderRadius:12,paddingHorizontal:10,marginBottom:10},searchInput:{flex:1,minWidth:0,minHeight:48,color:c.text,fontSize:15},
    content:{flexGrow:1,paddingHorizontal:12,paddingVertical:18},authContent:{justifyContent:'center',paddingVertical:16},authCard:{width:'100%',maxWidth:480,alignSelf:'center',backgroundColor:c.surface,borderWidth:1,borderColor:c.border,borderRadius:20,overflow:'hidden'},authWide:{maxWidth:960,flexDirection:'row',alignItems:'stretch'},hero:{backgroundColor:'#DDF5F4',padding:20,gap:12},heroSmall:{flexDirection:'row',alignItems:'center',padding:16,gap:10},heroWide:{flex:1,justifyContent:'center',padding:32},heroImageSmall:{width:84,height:84},heroImageWide:{width:'100%',height:230},heroCopy:{flexShrink:1,gap:6},heroTitle:{color:c.primary,fontSize:30,fontWeight:'800',lineHeight:36},heroTitleSmall:{color:c.primary,fontSize:18,fontWeight:'800',lineHeight:22},heroText:{color:c.text,fontSize:13,lineHeight:19},authForm:{width:'100%',padding:20,gap:15,minWidth:0},authFormWide:{flex:1,width:undefined,padding:36,justifyContent:'center'},authTitle:{fontSize:29,fontWeight:'800',color:c.primary,letterSpacing:-.6},
    screen:{width:'100%',maxWidth:1096,alignSelf:'center',gap:14},screenHeading:{flexDirection:'row',alignItems:'center',gap:8,marginBottom:2},title:{fontSize:25,fontWeight:'800',color:c.primary,letterSpacing:-.5},muted:{color:c.muted,fontSize:13,lineHeight:19},mutedCenter:{color:c.muted,fontSize:13,textAlign:'center'},label:{color:c.text,fontSize:14,fontWeight:'700',flexShrink:1},input:{width:'100%',minWidth:0,minHeight:49,paddingHorizontal:13,paddingVertical:12,borderWidth:1,borderColor:c.border,borderRadius:radius.input,color:c.text,backgroundColor:'#FCFFFF',fontSize:16},button:{minHeight:48,paddingHorizontal:16,paddingVertical:12,borderRadius:12,justifyContent:'center',alignItems:'center'},buttonText:{fontWeight:'700',textAlign:'center',fontSize:14},link:{color:c.primary,fontWeight:'700',textAlign:'center',lineHeight:20},surface:{backgroundColor:c.surface,borderWidth:1,borderColor:c.border,borderRadius:16,padding:15,gap:15},catalogMeta:{flexDirection:'row',alignItems:'center',backgroundColor:c.surface,borderRadius:15,padding:14,borderColor:c.border,borderWidth:1},counter:{fontSize:17,fontWeight:'800',color:c.primary},notice:{color:c.muted,fontSize:12,lineHeight:18},catalogGrid:{gap:9},catalogGridWide:{flexDirection:'row',flexWrap:'wrap',justifyContent:'space-between'},medicineRow:{flexDirection:'row',alignItems:'center',gap:12,padding:13,backgroundColor:c.surface,borderColor:c.border,borderWidth:1,borderRadius:15,minHeight:76},medicineRowWide:{width:'49%'},medicineIcon:{width:48,height:48,borderRadius:14,backgroundColor:'#DDF5F4',alignItems:'center',justifyContent:'center'},medicineName:{fontSize:15,fontWeight:'800',color:c.primary,lineHeight:20},description:{color:c.text,fontSize:15,lineHeight:23},detailHero:{flexDirection:'row',alignItems:'center',gap:12},sourceBox:{flexDirection:'row',alignItems:'center',gap:8,backgroundColor:'#DDF5F4',borderRadius:12,padding:13},source:{flex:1,color:c.primary,fontWeight:'700',lineHeight:19},empty:{backgroundColor:c.surface,padding:25,borderRadius:15,alignItems:'center',gap:10},pagination:{alignItems:'center',gap:6,padding:12},paginationControls:{flexDirection:'row',alignItems:'center',gap:15},pageNumber:{fontWeight:'800',color:c.primary,fontSize:15},menuRow:{flexDirection:'row',alignItems:'center',gap:12,padding:15,backgroundColor:c.surface,borderWidth:1,borderColor:c.border,borderRadius:15},proBanner:{backgroundColor:c.primary,borderRadius:18,padding:20,gap:10},bannerTitle:{color:'#fff',fontSize:21,fontWeight:'800'},bannerText:{color:'#E1F6F5',lineHeight:21},choice:{flexDirection:'row',alignItems:'center',gap:10,padding:13,borderRadius:10,borderWidth:1,borderColor:c.border},choiceActive:{backgroundColor:'#DDF5F4',borderColor:c.primary},errorBox:{flexDirection:'row',alignItems:'center',gap:8,padding:12,backgroundColor:'#FDECEC',borderRadius:12},errorText:{flexShrink:1,color:c.danger,fontWeight:'600',lineHeight:20},successBox:{flexDirection:'row',alignItems:'center',gap:8,padding:12,backgroundColor:'#DDF5F4',borderRadius:12},successText:{flexShrink:1,color:c.primary,fontWeight:'600',lineHeight:20},
    bottom:{backgroundColor:c.surface,borderTopWidth:1,borderTopColor:c.border},bottomInner:{width:'100%',maxWidth:760,alignSelf:'center',flexDirection:'row',alignItems:'center',paddingVertical:5,paddingHorizontal:4},tab:{flex:1,minWidth:0,alignItems:'center',justifyContent:'center',gap:3,minHeight:56},tabIcon:{height:31,width:48,borderRadius:16,alignItems:'center',justifyContent:'center'},tabIconActive:{backgroundColor:'#C9EFED'},tabLabel:{fontSize:10,color:c.muted,fontWeight:'600'},tabLabelActive:{color:c.primary,fontWeight:'800'}
});
