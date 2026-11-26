from datetime import timedelta
from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Q
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.pagination import PageNumberPagination
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from .admin_api import PlatformAdmin
from .models import SubscriptionPlan, Subscription, PointWallet, PointTransaction, Profile, ProfessionalApplication

User = get_user_model()

class Pages(PageNumberPagination):
    page_size = 20


def paginate(request, rows, encode):
    p = Pages()
    return p.get_paginated_response([encode(row) for row in p.paginate_queryset(rows, request)])


def plan_data(p):
    return dict(code=p.code, name=p.name, price_fcfa=p.price_fcfa, duration_days=p.duration_days, enabled=p.enabled)


def status(s):
    return 'expired' if s.status == 'active' and s.ends_at and s.ends_at <= timezone.now() else s.status


def sub_data(s):
    return dict(id=s.pk, username=s.user.username, plan=s.plan_id, price_fcfa=s.price_fcfa, duration_days=s.duration_days,
        status=status(s), requested_at=s.requested_at, starts_at=s.starts_at, ends_at=s.ends_at,
        reason=s.reason, decided_by=s.decided_by.username if s.decided_by_id else None)


def entry_data(e):
    return dict(id=e.pk, delta=e.delta, balance_after=e.balance_after, reason=e.reason, actor=e.actor.username if e.actor_id else "Système", created_at=e.created_at)


def verified(user):
    return bool(user.is_active and Profile.objects.filter(user=user, professional_verified=True, application__status='approved').exists())


def lock_user(pk):
    return get_object_or_404(User.objects.select_for_update(), pk=pk)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def plans(request):
    return Response([plan_data(p) for p in SubscriptionPlan.objects.filter(enabled=True).order_by('price_fcfa','code')])


@api_view(['GET','POST'])
@permission_classes([IsAuthenticated])
def my_subscription(request):
    if request.method == 'GET':
        rows = Subscription.objects.filter(user=request.user).select_related('user','decided_by')
        active = rows.filter(status='active', ends_at__gt=timezone.now()).first()
        pending = rows.filter(status='pending').first()
        return Response(dict(current=sub_data(active) if active else None, effective_plan=active.plan_id if active else 'free', pending=sub_data(pending) if pending else None,
            latest=[sub_data(s) for s in rows.order_by('-id')[:5]]))
    class Input(serializers.Serializer):
        plan = serializers.ChoiceField(choices=['silver','gold'])
    form = Input(data=request.data); form.is_valid(raise_exception=True)
    with transaction.atomic():
        user = lock_user(request.user.pk)
        if not user.is_active: raise PermissionDenied()
        p = get_object_or_404(SubscriptionPlan.objects.select_for_update(), pk=form.validated_data['plan'], enabled=True)
        Subscription.objects.filter(user=user,status='active',ends_at__lte=timezone.now()).update(status='expired')
        if Subscription.objects.filter(user=user,status__in=['pending','active']).exists():
            raise ValidationError('Une demande ou un abonnement payant est déjà en cours.')
        s = Subscription.objects.create(user=user,plan=p,price_fcfa=p.price_fcfa,duration_days=p.duration_days)
    return Response(sub_data(s),status=201)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def cancel_pending(request, pk):
    with transaction.atomic():
        lock_user(request.user.pk)
        s = get_object_or_404(Subscription.objects.select_for_update(),pk=pk,user=request.user)
        if s.status != 'pending': raise ValidationError('Seule une demande en attente peut être retirée par son auteur.')
        s.status='cancelled'; s.reason='Retrait par l’usager'; s.decided_at=timezone.now(); s.decided_by=request.user
        s.save(update_fields=['status','reason','decided_at','decided_by'])
    return Response(sub_data(s))


@api_view(['GET'])
@permission_classes([PlatformAdmin])
def admin_plans(request):
    return Response([plan_data(p) for p in SubscriptionPlan.objects.order_by('price_fcfa','code')])


@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def admin_plan(request, code):
    class Input(serializers.Serializer):
        price_fcfa=serializers.IntegerField(min_value=1,max_value=1000000,required=False)
        enabled=serializers.BooleanField(required=False)
    if code == 'free': raise ValidationError('L’offre gratuite ne peut pas être désactivée ou rendue payante.')
    form=Input(data=request.data); form.is_valid(raise_exception=True)
    with transaction.atomic():
        p=get_object_or_404(SubscriptionPlan.objects.select_for_update(),pk=code)
        for k,v in form.validated_data.items(): setattr(p,k,v)
        p.save()
    return Response(plan_data(p))


@api_view(['GET'])
@permission_classes([PlatformAdmin])
def admin_subscriptions(request):
    q=request.query_params.get('q','').strip(); st=request.query_params.get('status','')
    rows=Subscription.objects.select_related('user','decided_by').filter(user__username__icontains=q)
    now=timezone.now()
    if st=='expired': rows=rows.filter(Q(status='expired')|Q(status='active',ends_at__lte=now))
    elif st=='active': rows=rows.filter(status='active',ends_at__gt=now)
    elif st in ['pending','rejected','cancelled']: rows=rows.filter(status=st)
    return paginate(request,rows.order_by('-id'),sub_data)


@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def admin_subscription(request, pk):
    class Input(serializers.Serializer):
        action=serializers.ChoiceField(choices=['activate','reject','cancel'])
        reason=serializers.CharField(max_length=500, min_length=3)
    form=Input(data=request.data); form.is_valid(raise_exception=True); d=form.validated_data
    uid=get_object_or_404(Subscription,pk=pk).user_id
    with transaction.atomic():
        user=lock_user(uid)
        s=get_object_or_404(Subscription.objects.select_for_update(),pk=pk)
        now=timezone.now(); action=d['action']
        if action=='activate':
            if s.status!='pending' or not user.is_active: raise ValidationError('Demande non activable.')
            s.status='active'; s.starts_at=now; s.ends_at=now+timedelta(days=s.duration_days)
        elif action=='reject':
            if s.status!='pending': raise ValidationError('Demande déjà traitée.')
            s.status='rejected'
        else:
            if status(s) not in ['pending','active']: raise ValidationError('Abonnement non annulable.')
            s.status='cancelled'
        s.reason=d['reason']; s.decided_at=now; s.decided_by=request.user
        s.save()
        # Atomic: a failed decision cannot leave a false notification behind.
        from .models import ReviewNotification
        label = s.plan.name
        messages = {
            'activate': f'Votre abonnement {label} a été activé. Consultez votre compte pour connaître sa date de fin.',
            'reject': f'Votre demande d’abonnement {label} a été refusée. Consultez le motif dans votre compte.',
            'cancel': f'Votre abonnement ou demande {label} a été annulé par l’administration.'
        }
        ReviewNotification.objects.create(user_id=s.user_id, category='subscription', subscription=s, message=messages[action][:500])
    return Response(sub_data(s))


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def my_points(request):
    if not verified(request.user): raise PermissionDenied('Réservé aux professionnels validés.')
    wallet=PointWallet.objects.filter(user=request.user).first()
    return Response(dict(balance=wallet.balance if wallet else 0, latest=[entry_data(e) for e in wallet.entries.select_related('actor').order_by('-id')[:10]] if wallet else []))


def professional_users():
    return User.objects.filter(is_active=True,profile__professional_verified=True,profile__application__status='approved')


@api_view(['GET'])
@permission_classes([PlatformAdmin])
def admin_wallets(request):
    q=request.query_params.get('q','').strip()
    # Include revoked professionals with an existing wallet for audit; adjustment remains blocked.
    rows=User.objects.filter(Q(pk__in=professional_users().values('pk'))|Q(pointwallet__isnull=False)).filter(username__icontains=q).select_related('pointwallet','profile','profile__application')
    def encode(u):
        p=getattr(u,'profile',None); a=getattr(p,'application',None)
        w=getattr(u,'pointwallet',None)
        return dict(id=u.pk,username=u.username,balance=w.balance if w else 0,verified=bool(u.is_active and p and p.professional_verified and a and a.status=='approved'))
    return paginate(request,rows.order_by('username','pk'),encode)


@api_view(['GET','POST'])
@permission_classes([PlatformAdmin])
def admin_wallet(request, pk):
    user=get_object_or_404(User,pk=pk)
    if request.method=='GET':
        w=PointWallet.objects.filter(user=user).first()
        if not w and not verified(user): raise ValidationError('Portefeuille indisponible.')
        return paginate(request,PointTransaction.objects.filter(wallet__user=user).select_related('actor').order_by('-id'),entry_data)
    class Input(serializers.Serializer):
        delta=serializers.IntegerField(min_value=-100000,max_value=100000)
        reason=serializers.CharField(max_length=500,min_length=3)
        operation_id=serializers.UUIDField()
    form=Input(data=request.data); form.is_valid(raise_exception=True); d=form.validated_data
    if not d['delta']: raise ValidationError('Le montant doit être non nul.')
    with transaction.atomic():
        user=lock_user(pk)
        # Lock the same profile row as professional approval/revocation.
        Profile.objects.select_for_update().filter(user=user).first()
        if not verified(user): raise ValidationError('Professionnel non validé ou suspendu.')
        w,_=PointWallet.objects.get_or_create(user=user)
        w=PointWallet.objects.select_for_update().get(pk=w.pk)
        old=PointTransaction.objects.filter(operation_id=d['operation_id']).first()
        if old:
            if old.wallet_id!=w.pk or old.actor_id!=request.user.pk or old.delta!=d['delta'] or old.reason!=d['reason']:
                raise ValidationError('Identifiant d’opération déjà utilisé.')
            return Response(entry_data(old))
        balance=w.balance+d['delta']
        if balance<0: raise ValidationError('Solde insuffisant.')
        if balance>1000000000: raise ValidationError('Solde maximal dépassé.')
        w.balance=balance; w.save(update_fields=['balance'])
        e=PointTransaction.objects.create(wallet=w,delta=d['delta'],balance_after=balance,reason=d['reason'],actor=request.user,operation_id=d['operation_id'])
    return Response(entry_data(e),status=201)
