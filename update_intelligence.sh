#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/Bureau/MediCheck}"
cd "$ROOT"; ROOT="$(pwd)"
for cmd in uv python3 npm npx tesseract; do
  command -v "$cmd" >/dev/null || { echo "Commande manquante : $cmd. Pour OCR : sudo apt install tesseract-ocr tesseract-ocr-fra tesseract-ocr-eng" >&2; exit 1; }
done
for lang in fra eng; do tesseract --list-langs 2>/dev/null | grep -qx "$lang" || { echo "Langue OCR manquante : $lang"; exit 1; }; done
for f in backend/core/review_service.py backend/core/medicine_identity.py mobile/ReviewPanel.js; do
  [[ -f "$f" ]] || { echo "Installer d'abord update_reviews.sh : $f manquant"; exit 1; }
done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'echo "Installation interrompue. Sauvegarde éventuelle : ${backup:-non créée}. Ne supprimez pas votre base." >&2' ERR
(cd backend && uv run python manage.py migrate --check && uv run python manage.py makemigrations --check --dry-run)
cat > "$TMP/patch.py" <<'MEDICHECK_INTEL_FILE'
from pathlib import Path
import sys,ast
root,assets,out=map(Path,sys.argv[1:]); files={}
def read(p):return (root/p).read_text()
def change(s,a,b):
    if s.count(a)!=1:raise SystemExit('Version inattendue : '+a[:120])
    return s.replace(a,b)
def add(p,src):
    if (root/p).exists():raise SystemExit('Déjà présent : '+p)
    files[p]=(assets/src).read_text()
p='backend/core/models.py';s=read(p)
if 'ReviewCycle' not in s or 'MedicineReference' in s:raise SystemExit('Installer update_reviews.sh avant ce script ou module déjà installé.')
files[p]=s+'\nfrom .reference_models import MedicineReference, MedicinePresentation\n'
for n in ('reference_models.py','intelligence_api.py','intelligence_urls.py','test_intelligence.py'):add('backend/core/'+n,n)
add('backend/core/management/commands/import_reference.py','import_reference.py')
for p in ('backend/core/management/__init__.py','backend/core/management/commands/__init__.py'):
    if not (root/p).exists():files[p]=''
p='backend/config/urls.py';files[p]=read(p)+"\nfrom django.urls import include\nurlpatterns += [path('api/', include('core.intelligence_urls'))]\n"
p='backend/config/settings.py';files[p]=read(p)+'\n# JSON base64 OCR: 5 Mo image maximum, limite globale 8 Mo.\nDATA_UPLOAD_MAX_MEMORY_SIZE = 8 * 1024 * 1024\n'
p='backend/core/views.py';s=read(p);node=next(n for n in ast.parse(s).body if isinstance(n,ast.ClassDef) and n.name=='MedicineSerializer');lines=s.splitlines(keepends=True);start=node.lineno-1;end=node.end_lineno;block=''.join(lines[start:end]);import re
if 'reference' in block:raise SystemExit('Serializer personnalisé : patch annulé.')
block=re.sub(r"fields\s*=\s*\[([^\]]*)\]",lambda m:'fields=['+m.group(1)+",'reference']",block,count=1)
if "'reference'" not in block:raise SystemExit('Champs du serializer non reconnus.')
block=block.replace('class MedicineSerializer(serializers.ModelSerializer):','class MedicineSerializer(serializers.ModelSerializer):\n    reference = serializers.SerializerMethodField()\n\n    def get_reference(self, obj):\n        from .intelligence_api import reference_data\n        ref = getattr(obj, "reference", None)\n        return reference_data(ref) if ref and obj.published else None\n',1)
s=''.join(lines[:start])+block+''.join(lines[end:]);files[p]=s
p='mobile/App.js';s=read(p);s=change(s,"import ReviewPanel from './ReviewPanel';","import ReviewPanel from './ReviewPanel';\nimport IntelligencePanel, {ReferenceDetails} from './IntelligencePanel';")
# New services outside primary navigation to respect previous usager menu request.
anchor="                <BillingPanel api={api} token={token} verified={canPropose} />"
s=change(s,anchor,"                <View style={s.navigation}><Button title=\"Scanner et vérifier\" variant={screen === 'scanner' ? 'primary' : 'secondary'} disabled={busy} onPress={() => changeScreen('scanner')}/><Button title=\"Assistant IA\" variant={screen === 'assistant' ? 'primary' : 'secondary'} disabled={busy} onPress={() => changeScreen('assistant')}/></View>\n"+anchor)
s=change(s,"</> : canPropose && ['validations','myproposals','notifications'].includes(screen)","</> : ['scanner','assistant'].includes(screen) ? <IntelligencePanel key={screen} api={api} token={token} section={screen}/> : canPropose && ['validations','myproposals','notifications'].includes(screen)")
s=change(s,"<Text style={s.description}>{medicine.description || 'Description indisponible.'}</Text>","<Text style={s.description}>{medicine.description || 'Description indisponible.'}</Text>\n                        <ReferenceDetails reference={medicine.reference}/>")
files[p]=s;add('mobile/IntelligencePanel.js','IntelligencePanel.js')
for p,s in files.items():
    if p.endswith('.py'):ast.parse(s,filename=p)
    target=out/p;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(s)

MEDICHECK_INTEL_FILE
cat > "$TMP/reference_models.py" <<'MEDICHECK_INTEL_FILE'
from django.db import models

class MedicineReference(models.Model):
    medicine = models.OneToOneField('core.Medicine', on_delete=models.CASCADE, related_name='reference')
    cis = models.CharField(max_length=8, unique=True)
    official_name = models.TextField()
    form = models.TextField(blank=True)
    route = models.TextField(blank=True)
    holder = models.TextField(blank=True)
    authorization = models.TextField(blank=True)
    market = models.TextField(blank=True)
    components = models.JSONField(default=list)
    prescription = models.JSONField(default=list)
    imported_at = models.DateTimeField(auto_now=True)

class MedicinePresentation(models.Model):
    reference = models.ForeignKey(MedicineReference, on_delete=models.CASCADE, related_name='presentations')
    cip13 = models.CharField(max_length=13, unique=True)
    cip7 = models.CharField(max_length=7, blank=True)
    label = models.TextField()
    market = models.TextField(blank=True)

MEDICHECK_INTEL_FILE
cat > "$TMP/import_reference.py" <<'MEDICHECK_INTEL_FILE'
import csv, io, re
from collections import defaultdict
from pathlib import Path
from urllib.request import urlopen, Request
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from core.models import Medicine, MedicineReference, MedicinePresentation
from core.medicine_identity import normalize_name

BASE='https://base-donnees-publique.medicaments.gouv.fr/download/file/'
FILES={'cis':'CIS_bdpm.txt','cip':'CIS_CIP_bdpm.txt','compo':'CIS_COMPO_bdpm.txt','cpd':'CIS_CPD_bdpm.txt'}

def read_rows(name, directory):
    if directory:
        data=(Path(directory)/name).read_bytes()
    else:
        with urlopen(Request(BASE+name,headers={'User-Agent':'MediCheck-reference-import/1.0'}),timeout=90) as response:
            data=response.read(50_000_001)
    if not data or len(data)>50_000_000: raise ValueError('Fichier vide ou trop volumineux : '+name)
    try: text=data.decode('utf-8-sig')
    except UnicodeDecodeError: text=data.decode('cp1252')
    rows=list(csv.reader(io.StringIO(text), delimiter='\t'))
    if not rows or not any(re.fullmatch(r'\d{8}',r[0]) for r in rows if r): raise ValueError('Format BDPM inattendu : '+name)
    return rows

def parse_files(data):
    cis={}; cip=defaultdict(list); comp=defaultdict(list); cpd=defaultdict(list); seen={}
    for r in data['cis']:
        if len(r)>=11 and re.fullmatch(r'\d{8}',r[0]):
            cis[r[0]]=dict(official_name=r[1],form=r[2],route=r[3],authorization=r[4],market=r[6],holder=r[10])
    for r in data['cip']:
        if len(r)>=7 and r[0] in cis and re.fullmatch(r'\d{13}',r[6]):
            if r[6] in seen:
                if seen[r[6]]!=r[0]: raise ValueError('CIP13 ambigu : '+r[6])
                continue
            seen[r[6]]=r[0]; cip[r[0]].append(dict(cip13=r[6],cip7=r[1] if re.fullmatch(r'\d{7}',r[1]) else '',label=r[2],market=r[4]))
    for r in data['compo']:
        if len(r)>=7 and r[0] in cis and r[6]=='SA':
            entry=dict(substance=r[3],strength=r[4],basis=r[5]);
            if entry not in comp[r[0]]: comp[r[0]].append(entry)
    for r in data['cpd']:
        if len(r)>=2 and r[0] in cis and r[1] not in cpd[r[0]]: cpd[r[0]].append(r[1])
    if not cis or not cip or not comp: raise ValueError('Données officielles insuffisantes, import annulé.')
    return cis,cip,comp,cpd

class Command(BaseCommand):
    help='Enrichit uniquement les fiches publiées avec CIS existant, sans changer les propositions ni leur publication.'
    def add_arguments(self,p):
        p.add_argument('--directory'); p.add_argument('--dry-run',action='store_true')
    def handle(self,*args,**opts):
        try: cis,cip,comp,cpd=parse_files({k:read_rows(v,opts['directory']) for k,v in FILES.items()})
        except Exception as e: raise CommandError(str(e)) from e
        matches=[m for m in Medicine.objects.filter(published=True,official_cis__isnull=False) if m.official_cis in cis and normalize_name(m.name)==normalize_name(cis[m.official_cis]['official_name'])]
        self.stdout.write(f'{len(matches)} fiches correspondantes; {sum(len(cip[m.official_cis]) for m in matches)} présentations.')
        if not matches: raise CommandError('Aucun CIS correspondant. Vérifiez les médicaments importés.')
        if opts['dry_run']: return
        with transaction.atomic():
            # Les références importées sont un instantané ; aucune fiche clinique n’est modifiée.
            MedicineReference.objects.all().delete()
            for m in matches:
                k=m.official_cis
                ref=MedicineReference.objects.create(medicine=m,cis=k,**cis[k],components=comp[k],prescription=cpd[k])
                MedicinePresentation.objects.bulk_create([MedicinePresentation(reference=ref,**r) for r in cip[k]])
        self.stdout.write(self.style.SUCCESS('Références BDPM actualisées.'))

MEDICHECK_INTEL_FILE
cat > "$TMP/intelligence_api.py" <<'MEDICHECK_INTEL_FILE'
import base64, binascii, io, json, os, re, subprocess, tempfile
from datetime import date
from urllib.request import Request, urlopen
from urllib.error import URLError
from django.db.models import Q
from django.utils import timezone
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes, throttle_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.throttling import UserRateThrottle
from rest_framework.response import Response
from .models import Medicine, MedicineReference, MedicinePresentation
from .medicine_identity import normalize_name

NOTICE='Correspondance dans la BDPM française ou le catalogue local, pas une preuve d’authenticité, d’autorisation au Cameroun ou de sécurité d’utilisation. Demandez conseil à un pharmacien.'
class ScanThrottle(UserRateThrottle):
    scope='medicheck_scan'
    def get_rate(self): return '20/min'
class ChatThrottle(UserRateThrottle):
    scope='medicheck_chat'
    def get_rate(self): return '8/min'

def reference_data(ref):
    return dict(official_name=ref.official_name,form=ref.form,route=ref.route,holder=ref.holder,authorization=ref.authorization,market=ref.market,components=ref.components,prescription=ref.prescription,imported_at=ref.imported_at,source='https://base-donnees-publique.medicaments.gouv.fr/medicament/'+ref.cis+'/extrait',presentations=list(ref.presentations.values('cip13','cip7','label','market')))

def medicine_data(m):
    ref=getattr(m,'reference',None)
    return dict(id=m.pk,name=m.name,description=m.description,source=m.source,reference=reference_data(ref) if ref else None)

def tokens(text):
    return set(re.findall(r'[a-z0-9]{2,}',normalize_name(text)))
STOP=set('quel quelle quels quelles est sont avec dans pour sur une des les du de la le un et au aux ce cette que qui comment medicament medicaments composition substance dosage forme voie principe actif puis moi pouvez vous donner savoir'.split())

def candidates(text, limit=8, official_only=False):
    query=tokens(text)-STOP
    if not query: return []
    qs=Medicine.objects.filter(published=True).select_related('reference').prefetch_related('reference__presentations')
    if official_only: qs=qs.filter(reference__isnull=False)
    scored=[]
    for m in qs[:10000]:
        ref=getattr(m,'reference',None)
        words=tokens(m.name)
        substances=tokens(' '.join(x.get('substance','') for x in ref.components)) if ref else set()
        overlap=query & (words|substances)
        if overlap and any(not t.isdigit() for t in overlap):
            score=4*len(query&words)+2*len(query&substances)
            if normalize_name(m.name) in normalize_name(text):score+=12
            scored.append((score,m.pk,m))
    return [m for _,_,m in sorted(scored,key=lambda x:(-x[0],x[1]))[:limit]]

def code_from(raw):
    raw=raw.strip()
    # GS1 DataMatrix: identifiant (01), suivi du GTIN-14 ; ne pas interpréter les autres champs.
    match=re.match(r'^(?:\]d2)?(?:\(01\)|01)(\d{14})(?:\D|\d|$)',raw)
    if match and match[1].startswith('0'): return match[1][1:]
    if re.fullmatch(r'\d{14}',raw) and raw.startswith('0'):return raw[1:]
    if re.fullmatch(r'\d{7}|\d{13}',raw):return raw
    return ''

def lookup(raw):
    code=code_from(raw)
    if not code: return []
    filt=Q(cip13=code) if len(code)==13 else Q(cip7=code)
    return list(MedicinePresentation.objects.filter(filt,reference__medicine__published=True).select_related('reference__medicine')[:10])

class VerifyInput(serializers.Serializer):
    code=serializers.CharField(max_length=300,required=False,allow_blank=True,default='')
    name=serializers.CharField(max_length=200,required=False,allow_blank=True,default='')
    expiry=serializers.DateField(required=False,allow_null=True,default=None)
    def validate(self,d):
        if not d['code'] and not d['name']: raise serializers.ValidationError('Renseignez un code ou un nom.')
        return d

@api_view(['POST'])
@permission_classes([IsAuthenticated])
@throttle_classes([ScanThrottle])
def verify(request):
    s=VerifyInput(data=request.data);s.is_valid(raise_exception=True);d=s.validated_data
    hits=lookup(d['code']) if d['code'] else []
    if hits:
        matches=list({p.reference.medicine_id:p.reference.medicine for p in hits}.values());status='code_found' if len(matches)==1 else 'ambiguous'
    else:
        matches=candidates(d['name']) if d['name'] else [];status='name_candidates' if matches else 'not_found'
    warnings=[]
    if d['code'] and not hits:warnings.append('Code non reconnu dans les présentations importées.')
    if hits and d['name'] and not any(normalize_name(d['name'])==normalize_name(m.name) for m in matches):warnings.append('Le nom saisi ne correspond pas exactement à la dénomination enregistrée ; vérifier la boîte.')
    expiry='unknown' if d['expiry'] is None else 'expired' if d['expiry']<timezone.localdate() else 'not_expired_by_entered_date'
    if expiry=='expired':warnings.append('La date saisie est dépassée. Ne pas utiliser le produit périmé.')
    return Response(dict(status=status,matches=[medicine_data(m) for m in matches],presentations=[dict(code=p.cip13,label=p.label) for p in hits],expiry=expiry,warnings=warnings,notice=NOTICE))

@api_view(['POST'])
@permission_classes([IsAuthenticated])
@throttle_classes([ScanThrottle])
def ocr(request):
    from PIL import Image, ImageOps, UnidentifiedImageError
    raw=request.data.get('image','')
    if not isinstance(raw,str) or not raw or len(raw)>7_000_000:return Response({'detail':'Image JPEG/PNG obligatoire, maximum 5 Mo.'},status=400)
    try:
        binary=base64.b64decode(raw,validate=True)
        if len(binary)>5_000_000:raise ValueError()
        with Image.open(io.BytesIO(binary)) as img:
            if img.format not in ('JPEG','PNG') or img.width*img.height>20_000_000:raise ValueError()
            img=ImageOps.exif_transpose(img).convert('L');img.thumbnail((2200,2200))
            with tempfile.TemporaryDirectory() as tmp:
                path=os.path.join(tmp,'input.png');img.save(path)
                result=subprocess.run(['tesseract',path,'stdout','-l','fra+eng','--psm','11'],capture_output=True,timeout=20,check=True)
        text=result.stdout.decode('utf-8',errors='replace')[:6000]
    except (ValueError,binascii.Error,UnidentifiedImageError,OSError,Image.DecompressionBombError):return Response({'detail':'Image invalide ou moteur OCR indisponible.'},status=400)
    except (subprocess.TimeoutExpired,subprocess.CalledProcessError):return Response({'detail':'OCR indisponible ou délai dépassé.'},status=503)
    return Response(dict(text=text,matches=[medicine_data(m) for m in candidates(text)],notice='OCR approximatif : confirmez le nom et la date manuellement. '+NOTICE))

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def reference(request,pk):
    m=Medicine.objects.filter(pk=pk,published=True).select_related('reference').first()
    if not m:return Response({'detail':'Fiche introuvable.'},status=404)
    return Response(medicine_data(m))

class ChatInput(serializers.Serializer):
    question=serializers.CharField(max_length=500)
    medicine_id=serializers.IntegerField(required=False,min_value=1)
    external=serializers.BooleanField(default=False)

@api_view(['POST'])
@permission_classes([IsAuthenticated])
@throttle_classes([ChatThrottle])
def chat(request):
    s=ChatInput(data=request.data);s.is_valid(raise_exception=True);d=s.validated_data
    # Retrieval strictly uses imported reference metadata, never arbitrary user proposals.
    refs=candidates(d['question'],limit=5,official_only=True) if not d.get('medicine_id') else list(Medicine.objects.filter(pk=d['medicine_id'],published=True,reference__isnull=False).select_related('reference'))
    if not refs:return Response(dict(mode='no_source',answer='Aucune référence officielle correspondante. Recherchez un nom précis dans le catalogue ou demandez conseil à un pharmacien.',sources=[],notice=NOTICE))
    sources=[]
    for m in refs:
        r=m.reference
        sources.append(dict(id=m.id,name=r.official_name,form=r.form,route=r.route,holder=r.holder,components=r.components,authorization=r.authorization,market=r.market,url='https://base-donnees-publique.medicaments.gouv.fr/medicament/'+r.cis+'/extrait'))
    # Only allow factual metadata; the LLM chooses fields, never generates medical claims shown to users.
    fields={'name':'Dénomination','form':'Forme','route':'Voie','holder':'Titulaire de l’AMM','components':'Composition','authorization':'Statut AMM France','market':'Commercialisation France'}
    chosen=list(fields); mode='retrieval'
    key=os.environ.get('GROQ_API_KEY');model=os.environ.get('GROQ_MODEL','openai/gpt-oss-20b')
    if d['external'] and key:
        payload={'model':model,'messages':[{'role':'system','content':'Sélectionne uniquement les clés de métadonnées pertinentes à la question. Ne donne aucun conseil médical. Réponds uniquement par un objet JSON {"fields": ["name", "form", "route", "holder", "components", "authorization", "market"]} en choisissant les clés utiles. Si question clinique ou hors sujet, retourne {"fields": []}.'},{'role':'user','content':json.dumps({'question':d['question'],'available_fields':fields,'references':sources},ensure_ascii=False)}],'response_format':{'type':'json_object'},'temperature':0,'max_completion_tokens':300}
        try:
            req=Request('https://api.groq.com/openai/v1/chat/completions',data=json.dumps(payload).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'},method='POST')
            with urlopen(req,timeout=15) as res:result=json.loads(res.read(500000))
            selected=json.loads(result['choices'][0]['message']['content'])['fields']
            if isinstance(selected,list): chosen=[f for f in fields if f in selected];mode='rag_groq'
        except (URLError,TimeoutError,ValueError,KeyError,TypeError,IndexError,OSError):mode='retrieval_fallback'
    lines=['Informations de référence disponibles (pas de posologie ni de recommandation de traitement).']
    for i,r in enumerate(sources,1):
        lines.append(f'\n[{i}] {r["name"]}')
        for f in chosen:
            if f=='name':continue
            val=r[f]
            if f=='components':val=' ; '.join(' '.join(str(x.get(k,'')) for k in ('substance','strength','basis')).strip() for x in val)
            if val:lines.append(fields[f]+' : '+str(val))
    if not chosen:lines=['La question dépasse les informations factuelles disponibles. Consultez la notice officielle et un professionnel de santé.']
    return Response(dict(mode=mode,answer='\n'.join(lines),sources=[dict(id=r['id'],name=r['name'],url=r['url']) for r in sources],notice=NOTICE))

MEDICHECK_INTEL_FILE
cat > "$TMP/intelligence_urls.py" <<'MEDICHECK_INTEL_FILE'
from django.urls import path
from . import intelligence_api as api
urlpatterns=[path('intelligence/verify/',api.verify),path('intelligence/ocr/',api.ocr),path('intelligence/chat/',api.chat),path('intelligence/reference/<int:pk>/',api.reference)]

MEDICHECK_INTEL_FILE
cat > "$TMP/test_intelligence.py" <<'MEDICHECK_INTEL_FILE'
from datetime import date,timedelta
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APITestCase
from .models import Medicine, MedicineReference, MedicinePresentation
from .intelligence_api import code_from

class IntelligenceTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user=get_user_model().objects.create_user(username='intelligence-test')
        self.client.force_authenticate(self.user)
        self.med=Medicine.objects.create(author=self.user,name='Exemple unique 25 mg',description='Démonstration fictive',source='https://base-donnees-publique.medicaments.gouv.fr/medicament/12345678/extrait',published=True)
        self.ref=MedicineReference.objects.create(medicine=self.med,cis="12345678",official_name=self.med.name,components=[{'substance':'Exemple','strength':'25 mg','basis':'par unité'}])
        MedicinePresentation.objects.create(reference=self.ref,cip13='3400000000001',cip7='1234567',label='Boîte test')
    def test_codes(self):
        self.assertEqual(code_from('(01)03400000000001(17)301201'),'3400000000001')
        self.assertEqual(code_from('3400000000001'),'3400000000001')
        self.assertEqual(code_from('https://example.org'),'')
    def test_verify_and_unpublished(self):
        r=self.client.post('/api/intelligence/verify/',{'code':'3400000000001','expiry':str(timezone.localdate()-timedelta(days=1))},format='json')
        self.assertEqual(r.status_code,200,r.data);self.assertEqual(r.data['status'],'code_found');self.assertEqual(r.data['expiry'],'expired')
        self.med.published=False;self.med.save(update_fields=['published'])
        r=self.client.post('/api/intelligence/verify/',{'code':'3400000000001'},format='json');self.assertEqual(r.data['status'],'not_found')
        self.assertEqual(self.client.get(f'/api/intelligence/reference/{self.med.pk}/').status_code,404)
    def test_chat_retrieval(self):
        r=self.client.post('/api/intelligence/chat/',{'question':'Composition Exemple unique','external':False},format='json');self.assertEqual(r.status_code,200);self.assertEqual(r.data['mode'],'retrieval');self.assertIn('25 mg',r.data['answer'])
        r=self.client.post('/api/intelligence/chat/',{'question':'zzzzzz','external':False},format='json');self.assertEqual(r.data['mode'],'no_source')
    def test_permissions_and_invalid_ocr(self):
        self.assertEqual(self.client.post('/api/intelligence/ocr/',{'image':'not base64'},format='json').status_code,400)
        self.client.force_authenticate(None)
        self.assertIn(self.client.post('/api/intelligence/verify/',{'code':'3400000000001'},format='json').status_code,[401,403])

MEDICHECK_INTEL_FILE
cat > "$TMP/IntelligencePanel.js" <<'MEDICHECK_INTEL_FILE'
import React,{useRef,useState} from 'react';
import {View,Text,TextInput,Pressable,StyleSheet,ActivityIndicator,Linking,Platform} from 'react-native';
import {CameraView,useCameraPermissions} from 'expo-camera';
import * as ImagePicker from 'expo-image-picker';
import {colors as c} from './theme';
function Button({title,onPress,disabled=false,secondary=false}){return <Pressable accessibilityRole="button" onPress={onPress} disabled={disabled} style={[s.button,{backgroundColor:secondary?c.secondary:c.primary,opacity:disabled ? 0.45 : 1}]}><Text style={{color:secondary?c.text:'#fff',fontWeight:'700',textAlign:'center'}}>{title}</Text></Pressable>}
function Source({url}){return /^https?:\/\//i.test(url||'')?<Pressable onPress={()=>Linking.openURL(url).catch(()=>{})}><Text style={s.link}>{url}</Text></Pressable>:null}
export function ReferenceDetails({reference:r}){if(!r)return null;return <View style={s.card}><Text style={s.label}>Référence officielle française</Text><Text style={s.body}>{r.official_name}</Text>{[['Forme',r.form],['Voie',r.route],['Titulaire AMM',r.holder],['AMM France',r.authorization],['Commercialisation France',r.market]].map(([k,v])=>!!v&&<Text key={k} style={s.body}>{k} : {v}</Text>)}{r.components?.map((x,i)=><Text key={i} style={s.body}>{x.substance} — {x.strength} {x.basis}</Text>)}{!!r.prescription?.length&&<Text style={s.body}>Délivrance (France) : {r.prescription.join(' ; ')}</Text>}{!!r.presentations?.length&&<Text style={s.body}>{r.presentations.length} présentation(s) · CIP : {r.presentations.slice(0,5).map(x=>x.cip13).join(', ')}</Text>}<Text style={s.muted}>Données importées le {new Date(r.imported_at).toLocaleDateString('fr-FR')}. Autorisation au Cameroun non vérifiée.</Text><Source url={r.source}/></View>}
export default function IntelligencePanel({api,token,section}){
 const [permission,requestPermission]=useCameraPermissions(),[camera,Cam]=useState(false),[code,Code]=useState(''),[name,Name]=useState(''),[expiry,Expiry]=useState(''),[ocrText,Ocr]=useState(''),[results,Results]=useState(null),[error,E]=useState(''),[busy,B]=useState(false),[question,Q]=useState(''),[history,H]=useState([]),[external,X]=useState(false),[selected,S]=useState(null);const lock=useRef(false), scanned=useRef(false);
 async function run(fn){if(lock.current)return;lock.current=true;B(true);E('');try{await fn()}catch(e){E(e.message||String(e))}finally{lock.current=false;B(false)}}
 async function verify(raw=code){Results(null);Results(await api('intelligence/verify','POST',{code:raw.trim(),name:name.trim(),expiry:expiry.trim()||null},token))}
 async function cameraOn(){try{const p=permission?.granted?permission:await requestPermission();if(!p.granted){E('Permission caméra refusée. Saisissez le code manuellement.');return}scanned.current=false;Cam(true)}catch(e){E('Caméra indisponible : '+e.message)}}
 async function photo(take){await run(async()=>{if(take&&Platform.OS!=='web'){const p=await ImagePicker.requestCameraPermissionsAsync();if(!p.granted)throw Error('Permission caméra refusée.')}const options={base64:true,quality:.65,mediaTypes:ImagePicker.MediaTypeOptions.Images};const result=take?await ImagePicker.launchCameraAsync(options):await ImagePicker.launchImageLibraryAsync(options);if(result.canceled)return;const image=result.assets?.[0]?.base64;if(!image||image.length>7_000_000)throw Error('Image absente ou trop volumineuse.');Results(null);const r=await api('intelligence/ocr','POST',{image},token);Ocr(r.text);Results(r)})}
 async function ask(){const text=question.trim();if(!text)return;await run(async()=>{const reply=await api('intelligence/chat','POST',{question:text,external,...(selected?{medicine_id:selected.id}:{})},token);H(old=>[...old,{question:text,...reply}].slice(-20));Q('');if(reply.sources?.length===1)S(reply.sources[0]);})}
 if(section==='assistant')return <View style={s.panel}><Text style={s.title}>Assistant documentaire IA</Text><Text style={s.muted}>Questions sur l’identité, la composition, la forme et les références officielles. Pas de diagnostic, de posologie ou de recommandation de traitement. N’entrez pas de données personnelles ni de symptômes.</Text><Button title={external?'Groq activé — désactiver':'Autoriser Groq (question + références envoyées au fournisseur)'} onPress={()=>X(x=>!x)} secondary disabled={busy}/>{selected&&<View style={s.card}><Text style={s.label}>Contexte : {selected.name}</Text><Button title="Changer de médicament" secondary onPress={()=>S(null)}/></View>}{history.map((r,i)=><View key={i} style={s.card}><Text style={s.label}>Vous : {r.question}</Text><Text style={s.body}>{r.answer}</Text><Text style={s.muted}>Mode : {r.mode}</Text>{r.sources?.map(x=><View key={x.id} style={{gap:5}}><Text style={s.label}>{x.name}</Text><Source url={x.url}/><Button title="Continuer sur cette fiche" secondary onPress={()=>S(x)}/></View>)}<Text style={s.muted}>{r.notice}</Text></View>)}<TextInput accessibilityLabel="Question" style={s.input} multiline maxLength={500} value={question} onChangeText={Q} placeholder="Ex. Composition de [nom du médicament]"/><Button title="Envoyer" disabled={busy||!question.trim()} onPress={ask}/>{busy&&<ActivityIndicator color={c.primary}/>} {!!error&&<Text style={s.error}>{error}</Text>}</View>;
 return <View style={s.panel}><Text style={s.title}>Scanner et vérifier</Text><Text style={s.muted}>Une correspondance n’est pas une preuve d’authenticité. La BDPM est française. Vérifiez l’emballage et consultez un pharmacien.</Text><Button title={camera?'Fermer la caméra':'Scanner un code-barres'} onPress={()=>camera?Cam(false):cameraOn()} disabled={busy}/>{camera&&<View style={{height:250,overflow:'hidden',borderRadius:12}}><CameraView style={{flex:1}} facing="back" barcodeScannerSettings={{barcodeTypes:['ean13','ean8','datamatrix','qr','upc_a','code128']}} onBarcodeScanned={({data})=>{if(scanned.current)return;scanned.current=true;Code(data);Cam(false);run(()=>verify(data))}} onMountError={()=>{Cam(false);E('Caméra indisponible. Saisissez le code manuellement.')}}/></View>}<Button title="Photographier la boîte (OCR)" secondary onPress={()=>photo(true)} disabled={busy}/><Button title="Importer une photo (OCR)" secondary onPress={()=>photo(false)} disabled={busy}/>{!!ocrText&&<View style={s.card}><Text style={s.label}>Texte reconnu — à contrôler</Text><Text style={s.body}>{ocrText}</Text></View>}<Text style={s.label}>Code CIP / code-barres</Text><TextInput accessibilityLabel="Code" style={s.input} value={code} onChangeText={Code} autoCapitalize="none" placeholder="Code scanné ou saisi"/><Text style={s.label}>Nom exact sur l’emballage</Text><TextInput accessibilityLabel="Nom du médicament" style={s.input} value={name} onChangeText={Name} placeholder="Nom et dosage"/><Text style={s.label}>Date de péremption (facultative, à confirmer)</Text><TextInput accessibilityLabel="Date de péremption" style={s.input} value={expiry} onChangeText={Expiry} placeholder="AAAA-MM-JJ"/><Button title="Vérifier" onPress={()=>run(()=>verify())} disabled={busy||(!code.trim()&&!name.trim())}/>{busy&&<ActivityIndicator color={c.primary}/>} {!!error&&<Text style={s.error}>{error}</Text>}{results&&<View style={s.card}><Text style={s.label}>{({code_found:'Code référencé',ambiguous:'Code ambigu',name_candidates:'Correspondances possibles',not_found:'Non trouvé'})[results.status]||'Candidats OCR'}</Text><Text style={s.muted}>{({expired:'Date saisie dépassée',unknown:'Date non vérifiée',not_expired_by_entered_date:'Date saisie non dépassée — sécurité non établie'})[results.expiry]||''}</Text>{results.warnings?.map((w,i)=><Text key={i} style={s.error}>{w}</Text>)}{results.presentations?.map(p=><Text key={p.code} style={s.body}>{p.code} : {p.label}</Text>)}{results.matches?.map(m=><View key={m.id} style={s.card}><Text style={s.label}>{m.name}</Text><Source url={m.source}/><ReferenceDetails reference={m.reference}/><Button title="Utiliser ce nom pour la vérification" secondary onPress={()=>Name(m.name)}/></View>)}<Text style={s.muted}>{results.notice}</Text></View>}</View>
}
const s=StyleSheet.create({panel:{gap:12},card:{gap:8,padding:14,borderWidth:1,borderColor:c.border,borderRadius:12,backgroundColor:c.surface},title:{fontSize:23,fontWeight:'800',color:c.primary},label:{fontWeight:'700',color:c.primary},body:{color:c.text,lineHeight:21},muted:{color:c.muted,fontSize:13,lineHeight:19},button:{padding:13,borderRadius:10},input:{padding:13,borderColor:c.border,borderWidth:1,borderRadius:10,color:c.text,backgroundColor:c.surface},error:{color:c.danger,fontWeight:'600'},link:{color:c.primary,textDecorationLine:'underline'}});

MEDICHECK_INTEL_FILE
python3 "$TMP/patch.py" "$ROOT" "$TMP" "$TMP/output"
backup="$ROOT/.intelligence-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$backup"
while IFS= read -r -d '' f; do
  rel="${f#"$TMP/output/"}"
  if [[ -f "$ROOT/$rel" ]]; then mkdir -p "$backup/$(dirname "$rel")"; cp -p "$ROOT/$rel" "$backup/$rel"; fi
done < <(find "$TMP/output" -type f -print0)
for rel in backend/pyproject.toml backend/uv.lock mobile/package.json mobile/package-lock.json; do
  if [[ -f "$ROOT/$rel" ]]; then mkdir -p "$backup/$(dirname "$rel")"; cp -p "$ROOT/$rel" "$backup/$rel"; fi
done
if [[ -f backend/db.sqlite3 ]]; then
  python3 - "$backup/db.sqlite3" <<'MEDI_DB'
import sqlite3,sys
with sqlite3.connect('backend/db.sqlite3') as src, sqlite3.connect(sys.argv[1]) as dst: src.backup(dst)
MEDI_DB
  chmod 600 "$backup/db.sqlite3"
fi
printf 'Sauvegarde : %s\n' "$backup"
(cd backend && uv add pillow)
(cd mobile && npx expo install expo-camera expo-image-picker)
cp -R "$TMP/output/." "$ROOT/"
cd "$ROOT/backend"
uv run python manage.py check
uv run python manage.py makemigrations core
uv run python manage.py test core.test_intelligence core.test_reviews core.test_billing core.test_duplicates
uv run python manage.py migrate
# Le téléchargement BDPM est séparé : échec réseau ≠ installation détruite.
if ! uv run python manage.py import_reference; then
  echo 'Import BDPM non effectué. Réessayez : uv run python manage.py import_reference, ou utilisez --directory /chemin/vers/fichiers.' >&2
fi
printf '\nModules installés. Sauvegarde : %s\n' "$backup"
