#!/usr/bin/env python3
"""Import BDPM dans MediCheck. A placer a cote de manage.py."""
import argparse
import csv
import io
import os
import random
import re
import sys
import unicodedata
from datetime import datetime
from html import unescape
from pathlib import Path
from urllib.request import Request, urlopen

BASE = 'https://base-donnees-publique.medicaments.gouv.fr'
PAGE = BASE + '/telechargement'
URL = BASE + '/download/file/CIS_bdpm.txt'


def fetch(url):
    request = Request(url, headers={'User-Agent': 'MediCheck-Student-Import/1.0'})
    with urlopen(request, timeout=60) as response:
        return response.read()


def decode(data):
    for encoding in ('utf-8-sig', 'cp1252', 'latin-1'):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue


def norm(value):
    return ''.join(c for c in unicodedata.normalize('NFKD', value.casefold())
                   if not unicodedata.combining(c)).strip()


def official_date():
    html = decode(fetch(PAGE))
    text = re.sub(r'\s+', ' ', unescape(re.sub(r'<[^>]+>', ' ', html)))
    match = re.search(r'Fichier des spécialités\s*\(\s*Date de mise à jour\s*:\s*(\d{2}/\d{2}/\d{4})', text, re.I)
    if not match:
        raise ValueError('Date BDPM introuvable : consultez la page officielle et utilisez --source-date JJ/MM/AAAA.')
    return match.group(1)


def parse_rows(data, source_date):
    seen = set()
    names = set()
    results = []
    for row in csv.reader(io.StringIO(decode(data)), delimiter='\t'):
        if len(row) < 7:
            continue
        cis, name, form, route, authorization, procedure, market = (x.strip() for x in row[:7])
        if not re.fullmatch(r'\d{8}', cis) or not name or len(name) > 200:
            continue
        if norm(authorization) not in {'autorisation active', 'valide', 'autorisation valide'} or norm(market) != 'commercialisee':
            continue
        if cis in seen or norm(name) in names:
            continue
        seen.add(cis)
        names.add(norm(name))
        desc = (
            f'Code CIS : {cis}\nForme pharmaceutique : {form or "Non renseignée"}\n'
            f'Voie(s) d’administration : {route or "Non renseignée"}\n'
            f'Statut AMM (France) : {authorization}\nCommercialisation (France) : {market}\n'
            f'Source : Base de données publique des médicaments (BDPM / ANSM), fichier des spécialités, mise à jour du {source_date}.\n'
            'Import de référence pour MediCheck, non validé par les professionnels de la plateforme. '
            'Disponibilité et autorisation au Cameroun non vérifiées. '
            'Consulter la fiche officielle pour la notice, la posologie et les contre-indications.'
        )
        results.append({'name': name, 'description': desc, 'source': f'{BASE}/medicament/{cis}/extrait'})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--limit', type=int, default=150, help='Nombre de fiches distinctes à ajouter au lot (défaut : 150).')
    parser.add_argument('--file', type=Path, help='Fichier CIS_bdpm.txt local, sinon téléchargement automatique.')
    parser.add_argument('--source-date', help='Date de mise à jour du fichier, JJ/MM/AAAA (obligatoire pour un fichier local).')
    parser.add_argument('--author', help='Nom du superutilisateur auteur (défaut : premier superutilisateur actif).')
    parser.add_argument('--publish-demo', action='store_true', help='Rendre les nouvelles fiches visibles dans le catalogue local (DEBUG uniquement).')
    parser.add_argument('--dry-run', action='store_true', help='Prévisualiser sans écrire dans la base.')
    args = parser.parse_args()
    if args.limit < 1:
        parser.error('--limit doit être positif')
    if args.file and not args.source_date:
        parser.error('--source-date est obligatoire avec --file')
    if not Path(__file__).with_name('manage.py').exists():
        parser.error('Placez ce script dans backend/, à côté de manage.py.')
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
    import django
    django.setup()
    from django.conf import settings
    from django.contrib.auth import get_user_model
    from django.db import transaction
    from core.models import Medicine
    if args.publish_demo and not settings.DEBUG:
        parser.error('--publish-demo est réservé au développement (DEBUG=True).')
    try:
        date = args.source_date or official_date()
        datetime.strptime(date, '%d/%m/%Y')
        data = args.file.read_bytes() if args.file else fetch(URL)
        rows = parse_rows(data, date)
    except (OSError, ValueError) as exc:
        parser.exit(1, f'Import impossible : {exc}\nTéléchargement manuel : {PAGE}\n')
    if len(rows) < args.limit:
        parser.exit(1, f'Seulement {len(rows)} fiches admissibles trouvées ; aucune écriture. Vérifiez le fichier et son format.\n')
    # Echantillon stable : les réexécutions ne multiplient pas les mêmes fiches.
    rows.sort(key=lambda row: row['source'])
    random.Random(4077).shuffle(rows)
    selected = rows[:args.limit]
    if args.dry_run:
        print(f'{len(rows)} références admissibles ; {len(selected)} sélectionnées. Source : BDPM, {date}.')
        for row in selected[:10]:
            print('-', row['name'])
        return
    users = get_user_model().objects.filter(is_superuser=True, is_active=True).order_by('pk')
    if args.author:
        users = users.filter(username=args.author)
    author = users.first()
    if author is None:
        parser.exit(1, 'Créez un superutilisateur : uv run python manage.py createsuperuser\n')
    created = skipped = published = 0
    with transaction.atomic():
        for row in selected:
            # Ne jamais écraser une fiche existante ou modifier une validation.
            from core.duplicate_api import find_duplicate
            existing = find_duplicate(row['name'], row['source']) is not None or Medicine.objects.filter(source=row['source']).exists()
            if existing:
                skipped += 1
                continue
            Medicine.objects.create(**row, author=author, published=args.publish_demo)
            created += 1
            published += int(args.publish_demo)
    print(f'Import terminé : {created} créées, {skipped} déjà présentes, {published} nouvelles fiches visibles.')
    print(f'Total catalogue : {Medicine.objects.count()} ; publiées : {Medicine.objects.filter(published=True).count()}')
    print(f'Source : BDPM / ANSM, mise à jour du {date} ; marché français.')


if __name__ == '__main__':
    main()
