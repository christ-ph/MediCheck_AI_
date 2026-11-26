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
