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
