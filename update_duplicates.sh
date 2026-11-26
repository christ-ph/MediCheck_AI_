#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT/backend"
[[ -f manage.py && -f core/professional_api.py ]] || { echo 'Placez ce script à la racine de MediCheck et installez update_professional.sh.' >&2; exit 1; }
command -v uv >/dev/null || { echo 'uv introuvable.' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'echo "Installation interrompue. Consultez les erreurs et la sauvegarde avant de relancer." >&2' ERR
uv run python manage.py migrate --check
uv run python manage.py makemigrations --check --dry-run
cat > "$TMP/medicine_identity.py" <<'MEDICHECK_MEDICINE_IDENTITY_PY'
"""Conservative identity matching; no clinical equivalence inferred."""
import hashlib
import re
import unicodedata
from urllib.parse import urlsplit


def normalize_name(name):
    name = unicodedata.normalize('NFKD', name.casefold())
    name = ''.join(c for c in name if not unicodedata.combining(c))
    name = name.translate(str.maketrans({'’': "'", '‐': '-', '‑': '-', '–': '-'}))
    return ' '.join(name.split())


def name_key(name):
    return hashlib.sha256(normalize_name(name).encode('utf-8')).hexdigest()


def official_cis(source):
    try:
        url = urlsplit(source.strip())
        if url.scheme not in ('https', 'http') or url.hostname != 'base-donnees-publique.medicaments.gouv.fr':
            return None
        match = re.fullmatch(r'/medicament/([0-9]{8})(?:/[^?#]*)?', url.path)
        return match.group(1) if match else None
    except (ValueError, AttributeError):
        return None
MEDICHECK_MEDICINE_IDENTITY_PY
cat > "$TMP/duplicate_api.py" <<'MEDICHECK_DUPLICATE_API_PY'
from django.db.models import Q
from rest_framework.exceptions import APIException
from .medicine_identity import name_key, official_cis
from .models import Medicine


class DuplicateMedicine(APIException):
    status_code = 409
    default_code = 'duplicate_medicine'


def find_duplicate(name, source, exclude=None):
    criteria = Q(identity_key=name_key(name))
    cis = official_cis(source)
    if cis:
        criteria |= Q(official_cis=cis)
    rows = Medicine.objects.filter(criteria)
    if exclude is not None:
        rows = rows.exclude(pk=exclude)
    return rows.order_by('-published', 'pk').first()


def reject_duplicate(medicine):
    if medicine.published:
        raise DuplicateMedicine({'detail': 'Ce médicament existe déjà dans le catalogue : ' + medicine.name,
                                 'code': 'duplicate_medicine', 'medicine_id': medicine.pk})
    # Do not disclose unpublished proposals or their authors.
    raise DuplicateMedicine({'detail': 'Une fiche correspondant à ce médicament existe déjà et est non publiée.',
                             'code': 'duplicate_medicine'})
MEDICHECK_DUPLICATE_API_PY
cat > "$TMP/test_duplicates.py" <<'MEDICHECK_TEST_DUPLICATES_PY'
from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from rest_framework.test import APITestCase
from .models import Medicine, Profile, ProfessionalApplication
from .medicine_identity import name_key, official_cis


class DuplicateTests(APITestCase):
    def setUp(self):
        U = get_user_model()
        self.pro = U.objects.create_user(username='duplicate-pro')
        p = Profile.objects.create(user=self.pro, professional_requested=True, professional_verified=True)
        ProfessionalApplication.objects.create(profile=p, status='approved', proof=b'%PDF-test')
        self.user = U.objects.create_user(username='duplicate-user')
        self.client.force_authenticate(self.pro)
        self.data = {'name': 'Paracétamol 500 mg', 'description': 'Fiche fictive de test', 'source': 'https://example.org/reference'}

    def submit(self, **changes):
        return self.client.post('/api/proposals/', {**self.data, **changes}, format='json')

    def test_published_duplicate(self):
        Medicine.objects.create(**self.data, author=self.pro, published=True)
        r = self.submit(name=' PARACETAMOL  500 MG ')
        self.assertEqual(r.status_code, 409)
        self.assertIn('catalogue', str(r.data['detail']))
        self.assertEqual(Medicine.objects.count(), 1)

    def test_pending_duplicate_and_distinct_dose(self):
        self.assertEqual(self.submit().status_code, 201)
        self.assertEqual(self.submit(name='paracetamol 500 mg').status_code, 409)
        self.assertEqual(self.submit(name='Paracétamol 1000 mg').status_code, 201)
        self.assertEqual(Medicine.objects.filter(published=False).count(), 2)

    def test_cis(self):
        base = 'https://base-donnees-publique.medicaments.gouv.fr/medicament/12345678/'
        self.assertEqual(self.submit(source=base+'extrait').status_code, 201)
        self.assertEqual(self.submit(name='Autre nom de test', source=base+'notice').status_code, 409)
        self.assertIsNone(official_cis('https://example.org/medicament/12345678/extrait'))

    def test_permission_and_constraint(self):
        Medicine.objects.create(**self.data, author=self.pro)
        self.client.force_authenticate(self.user)
        self.assertEqual(self.submit().status_code, 403)
        with self.assertRaises(IntegrityError), transaction.atomic():
            Medicine.objects.create(**{**self.data, 'name': 'PARACETAMOL 500 MG'}, author=self.pro)
        self.assertEqual(name_key('A 1,5 mg'), name_key('a 1,5 mg'))
        self.assertNotEqual(name_key('A 1,5 mg'), name_key('A 15 mg'))
MEDICHECK_TEST_DUPLICATES_PY
cat > "$TMP/patch.py" <<'MEDICHECK_PATCH_PY'
import ast
from pathlib import Path
import sys
import os
from collections import defaultdict
from shutil import copy2
from datetime import datetime

root = Path.cwd()
assets = Path(sys.argv[1])
sys.path.insert(0, str(root))
sys.path.insert(0, str(assets))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
import django
django.setup()
from django.db import connection
from django.db.migrations.loader import MigrationLoader
from core.models import Medicine
from medicine_identity import name_key, official_cis

model_path = root/'core/models.py'
view_path = root/'core/views.py'
if 'identity_key' in model_path.read_text():
    sys.exit('Module de détection déjà installé ou installation partielle. Ne pas appliquer deux fois.')
# Preflight: report legacy collisions; never delete or merge data automatically.
keys, codes = defaultdict(list), defaultdict(list)
for pk, name, source in Medicine.objects.values_list('pk','name','source').iterator():
    keys[name_key(name)].append((pk,name))
    cis = official_cis(source)
    if cis: codes[cis].append((pk,name))
conflicts = [v for group in (keys,codes) for v in group.values() if len(v)>1]
if conflicts:
    print('Doublons préexistants : aucune modification effectuée.')
    for group in conflicts:
        print(' - ' + ' | '.join(f'#{pk} {name}' for pk,name in group))
    sys.exit('Faites examiner ces fiches avant de réessayer. Aucun médicament supprimé.')

loader = MigrationLoader(connection)
leaves = loader.graph.leaf_nodes('core')
if len(leaves)!=1 or leaves[0] not in loader.applied_migrations:
    sys.exit('Une seule dernière migration core appliquée est nécessaire. Vérifiez showmigrations.')
leaf = leaves[0][1]
if not leaf[:4].isdigit(): sys.exit('Numérotation de migration inhabituelle.')
new_name = f'{int(leaf[:4])+1:04d}_medicine_identity'
model = model_path.read_text()
node = next(n for n in ast.parse(model).body if isinstance(n,ast.ClassDef) and n.name=='Medicine')
if any(isinstance(n,ast.FunctionDef) and n.name in ('save','clean') for n in node.body):
    sys.exit('Le modèle Medicine a été personnalisé : patch annulé.')
lines = model.splitlines(keepends=True)
addition = '''
    identity_key = models.CharField(max_length=64, unique=True, editable=False)
    official_cis = models.CharField(max_length=8, unique=True, null=True, blank=True, editable=False)

    def save(self, *args, **kwargs):
        from .medicine_identity import name_key, official_cis
        fields = kwargs.get('update_fields')
        if fields is not None:
            fields = set(fields)
        if fields is None or 'name' in fields:
            self.identity_key = name_key(self.name)
            if fields is not None: fields.add('identity_key')
        if fields is None or 'source' in fields:
            self.official_cis = official_cis(self.source)
            if fields is not None: fields.add('official_cis')
        if fields is not None: kwargs['update_fields'] = fields
        return super().save(*args, **kwargs)

    def clean(self):
        from django.core.exceptions import ValidationError
        from .duplicate_api import find_duplicate
        super().clean()
        if find_duplicate(self.name, self.source, exclude=self.pk):
            raise ValidationError('Une fiche correspondante existe déjà dans le catalogue ou les propositions.')
'''
model=''.join(lines[:node.end_lineno])+addition+''.join(lines[node.end_lineno:])
view = view_path.read_text()
cls=next(n for n in ast.parse(view).body if isinstance(n,ast.ClassDef) and n.name=='Proposal')
node=next(n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name=='perform_create')
old='\n'.join(view.splitlines()[node.lineno-1:node.end_lineno])
if 'profile_info' not in old or 'published=False' not in old or 'transaction.atomic()' not in old:
    sys.exit('La vue Proposal ne correspond pas à la mise à jour professionnelle attendue.')
new='''    def perform_create(self, s):
        from django.db import IntegrityError, OperationalError
        from rest_framework.exceptions import PermissionDenied, APIException
        from .duplicate_api import find_duplicate, reject_duplicate
        name, source = s.validated_data['name'], s.validated_data['source']
        try:
            with transaction.atomic():
                Profile.objects.select_for_update().filter(user=self.request.user).first()
                if not profile_info(self.request.user)['professional_verified']:
                    raise PermissionDenied('Compte professionnel non validé.')
                duplicate = find_duplicate(name, source)
                if duplicate:
                    reject_duplicate(duplicate)
                s.save(author=self.request.user, published=False)
        except IntegrityError:
            duplicate = find_duplicate(name, source)
            if duplicate:
                reject_duplicate(duplicate)
            raise
        except OperationalError as exc:
            if 'locked' not in str(exc).lower():
                raise
            error = APIException('Base temporairement occupée. Veuillez réessayer.')
            error.status_code = 503
            raise error from exc'''
view=view.replace(old,new,1)
# Freeze matching functions in the historical migration.
migration=(assets/'medicine_identity.py').read_text()+f'''

from django.db import migrations, models


def backfill(apps, schema_editor):
    Medicine = apps.get_model('core', 'Medicine')
    rows = Medicine.objects.using(schema_editor.connection.alias)
    for m in rows.all().iterator():
        rows.filter(pk=m.pk).update(identity_key=name_key(m.name), official_cis=official_cis(m.source))


class Migration(migrations.Migration):
    dependencies = [('core', {leaf!r})]
    operations = [
        migrations.AddField(model_name='medicine', name='identity_key', field=models.CharField(max_length=64, unique=True, editable=False, null=True)),
        migrations.AddField(model_name='medicine', name='official_cis', field=models.CharField(max_length=8, unique=True, null=True, blank=True, editable=False)),
        migrations.RunPython(backfill, migrations.RunPython.noop),
        migrations.AlterField(model_name='medicine', name='identity_key', field=models.CharField(max_length=64, unique=True, editable=False)),
    ]
'''
files={model_path:model,view_path:view,root/'core/migrations'/f'{new_name}.py':migration}
for n in ('medicine_identity.py','duplicate_api.py','test_duplicates.py'):
    files[root/'core'/n]=(assets/n).read_text()
# Keep repeat imports from the original seed script compatible with the new keys.
seed = root/'seed_medicines.py'
if seed.exists():
    s=seed.read_text()
    old="existing = Medicine.objects.filter(source=row['source']).exists() or Medicine.objects.filter(name__iexact=row['name']).exists()"
    if s.count(old)==1:
        files[seed]=s.replace(old,"from core.duplicate_api import find_duplicate\n            existing = find_duplicate(row['name'], row['source']) is not None or Medicine.objects.filter(source=row['source']).exists()",1)
    else:
        print('Seed personnalisé : non modifié. Les contraintes de la base restent actives.')
for p,text in files.items():
    ast.parse(text,filename=str(p))
    if p not in (model_path,view_path,seed) and p.exists(): sys.exit(f'Fichier existant : {p}')
backup=root.parent/('.duplicates-backup-'+datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
backup.mkdir(mode=0o700)
for p in files:
    if p.exists():
        target=backup/p.relative_to(root)
        target.parent.mkdir(parents=True,exist_ok=True)
        copy2(p,target)
for p,text in files.items(): p.write_text(text)
print('Sources mises à jour. Sauvegarde :',backup)
print('Migration créée :',new_name)
MEDICHECK_PATCH_PY
uv run python "$TMP/patch.py" "$TMP"
uv run python manage.py makemigrations --check --dry-run
uv run python manage.py migrate
uv run python manage.py check
uv run python manage.py test core.test_duplicates
printf '\nDétection des doublons installée. Redémarrez Django.\n'
