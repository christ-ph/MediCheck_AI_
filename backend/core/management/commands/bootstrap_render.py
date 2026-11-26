"""Bootstrap an empty demo DB; export only public BDPM fields locally."""
import json
import os
from pathlib import Path
from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from core.models import Medicine, MedicineReference, MedicinePresentation
from core.medicine_identity import normalize_name

REF_FIELDS = ('cis', 'official_name', 'form', 'route', 'holder', 'authorization', 'market', 'components', 'prescription')
CIP_FIELDS = ('cip13', 'cip7', 'label', 'market')
SNAPSHOT = Path(settings.BASE_DIR) / 'data' / 'bdpm_demo.json'

class Command(BaseCommand):
    help = 'Prepare demo admin and public BDPM catalog. Never copies user data.'

    def add_arguments(self, parser):
        parser.add_argument('--export-catalog', action='store_true')

    def handle(self, *args, **options):
        if options['export_catalog']:
            return self.export_catalog()
        return self.bootstrap()

    def export_catalog(self):
        if not settings.DEBUG:
            raise CommandError('Export réservé à la base de développement.')
        data = []
        for ref in MedicineReference.objects.filter(medicine__published=True).select_related('medicine').prefetch_related('presentations').order_by('cis'):
            if ref.cis != ref.medicine.official_cis or normalize_name(ref.official_name) != normalize_name(ref.medicine.name):
                continue
            item = {k: getattr(ref, k) for k in REF_FIELDS}
            item['presentations'] = [{k: getattr(p, k) for k in CIP_FIELDS} for p in ref.presentations.all()]
            data.append(item)
        if not data:
            raise CommandError('Aucune référence BDPM publiée à exporter.')
        SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
        SNAPSHOT.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        self.stdout.write(self.style.SUCCESS(f'{len(data)} références BDPM publiques exportées. Vérifiez le JSON avant le commit.'))

    @transaction.atomic
    def bootstrap(self):
        User = get_user_model()
        username = os.getenv('DJANGO_SUPERUSER_USERNAME', '').strip()
        password = os.getenv('DJANGO_SUPERUSER_PASSWORD', '')
        author = None
        if username:
            author = User.objects.filter(username=username).first()
            if author is None:
                if not password:
                    raise CommandError('Mot de passe administrateur manquant.')
                validate_password(password, user=User(username=username))
                author = User.objects.create_superuser(username=username, password=password)
                self.stdout.write('Administrateur initial créé.')
            elif not (author.is_superuser and author.is_active):
                raise CommandError('Le nom administrateur existe mais ne correspond pas à un superutilisateur actif.')
        elif password:
            raise CommandError('Nom administrateur manquant.')
        # Do not overwrite existing medicines on restart or redeployment.
        if not SNAPSHOT.exists() or Medicine.objects.exists():
            return
        if author is None:
            author = User.objects.filter(is_superuser=True, is_active=True).order_by('pk').first()
        if author is None:
            raise CommandError('Un administrateur est requis pour initialiser le catalogue.')
        rows = json.loads(SNAPSHOT.read_text(encoding='utf-8'))
        for row in rows:
            cis = row['cis']
            name = row['official_name']
            description = (f'Code CIS : {cis}\nForme pharmaceutique : {row["form"]}\nVoie : {row["route"]}\n'
                           f'AMM (France) : {row["authorization"]}\nCommercialisation (France) : {row["market"]}\n'
                           'Source : BDPM / ANSM. Référence de démonstration, non validée par les professionnels de la plateforme. Autorisation au Cameroun non vérifiée.')
            medicine = Medicine.objects.create(name=name, description=description, source=f'https://base-donnees-publique.medicaments.gouv.fr/medicament/{cis}/extrait', published=True, author=author)
            if medicine.official_cis != cis:
                raise CommandError('Code CIS non reconnu par le modèle.')
            ref = MedicineReference.objects.create(medicine=medicine, **{k: row[k] for k in REF_FIELDS})
            MedicinePresentation.objects.bulk_create([MedicinePresentation(reference=ref, **{k: p[k] for k in CIP_FIELDS}) for p in row['presentations']])
        self.stdout.write(self.style.SUCCESS(f'{len(rows)} références de démonstration initialisées.'))
