import React, { useRef, useState, useEffect } from 'react';
import {
    View, Text, TextInput, Pressable, Image, ScrollView, StyleSheet,
    useWindowDimensions, Platform, ActivityIndicator, Linking
} from 'react-native';
import { colors as c, radius } from './theme';
import * as DocumentPicker from 'expo-document-picker';

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
    const response = await fetch(url, {
        method,
        headers: {
            Accept: 'application/json',
            ...(data !== null && !(data instanceof FormData) ? { 'Content-Type': 'application/json' } : {}),
            ...(token ? { Authorization: `Bearer ${token}` } : {})
        },
        ...(data !== null ? { body: data instanceof FormData ? data : JSON.stringify(data) } : {})
    });
    const raw = await response.text();
    let result;
    try { result = raw ? JSON.parse(raw) : null; }
    catch { throw new Error(`Réponse non JSON du serveur (HTTP ${response.status}).`); }
    if (!response.ok) {
        throw new Error(result?.detail || JSON.stringify(result) || `HTTP ${response.status}`);
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

export default function App() {
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
    const [error, setError] = useState('');
    const [success, setSuccess] = useState('');
    const [busy, setBusy] = useState(false);
    const [screen, setScreen] = useState('catalog');

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
        setToken(result.access); setPassword(''); setQuery('');
        setScreen('catalog'); setCatalog(null);
        await refreshProfile(result.access);
        await loadMedicines('', result.access, 1);
    }

    async function refreshProfile(accessToken = token) {
        const result = await api('me', 'GET', null, accessToken);
        setProfile(result);
        if (!result.professional_verified) setScreen(old => old === 'proposal' ? 'catalog' : old);
        return result;
    }

    useEffect(() => {
        if (!token) return;
        let active = true;
        const timer = setInterval(async () => {
            try {
                const result = await api('me', 'GET', null, token);
                if (!active) return;
                setProfile(result);
                if (!result.professional_verified) setScreen(old => old === 'proposal' ? 'catalog' : old);
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
        if (key === 'proposal' && !canPropose) return;
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
            setSuccess('Proposition enregistrée pour examen.');
        }
        setName(''); setDetails(''); setSource('');
    }

    function logout() {
        setToken(''); setCatalog(null); setQuery(''); setPassword('');
        setMode('login'); setProfile(null); setApplication({}); setProof(null); changeScreen('catalog');
    }

    const messages = <>
        {!!error && <View style={s.errorBox}><Text accessibilityRole="alert" style={s.errorText}>{error}</Text></View>}
        {!!success && <View style={s.successBox}><Text accessibilityLiveRegion="polite" style={s.successText}>{success}</Text></View>}
    </>;

    const pagination = total > 0 && <View style={s.pagination}>
        <Text style={s.mutedCenter}>
            Affichage de {(page - 1) * PAGE_SIZE + 1} à {Math.min(page * PAGE_SIZE, total)} sur {total}
        </Text>
        <View style={s.paginationControls}>
            <Button title="Précédent" variant="secondary" disabled={busy || !catalog.previous}
                onPress={() => run(() => loadMedicines(activeQuery, token, page - 1))} />
            <View style={s.pageIndicator}><Text style={s.pageNumber}>{page} / {totalPages}</Text></View>
            <Button title="Suivant" disabled={busy || !catalog.next}
                onPress={() => run(() => loadMedicines(activeQuery, token, page + 1))} />
        </View>
    </View>;

    return <ScrollView ref={scroll} contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
        <View style={s.header}>
            <Text style={s.brand}>MediCheck<Text style={{ color: c.tertiary }}> AI</Text></Text>
            <Text style={s.muted}>Comprendre avant de prendre.</Text>
        </View>
        {!token ? <View style={[s.card, { flexDirection: width >= 700 ? 'row' : 'column' }]}>
            <View style={[s.hero, { flex: width >= 700 ? 1 : undefined }]}>
                <Image source={require('./assets/medicine.png')} resizeMode="contain"
                    style={{ width: '100%', height: width >= 700 ? 300 : 180 }} />
                <Text style={s.title}>Votre espace d’information pharmaceutique.</Text>
                <Text style={s.muted}>Identifiez vos médicaments et consultez leurs informations.</Text>
            </View>
            <View style={s.form}>
                <Text style={s.title}>{mode === 'login' ? 'Connexion' : 'Créer un compte'}</Text>
                {messages}
                <Field label="Identifiant" placeholder="Votre identifiant" value={user} onChangeText={setUser}
                    autoCapitalize="none" autoCorrect={false} editable={!busy} />
                {mode === 'register' && <>
                    <Field label="Adresse email" value={email} onChangeText={setEmail}
                        keyboardType="email-address" autoCapitalize="none" editable={!busy} />

                </>}
                <Field label="Mot de passe" value={password} onChangeText={setPassword}
                    secureTextEntry autoCapitalize="none" editable={!busy} />
                <Button title={busy ? 'Connexion / envoi en cours...' : mode === 'login' ? 'Se connecter' : 'S’inscrire'}
                    disabled={busy} onPress={() => run(auth)} />
                <Pressable disabled={busy} onPress={() => {
                    setMode(mode === 'login' ? 'register' : 'login'); setError(''); setSuccess('');
                }}><Text style={s.link}>{mode === 'login' ? 'Pas de compte ? Inscrivez-vous' : 'Déjà inscrit ? Connectez-vous'}</Text></Pressable>
            </View>
        </View> : <View style={s.card}>
            <View style={s.form}>
                <Text style={s.title}>Bienvenue, {user}</Text>
                <View style={s.navigation}>
                    {[['catalog', 'Catalogue'], ['report', 'Signalement'], ...(canPropose ? [['proposal', 'Proposer']] : [])].map(([key, label]) =>
                        <Button key={key} title={label} variant={screen === key ? 'primary' : 'secondary'}
                            disabled={busy} onPress={() => changeScreen(key)} />)}
                </View>
                {messages}
                <View style={s.sourceBox}>
                    <Text style={s.label}>{canPropose ? 'Professionnel de santé validé' : 'Espace personnel · Usager'}</Text>
                    <Text style={s.muted}>{statusLabels[profile?.professional_status] || 'Statut en cours de chargement'}</Text>
                    {!!profile?.reason && <Text style={s.muted}>Motif : {profile.reason}</Text>}
                    <View style={s.navigation}>
                        {profile && !canPropose && profile.professional_status !== 'pending' && <Button title={showApplication ? 'Fermer le dossier' : 'Devenir professionnel'} variant="secondary" disabled={busy} onPress={() => setShowApplication(v => !v)} />}
                        <Button title="Actualiser mon statut" variant="secondary" disabled={busy} onPress={() => run(() => refreshProfile())} />
                    </View>
                </View>
                {showApplication && !canPropose && profile?.professional_status !== 'pending' ? <>
                    <View style={s.formBanner}><Text style={s.bannerTitle}>Dossier professionnel</Text><Text style={s.bannerText}>Toutes les informations et un justificatif sont obligatoires.</Text></View>
                    {applicationFields.map(([key, label]) => <Field key={key} label={label} value={application[key] || ''} onChangeText={value => setApplication(old => ({...old, [key]: value}))} editable={!busy} keyboardType={key === 'phone' ? 'phone-pad' : 'default'} />)}
                    <Text style={s.label}>Justificatif (PDF, JPG ou PNG, 5 Mo maximum)</Text>
                    <Text style={s.muted}>{proof?.name || 'Aucun fichier sélectionné'}</Text>
                    <Button title="Choisir un justificatif" variant="secondary" disabled={busy} onPress={() => run(pickProof)} />
                    <Text style={s.muted}>Le document sera accessible uniquement aux administrateurs autorisés. N’envoyez pas de dossier de patient.</Text>
                    <Button title="Soumettre mon dossier" disabled={busy} onPress={() => run(sendApplication)} />
                </> : screen === 'catalog' || (screen === 'proposal' && !canPropose) ? <>
                    <Text style={s.title}>Catalogue</Text>
                    {catalog && <Text style={s.counter}>{total} médicament(s) trouvé(s){activeQuery ? ` — ${activeQuery}` : ''}</Text>}
                    <Text style={s.muted}>Catalogue de démonstration : fiches non validées cliniquement.</Text>
                    <Field label="Rechercher un médicament" placeholder="Doliprane, Paracétamol..." value={query}
                        onChangeText={setQuery} editable={!busy}
                        onSubmitEditing={() => run(() => loadMedicines(query, token, 1))} />
                    <View style={s.navigation}>
                        <Button title="Rechercher" disabled={busy} onPress={() => run(() => loadMedicines(query, token, 1))} />
                        <Button title="Tous les médicaments" variant="secondary" disabled={busy}
                            onPress={() => run(async () => { setQuery(''); await loadMedicines('', token, 1); })} />
                    </View>
                    {busy && <ActivityIndicator size="large" color={c.primary} />}
                    {!busy && catalog && !items.length && <View style={s.empty}>
                        <Text style={s.label}>Aucun médicament trouvé.</Text><Text style={s.muted}>Essayez une autre recherche.</Text>
                    </View>}
                    {!busy && !catalog && !error && <Text style={s.muted}>Utilisez la recherche pour charger le catalogue.</Text>}
                    {pagination}
                    {items.map(medicine => <View key={medicine.id} style={s.result}>
                        <View style={s.medicineHeader}>
                            <View style={s.medicineIcon}><Text style={s.pageNumber}>{medicine.name?.charAt(0).toUpperCase()}</Text></View>
                            <View style={{ flex: 1 }}><Text style={s.medicineName}>{medicine.name}</Text><Text style={s.muted}>Fiche de démonstration</Text></View>
                        </View>
                        <Text style={s.description}>{medicine.description || 'Description indisponible.'}</Text>
                        {!!medicine.source && <View style={s.sourceBox}>
                            <Text style={s.label}>Source</Text>
                            <Pressable accessibilityRole="link" onPress={() => {
                                if (/^https?:\/\//i.test(medicine.source)) Linking.openURL(medicine.source).catch(() => setError('Impossible d’ouvrir la source.'));
                            }}><Text style={s.source}>{medicine.source}</Text></Pressable>
                        </View>}
                        <Button title="Signaler ce médicament" variant="secondary" disabled={busy}
                            onPress={() => { changeScreen('report'); setName(medicine.name); }} />
                    </View>)}
                    {pagination}
                </> : <>
                    <View style={s.formBanner}>
                        <Text style={s.bannerTitle}>{screen === 'report' ? 'Signaler un médicament' : 'Proposer un médicament'}</Text>
                        <Text style={s.bannerText}>{screen === 'report' ? 'Contribuez à la sécurité des usagers.' : 'Réservé aux professionnels de santé validés.'}</Text>
                    </View>
                    <Field label="Nom du médicament" value={name} onChangeText={setName} editable={!busy} />
                    {screen === 'report' ? <View style={{ gap: 8 }}>
                        <Text style={s.label}>Type de signalement</Text>
                        {[['expired', 'Médicament périmé'], ['suspect', 'Médicament suspect'], ['adverse', 'Effet indésirable']].map(([key, label]) =>
                            <Button key={key} title={label} variant={kind === key ? 'primary' : 'secondary'} disabled={busy} onPress={() => setKind(key)} />)}
                    </View> : <Field label="Source officielle (URL)" placeholder="https://..." value={source} onChangeText={setSource} autoCapitalize="none" editable={!busy} />}
                    <Field label="Description" value={details} onChangeText={setDetails} multiline
                        style={{ minHeight: 130, textAlignVertical: 'top' }} editable={!busy} />
                    <Button title={busy ? 'Envoi en cours...' : 'Envoyer'} disabled={busy} onPress={() => run(submitForm)} />
                </>}
                <Button title="Se déconnecter" variant="danger" disabled={busy} onPress={logout} />
            </View>
        </View>}
        <View style={s.footer}>
            <Text style={s.mutedCenter}>MediCheck AI — Information pharmaceutique</Text>
            <Text style={s.mutedCenter}>Version de démonstration. Ne remplace pas un médecin ou un pharmacien.</Text>
        </View>
    </ScrollView>;
}

const s = StyleSheet.create({
    page: { flexGrow: 1, backgroundColor: c.background, padding: 24, gap: 20 },
    header: { width: '100%', maxWidth: 1000, alignSelf: 'center', gap: 5 },
    brand: { fontSize: 30, fontWeight: '800', color: c.primary },
    card: { backgroundColor: c.surface, borderRadius: radius.card, overflow: 'hidden', borderWidth: 1, borderColor: c.border, width: '100%', maxWidth: 1000, alignSelf: 'center' },
    hero: { padding: 24, backgroundColor: c.background, justifyContent: 'center', gap: 15 },
    form: { flex: 1, padding: 24, gap: 16 },
    title: { fontSize: 26, fontWeight: '800', color: c.primary },
    muted: { color: c.muted, fontSize: 14, lineHeight: 21 },
    mutedCenter: { color: c.muted, fontSize: 13, textAlign: 'center' },
    label: { fontSize: 14, fontWeight: '700', color: c.text },
    input: { borderWidth: 1, borderColor: c.border, borderRadius: radius.input, padding: 14, minHeight: 50, color: c.text, backgroundColor: c.surface, fontSize: 15 },
    button: { paddingHorizontal: 16, paddingVertical: 14, borderRadius: 12, minHeight: 48, justifyContent: 'center', alignItems: 'center' },
    buttonText: { fontWeight: '700', textAlign: 'center', fontSize: 14 },
    link: { color: c.primary, fontWeight: '700', textAlign: 'center' },
    navigation: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
    counter: { color: c.primary, fontSize: 14, fontWeight: '600' },
    result: { padding: 18, borderRadius: 16, backgroundColor: c.surface, borderColor: c.border, borderWidth: 1, gap: 14 },
    medicineHeader: { flexDirection: 'row', alignItems: 'center', gap: 14 },
    medicineIcon: { width: 54, height: 54, borderRadius: 14, backgroundColor: c.background, justifyContent: 'center', alignItems: 'center' },
    medicineName: { color: c.primary, fontSize: 17, fontWeight: '800' },
    description: { fontSize: 14, lineHeight: 21, color: c.text },
    sourceBox: { backgroundColor: c.background, padding: 12, borderRadius: 10, gap: 6 },
    source: { color: c.primary, fontSize: 12, textDecorationLine: 'underline' },
    empty: { padding: 24, alignItems: 'center', gap: 8, backgroundColor: c.background, borderRadius: 12 },
    formBanner: { backgroundColor: c.primary, padding: 24, borderRadius: 16, borderLeftWidth: 5, borderLeftColor: c.tertiary, gap: 8 },
    bannerTitle: { color: '#FFFFFF', fontSize: 22, fontWeight: '800' },
    bannerText: { color: c.background, fontSize: 14 },
    errorBox: { backgroundColor: '#FDECEC', borderWidth: 1, borderColor: c.danger, borderRadius: 12, padding: 16 },
    errorText: { color: c.danger, fontWeight: '600' },
    successBox: { backgroundColor: c.background, borderWidth: 1, borderColor: c.secondary, borderRadius: 12, padding: 16 },
    successText: { color: c.primary, fontWeight: '600' },
    pagination: { padding: 14, borderRadius: 16, borderWidth: 1, borderColor: c.border, backgroundColor: c.background, gap: 12 },
    paginationControls: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'center', gap: 8 },
    pageIndicator: { padding: 12, borderRadius: 10, borderWidth: 1, borderColor: c.secondary, backgroundColor: c.surface },
    pageNumber: { fontWeight: '800', color: c.primary, fontSize: 16 },
    footer: { alignItems: 'center', paddingVertical: 20, gap: 5 }
});
