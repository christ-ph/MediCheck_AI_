from django.db import transaction, IntegrityError, OperationalError
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes
from rest_framework.exceptions import PermissionDenied, ValidationError, APIException
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from .models import Medicine, ReviewCycle, ReviewAssignment, ReviewNotification
from .billing_api import verified, paginate
from .admin_api import PlatformAdmin
from .review_service import create_cycle, reconcile, sync_all
from .duplicate_api import find_duplicate, reject_duplicate


def require_pro(user):
    if not verified(user): raise PermissionDenied('Réservé aux professionnels validés.')


def summary(c, detail=False, admin=False):
    rows=list(c.assignments.select_related('reviewer').order_by('id'))
    active=[a for a in rows if a.state!='cancelled']
    result=dict(id=c.pk, medicine_id=c.medicine_id, number=c.number, name=c.name, description=c.description, source=c.source,
        author=c.medicine.author.username, status=c.status, reason=c.reason, assigned=len(active), voted=sum(a.state=='voted' for a in active), created_at=c.created_at)
    if admin or (detail and c.status in ('revision','published')):
        result['reviews']=[dict(id=a.pk, reviewer=a.reviewer.username if admin else None, state=a.state, decision=a.decision, comment=a.comment, checks=a.checks) for a in rows if admin or a.state=='voted']
    if detail:
        result['can_revise'] = c.status=='revision' and not c.medicine.published and not c.medicine.review_cycles.filter(number__gt=c.number).exists()
    return result


def conflict(message):
    e=APIException(message); e.status_code=409; return e


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def inbox(request):
    require_pro(request.user)
    rows=ReviewAssignment.objects.filter(reviewer=request.user).exclude(state='cancelled').select_related('cycle__medicine__author').order_by('-id')
    return paginate(request,rows,lambda a:dict(id=a.pk,state=a.state,decision=a.decision,comment=a.comment,cycle=summary(a.cycle)))


class Vote(serializers.Serializer):
    decision=serializers.ChoiceField(choices=['approve','reject'])
    comment=serializers.CharField(min_length=20,max_length=4000)
    source_checked=serializers.BooleanField()
    identity_checked=serializers.BooleanField()
    content_checked=serializers.BooleanField()
    def validate(self,d):
        if not all(d[x] for x in ('source_checked','identity_checked','content_checked')):
            raise serializers.ValidationError('Confirmez avoir effectué les trois vérifications, même en cas de rejet.')
        return d


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def vote(request,pk):
    require_pro(request.user)
    form=Vote(data=request.data); form.is_valid(raise_exception=True); d=form.validated_data
    ref=get_object_or_404(ReviewAssignment.objects.select_related('cycle'),pk=pk,reviewer=request.user)
    with transaction.atomic():
        m=Medicine.objects.select_for_update().get(pk=ref.cycle.medicine_id)
        c=ReviewCycle.objects.get(pk=ref.cycle_id)
        reconcile(c,m)
        a=ReviewAssignment.objects.get(pk=pk)
        if c.status!='reviewing' or a.state!='pending' or m.author_id==request.user.pk or not verified(request.user):
            # Keep any reconciliation changes when returning a conflict.
            return Response({'detail':'Affectation indisponible, déjà votée ou cycle fermé.'},status=409)
        a.decision=d['decision']; a.comment=d['comment']; a.state='voted'; a.voted_at=timezone.now()
        a.checks={k:d[k] for k in ('source_checked','identity_checked','content_checked')}
        a.save(update_fields=['decision','comment','state','voted_at','checks'])
        reconcile(c,m)
    return Response({'status':c.status,'detail':'Avis enregistré.'})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def mine(request):
    require_pro(request.user)
    rows=ReviewCycle.objects.filter(medicine__author=request.user).select_related('medicine__author').order_by('-id')
    return paginate(request,rows,lambda c:summary(c,detail=True))


class Correction(serializers.Serializer):
    name=serializers.CharField(max_length=200)
    description=serializers.CharField(max_length=20000)
    source=serializers.URLField(max_length=200)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def revise(request,pk):
    require_pro(request.user)
    form=Correction(data=request.data); form.is_valid(raise_exception=True); d=form.validated_data
    old=get_object_or_404(ReviewCycle,pk=pk,medicine__author=request.user)
    try:
        with transaction.atomic():
            m=Medicine.objects.select_for_update().get(pk=old.medicine_id)
            latest=m.review_cycles.order_by('-number').first()
            from .review_service import eligible_ids
            if request.user.pk not in eligible_ids([request.user.pk]): raise PermissionDenied('Compte non habilité.')
            if m.published or latest.pk!=pk or latest.status!='revision': raise conflict('Ce cycle ne peut pas être corrigé.')
            if all(getattr(m,k)==v for k,v in d.items()): raise ValidationError('Modifiez la fiche avant de la soumettre à nouveau.')
            duplicate=find_duplicate(d['name'],d['source'],exclude=m.pk)
            if duplicate: reject_duplicate(duplicate)
            for k,v in d.items(): setattr(m,k,v)
            m.save()
            c=create_cycle(m,latest.number+1)
    except IntegrityError:
        duplicate=find_duplicate(d['name'],d['source'],exclude=old.medicine_id)
        if duplicate: reject_duplicate(duplicate)
        raise
    return Response(summary(c),status=201)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def notifications(request):
    rows=ReviewNotification.objects.filter(user=request.user).order_by('-id')
    return paginate(request,rows,lambda n:dict(id=n.pk,category=n.category,message=n.message,read=bool(n.read_at),created_at=n.created_at))


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def mark_read(request,pk):
    ReviewNotification.objects.filter(user=request.user,pk=pk,read_at__isnull=True).update(read_at=timezone.now())
    return Response(status=204)


@api_view(['GET'])
@permission_classes([PlatformAdmin])
def admin_cycles(request):
    rows=ReviewCycle.objects.select_related('medicine__author').order_by('-id')
    status=request.query_params.get('status',''); q=request.query_params.get('q','').strip()
    if status: rows=rows.filter(status=status)
    if q: rows=rows.filter(name__icontains=q)
    return paginate(request,rows,lambda c:summary(c,admin=True))


@api_view(['POST'])
@permission_classes([PlatformAdmin])
def admin_sync(request):
    return Response({'processed':sync_all()})
