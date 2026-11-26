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

