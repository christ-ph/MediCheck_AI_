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
    if not MedicineReference.objects.filter(medicine__published=True).exists():
        return Response(dict(mode='no_reference',answer='Le référentiel officiel BDPM n’a pas encore été importé. Contactez l’administration.',sources=[],notice=NOTICE))
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
    provider_notice=''
    if d['external'] and not key:
        mode='retrieval_no_key'; provider_notice='Groq non configuré sur Django (GROQ_API_KEY absente). Réponse locale.'
    if d['external'] and key:
        payload={'model':model,'messages':[{'role':'system','content':'Sélectionne uniquement les clés de métadonnées pertinentes à la question. Ne donne aucun conseil médical. Réponds uniquement par un objet JSON {"fields": ["name", "form", "route", "holder", "components", "authorization", "market"]} en choisissant les clés utiles. Si question clinique ou hors sujet, retourne {"fields": []}.'},{'role':'user','content':json.dumps({'question':d['question'],'available_fields':fields,'references':sources},ensure_ascii=False)}],'response_format':{'type':'json_object'},'temperature':0,'max_completion_tokens':300}
        try:
            req=Request('https://api.groq.com/openai/v1/chat/completions',data=json.dumps(payload).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'},method='POST')
            with urlopen(req,timeout=15) as res:result=json.loads(res.read(500000))
            selected=json.loads(result['choices'][0]['message']['content'])['fields']
            if isinstance(selected,list): chosen=[f for f in fields if f in selected];mode='rag_groq'
        except (URLError,TimeoutError,ValueError,KeyError,TypeError,IndexError,OSError):
            mode='retrieval_fallback'; provider_notice='Groq indisponible : vérifier la clé, le modèle et la connexion serveur. Réponse locale.'
    lines=['Informations de référence disponibles (pas de posologie ni de recommandation de traitement).']
    for i,r in enumerate(sources,1):
        lines.append(f'\n[{i}] {r["name"]}')
        for f in chosen:
            if f=='name':continue
            val=r[f]
            if f=='components':val=' ; '.join(' '.join(str(x.get(k,'')) for k in ('substance','strength','basis')).strip() for x in val)
            if val:lines.append(fields[f]+' : '+str(val))
    if not chosen:lines=['La question dépasse les informations factuelles disponibles. Consultez la notice officielle et un professionnel de santé.']
    return Response(dict(mode=mode,provider_notice=provider_notice,answer='\n'.join(lines),sources=[dict(id=r['id'],name=r['name'],url=r['url']) for r in sources],notice=NOTICE))

