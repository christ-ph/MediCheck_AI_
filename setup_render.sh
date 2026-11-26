#!/usr/bin/env bash
set -Eeuo pipefail
# Usage: bash setup_render.sh [--with-catalog]
with_catalog=0
case "${1:-}" in '') ;; --with-catalog) with_catalog=1 ;; *) echo 'Usage: bash setup_render.sh [--with-catalog]' >&2; exit 2;; esac
if [[ -f ./backend/manage.py && -f ./backend/config/settings.py ]]; then
  ROOT="$PWD"
elif [[ -f "$HOME/Bureau/MediCheck/backend/manage.py" ]]; then
  ROOT="$HOME/Bureau/MediCheck"
else
  echo 'Lancez ce script depuis la racine MediCheck.' >&2; exit 1
fi
cd "$ROOT"
command -v uv >/dev/null || { echo 'uv introuvable.' >&2; exit 1; }
backup="$ROOT/.render-backup-$(date +%Y%m%d-%H%M%S)-$$"
files=(render.yaml .gitignore backend/Dockerfile backend/.dockerignore backend/entrypoint.sh backend/config/render_settings.py backend/config/wsgi.py backend/config/urls.py backend/pyproject.toml backend/uv.lock backend/core/management/commands/bootstrap_render.py backend/data/bdpm_demo.json)
for f in "${files[@]}"; do
  if [[ -f "$f" ]]; then mkdir -p "$backup/$(dirname "$f")"; cp -p "$f" "$backup/$f"; fi
done
trap 'echo "Erreur. Sauvegarde des fichiers préexistants : $backup" >&2' ERR
mkdir -p "$backup"
cat > render.yaml <<'EOF'
services:
  - type: web
    name: medicheck-api
    runtime: docker
    plan: free
    region: frankfurt
    branch: main
    rootDir: backend
    dockerfilePath: ./Dockerfile
    dockerContext: .
    healthCheckPath: /health/
    envVars:
      - key: DJANGO_SETTINGS_MODULE
        value: config.render_settings
      - key: DJANGO_DEBUG
        value: "0"
      - key: DJANGO_SECRET_KEY
        generateValue: true
      - key: DATABASE_URL
        fromDatabase:
          name: medicheck-db
          property: connectionString
      - key: DJANGO_ALLOWED_HOSTS
        value: localhost,127.0.0.1
      - key: CORS_ALLOWED_ORIGINS
        value: https://medicheck-app.vercel.app,https://medicheck-admin.vercel.app
      - key: CSRF_TRUSTED_ORIGINS
        value: https://medicheck-admin.vercel.app
      - key: GROQ_API_KEY
        sync: false
      - key: GROQ_MODEL
        value: openai/gpt-oss-20b
      - key: DJANGO_SUPERUSER_USERNAME
        sync: false
      - key: DJANGO_SUPERUSER_PASSWORD
        sync: false
      - key: WEB_CONCURRENCY
        value: "1"
databases:
  - name: medicheck-db
    databaseName: medicheck
    user: medicheck
    plan: free
    region: frankfurt
    ipAllowList: []
EOF
cat > backend/Dockerfile <<'EOF'
FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    DJANGO_SETTINGS_MODULE=config.render_settings
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    tesseract-ocr tesseract-ocr-fra tesseract-ocr-eng libpq5 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project
COPY . .
RUN chmod +x /app/entrypoint.sh
EXPOSE 10000
CMD ["/app/entrypoint.sh"]
EOF
cat > backend/.dockerignore <<'EOF'
.venv/
venv/
**/__pycache__/
**/*.pyc
.env
.env.*
**/.env
**/.env.*
*.sqlite*
*.db
*.sql
*.dump
.git/
media/
private_media/
uploads/
staticfiles/
*.log
*.bak
*.backup
*.before-admin
*.zip
*.tar.gz
EOF
cat > backend/entrypoint.sh <<'EOF'
#!/bin/sh
set -eu
python manage.py migrate --noinput
python manage.py collectstatic --noinput
python manage.py bootstrap_render
exec gunicorn config.wsgi:application \
  --bind "0.0.0.0:${PORT:-10000}" \
  --workers "${WEB_CONCURRENCY:-1}" --threads 2 --timeout 120 \
  --access-logfile - --error-logfile -
EOF
chmod +x backend/entrypoint.sh
# A dedicated settings module leaves local development unchanged.
cat > backend/config/render_settings.py <<'EOF'
from .settings import *  # noqa: F401,F403
import os
import dj_database_url


def env_list(name):
    return [v.strip() for v in os.getenv(name, '').split(',') if v.strip()]


DEBUG = False
SECRET_KEY = os.environ['DJANGO_SECRET_KEY']
ALLOWED_HOSTS = list(dict.fromkeys(env_list('DJANGO_ALLOWED_HOSTS') + ['localhost', '127.0.0.1'] + ([os.environ['RENDER_EXTERNAL_HOSTNAME']] if os.getenv('RENDER_EXTERNAL_HOSTNAME') else [])))
DATABASES = {'default': dj_database_url.parse(os.environ['DATABASE_URL'], conn_max_age=60, conn_health_checks=True)}
CORS_ALLOWED_ORIGINS = env_list('CORS_ALLOWED_ORIGINS')
CORS_ALLOW_ALL_ORIGINS = False
CSRF_TRUSTED_ORIGINS = env_list('CSRF_TRUSTED_ORIGINS')
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
MIDDLEWARE = list(MIDDLEWARE)
MIDDLEWARE.insert(MIDDLEWARE.index('django.middleware.security.SecurityMiddleware') + 1, 'whitenoise.middleware.WhiteNoiseMiddleware')
STORAGES = {
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {'BACKEND': 'whitenoise.storage.CompressedManifestStaticFilesStorage'},
}
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_HSTS_SECONDS = 3600
SECURE_SSL_REDIRECT = True
# Allow internal health probes without redirects; no private data is returned.
SECURE_REDIRECT_EXEMPT = [r'^health/$']
X_FRAME_OPTIONS = 'DENY'
if 'django.middleware.clickjacking.XFrameOptionsMiddleware' not in MIDDLEWARE:
    MIDDLEWARE.append('django.middleware.clickjacking.XFrameOptionsMiddleware')
EOF
if [[ ! -f backend/config/wsgi.py ]]; then
cat > backend/config/wsgi.py <<'EOF'
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
application = get_wsgi_application()
EOF
fi
python3 - <<'PY'
from pathlib import Path
p=Path('backend/config/urls.py')
s=p.read_text()
if 'path("health/"' not in s and "path('health/'" not in s:
    p.write_text(s.rstrip()+'''\n\n# Render health check\nfrom django.http import JsonResponse\nfrom django.db import connection, DatabaseError\n\ndef health(request):\n    try:\n        with connection.cursor() as cursor:\n            cursor.execute("SELECT 1")\n    except DatabaseError:\n        return JsonResponse({"status": "unavailable"}, status=503)\n    return JsonResponse({"status": "ok", "service": "MediCheck AI"})\n\nurlpatterns += [path("health/", health)]\n''')
p=Path('.gitignore')
s=p.read_text() if p.exists() else ''
for rule in ['.backup-*/','.render-backup-*/','.*-backup-*/','.env','.env.*','!.env.example','!.env.sample','!.env.template','.venv/','db.sqlite3','*.sqlite3','*.sqlite3-*','.expo/','staticfiles/']:
    if rule not in s.splitlines(): s += '\n'+rule+'\n'
p.write_text(s)
PY
mkdir -p backend/core/management/commands
cat > backend/core/management/commands/bootstrap_render.py <<'EOF'
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
EOF
cd backend
# Already present in the user's latest terminal output: avoid resolving again when installed.
if ! uv run --locked python -c 'import gunicorn, dj_database_url, psycopg, whitenoise' >/dev/null 2>&1; then
  uv add gunicorn dj-database-url 'psycopg[binary]' whitenoise
fi
# Force the local settings for checks/export; do not leak secrets to the new files.
DJANGO_SETTINGS_MODULE=config.settings uv run --locked python manage.py check
DJANGO_SETTINGS_MODULE=config.settings uv run --locked python manage.py test
if [[ "$with_catalog" == 1 ]]; then
  DJANGO_SETTINGS_MODULE=config.settings uv run --locked python manage.py bootstrap_render --export-catalog
fi
# No DB connection needed for Django's ordinary system check.
DJANGO_SETTINGS_MODULE=config.render_settings DJANGO_SECRET_KEY=local-check-only-not-for-deployment DATABASE_URL=postgresql://check:check@127.0.0.1:5432/check RENDER_EXTERNAL_HOSTNAME=medicheck-api.onrender.com uv run --locked python manage.py check
cd "$ROOT"
printf '\nConfiguration créée. Sauvegarde : %s\n' "$backup"
printf 'Vérifiez git status, puis commitez les fichiers Render. Aucun push ni déploiement effectué.\n'
