"""All state transitions are serialized by the medicine row (PostgreSQL).
SQLite serializes writers and may return a transient database-locked error.
"""
import random
import uuid
from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Count, Q
from django.utils import timezone
from .models import Medicine, Profile, ReviewCycle, ReviewAssignment, ReviewNotification, PointWallet, PointTransaction
from .billing_api import professional_users, verified

User = get_user_model()


def notify(user_id, cycle, message):
    ReviewNotification.objects.create(user_id=user_id, cycle=cycle, message=message[:500])


def create_cycle(medicine, number=1):
    cycle = ReviewCycle.objects.create(medicine=medicine, number=number, name=medicine.name, description=medicine.description, source=medicine.source)
    reconcile(cycle, medicine)
    return cycle


def eligible_ids(ids):
    # Lock profile rows in consistent order, matching the existing approval API.
    list(Profile.objects.select_for_update().filter(user_id__in=ids).order_by('pk').values_list('pk', flat=True))
    return set(professional_users().filter(pk__in=ids).values_list('pk', flat=True))


def credit(user_id, medicine_id, kind, amount):
    operation_id = uuid.uuid5(uuid.NAMESPACE_URL, f'medicheck:review:v1:{medicine_id}:{kind}:{user_id}')
    wallet, _ = PointWallet.objects.get_or_create(user_id=user_id)
    wallet = PointWallet.objects.select_for_update().get(pk=wallet.pk)
    if PointTransaction.objects.filter(operation_id=operation_id).exists():
        return
    wallet.balance += amount
    wallet.save(update_fields=['balance'])
    PointTransaction.objects.create(wallet=wallet, delta=amount, balance_after=wallet.balance, actor=None,
        reason=f'Validation collaborative #{medicine_id} — '+('publication' if kind=='author' else 'examen complet'), operation_id=operation_id)


def reconcile(cycle, medicine):
    """Caller holds the medicine lock, inside transaction.atomic()."""
    if cycle.status not in ('waiting','reviewing'):
        return
    previous = cycle.status
    active = list(cycle.assignments.exclude(state='cancelled').order_by('pk'))
    ids = [a.reviewer_id for a in active]+[medicine.author_id]
    allowed = eligible_ids(ids)
    for a in active:
        if a.reviewer_id not in allowed or a.reviewer_id == medicine.author_id:
            a.state='cancelled'; a.save(update_fields=['state'])
    active = list(cycle.assignments.exclude(state='cancelled').order_by('pk'))
    if medicine.author_id not in allowed:
        cycle.status='waiting'; cycle.reason='Auteur non habilité ou suspendu.'
    else:
        missing=5-len(active)
        if missing>0:
            used=cycle.assignments.values_list('reviewer_id',flat=True)
            candidates=list(professional_users().exclude(pk=medicine.author_id).exclude(pk__in=used)
                .annotate(load=Count('medicine_assignments',filter=Q(medicine_assignments__state='pending',medicine_assignments__cycle__status='reviewing')))
                .values_list('pk','load'))
            random.SystemRandom().shuffle(candidates)
            candidates.sort(key=lambda x:x[1])
            # Re-check eligibility on voting and on finalization. No self review.
            if len(candidates)>=missing:
                for uid,_ in candidates[:missing]:
                    ReviewAssignment.objects.create(cycle=cycle,reviewer_id=uid)
                    notify(uid,cycle,f'Nouvelle demande de validation : {cycle.name}')
                active=list(cycle.assignments.exclude(state='cancelled').order_by('pk'))
        cycle.status='reviewing' if len(active)==5 else 'waiting'
        cycle.reason='' if cycle.status=='reviewing' else f'{5-len(active)} réviseur(s) supplémentaire(s) nécessaire(s).'
    cycle.save(update_fields=['status','reason'])
    if previous != cycle.status and cycle.status=='reviewing':
        notify(medicine.author_id,cycle,f'Cinq réviseurs affectés à {cycle.name}.')
    if cycle.status != 'reviewing' or len(active)!=5 or any(a.state!='voted' for a in active):
        return
    allowed = eligible_ids([medicine.author_id]+[a.reviewer_id for a in active])
    if len(allowed)!=6:
        # Another transaction changed eligibility. Reconciliation will replace unavailable reviewers.
        return
    same = (medicine.name,medicine.description,medicine.source)==(cycle.name,cycle.description,cycle.source)
    approved=all(a.decision=='approve' for a in active) and same and not medicine.published
    cycle.status='published' if approved else 'revision'
    cycle.reason='' if approved else ('La fiche a changé pendant la validation.' if not same else 'Un ou plusieurs avis demandent une correction.')
    cycle.closed_at=timezone.now(); cycle.save(update_fields=['status','reason','closed_at'])
    if approved:
        medicine.published=True; medicine.save(update_fields=['published'])
    # Reward every complete active review, independent of the vote; no repeat reward on a later cycle.
    rewards=[(a.reviewer_id,'reviewer',10) for a in active]
    if approved: rewards.append((medicine.author_id,'author',50))
    for uid,kind,amount in sorted(rewards):
        credit(uid,medicine.pk,kind,amount)
    notify(medicine.author_id,cycle,f'{cycle.name} : '+('publié. 50 points attribués.' if approved else 'correction demandée. Consultez les avis.'))
    for a in active:
        notify(a.reviewer_id,cycle,f'Cycle terminé pour {cycle.name}. Consultez votre portefeuille.')


@transaction.atomic
def sync_one(medicine_id):
    medicine=Medicine.objects.select_for_update().get(pk=medicine_id)
    if medicine.published: return
    cycle=medicine.review_cycles.order_by('-number').first()
    if cycle is None:
        create_cycle(medicine)
    elif cycle.status in ('waiting','reviewing'):
        reconcile(cycle,medicine)


def sync_all():
    ids=list(Medicine.objects.filter(published=False).exclude(review_cycles__status='revision').values_list('pk',flat=True).distinct())
    # Include corrected proposals with an open cycle despite older revision cycles.
    ids=set(ids)|set(ReviewCycle.objects.filter(status__in=['waiting','reviewing'],medicine__published=False).values_list('medicine_id',flat=True))
    for pk in sorted(ids):
        sync_one(pk)
    return len(ids)
