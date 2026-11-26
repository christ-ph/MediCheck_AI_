#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/Bureau/MediCheck}"
cd "$ROOT"
ROOT="$(pwd)"
command -v uv >/dev/null
command -v python3 >/dev/null
for f in backend/manage.py backend/core/models.py backend/core/admin_api.py mobile/App.js mobile/session.js admin-web/src/main.jsx admin-web/src/session.js; do
  [[ -f "$f" ]] || { echo "Fichier manquant : $f. Installer les mises à jour précédentes." >&2; exit 1; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/billing_models.py" <<'MEDICHECK_FILE'
from django.conf import settings
from django.db import models
from django.db.models import Q


class SubscriptionPlan(models.Model):
    code = models.CharField(max_length=12, primary_key=True)
    name = models.CharField(max_length=40)
    price_fcfa = models.PositiveIntegerField(default=0)
    duration_days = models.PositiveIntegerField(default=30)
    enabled = models.BooleanField(default=True)


class Subscription(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    plan = models.ForeignKey(SubscriptionPlan, on_delete=models.PROTECT)
    price_fcfa = models.PositiveIntegerField()
    duration_days = models.PositiveIntegerField()
    status = models.CharField(max_length=12, default='pending', choices=[(x,x) for x in ('pending','active','rejected','cancelled','expired')])
    requested_at = models.DateTimeField(auto_now_add=True)
    starts_at = models.DateTimeField(null=True, blank=True)
    ends_at = models.DateTimeField(null=True, blank=True)
    decided_at = models.DateTimeField(null=True, blank=True)
    decided_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name='subscription_decisions')
    reason = models.CharField(max_length=500, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['user'], condition=Q(status__in=['pending','active']), name='one_open_subscription')]


class PointWallet(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    balance = models.PositiveBigIntegerField(default=0)


class PointTransaction(models.Model):
    wallet = models.ForeignKey(PointWallet, on_delete=models.PROTECT, related_name='entries')
    delta = models.BigIntegerField()
    balance_after = models.PositiveBigIntegerField()
    reason = models.CharField(max_length=500)
    actor = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name='point_adjustments')
    operation_id = models.UUIDField(unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
MEDICHECK_FILE
cat > "$tmp/billing_api.py" <<'MEDICHECK_FILE'
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
    return dict(id=e.pk, delta=e.delta, balance_after=e.balance_after, reason=e.reason, actor=e.actor.username, created_at=e.created_at)


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
MEDICHECK_FILE
cat > "$tmp/billing_urls.py" <<'MEDICHECK_FILE'
from django.urls import path
from . import billing_api as a
urlpatterns = [
    path('billing/plans/', a.plans),
    path('billing/subscription/', a.my_subscription),
    path('billing/subscription/<int:pk>/cancel/', a.cancel_pending),
    path('billing/points/', a.my_points),
    path('admin/billing/plans/', a.admin_plans),
    path('admin/billing/plans/<str:code>/', a.admin_plan),
    path('admin/billing/subscriptions/', a.admin_subscriptions),
    path('admin/billing/subscriptions/<int:pk>/', a.admin_subscription),
    path('admin/billing/wallets/', a.admin_wallets),
    path('admin/billing/wallets/<int:pk>/', a.admin_wallet),
]
MEDICHECK_FILE
cat > "$tmp/test_billing.py" <<'MEDICHECK_FILE'
import uuid
from datetime import timedelta
from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework.test import APITestCase
from .models import SubscriptionPlan, Subscription, Profile, ProfessionalApplication, PointWallet, PointTransaction

class BillingTests(APITestCase):
    def setUp(self):
        U=get_user_model()
        self.user=U.objects.create_user(username='billing-user')
        self.pro=U.objects.create_user(username='billing-pro')
        self.admin=U.objects.create_superuser(username='billing-admin',password='test-only-pass')
        p=Profile.objects.create(user=self.pro,professional_requested=True,professional_verified=True)
        ProfessionalApplication.objects.create(profile=p,status='approved',proof=b'%PDF-test')
        for code,price in [('free',0),('silver',1000),('gold',2500)]:
            SubscriptionPlan.objects.update_or_create(code=code,defaults={'name':code.title(),'price_fcfa':price,'enabled':True})
    def auth(self,u): self.client.force_authenticate(user=u)
    def test_subscription_flow(self):
        self.auth(self.user)
        self.assertEqual(self.client.get('/api/admin/billing/subscriptions/').status_code,403)
        self.assertEqual(self.client.get('/api/billing/subscription/').data['effective_plan'],'free')
        r=self.client.post('/api/billing/subscription/',{'plan':'silver','price_fcfa':1},format='json')
        self.assertEqual(r.status_code,201); pk=r.data['id']; self.assertEqual(r.data['price_fcfa'],1000)
        self.assertEqual(self.client.post('/api/billing/subscription/',{'plan':'gold'},format='json').status_code,400)
        self.auth(self.pro)
        self.assertEqual(self.client.post(f'/api/billing/subscription/{pk}/cancel/',{},format='json').status_code,404)
        self.auth(self.admin)
        self.assertEqual(self.client.patch(f'/api/admin/billing/subscriptions/{pk}/',{'action':'activate','reason':'Test de démonstration'},format='json').status_code,200)
        self.auth(self.user)
        self.assertEqual(self.client.get('/api/billing/subscription/').data['effective_plan'],'silver')
        Subscription.objects.filter(pk=pk).update(ends_at=timezone.now()-timedelta(seconds=1))
        self.assertEqual(self.client.get('/api/billing/subscription/').data['effective_plan'],'free')
        self.assertEqual(self.client.post('/api/billing/subscription/',{'plan':'gold'},format='json').status_code,201)
    def test_points_permissions_and_balance(self):
        self.auth(self.user)
        self.assertEqual(self.client.get('/api/billing/points/').status_code,403)
        url=f'/api/admin/billing/wallets/{self.pro.pk}/'
        d={'delta':50,'reason':'Contribution de test','operation_id':str(uuid.uuid4())}
        self.assertEqual(self.client.post(url,d,format='json').status_code,403)
        self.auth(self.admin)
        self.assertEqual(self.client.post(url,d,format='json').status_code,201)
        self.assertEqual(self.client.post(url,d,format='json').status_code,200)
        self.assertEqual(PointTransaction.objects.count(),1)
        self.assertEqual(self.client.post(url,{**d,'delta':-51,'operation_id':str(uuid.uuid4())},format='json').status_code,400)
        self.assertEqual(PointWallet.objects.get(user=self.pro).balance,50)
        self.auth(self.pro)
        self.assertEqual(self.client.get('/api/billing/points/').data['balance'],50)
        Profile.objects.filter(user=self.pro).update(professional_verified=False)
        self.assertEqual(self.client.get('/api/billing/points/').status_code,403)
MEDICHECK_FILE
cat > "$tmp/BillingPanel.js" <<'MEDICHECK_FILE'
import React, {useState, useEffect, useRef} from 'react';
import {View, Text, StyleSheet, Pressable, ActivityIndicator} from 'react-native';
import {colors as c} from './theme';
const labels={free:'Free',silver:'Silver',gold:'Gold',pending:'En attente',active:'Actif',expired:'Expiré',cancelled:'Annulé',rejected:'Refusé'};
const date=x=>x?new Date(x).toLocaleDateString('fr-FR'):'—';
const money=x=>Number(x).toLocaleString('fr-FR')+' FCFA';
const benefits={free:'Catalogue, signalements et sécurité',silver:'Services Free + scan et historique (à venir)',gold:'Services Silver + assistant IA étendu (à venir)'};
function Button({title,onPress,disabled,secondary}) {return <Pressable accessibilityRole="button" disabled={disabled} onPress={onPress} style={[s.button,{backgroundColor:secondary?c.secondary:c.primary,opacity:disabled ? 0.5 : 1}]}><Text style={{color:secondary?c.text:'#fff',fontWeight:'700',textAlign:'center'}}>{title}</Text></Pressable>}
export default function BillingPanel({api,token,verified}){
  const [data,setData]=useState(null),[points,setPoints]=useState(null),[plans,setPlans]=useState([]),[tab,setTab]=useState(''),[busy,B]=useState(false),[error,E]=useState(''),[message,M]=useState('');
  const lock=useRef(false);
  async function load(which){
    if(which==='plans') {const [p,d]=await Promise.all([api('billing/plans','GET',null,token),api('billing/subscription','GET',null,token)]);setPlans(p);setData(d);}
    else if(which==='points'&&verified) setPoints(await api('billing/points','GET',null,token));
  }
  async function run(fn){if(lock.current)return;lock.current=true;B(true);E('');M('');try{await fn();}catch(e){E(e.message);}finally{lock.current=false;B(false);}}
  useEffect(()=>{if(!verified){setPoints(null);setTab(t=>t==='points'?'':t);}},[verified]);
  function open(which){setTab(which);run(()=>load(which));}
  return <View style={s.panel}>
    <Text style={s.title}>Mon compte</Text><View style={s.row}><Button title="Mes abonnements" secondary disabled={busy} onPress={()=>open('plans')}/>{verified&&<Button title="Mes points" secondary disabled={busy} onPress={()=>open('points')}/>}</View>
    {!!tab&&<><Button title="Fermer" secondary disabled={busy} onPress={()=>{setTab('');E('');M('');}}/><Button title="Actualiser" disabled={busy} onPress={()=>run(()=>load(tab))}/></>}
    {busy&&<ActivityIndicator color={c.primary}/>}{!!error&&<Text accessibilityRole="alert" style={{color:c.danger}}>{error}</Text>}{!!message&&<Text style={s.title}>{message}</Text>}
    {tab==='plans'&&data&&<><Text style={s.heading}>Offre actuelle : {labels[data.effective_plan]}</Text>{data.current&&<Text style={s.body}>Expiration : {date(data.current.ends_at)}</Text>}
      <Text style={s.body}>Abonnements de démonstration : aucun paiement ni prélèvement réel. Les options avancées sont à venir.</Text>
      {data.pending&&<View style={s.card}><Text style={s.heading}>Demande {labels[data.pending.plan]} en attente</Text><Text style={s.body}>{money(data.pending.price_fcfa)}</Text><Button title="Retirer ma demande" disabled={busy} secondary onPress={()=>run(async()=>{await api(`billing/subscription/${data.pending.id}/cancel`,'POST',{},token);await load('plans');M('Demande retirée.');})}/></View>}
      {plans.map(p=><View key={p.code} style={[s.card,{borderLeftWidth:5,borderLeftColor:p.code==='gold'?c.tertiary:p.code==='silver'?c.secondary:c.primary}]}><Text style={s.heading}>{p.name}</Text><Text style={s.amount}>{money(p.price_fcfa)} / {p.duration_days} jours</Text><Text style={s.body}>{benefits[p.code]}</Text>{p.code!=='free'&&<Button title="Demander cette offre (démo)" disabled={busy||!!data.pending||!!data.current} onPress={()=>run(async()=>{await api('billing/subscription','POST',{plan:p.code},token);await load('plans');M('Demande transmise. Aucun paiement effectué.');})}/>}</View>)}
      {!!data.current&&<Text style={s.body}>Pour changer d’offre avant expiration, contactez l’administration.</Text>}
      <Text style={s.heading}>Dernières demandes</Text>{data.latest.map(x=><View key={x.id} style={s.card}><Text style={s.heading}>{labels[x.plan]} — {labels[x.status]}</Text><Text style={s.body}>{money(x.price_fcfa)} · {date(x.requested_at)}{x.reason?' · '+x.reason:''}</Text></View>)}
    </>}
    {tab==='points'&&verified&&points&&<><View style={s.balance}><Text style={{color:'#fff'}}>Solde de points</Text><Text style={{color:'#fff',fontSize:32,fontWeight:'800'}}>{points.balance} pts</Text></View><Text style={s.body}>Points non monétaires. Aucun retrait d’argent disponible.</Text><Text style={s.heading}>10 dernières opérations</Text>{points.latest.length===0&&<Text style={s.body}>Aucune opération.</Text>}{points.latest.map(x=><View key={x.id} style={s.card}><Text style={[s.heading,{color:x.delta<0?c.danger:c.primary}]}>{x.delta>0?'+':''}{x.delta} pts</Text><Text style={s.body}>{x.reason} · {date(x.created_at)}</Text><Text style={s.body}>Solde après opération : {x.balance_after}</Text></View>)}</>}
  </View>;
}
const s=StyleSheet.create({panel:{padding:14,borderRadius:14,backgroundColor:c.background,gap:10},row:{flexDirection:'row',flexWrap:'wrap',gap:8},title:{color:c.primary,fontSize:19,fontWeight:'800'},heading:{color:c.primary,fontWeight:'700',fontSize:15},body:{color:c.text,fontSize:13,lineHeight:20},card:{backgroundColor:'#fff',borderRadius:12,borderWidth:1,borderColor:c.border,padding:14,gap:8},amount:{color:c.primary,fontSize:18,fontWeight:'800'},balance:{backgroundColor:c.primary,padding:18,borderRadius:12,gap:5},button:{padding:12,borderRadius:12,minHeight:44,justifyContent:'center'}});
MEDICHECK_FILE
cat > "$tmp/BillingAdmin.jsx" <<'MEDICHECK_FILE'
import React,{useEffect,useRef,useState} from 'react';
const labels={free:'Free',silver:'Silver',gold:'Gold',pending:'En attente',active:'Actif',expired:'Expiré',cancelled:'Annulé',rejected:'Refusé'};
const date=x=>x?new Date(x).toLocaleString('fr-FR'):'—';
const money=x=>Number(x).toLocaleString('fr-FR')+' FCFA';
export default function BillingAdmin({api,token,section}){
  const [plans,P]=useState([]),[data,D]=useState(null),[query,Q]=useState(''),[search,S]=useState(''),[filter,F]=useState(''),[page,Page]=useState(1),[rev,R]=useState(0),[error,E]=useState(''),[busy,B]=useState(false),[loading,L]=useState(false),[message,M]=useState(''),[wallet,W]=useState(null),[history,H]=useState(null),[hp,HP]=useState(1),[delta,Delta]=useState(''),[reason,Reason]=useState('');
  const op=useRef(null),lock=useRef(false);
  const call=(path,method='GET',payload=null)=>api('admin/billing/'+path,token,method,payload);
  useEffect(()=>{let live=true;L(true);E('');D(null);const path=(section==='subscriptions'?'subscriptions/':'wallets/')+'?'+new URLSearchParams({q:search,page:String(page),status:filter});Promise.all([call(path),section==='subscriptions'?call('plans/'):Promise.resolve([])]).then(([d,p])=>{if(live){D(d);P(p);}}).catch(e=>{if(live)E(e.message);}).finally(()=>{if(live)L(false);});return()=>{live=false;};},[section,search,filter,page,rev,token]);
  useEffect(()=>{if(!wallet)return;let live=true;H(null);call(`wallets/${wallet.id}/?page=${hp}`).then(x=>{if(live)H(x);}).catch(e=>{if(live)E(e.message);});return()=>{live=false;};},[wallet?.id,hp,rev,token]);
  async function run(fn){if(lock.current)return;lock.current=true;B(true);E('');M('');try{await fn();R(x=>x+1);}catch(e){E(e.message);}finally{lock.current=false;B(false);}}
  function decision(r,action){const why=window.prompt('Motif obligatoire (activation de démonstration uniquement) :');if(!why?.trim())return;run(async()=>{await call(`subscriptions/${r.id}/`,'PATCH',{action,reason:why.trim()});Page(1);M('Décision enregistrée.');});}
  function price(p){const raw=window.prompt('Nouveau prix mensuel en FCFA :',String(p.price_fcfa));if(raw===null)return;const n=Number(raw);if(!Number.isInteger(n)||n<1||n>1000000){E('Prix invalide.');return;}run(async()=>{await call(`plans/${p.code}/`,'PATCH',{price_fcfa:n});M('Tarif mis à jour pour les futures demandes.');});}
  function adjust(e){e.preventDefault();const n=Number(delta);if(!Number.isInteger(n)||n===0||Math.abs(n)>100000||reason.trim().length<3){E('Montant entier non nul et motif obligatoire.');return;}const fingerprint=JSON.stringify([wallet.id,n,reason.trim()]);if(op.current?.fingerprint!==fingerprint){op.current={fingerprint,id:crypto.randomUUID()};}const operation_id=op.current.id;run(async()=>{const x=await call(`wallets/${wallet.id}/`,'POST',{delta:n,reason:reason.trim(),operation_id});W(w=>({...w,balance:x.balance_after}));Delta('');Reason('');op.current=null;HP(1);M('Opération enregistrée.');});}
  const pager=(d,p,set)=><div className="pagination"><span>{d.count} résultat(s) · Page {p} / {Math.max(1,Math.ceil(d.count/20))}</span><div><button className="secondary" disabled={busy||!d.previous} onClick={()=>set(x=>x-1)}>Précédent</button> <button disabled={busy||!d.next} onClick={()=>set(x=>x+1)}>Suivant</button></div></div>;
  return <section className="panel billing-panel"><div className="hero"><h2>{section==='subscriptions'?'Gestion des abonnements':'Gestion des points'}</h2><p>{section==='subscriptions'?'Activation de démonstration, sans encaissement réel.':'Crédits et débits tracés, réservés aux professionnels validés.'}</p></div>{error&&<div className="error" role="alert">{error}</div>}{message&&<div className="notice" role="status">{message}</div>}
  {section==='subscriptions'&&<div className="cards">{plans.map(p=><div className="stat" key={p.code}><span>{p.name} · {p.enabled?'Disponible':'Désactivée'}</span><strong>{money(p.price_fcfa)}</strong><small>{p.duration_days} jours</small>{p.code!=='free'&&<div style={{display:'flex',gap:8,flexWrap:'wrap'}}><button disabled={busy} onClick={()=>price(p)}>Modifier tarif</button><button className="secondary" disabled={busy} onClick={()=>run(async()=>{await call(`plans/${p.code}/`,'PATCH',{enabled:!p.enabled});})}>{p.enabled?'Désactiver':'Activer'}</button></div>}</div>)}</div>}
  <div className="toolbar"><form onSubmit={e=>{e.preventDefault();Page(1);S(query.trim());}}><input placeholder="Identifiant utilisateur" value={query} onChange={e=>Q(e.target.value)}/><button disabled={busy||loading}>Rechercher</button></form>{section==='subscriptions'&&<select value={filter} onChange={e=>{F(e.target.value);Page(1);}}>{['','pending','active','expired','rejected','cancelled'].map(x=><option key={x} value={x}>{labels[x]||'Tous les statuts'}</option>)}</select>}<button className="secondary" disabled={busy} onClick={()=>R(x=>x+1)}>Actualiser</button></div>
  {loading&&<p>Chargement…</p>}{data&&<><div className="table-wrap"><table><thead><tr>{(section==='subscriptions'?['Utilisateur','Offre','Tarif','Statut','Expiration','Décision']:['Professionnel','Statut','Solde','Action']).map(x=><th key={x}>{x}</th>)}</tr></thead><tbody>{data.results.map(r=><tr key={r.id}>{section==='subscriptions'?<><td>{r.username}</td><td>{labels[r.plan]}</td><td>{money(r.price_fcfa)}</td><td>{labels[r.status]}{r.reason&&<p>{r.reason}</p>}</td><td>{date(r.ends_at)}</td><td>{r.status==='pending'&&<><button disabled={busy} onClick={()=>decision(r,'activate')}>Activer (démo)</button> <button className="danger" disabled={busy} onClick={()=>decision(r,'reject')}>Refuser</button></>}{r.status==='active'&&<button className="danger" disabled={busy} onClick={()=>decision(r,'cancel')}>Annuler</button>}</td></>:<><td>{r.username}</td><td>{r.verified?'Validé':'Non habilité'}</td><td>{r.balance} pts</td><td><button disabled={busy} onClick={()=>{W(r);HP(1);Delta('');Reason('');}}>Ouvrir portefeuille</button></td></>}</tr>)}</tbody></table></div>{!data.results.length&&<p>Aucun résultat.</p>}{pager(data,page,Page)}</>}
  {section==='wallets'&&wallet&&<div className="billing-wallet"><h2>Portefeuille — {wallet.username}</h2><p>Solde : <strong>{data?.results.find(x=>x.id===wallet.id)?.balance??wallet.balance} pts</strong></p>{wallet.verified&&<form onSubmit={adjust} style={{display:'grid',gap:10}}><label>Montant signé (ex. 50 ou -10)<input type="number" required step="1" min="-100000" max="100000" value={delta} onChange={e=>Delta(e.target.value)}/></label><label>Motif / référence de contribution<input required maxLength={500} value={reason} onChange={e=>Reason(e.target.value)}/></label><button disabled={busy}>Enregistrer l’opération</button></form>}<h3>Historique</h3>{history&&<><div className="table-wrap"><table><thead><tr><th>Date</th><th>Points</th><th>Solde</th><th>Motif</th><th>Administrateur</th></tr></thead><tbody>{history.results.map(x=><tr key={x.id}><td>{date(x.created_at)}</td><td>{x.delta>0?'+':''}{x.delta}</td><td>{x.balance_after}</td><td>{x.reason}</td><td>{x.actor}</td></tr>)}</tbody></table></div>{pager(history,hp,HP)}</>}<button className="secondary" disabled={busy} onClick={()=>W(null)}>Fermer le portefeuille</button></div>}
  </section>;
}
MEDICHECK_FILE
cat > "$tmp/patch.py" <<'MEDICHECK_FILE'
from pathlib import Path
import sys, ast
root=Path(sys.argv[1]); tmp=Path(sys.argv[2]); out=Path(sys.argv[3]);
files={}
def replace(s,old,new):
    if s.count(old)!=1: raise SystemExit('Version inattendue, patch annulé : '+old[:100])
    return s.replace(old,new,1)
def read(p): return (root/p).read_text()
def add(p,content):
    if (root/p).exists(): raise SystemExit('Fichier déjà présent : '+p)
    files[p]=content
m='backend/core/models.py'; s=read(m)
if 'class ProfessionalApplication' not in s or 'SubscriptionPlan' in s: raise SystemExit('Appliquer update_professional.sh avant cette mise à jour, ou module déjà installé.')
files[m]=s+'\n\nfrom .billing_models import SubscriptionPlan, Subscription, PointWallet, PointTransaction\n'
for n in ('billing_models.py','billing_api.py','billing_urls.py','test_billing.py'): add('backend/core/'+n,(tmp/n).read_text())
p='backend/config/urls.py'; files[p]=read(p)+"\nfrom django.urls import include\nurlpatterns += [path('api/', include('core.billing_urls'))]\n"
p='mobile/App.js'; s=read(p)
s=replace(s,"import { session } from './session';","import { session } from './session';\nimport BillingPanel from './BillingPanel';")
s=replace(s,"                {showApplication && !canPropose && profile?.professional_status !== 'pending' ? <>","                <BillingPanel api={api} token={token} verified={canPropose} />\n                {showApplication && !canPropose && profile?.professional_status !== 'pending' ? <>")
files[p]=s; add('mobile/BillingPanel.js',(tmp/'BillingPanel.js').read_text())
p='admin-web/src/main.jsx'; s=read(p)
s=replace(s,"import { session } from './session';","import { session } from './session';\nimport BillingAdmin from './BillingAdmin';")
s=replace(s,"reports:'Signalements'};","reports:'Signalements',subscriptions:'Abonnements',wallets:'Points et récompenses'};")
s=replace(s,"useEffect(()=>{if(!token)return;let alive=true;L(true);E('');D(null);","useEffect(()=>{if(!token||['subscriptions','wallets'].includes(section))return;let alive=true;L(true);E('');D(null);")
s=replace(s,"{section==='overview'?<>","{['subscriptions','wallets'].includes(section)?<BillingAdmin key={section} api={api} token={token} section={section}/>:section==='overview'?<>")
files[p]=s; add('admin-web/src/BillingAdmin.jsx',(tmp/'BillingAdmin.jsx').read_text())
p='admin-web/src/style.css'; files[p]=read(p)+'''\n/* Modules abonnements et points */\n.billing-panel{display:grid;gap:20px}.billing-panel .stat{display:flex;flex-direction:column;gap:10px}.billing-wallet{border:1px solid #cde8e9;border-radius:16px;padding:20px;display:grid;gap:12px;background:#ecfffd}.billing-wallet form{max-width:540px}.billing-wallet label{display:grid;gap:6px}.billing-panel .toolbar{flex-wrap:wrap}.billing-panel td p{font-size:12px;max-width:240px;overflow-wrap:anywhere}\n'''
for p,s in files.items():
    if p.endswith('.py'):ast.parse(s,filename=p)
    dest=out/p;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(s)
MEDICHECK_FILE
python3 "$tmp/patch.py" "$ROOT" "$tmp" "$tmp/output"
backup="$ROOT/.billing-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
while IFS= read -r -d '' f; do
  rel="${f#"$tmp/output/"}"
  if [[ -f "$ROOT/$rel" ]]; then
    mkdir -p "$backup/$(dirname "$rel")"
    cp -p "$ROOT/$rel" "$backup/$rel"
  fi
done < <(find "$tmp/output" -type f -print0)
# SQLite backup via its backup API, without deleting or overwriting the database.
if [[ -f backend/db.sqlite3 ]]; then
  python3 - "$backup/db.sqlite3" <<'DBBACKUP'
import sqlite3,sys
with sqlite3.connect('backend/db.sqlite3') as src, sqlite3.connect(sys.argv[1]) as dst:
    src.backup(dst)
DBBACKUP
  chmod 600 "$backup/db.sqlite3"
fi
chmod 700 "$backup"
cp -R "$tmp/output/." "$ROOT/"
cd "$ROOT/backend"
uv run python manage.py check
uv run python manage.py makemigrations core
uv run python manage.py migrate
uv run python manage.py shell -c "from core.models import SubscriptionPlan; [SubscriptionPlan.objects.get_or_create(code=c, defaults=dict(name=n,price_fcfa=p,duration_days=30)) for c,n,p in [('free','Free',0),('silver','Silver',1000),('gold','Gold',2500)]]"
uv run python manage.py test core.test_billing
cd "$ROOT/admin-web"
npm run build
printf '\nInstallation terminée. Sauvegarde : %s\n' "$backup"
printf '%s\n' 'Django : uv run python manage.py runserver 0.0.0.0:8000' 'Admin : npm run dev' 'Mobile : npx expo start --web --clear'
