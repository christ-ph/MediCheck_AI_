#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$ROOT/mobile/App.js" || ! -f "$ROOT/mobile/ReviewPanel.js" ]]; then
  echo 'Placez ce script à la racine de MediCheck (après update_intelligence.sh).' >&2; exit 1
fi
for cmd in python3 node npm npx uv; do command -v "$cmd" >/dev/null || { echo "$cmd est requis"; exit 1; }; done
for f in backend/manage.py backend/core/review_models.py backend/core/review_api.py backend/core/billing_api.py backend/core/professional_api.py; do
  [[ -f "$ROOT/$f" ]] || { echo "Fichier manquant : $f" >&2; exit 1; }
done
(cd "$ROOT/backend" && uv run python manage.py migrate --check && uv run python manage.py makemigrations --check --dry-run)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'echo "Échec : consultez le message précédent. Si une sauvegarde a été créée, elle est conservée." >&2' ERR
cat > "$TMP/patch.py" <<'MEDICHECK_PATCH_EOF'
from pathlib import Path
import sys
root, asset, out = map(Path,sys.argv[1:])
p=root/'mobile/App.js'
s=p.read_text()
for marker in ("import { session }",'import BillingPanel','import ReviewPanel','import IntelligencePanel','async function loadMedicines','async function sendApplication','async function refreshProfile','const messages = <>'):
    if marker not in s: raise SystemExit('Version incompatible: '+marker+'. Installez update_intelligence.sh avant ce patch.')
if 'function AppContent()' in s: raise SystemExit('Interface déjà mise à jour.')
s=s.split('    const messages = <>',1)[0]
def change(a,b,n=1):
    global s
    if s.count(a)!=n: raise SystemExit('Code inattendu: '+a[:90])
    s=s.replace(a,b)
change("    useWindowDimensions, Platform, ActivityIndicator, Linking", "    useWindowDimensions, Platform, ActivityIndicator, Linking, KeyboardAvoidingView, Keyboard")
change("import { colors as c, radius } from './theme';", "import { colors as c, radius } from './theme';\nimport Ionicons from '@expo/vector-icons/Ionicons';\nimport { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';")
change('export default function App() {','function AppContent() {')
change("    const [screen, setScreen] = useState('catalog');", """    const [screen, setScreen] = useState('catalog');
    const [searchOpen, setSearchOpen] = useState(false);
    const [selectedMedicine, setSelectedMedicine] = useState(null);
    const [keyboardVisible, setKeyboardVisible] = useState(false);
    useEffect(() => {
        const a = Keyboard.addListener('keyboardDidShow', () => setKeyboardVisible(true));
        const b = Keyboard.addListener('keyboardDidHide', () => setKeyboardVisible(false));
        return () => { a.remove(); b.remove(); };
    }, []);
    useEffect(() => { scroll.current?.scrollTo({y:0,animated:false}); }, [screen, mode]);
    function switchMode(next) { setMode(next); setPassword(''); setError(''); setSuccess(''); }
""")
change("['proposal','validations','myproposals','notifications'].includes(old)","['professional','proposal','validations','myproposals'].includes(old)",2)
change("if (['proposal','validations','myproposals','notifications'].includes(key) && !canPropose) return;", "if (['professional','proposal','validations','myproposals'].includes(key) && !canPropose) return;\n        setSearchOpen(false); setSelectedMedicine(null);")
# If signout is caused by an invalid session, also discard transient UI state.
change("setMode('login'); setProfile(null); setApplication({}); setProof(null); changeScreen('catalog');", "setMode('login'); setProfile(null); setApplication({}); setProof(null); setSearchOpen(false); setSelectedMedicine(null); changeScreen('catalog');")
s+=(asset/'layout.txt').read_text()
review=(root/'mobile/ReviewPanel.js').read_text()
old='export default function ReviewPanel({api,token,section})'
if review.count(old)!=1:raise SystemExit('Version ReviewPanel inattendue.')
review=review.replace(old,'export default function ReviewPanel({api,token,section,onChanged})')
old="onPress={()=>act(()=>api(`reviews/notifications/${row.id}/read`,'POST',{},token))}"
new="onPress={()=>act(async()=>{await api(`reviews/notifications/${row.id}/read`,'POST',{},token);onChanged?.();})}"
if review.count(old)!=1:raise SystemExit('Version des notifications inattendue.')
review=review.replace(old,new)
review=review.replace('Messages liés aux propositions et aux validations.', 'Abonnements, dossiers professionnels et contributions.')
review=review.replace("<View key={row.id} style={s.card}><Text style={s.label}>{row.read?'Lu':'Nouveau'}", "<View key={row.id} style={[s.card,!row.read&&s.unread]}><Text style={s.label}>{({subscription:'Abonnement',professional:'Dossier professionnel',review:'Validation médicale'})[row.category]||'Notification'} · {row.read?'Lu':'Nouveau'}")
review=review.replace('panel:{gap:12},card:', "panel:{gap:12},unread:{borderLeftWidth:4,borderLeftColor:c.primary,backgroundColor:'#F2FAFA'},card:")
out.mkdir(parents=True,exist_ok=True)
(out/'App.js').write_text(s)
(out/'ReviewPanel.js').write_text(review)
MEDICHECK_PATCH_EOF
cat > "$TMP/layout.txt" <<'MEDICHECK_LAYOUT_EOF'
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
                    </> : ['scanner','assistant'].includes(screen) ? <View style={s.surface}><IntelligencePanel key={screen} api={api} token={token} section={screen}/></View> : (screen === 'notifications' || (canPropose && ['validations','myproposals'].includes(screen))) ? <View style={s.surface}><ReviewPanel key={screen} api={api} token={token} section={screen} onChanged={()=>refreshProfile().catch(()=>{})}/></View> : (screen === 'report' || (screen === 'proposal' && canPropose)) ? <View style={s.surface}>
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
MEDICHECK_LAYOUT_EOF
cat > "$TMP/backend_patch.py" <<'MEDICHECK_BACKEND_EOF'
import ast
from pathlib import Path
import sys
root, out = map(Path,sys.argv[1:])
def edit(name, replacements):
    src=root/'backend/core'/name
    text=src.read_text()
    for old,new in replacements:
        if text.count(old)!=1: raise SystemExit('Version inattendue dans '+name+': '+old[:90])
        text=text.replace(old,new,1)
    ast.parse(text)
    (out/name).write_text(text)
out.mkdir(parents=True,exist_ok=True)
edit('review_models.py',[(
    '    cycle = models.ForeignKey(ReviewCycle, on_delete=models.PROTECT)\n    message = models.CharField(max_length=500)',
    "    cycle = models.ForeignKey(ReviewCycle, on_delete=models.PROTECT, null=True, blank=True)\n    category = models.CharField(max_length=16, default='review', choices=[('review','Validation médicale'),('subscription','Abonnement'),('professional','Dossier professionnel')])\n    subscription = models.ForeignKey('core.Subscription', on_delete=models.PROTECT, null=True, blank=True)\n    message = models.CharField(max_length=500)"
)])
edit('professional_api.py',[
    ('    unread = ReviewNotification.objects.filter(user=user, read_at__isnull=True).count() if verified else 0', '    unread = ReviewNotification.objects.filter(user=user, read_at__isnull=True).count()'),
    ('return dict(review_unread=unread, username=', 'return dict(notification_unread=unread, review_unread=unread, username='),
    ("        profile.professional_verified = verified\n        profile.save(update_fields=['professional_verified'])", """        profile.professional_verified = verified
        profile.save(update_fields=['professional_verified'])
        from .models import ReviewNotification
        messages = {'approved':'Votre dossier professionnel a été accepté. Vous pouvez désormais contribuer au catalogue.', 'rejected':'Votre dossier professionnel a été refusé. Consultez le motif dans votre compte.', 'revoked':'Votre validation professionnelle a été retirée. Consultez votre compte.'}
        ReviewNotification.objects.create(user_id=profile.user_id, category='professional', message=messages[app.status])""")
])
edit('review_api.py',[("lambda n:dict(id=n.pk,message=n.message,read=bool(n.read_at),created_at=n.created_at)","lambda n:dict(id=n.pk,category=n.category,message=n.message,read=bool(n.read_at),created_at=n.created_at)")])
edit('billing_api.py',[(
    "        s.reason=d['reason']; s.decided_at=now; s.decided_by=request.user\n        s.save()\n    return Response(sub_data(s))",
    """        s.reason=d['reason']; s.decided_at=now; s.decided_by=request.user
        s.save()
        # Atomic: a failed decision cannot leave a false notification behind.
        from .models import ReviewNotification
        label = s.plan.name
        messages = {
            'activate': f'Votre abonnement {label} a été activé. Consultez votre compte pour connaître sa date de fin.',
            'reject': f'Votre demande d’abonnement {label} a été refusée. Consultez le motif dans votre compte.',
            'cancel': f'Votre abonnement ou demande {label} a été annulé par l’administration.'
        }
        ReviewNotification.objects.create(user_id=s.user_id, category='subscription', subscription=s, message=messages[action][:500])
    return Response(sub_data(s))"""
)])
MEDICHECK_BACKEND_EOF
python3 "$TMP/patch.py" "$ROOT" "$TMP" "$TMP/out"
python3 "$TMP/backend_patch.py" "$ROOT" "$TMP/backend-out"
cat > "$TMP/backend-out/test_notifications.py" <<'MEDICHECK_TEST_EOF'
from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase
from .models import SubscriptionPlan, ReviewNotification, Profile, ProfessionalApplication

class NotificationTests(APITestCase):
    def setUp(self):
        User = get_user_model()
        self.user = User.objects.create_user(username='notif-user')
        self.other = User.objects.create_user(username='notif-other')
        self.admin = User.objects.create_superuser(username='notif-admin', password='test-only-pass')
        SubscriptionPlan.objects.update_or_create(code='silver', defaults=dict(name='Silver',price_fcfa=1000,enabled=True))
    def test_subscription_notification_and_privacy(self):
        self.client.force_authenticate(self.user)
        r=self.client.post('/api/billing/subscription/',{'plan':'silver'},format='json')
        self.assertEqual(r.status_code,201)
        pk=r.data['id']
        self.client.force_authenticate(self.admin)
        url=f'/api/admin/billing/subscriptions/{pk}/'
        data={'action':'activate','reason':'Activation de test'}
        self.assertEqual(self.client.patch(url,data,format='json').status_code,200)
        self.assertEqual(self.client.patch(url,data,format='json').status_code,400)
        n=ReviewNotification.objects.get(subscription_id=pk,category='subscription')
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.get('/api/reviews/notifications/').data['count'],0)
        self.client.post(f'/api/reviews/notifications/{n.pk}/read/',{},format='json')
        n.refresh_from_db(); self.assertIsNone(n.read_at)
        self.client.force_authenticate(self.user)
        me=self.client.get('/api/me/').data
        self.assertFalse(me['professional_verified']); self.assertEqual(me['notification_unread'],1)
        r=self.client.get('/api/reviews/notifications/')
        self.assertEqual(r.data['results'][0]['category'],'subscription')
        self.assertEqual(self.client.post(f'/api/reviews/notifications/{n.pk}/read/',{},format='json').status_code,204)
        self.assertEqual(self.client.get('/api/me/').data['notification_unread'],0)
    def test_professional_decision(self):
        p=Profile.objects.create(user=self.user,professional_requested=True)
        ProfessionalApplication.objects.create(profile=p,status='pending',proof=b'%PDF-test')
        self.client.force_authenticate(self.admin)
        r=self.client.patch(f'/api/admin/professionals/{p.pk}/',{'verified':True},format='json')
        self.assertEqual(r.status_code,200)
        self.client.force_authenticate(self.user)
        self.assertEqual(self.client.get('/api/me/').data['notification_unread'],1)
        self.assertEqual(self.client.get('/api/reviews/notifications/').data['results'][0]['category'],'professional')
MEDICHECK_TEST_EOF
if [[ -e "$ROOT/backend/core/test_notifications.py" ]]; then echo 'Module notifications déjà présent, abandon.' >&2; exit 1; fi
BACKUP="$ROOT/.mobile-ui-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$BACKUP"
mkdir -p "$BACKUP/backend/core" "$BACKUP/backend/migrations"
for f in review_models.py professional_api.py review_api.py billing_api.py; do cp -p "$ROOT/backend/core/$f" "$BACKUP/backend/core/$f"; done
cp -a "$ROOT/backend/core/migrations/." "$BACKUP/backend/migrations/"
if [[ -f "$ROOT/backend/db.sqlite3" ]]; then
  python3 - "$ROOT/backend/db.sqlite3" "$BACKUP/db.sqlite3" <<'MEDICHECK_DB_EOF'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as src, sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
MEDICHECK_DB_EOF
  chmod 600 "$BACKUP/db.sqlite3"
fi
for f in App.js ReviewPanel.js package.json package-lock.json; do
  if [[ -f "$ROOT/mobile/$f" ]]; then cp -p "$ROOT/mobile/$f" "$BACKUP/$f"; fi
done
printf 'Sauvegarde : %s\n' "$BACKUP"
cd "$ROOT/mobile"
# Expo choisit les versions compatibles avec le SDK déjà installé.
npx expo install @expo/vector-icons expo-font react-native-safe-area-context
cp "$TMP/backend-out/"*.py "$ROOT/backend/core/"
(
 cd "$ROOT/backend"
 uv run python manage.py makemigrations core
 uv run python manage.py check
 uv run python manage.py test core.test_notifications core.test_reviews core.test_billing core.test_duplicates
 uv run python manage.py migrate
)
cp "$TMP/out/App.js" App.js
cp "$TMP/out/ReviewPanel.js" ReviewPanel.js
printf '\nInterface et notifications installées. Migration Django appliquée.\n' 
printf 'Pour lancer : cd "%s/mobile" && npx expo start --lan --clear\n' "$ROOT"
printf 'Pour vérifier : npx expo-doctor ; npx expo export --platform web\n'
printf 'Sauvegarde des sources et manifestes npm : %s\n' "$BACKUP"
