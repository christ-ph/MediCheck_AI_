#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/Bureau/MediCheck}"
cd "$ROOT"
for f in backend/manage.py backend/core/models.py backend/core/views.py backend/core/admin_api.py backend/core/admin_urls.py backend/config/urls.py mobile/App.js admin-web/src/main.jsx; do
  [[ -f "$f" ]] || { echo "Fichier manquant : $f (installez d'abord le portail admin)." >&2; exit 1; }
done
command -v uv >/dev/null
command -v npm >/dev/null
command -v python3 >/dev/null
if grep -q '^class ProfessionalApplication' backend/core/models.py; then
  echo 'Mise à jour déjà présente. Ne relancez pas le patch; terminez les migrations et l’installation Expo.' >&2
  exit 1
fi
# Install the SDK-compatible picker before modifying source code.
(cd mobile && npx expo install expo-document-picker)
backup=".backup-professional-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
for f in backend/core/models.py backend/core/views.py backend/core/admin_api.py backend/core/admin_urls.py backend/config/urls.py mobile/App.js admin-web/src/main.jsx; do
  mkdir -p "$backup/$(dirname "$f")"
  cp -p "$f" "$backup/$f"
done
printf 'Sauvegarde des sources : %s\n' "$backup"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/pro_model.py" <<'MEDIMODEL'


class ProfessionalApplication(models.Model):
    class Status(models.TextChoices):
        PENDING = 'pending', 'En attente'
        APPROVED = 'approved', 'Validé'
        REJECTED = 'rejected', 'Refusé'
        REVOKED = 'revoked', 'Révoqué'

    profile = models.OneToOneField(Profile, on_delete=models.CASCADE, related_name='application')
    full_name = models.CharField(max_length=180)
    profession = models.CharField(max_length=100)
    registration_number = models.CharField(max_length=100)
    issuer = models.CharField(max_length=180)
    institution = models.CharField(max_length=180)
    location = models.CharField(max_length=180)
    phone = models.CharField(max_length=40)
    proof = models.BinaryField(editable=False)
    proof_type = models.CharField(max_length=40)
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.PENDING)
    reason = models.CharField(max_length=500, blank=True)
    submitted_at = models.DateTimeField(auto_now=True)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name='reviewed_professional_applications')
MEDIMODEL
cat > "$tmp/professional_api.py" <<'MEDIAPI'
from django.db import transaction
from django.http import HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes, parser_classes
from rest_framework.parsers import MultiPartParser, FormParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.response import Response
from .models import Profile, ProfessionalApplication as Application


class ApplicationSerializer(serializers.Serializer):
    full_name = serializers.CharField(max_length=180, min_length=3)
    profession = serializers.CharField(max_length=100, min_length=2)
    registration_number = serializers.CharField(max_length=100, min_length=2)
    issuer = serializers.CharField(max_length=180, min_length=2)
    institution = serializers.CharField(max_length=180, min_length=2)
    location = serializers.CharField(max_length=180, min_length=2)
    phone = serializers.RegexField(regex=r'^\+?[0-9 ()-]{7,40}$')
    proof = serializers.FileField()

    def validate_proof(self, file):
        if not 0 < file.size <= 5 * 1024 * 1024:
            raise serializers.ValidationError('Justificatif limité à 5 Mo.')
        header = file.read(8)
        file.seek(0)
        if header.startswith(b'%PDF-'):
            kind = 'application/pdf'
        elif header.startswith(b'\xff\xd8\xff'):
            kind = 'image/jpeg'
        elif header == b'\x89PNG\r\n\x1a\n':
            kind = 'image/png'
        else:
            raise serializers.ValidationError('Format accepté : PDF, JPG ou PNG.')
        return (file.read(), kind)


def profile_info(user):
    profile, _ = Profile.objects.get_or_create(user=user)
    row = Application.objects.filter(profile=profile).values('status', 'reason').first()
    verified = bool(user.is_active and profile.professional_verified and row and row['status'] == Application.Status.APPROVED)
    status = row['status'] if row else ('incomplete' if profile.professional_requested or profile.professional_verified else 'none')
    if status == Application.Status.APPROVED and not verified:
        status = Application.Status.REVOKED
    return dict(username=user.username, professional_requested=profile.professional_requested,
                professional_verified=verified, professional_status=status,
                reason=row['reason'] if row else '')


@api_view(['POST'])
@permission_classes([IsAuthenticated])
@parser_classes([MultiPartParser, FormParser])
def apply_professional(request):
    serializer = ApplicationSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    data = dict(serializer.validated_data)
    proof, proof_type = data.pop('proof')
    with transaction.atomic():
        profile, _ = Profile.objects.get_or_create(user=request.user)
        profile = Profile.objects.select_for_update().get(pk=profile.pk)
        existing = Application.objects.filter(profile=profile).values('status').first()
        if existing and (existing['status'] == Application.Status.PENDING or (existing['status'] == Application.Status.APPROVED and profile.professional_verified)):
            raise ValidationError('Un dossier est déjà en attente ou validé.')
        Application.objects.update_or_create(profile=profile, defaults={**data, 'proof': proof, 'proof_type': proof_type,
            'status': Application.Status.PENDING, 'reason': '', 'reviewed_at': None, 'reviewed_by': None})
        profile.professional_requested = True
        profile.professional_verified = False
        profile.save(update_fields=['professional_requested', 'professional_verified'])
    return Response(profile_info(request.user), status=201)


def decide(request, pk):
    class Decision(serializers.Serializer):
        verified = serializers.BooleanField()
        reason = serializers.CharField(max_length=500, required=False, allow_blank=True)
    s = Decision(data=request.data)
    s.is_valid(raise_exception=True)
    verified = s.validated_data['verified']
    reason = s.validated_data.get('reason', '').strip()
    with transaction.atomic():
        profile = get_object_or_404(Profile.objects.select_for_update(), pk=pk, professional_requested=True)
        app = Application.objects.filter(profile=profile).defer('proof').first()
        if not app:
            raise ValidationError('Dossier incomplet : le professionnel doit soumettre un justificatif.')
        if verified:
            if not profile.user.is_active or app.status != Application.Status.PENDING:
                raise ValidationError('Seul un dossier en attente associé à un compte actif peut être validé.')
            app.status = Application.Status.APPROVED
            reason = ''
        else:
            if not reason:
                raise ValidationError('Motif obligatoire pour un refus ou une révocation.')
            if app.status == Application.Status.PENDING:
                app.status = Application.Status.REJECTED
            elif app.status == Application.Status.APPROVED:
                app.status = Application.Status.REVOKED
            else:
                raise ValidationError('Ce dossier a déjà été traité.')
        app.reason = reason
        app.reviewed_by = request.user
        app.reviewed_at = timezone.now()
        app.save(update_fields=['status', 'reason', 'reviewed_by', 'reviewed_at'])
        profile.professional_verified = verified
        profile.save(update_fields=['professional_verified'])
    return Response({'verified': verified, 'status': app.status})


def proof_response(pk):
    app = get_object_or_404(Application, profile_id=pk)
    ext = {'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png'}[app.proof_type]
    response = HttpResponse(bytes(app.proof), content_type='application/octet-stream')
    response['Content-Disposition'] = f'attachment; filename="justificatif-{pk}.{ext}"'
    response['Cache-Control'] = 'no-store, private'
    response['X-Content-Type-Options'] = 'nosniff'
    return response
MEDIAPI
cat > "$tmp/patch_backend.py" <<'MEDIPATCH'
from pathlib import Path
import ast
import sys

# All replacements are prepared and syntax-checked before writing.
root = Path.cwd()

def replace_function(text, name, replacement, class_name=None):
    tree = ast.parse(text)
    nodes = tree.body
    if class_name:
        nodes = next(n.body for n in nodes if isinstance(n, ast.ClassDef) and n.name == class_name)
    node = next(n for n in nodes if isinstance(n, ast.FunctionDef) and n.name == name)
    start = min([node.lineno] + [d.lineno for d in node.decorator_list]) - 1
    lines = text.splitlines(keepends=True)
    return ''.join(lines[:start]) + replacement.rstrip() + '\n' + ''.join(lines[node.end_lineno:])

files = {}
models = root/'backend/core/models.py'
assert 'class ProfessionalApplication' not in models.read_text(), 'Mise à jour déjà installée.'
files[models] = models.read_text() + (Path(sys.argv[1])/'pro_model.py').read_text()
views = root/'backend/core/views.py'
s = views.read_text()
s += '\nfrom .professional_api import profile_info, apply_professional\n'
s = replace_function(s, 'register', '''@api_view(['POST'])
@permission_classes([AllowAny])
def register(request):
    s = Registration(data=request.data)
    s.is_valid(raise_exception=True)
    d = s.validated_data.copy()
    if d.pop('professional_requested', False):
        raise serializers.ValidationError('Créez un compte usager puis déposez un dossier professionnel.')
    with transaction.atomic():
        u = User.objects.create_user(**d)
        Profile.objects.create(user=u)
    return Response({'username': u.username}, status=201)''')
s = replace_function(s, 'me', '''@api_view(['GET'])
def me(request):
    return Response(profile_info(request.user))''')
s = replace_function(s, 'perform_create', '''    def perform_create(self, s):
        from rest_framework.exceptions import PermissionDenied
        # Same row lock as the approval/revocation flow, where supported.
        with transaction.atomic():
            Profile.objects.select_for_update().filter(user=self.request.user).first()
            if not profile_info(self.request.user)['professional_verified']:
                raise PermissionDenied('Compte professionnel non validé.')
            s.save(author=self.request.user, published=False)''', 'Proposal')
# Ensure the mobile's 20-item server pagination even on the initial starter.
cat = next(n for n in ast.parse(s).body if isinstance(n, ast.ClassDef) and n.name == 'Catalog')
if not any(isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'pagination_class' for t in n.targets) for n in cat.body):
    lines = s.splitlines(keepends=True)
    lines.insert(cat.lineno, '    pagination_class = ProfessionalUpdatePagination\n')
    # Define the pagination class before Catalog is evaluated.
    lines.insert(cat.lineno - 1, 'from rest_framework.pagination import PageNumberPagination\nclass ProfessionalUpdatePagination(PageNumberPagination):\n    page_size = 20\n    page_size_query_param = "page_size"\n    max_page_size = 100\n\n')
    s = ''.join(lines)
files[views] = s
admin = root/'backend/core/admin_api.py'
s = admin.read_text() + '\nfrom .models import ProfessionalApplication as Application\nfrom .professional_api import decide, proof_response\n'
s = replace_function(s, 'overview', '''@api_view(['GET'])
@permission_classes([PlatformAdmin])
def overview(request):
    return Response(dict(username=request.user.username,
        users=User.objects.count(), medicines=Medicine.objects.count(),
        pending=Application.objects.filter(status='pending', profile__user__is_active=True).count(),
        verified=Application.objects.filter(status='approved', profile__professional_verified=True, profile__user__is_active=True).count(),
        reports=Report.objects.count()))''')
s = replace_function(s, 'professionals', '''@api_view(['GET'])
@permission_classes([PlatformAdmin])
def professionals(request):
    q = request.query_params.get('q', '').strip()
    rows = Profile.objects.filter(Q(professional_requested=True) | Q(professional_verified=True)).filter(
        Q(user__username__icontains=q) | Q(user__email__icontains=q) |
        Q(application__full_name__icontains=q) | Q(application__registration_number__icontains=q))
    status = request.query_params.get('status', '')
    if status == 'pending':
        rows = rows.filter(application__status='pending', user__is_active=True)
    elif status == 'verified':
        rows = rows.filter(application__status='approved', professional_verified=True, user__is_active=True)
    elif status == 'revoked':
        rows = rows.filter(Q(application__status='revoked') | Q(application__status='approved', professional_verified=False))
    elif status == 'rejected':
        rows = rows.filter(application__status='rejected')
    elif status == 'incomplete':
        rows = rows.filter(application__isnull=True)
    paginator = PageNumberPagination()
    paginator.page_size = 20
    fields = ['full_name','profession','registration_number','issuer','institution','location','phone','submitted_at','reason']
    selected = paginator.paginate_queryset(rows.order_by('id').values('id','user__username','user__email','user__is_active','professional_verified','application__status', *['application__'+f for f in fields]), request)
    results = []
    for row in selected:
        state = row.pop('application__status') or 'incomplete'
        if state == 'approved' and not row['professional_verified']:
            state = 'revoked'
        row['application_status'] = state
        row['professional_verified'] = bool(state == 'approved' and row['user__is_active'])
        for f in fields:
            row[f] = row.pop('application__'+f)
        results.append(row)
    response = paginator.get_paginated_response(results)
    response['Cache-Control'] = 'no-store, private'
    return response''')
s = replace_function(s, 'verify_professional', '''@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def verify_professional(request, pk):
    return decide(request, pk)

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def professional_proof(request, pk):
    return proof_response(pk)''')
files[admin] = s
urls = root/'backend/core/admin_urls.py'
s = urls.read_text()
s += "\nurlpatterns += [path('professionals/<int:pk>/proof/', a.professional_proof)]\n"
files[urls] = s
urls = root/'backend/config/urls.py'
s = urls.read_text()
s += "\nurlpatterns += [path('api/professional/application/', views.apply_professional)]\n"
files[urls] = s
# Keep native Django admin as read-only for professional flags to avoid bypass.
# The effective permission also requires the new approved dossier, regardless of old CLI.
for path, text in files.items():
    ast.parse(text, filename=str(path))
for path, text in files.items():
    path.write_text(text)
MEDIPATCH
cat > "$tmp/App.js" <<'MEDIMOBILE'
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
MEDIMOBILE
cat > "$tmp/main.jsx" <<'MEDIADMIN'
import React, { useState, useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import './style.css';

async function api(path, token='', method='GET', data=null) {
  const res = await fetch('/api/'+path, {method, headers:{Accept:'application/json', ...(token?{Authorization:`Bearer ${token}`} : {}), ...(data!==null?{'Content-Type':'application/json'}:{})}, ...(data!==null?{body:JSON.stringify(data)}:{})});
  const result = await res.json().catch(()=>null);
  if (!res.ok) { const e = new Error(result?.detail || (result?JSON.stringify(result):`HTTP ${res.status}`)); e.status=res.status; throw e; }
  return result;
}
const sections = {overview:'Tableau de bord',professionals:'Professionnels de santé',users:'Utilisateurs',medicines:'Médicaments',reports:'Signalements'};
function App(){
  const [token,T]=useState(''), [username,U]=useState(''), [password,P]=useState('');
  const [section,S]=useState('overview'), [stats,Stats]=useState(null), [data,D]=useState(null);
  const [q,Q]=useState(''), [search,Search]=useState(''), [filter,F]=useState(''), [page,Page]=useState(1), [revision,R]=useState(0);
  const [error,E]=useState(''), [message,M]=useState(''), [loading,L]=useState(false), [busy,B]=useState(false);
  function logout(){T('');P('');D(null);Stats(null);S('overview');Q('');Search('');F('');Page(1);M('');E('');}
  function fail(e){if(e.status===401||e.status===403){logout();E('Session expirée ou accès administrateur refusé.');}else E(e.message);}
  async function login(e){e.preventDefault();B(true);E('');try{const j=await api('token/','','POST',{username,password});const info=await api('admin/overview/',j.access);Stats(info);P('');T(j.access);}catch(e){E(e.message);}finally{B(false);}}
  function navigate(key){S(key);Q('');Search('');F('');Page(1);D(null);E('');M('');}
  useEffect(()=>{if(!token)return;let alive=true;L(true);E('');D(null);
    const path=section==='overview'?'admin/overview/':`admin/${section}/?${new URLSearchParams({q:search,status:filter,page:String(page)})}`;
    api(path,token).then(j=>{if(alive){if(section==='overview')Stats(j);else D(j);}}).catch(e=>{if(alive)fail(e);}).finally(()=>{if(alive)L(false);});
    return()=>{alive=false;};
  },[token,section,search,filter,page,revision]);
  async function action(path,payload,question){if(!window.confirm(question))return;B(true);E('');M('');try{await api(path,token,'PATCH',payload);M('Modification enregistrée.');Page(1);R(x=>x+1);}catch(e){fail(e);}finally{B(false);}}
  async function downloadProof(id){
    B(true); E('');
    try {
      const res=await fetch(`/api/admin/professionals/${id}/proof/`,{headers:{Authorization:`Bearer ${token}`}});
      if(!res.ok){const e=new Error('Impossible de télécharger le justificatif.');e.status=res.status;throw e;}
      const url=URL.createObjectURL(await res.blob());
      const link=document.createElement('a');link.href=url;
      link.download=res.headers.get('Content-Disposition')?.match(/filename="([^"]+)"/)?.[1]||'justificatif';
      document.body.appendChild(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
    }catch(e){fail(e);}finally{B(false);}
  }
  function decide(r, verified){
    let reason='';
    if(!verified){const answer=window.prompt('Motif du refus ou de la révocation (obligatoire) :');if(!answer?.trim())return;reason=answer.trim();}
    action(`admin/professionals/${r.id}/`,{verified,reason},verified?'Confirmez-vous avoir vérifié le justificatif et le numéro professionnel auprès de son organisme émetteur ?':'Confirmer la décision ?');
  }
  if(!token)return <main className="login"><div className="login-art"><div className="mark">M+</div><h1>MediCheck AI</h1><p>Information pharmaceutique et supervision.</p><span>PORTAIL ADMINISTRATEUR</span></div><form className="login-form" onSubmit={login}><div className="eyebrow">ESPACE SÉCURISÉ</div><h1>Connexion</h1><p>Utilisez votre compte administrateur Django.</p>{error&&<div role="alert" className="error">{error}</div>}<label>Identifiant<input required autoComplete="username" value={username} onChange={e=>U(e.target.value)}/></label><label>Mot de passe<input required type="password" autoComplete="current-password" value={password} onChange={e=>P(e.target.value)}/></label><button disabled={busy}>{busy?'Connexion…':'Se connecter'}</button></form></main>;
  const rows=data?.results||[];
  return <div className="layout"><aside><div className="brand">MediCheck <span>AI</span><small>Administration</small></div><nav>{Object.entries(sections).map(([k,v])=><button key={k} disabled={busy} className={section===k?'selected':''} onClick={()=>navigate(k)}>{v}</button>)}</nav><button className="logout" disabled={busy} onClick={logout}>Se déconnecter</button></aside><main className="workspace"><header><div><div className="eyebrow">ESPACE ADMINISTRATION</div><h1>{sections[section]}</h1></div><span className="tag">{stats?.username||username}</span></header>{error&&<div role="alert" className="error">{error} <button className="secondary" onClick={()=>R(x=>x+1)}>Réessayer</button></div>}{message&&<div role="status" className="notice">{message}</div>}
  {section==='overview'?<><div className="hero"><h2>Bienvenue dans votre espace de gestion</h2><p>Consultez les demandes et supervisez le catalogue de MediCheck AI.</p></div>{loading&&<p>Chargement…</p>}{stats&&<div className="cards">{[['Utilisateurs','users','users'],['Médicaments','medicines','medicines'],['Demandes en attente','pending','professionals'],['Professionnels validés','verified','professionals'],['Signalements','reports','reports']].map(([label,k,target])=><button className="stat" key={k} onClick={()=>{navigate(target);if(k==='pending'||k==='verified')F(k);}}><span>{label}</span><strong>{stats[k]}</strong><small>Consulter</small></button>)}</div>}</>:<section className="panel"><div className="toolbar"><form onSubmit={e=>{e.preventDefault();Page(1);Search(q.trim());}}><input aria-label="Rechercher" placeholder="Rechercher…" value={q} onChange={e=>Q(e.target.value)}/><button disabled={loading||busy}>Rechercher</button></form>{section==='professionals'&&<select aria-label="Statut" value={filter} disabled={busy} onChange={e=>{F(e.target.value);Page(1);}}><option value="">Tous les statuts</option><option value="pending">En attente</option><option value="verified">Validés</option><option value="rejected">Refusés</option><option value="revoked">Révoqués</option><option value="incomplete">Incomplets</option></select>}</div>
  {section==='professionals'&&<p className="hint">Consultez le dossier et vérifiez les justificatifs auprès de l’organisme émetteur avant de valider.</p>}
  {loading?<p>Chargement…</p>:data&&<><div className="table-wrap"><table><thead><tr>{(section==='professionals'?['Identifiant','Dossier professionnel','Statut','Action']:section==='users'?['Identifiant','Email','Statut','Action']:section==='medicines'?['Médicament','Auteur','Publication','Source']:['Médicament','Type','Utilisateur','Description','Date']).map(h=><th key={h}>{h}</th>)}</tr></thead><tbody>{rows.map(r=><tr key={r.id}>{section==='professionals'?<><td>{r.user__username}<br/><small>{r.user__email}</small></td><td>{r.application_status==='incomplete'?<span>Dossier à compléter</span>:<details><summary>{r.full_name} — {r.profession}</summary><p>Matricule : {r.registration_number}<br/>Organisme : {r.issuer}<br/>Établissement : {r.institution}<br/>Ville / pays : {r.location}<br/>Téléphone : {r.phone}<br/>Déposé le : {new Date(r.submitted_at).toLocaleString('fr-FR')}</p><button className="secondary" disabled={busy} onClick={()=>downloadProof(r.id)}>Télécharger le justificatif</button></details>}</td><td><span className="tag">{!r.user__is_active?'Suspendu':({pending:'En attente',approved:'Validé',rejected:'Refusé',revoked:'Révoqué',incomplete:'Incomplet'}[r.application_status])}</span>{r.reason&&<p>{r.reason}</p>}</td><td>{r.application_status==='pending'&&<div style={{display:'flex',gap:8,flexWrap:'wrap'}}><button disabled={busy||!r.user__is_active} onClick={()=>decide(r,true)}>Valider</button><button className="danger" disabled={busy} onClick={()=>decide(r,false)}>Refuser</button></div>}{r.application_status==='approved'&&<button className="danger" disabled={busy} onClick={()=>decide(r,false)}>Révoquer</button>}</td></>:section==='users'?<><td>{r.username}</td><td>{r.email}</td><td>{r.is_staff||r.is_superuser?'Administrateur / staff':r.is_active?'Actif':'Suspendu'}</td><td>{!(r.is_staff||r.is_superuser)&&<button className={r.is_active?'danger':'primary'} disabled={busy} onClick={()=>action(`admin/users/${r.id}/`,{active:!r.is_active},'Confirmer la modification du compte ?')}>{r.is_active?'Suspendre':'Réactiver'}</button>}</td></>:section==='medicines'?<><td>{r.name}</td><td>{r.author__username}</td><td>{r.published?'Publié (démo possible)':'Non publié'}</td><td>{/^https?:\/\//i.test(r.source||'')?<a href={r.source} target="_blank" rel="noreferrer">Consulter</a>:'—'}</td></>:<><td>{r.medicine}</td><td>{{expired:'Périmé',suspect:'Suspect',adverse:'Effet indésirable'}[r.kind]||r.kind}</td><td>{r.user__username}</td><td>{r.details}</td><td>{new Date(r.created).toLocaleString('fr-FR')}</td></>}</tr>)}</tbody></table></div>{rows.length===0&&<p className="hint">Aucun résultat.</p>}<div className="pagination"><span>{data.count} résultat(s) · Page {page} / {Math.max(1,Math.ceil(data.count/20))}</span><div><button className="secondary" disabled={busy||!data.previous} onClick={()=>Page(p=>p-1)}>Précédent</button> <button disabled={busy||!data.next} onClick={()=>Page(p=>p+1)}>Suivant</button></div></div></>}
  </section>}
  <footer>MediCheck AI · Prototype de développement · Les fiches publiées ne prouvent pas une validation médicale.</footer></main></div>;
}
createRoot(document.getElementById('root')).render(<App/>);
MEDIADMIN
python3 "$tmp/patch_backend.py" "$tmp"
cp "$tmp/professional_api.py" backend/core/professional_api.py
cp "$tmp/App.js" mobile/App.js
cp "$tmp/main.jsx" admin-web/src/main.jsx
(cd backend && uv run python manage.py check && uv run python manage.py makemigrations core && uv run python manage.py migrate)
(cd admin-web && npm run build)
echo 'Mise à jour installée. Redémarrez Django, Expo et le portail admin.'
