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


from django.db import migrations, models


def backfill(apps, schema_editor):
    Medicine = apps.get_model('core', 'Medicine')
    rows = Medicine.objects.using(schema_editor.connection.alias)
    for m in rows.all().iterator():
        rows.filter(pk=m.pk).update(identity_key=name_key(m.name), official_cis=official_cis(m.source))


class Migration(migrations.Migration):
    dependencies = [('core', '0003_subscriptionplan_pointwallet_pointtransaction_and_more')]
    operations = [
        migrations.AddField(model_name='medicine', name='identity_key', field=models.CharField(max_length=64, unique=True, editable=False, null=True)),
        migrations.AddField(model_name='medicine', name='official_cis', field=models.CharField(max_length=8, unique=True, null=True, blank=True, editable=False)),
        migrations.RunPython(backfill, migrations.RunPython.noop),
        migrations.AlterField(model_name='medicine', name='identity_key', field=models.CharField(max_length=64, unique=True, editable=False)),
    ]
