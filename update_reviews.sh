#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/Bureau/MediCheck}"
cd "$ROOT"; ROOT="$(pwd)"
command -v uv >/dev/null; command -v python3 >/dev/null; command -v npm >/dev/null
for f in backend/manage.py backend/core/duplicate_api.py backend/core/billing_api.py mobile/BillingPanel.js admin-web/src/BillingAdmin.jsx; do
  [[ -f "$f" ]] || { echo "Fichier manquant : $f. Installez les mises à jour précédentes." >&2; exit 1; }
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
trap 'echo "Installation interrompue. Consultez les erreurs ; ne supprimez pas la base de données." >&2' ERR
(cd backend && uv run python manage.py migrate --check && uv run python manage.py makemigrations --check --dry-run)
cat > "$TMP/ReviewAdmin.jsx" <<'MEDICHECK_REVIEW_FILE'
import React,{useEffect,useState,useRef} from 'react';
const labels={waiting:'En attente',reviewing:'En cours',published:'Publié',revision:'Correction demandée',pending:'À examiner',voted:'Avis rendu',cancelled:'Annulé',approve:'Approuvé',reject:'Rejeté'};
export default function ReviewAdmin({api,token}){
 const [rows,D]=useState(null),[q,Q]=useState(''),[search,S]=useState(''),[filter,F]=useState(''),[page,P]=useState(1),[rev,R]=useState(0),[error,E]=useState(''),[message,M]=useState(''),[busy,B]=useState(false);const lock=useRef(false);
 useEffect(()=>{let alive=true;D(null);E('');api(`admin/reviews/?${new URLSearchParams({q:search,status:filter,page:String(page)})}`,token).then(j=>{if(alive)D(j)}).catch(e=>{if(alive)E(e.message)});return()=>{alive=false}},[token,api,search,filter,page,rev]);
 async function sync(){if(lock.current)return;lock.current=true;B(true);E('');M('');try{const result=await api('admin/reviews/sync/',token,'POST',{});M(`${result.processed} proposition(s) examinée(s) pour affectation.`);R(x=>x+1)}catch(e){E(e.message)}finally{lock.current=false;B(false)}}
 return <section className="panel"><div className="hero"><h2>Validation collaborative</h2><p>Cinq avis indépendants et unanimes sont nécessaires. Les décisions et leurs justifications restent consultables.</p></div>
 <div className="toolbar"><form onSubmit={e=>{e.preventDefault();P(1);S(q.trim())}}><input value={q} onChange={e=>Q(e.target.value)} placeholder="Nom du médicament"/><button>Rechercher</button></form><select value={filter} onChange={e=>{F(e.target.value);P(1)}}><option value="">Tous les statuts</option>{['waiting','reviewing','published','revision'].map(x=><option key={x} value={x}>{labels[x]}</option>)}</select><button className="secondary" onClick={()=>R(x=>x+1)}>Actualiser</button><button disabled={busy} onClick={sync}>{busy?'Synchronisation…':'Relancer les affectations'}</button></div>
 {error&&<p className="error" role="alert">{error}</p>}{message&&<p className="notice">{message}</p>}
 {!rows&&!error&&<p>Chargement…</p>}{rows&&<><div className="table-wrap"><table><thead><tr><th>Fiche / cycle</th><th>Auteur</th><th>Statut</th><th>Avis</th><th>Détails</th></tr></thead><tbody>{rows.results.map(x=><tr key={x.id}><td>{x.name}<br/>Cycle {x.number}</td><td>{x.author}</td><td>{labels[x.status]}<br/>{x.reason}</td><td>{x.voted}/5 · {x.assigned}/5 affectés</td><td><details><summary>Consulter les examens</summary><p style={{whiteSpace:'pre-wrap'}}>{x.description}</p>{/^https?:\/\//i.test(x.source)&&<a target="_blank" rel="noreferrer" href={x.source}>Source</a>}{x.reviews.map(a=><div key={a.id} style={{borderTop:'1px solid #b9d8dc',padding:'10px 0'}}><strong>{a.reviewer} — {labels[a.state]}</strong><p>{labels[a.decision]} {a.comment}</p>{a.state==='voted'&&<small>Vérifications déclarées : {Object.values(a.checks).filter(Boolean).length}/3</small>}</div>)}</details></td></tr>)}</tbody></table></div>{!rows.results.length&&<p>Aucune proposition.</p>}<div className="pagination"><span>{rows.count} cycle(s) · Page {page}</span><div><button className="secondary" disabled={!rows.previous} onClick={()=>P(x=>x-1)}>Précédent</button> <button disabled={!rows.next} onClick={()=>P(x=>x+1)}>Suivant</button></div></div></>}
 </section>
}
MEDICHECK_REVIEW_FILE
cat > "$TMP/ReviewPanel.js" <<'MEDICHECK_REVIEW_FILE'
import React, {useEffect,useRef,useState} from 'react';
import {View,Text,TextInput,Pressable,StyleSheet,Linking,ActivityIndicator} from 'react-native';
import {colors as c} from './theme';
const labels={waiting:'En attente de réviseurs',reviewing:'En cours de validation',published:'Publié',revision:'Correction demandée',pending:'À examiner',voted:'Avis transmis',cancelled:'Annulé',approve:'Approuvé',reject:'Rejeté'};
const checks=[['source_checked','J’ai examiné la source officielle et sa fiabilité.'],['identity_checked','J’ai vérifié le nom, la forme et le dosage disponibles.'],['content_checked','J’ai examiné les indications, risques et informations de la fiche.']];
function Btn({title,onPress,disabled=false,danger=false}){return <Pressable accessibilityRole="button" disabled={disabled} onPress={onPress} style={[s.button,{backgroundColor:danger?c.danger:c.primary,opacity:disabled ? 0.45 : 1}]}><Text style={s.white}>{title}</Text></Pressable>}
function Source({url}){return /^https?:\/\//i.test(url||'')?<Pressable onPress={()=>Linking.openURL(url).catch(()=>{})}><Text style={s.link}>{url}</Text></Pressable>:null}
export default function ReviewPanel({api,token,section}){
  const [page,P]=useState(1),[data,D]=useState(null),[error,E]=useState(''),[message,M]=useState(''),[busy,B]=useState(false),[loading,L]=useState(false),[rev,R]=useState(0),[selected,S]=useState(null),[comment,C]=useState(''),[checked,K]=useState({}),[edit,F]=useState({});
  const lock=useRef(false);
  const route=section==='validations'?'inbox':section==='myproposals'?'mine':'notifications';
  useEffect(()=>{let alive=true;L(true);D(null);E('');api(`reviews/${route}?page=${page}`,'GET',null,token).then(j=>{if(alive)D(j)}).catch(e=>{if(alive)E(e.message)}).finally(()=>{if(alive)L(false)});return()=>{alive=false}},[api,token,route,page,rev]);
  useEffect(()=>{if(section!=='notifications')return;const timer=setInterval(()=>{if(!lock.current)R(x=>x+1)},15000);return()=>clearInterval(timer)},[section]);
  async function act(fn){if(lock.current)return;lock.current=true;B(true);E('');M('');try{await fn();S(null);M('Opération enregistrée.');R(x=>x+1)}catch(e){E(e.message)}finally{lock.current=false;B(false)}}
  function choose(a){S(a.id);C('');K({})}
  function startEdit(cycle){S(cycle.id);F({name:cycle.name,description:cycle.description,source:cycle.source})}
  const ready=comment.trim().length>=20&&checks.every(([k])=>checked[k]);
  return <View style={s.panel}>
    <Text style={s.title}>{section==='validations'?'Demandes de validation':section==='myproposals'?'Mes propositions':'Notifications internes'}</Text>
    <Text style={s.muted}>{section==='validations'?'Examinez chaque fiche de façon indépendante. Les autres votes ne sont pas affichés pendant le cycle.':section==='myproposals'?'Suivez vos cycles et corrigez les fiches qui nécessitent une révision.':'Messages liés aux propositions et aux validations.'}</Text>
    <Btn title="Actualiser" disabled={busy||loading} onPress={()=>R(x=>x+1)}/>
    {!!error&&<Text style={s.error}>{error}</Text>}{!!message&&<Text style={s.muted}>{message}</Text>}{loading&&<ActivityIndicator color={c.primary}/>}
    {data?.results?.length===0&&<Text style={s.muted}>Aucun élément pour le moment.</Text>}
    {data?.results?.map(row=>{
      if(section==='notifications')return <View key={row.id} style={s.card}><Text style={s.label}>{row.read?'Lu':'Nouveau'} · {new Date(row.created_at).toLocaleString('fr-FR')}</Text><Text style={s.body}>{row.message}</Text>{!row.read&&<Btn title="Marquer comme lu" disabled={busy} onPress={()=>act(()=>api(`reviews/notifications/${row.id}/read`,'POST',{},token))}/>}</View>;
      const cycle=section==='validations'?row.cycle:row;
      return <View key={row.id} style={s.card}>
        <Text style={s.title}>{cycle.name}</Text><Text style={s.label}>Cycle {cycle.number} · {labels[cycle.status]} · {cycle.voted}/5 avis · {cycle.assigned}/5 affectations</Text>
        {section==='validations'&&<Text style={s.muted}>Auteur : {cycle.author} · {labels[row.state]}</Text>}
        {!!cycle.reason&&<Text style={s.muted}>{cycle.reason}</Text>}
        <Text style={s.body}>{cycle.description}</Text><Source url={cycle.source}/>
        {section==='validations'&&row.state==='voted'&&<Text style={s.body}>Votre avis : {labels[row.decision]} — {row.comment}</Text>}
        {section==='validations'&&row.state==='pending'&&cycle.status==='reviewing'&&(selected===row.id?<>
          <Text style={s.label}>Justification médicale (20 caractères minimum)</Text><TextInput style={[s.input,{minHeight:100}]} multiline value={comment} editable={!busy} onChangeText={C}/>
          {checks.map(([k,label])=><Pressable key={k} accessibilityRole="checkbox" accessibilityState={{checked:!!checked[k]}} disabled={busy} onPress={()=>K(o=>({...o,[k]:!o[k]}))} style={s.check}><Text style={s.label}>{checked[k]?'[x]':'[ ]'} {label}</Text></Pressable>)}
          <Btn title="Approuver" disabled={!ready||busy} onPress={()=>act(()=>api(`reviews/inbox/${row.id}/vote`,'POST',{decision:'approve',comment,...checked},token))}/>
          <Btn title="Rejeter" danger disabled={!ready||busy} onPress={()=>act(()=>api(`reviews/inbox/${row.id}/vote`,'POST',{decision:'reject',comment,...checked},token))}/>
          <Btn title="Fermer" disabled={busy} onPress={()=>S(null)}/>
        </>:<Btn title="Examiner la fiche" disabled={busy} onPress={()=>choose(row)}/>)}
        {section==='myproposals'&&cycle.reviews?.map((r,i)=><View key={r.id} style={s.check}><Text style={s.label}>Avis {i+1} : {labels[r.decision]}</Text><Text style={s.body}>{r.comment}</Text></View>)}
        {section==='myproposals'&&cycle.can_revise&&(selected===row.id?<>
          {['name','description','source'].map(k=><View key={k}><Text style={s.label}>{{name:'Nom',description:'Description corrigée',source:'Source officielle'}[k]}</Text><TextInput style={[s.input,k==='description'&&{minHeight:100}]} multiline={k==='description'} value={edit[k]} editable={!busy} onChangeText={v=>F(o=>({...o,[k]:v}))}/></View>)}
          <Btn title="Soumettre la correction" disabled={busy} onPress={()=>act(()=>api(`reviews/mine/${row.id}/revise`,'POST',edit,token))}/><Btn title="Fermer" disabled={busy} onPress={()=>S(null)}/>
        </>:<Btn title="Corriger et relancer" disabled={busy} onPress={()=>startEdit(cycle)}/>)}
      </View>
    })}
    {data&&<View style={{gap:8}}><Text style={s.muted}>Page {page} / {Math.max(1,Math.ceil(data.count/20))}</Text><View style={{flexDirection:'row',flexWrap:'wrap',gap:8}}><Btn title="Précédent" disabled={!data.previous||busy} onPress={()=>{S(null);P(x=>x-1)}}/><Btn title="Suivant" disabled={!data.next||busy} onPress={()=>{S(null);P(x=>x+1)}}/></View></View>}
  </View>
}
const s=StyleSheet.create({panel:{gap:12},card:{gap:10,padding:15,borderWidth:1,borderColor:c.border,borderRadius:16,backgroundColor:c.surface},title:{fontSize:19,fontWeight:'800',color:c.primary},label:{fontWeight:'700',color:c.text},body:{color:c.text,lineHeight:22},muted:{color:c.muted,lineHeight:20},error:{color:c.danger},link:{color:c.primary,textDecorationLine:'underline'},button:{padding:12,borderRadius:10,alignItems:'center'},white:{color:'#fff',fontWeight:'700'},input:{borderWidth:1,borderColor:c.border,borderRadius:10,padding:12,color:c.text,backgroundColor:c.surface,textAlignVertical:'top'},check:{padding:10,borderRadius:8,backgroundColor:c.background,gap:4}});
MEDICHECK_REVIEW_FILE
cat > "$TMP/patch.py" <<'MEDICHECK_REVIEW_FILE'
from pathlib import Path
import ast, sys
root=Path(sys.argv[1]); assets=Path(sys.argv[2]); out=Path(sys.argv[3]); files={}
def read(p):return (root/p).read_text()
def replace(s,a,b,expected=1):
    if s.count(a)!=expected:raise SystemExit('Version inattendue, patch annulé : '+a[:120])
    return s.replace(a,b)
def add(p,s):
    if (root/p).exists():raise SystemExit('Fichier déjà présent : '+p)
    files[p]=s
p='backend/core/models.py'; s=read(p)
if 'identity_key' not in s or 'PointTransaction' not in s or 'ReviewCycle' in s:raise SystemExit('Installer les mises à jour billing et duplicates ; ou module déjà installé.')
files[p]=s+'\nfrom .review_models import ReviewCycle, ReviewAssignment, ReviewNotification\n'
for n in ('review_models.py','review_service.py','review_api.py','review_urls.py','test_reviews.py'):add('backend/core/'+n,(assets/n).read_text())
p='backend/core/billing_models.py'; s=read(p); files[p]=replace(s,"actor = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name='point_adjustments')","actor = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name='point_adjustments')")
p='backend/core/billing_api.py'; files[p]=replace(read(p),'actor=e.actor.username,','actor=e.actor.username if e.actor_id else "Système",')
p='backend/core/views.py'; s=read(p); files[p]=replace(s,'                s.save(author=self.request.user, published=False)','                medicine = s.save(author=self.request.user, published=False)\n                from .review_service import create_cycle\n                create_cycle(medicine)')
p='backend/core/professional_api.py'; s=read(p)
s=replace(s,"    return dict(username=user.username, professional_requested=profile.professional_requested,","    from .models import ReviewNotification\n    unread = ReviewNotification.objects.filter(user=user, read_at__isnull=True).count() if verified else 0\n    return dict(review_unread=unread, username=user.username, professional_requested=profile.professional_requested,")
files[p]=replace(s,"    return Response({'verified': verified, 'status': app.status})","    from .review_service import sync_all\n    transaction.on_commit(sync_all, robust=True)\n    return Response({'verified': verified, 'status': app.status})")
p='backend/core/admin_api.py'; s=read(p)
old="    updated = User.objects.filter(pk=pk, is_staff=False, is_superuser=False).update(is_active=s.validated_data['active'])"
new="    from django.db import transaction\n    from .review_service import sync_all\n    with transaction.atomic():\n        list(Profile.objects.select_for_update().filter(user_id=pk).values_list('pk', flat=True))\n        updated = User.objects.filter(pk=pk, is_staff=False, is_superuser=False).update(is_active=s.validated_data['active'])\n        if updated:\n            transaction.on_commit(sync_all, robust=True)"
files[p]=replace(s,old,new)
p='backend/core/admin.py'; s=read(p)
files[p]=replace(s,"    readonly_fields=('published',)","    readonly_fields=('published',)\n\n    def get_readonly_fields(self, request, obj=None):\n        if obj and obj.review_cycles.exists():\n            return ('name', 'description', 'source', 'published', 'author')\n        return super().get_readonly_fields(request, obj)")
p='backend/config/urls.py'; files[p]=read(p)+"\nfrom django.urls import include\nurlpatterns += [path('api/', include('core.review_urls'))]\n"
p='mobile/App.js'; s=read(p)
s=replace(s,"import BillingPanel from './BillingPanel';","import BillingPanel from './BillingPanel';\nimport ReviewPanel from './ReviewPanel';")
s=replace(s,"old === 'proposal' ? 'catalog' : old","['proposal','validations','myproposals','notifications'].includes(old) ? 'catalog' : old",2)
s=replace(s,"if (key === 'proposal' && !canPropose) return;","if (['proposal','validations','myproposals','notifications'].includes(key) && !canPropose) return;")
s=replace(s,"[['proposal', 'Proposer']]","[['proposal', 'Proposer'], ['validations','Validations'], ['myproposals','Mes propositions'], ['notifications', profile?.review_unread ? `Notifications (${profile.review_unread})` : 'Notifications']]")
s=replace(s,"</> : screen === 'catalog' || (screen === 'proposal' && !canPropose) ? <>","</> : canPropose && ['validations','myproposals','notifications'].includes(screen) ? <ReviewPanel key={screen} api={api} token={token} section={screen}/> : screen === 'catalog' || (!canPropose && ['proposal','validations','myproposals','notifications'].includes(screen)) ? <>")
s=replace(s,"setSuccess('Proposition enregistrée pour examen.');","setSuccess('Proposition enregistrée. Retrouvez son état dans Mes propositions.');\n            setScreen('myproposals');")
files[p]=s; add('mobile/ReviewPanel.js',(assets/'ReviewPanel.js').read_text())
p='admin-web/src/main.jsx'; s=read(p)
s=replace(s,"import BillingAdmin from './BillingAdmin';","import BillingAdmin from './BillingAdmin';\nimport ReviewAdmin from './ReviewAdmin';")
s=replace(s,"wallets:'Points et récompenses'};","wallets:'Points et récompenses',reviews:'Validations collaboratives'};")
s=replace(s,"if(!token||['subscriptions','wallets'].includes(section))return;","if(!token||['subscriptions','wallets','reviews'].includes(section))return;")
s=replace(s,"{['subscriptions','wallets'].includes(section)?<BillingAdmin","{section==='reviews'?<ReviewAdmin api={api} token={token}/>:['subscriptions','wallets'].includes(section)?<BillingAdmin")
files[p]=s;add('admin-web/src/ReviewAdmin.jsx',(assets/'ReviewAdmin.jsx').read_text())
for p,s in files.items():
    if p.endswith('.py'):ast.parse(s,filename=p)
    d=out/p;d.parent.mkdir(parents=True,exist_ok=True);d.write_text(s)
MEDICHECK_REVIEW_FILE
cat > "$TMP/review_api.py" <<'MEDICHECK_REVIEW_FILE'
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
    return paginate(request,rows,lambda n:dict(id=n.pk,message=n.message,read=bool(n.read_at),created_at=n.created_at))


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
MEDICHECK_REVIEW_FILE
cat > "$TMP/review_models.py" <<'MEDICHECK_REVIEW_FILE'
from django.conf import settings
from django.db import models
from django.db.models import Q


class ReviewCycle(models.Model):
    medicine = models.ForeignKey('core.Medicine', on_delete=models.PROTECT, related_name='review_cycles')
    number = models.PositiveIntegerField(default=1)
    name = models.CharField(max_length=200)
    description = models.TextField()
    source = models.URLField()
    status = models.CharField(max_length=16, default='waiting', choices=[(x,x) for x in ('waiting','reviewing','published','revision')])
    reason = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    closed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['medicine','number'], name='unique_medicine_review_cycle'),
                       models.UniqueConstraint(fields=['medicine'], condition=Q(status__in=['waiting','reviewing']), name='one_open_review_cycle')]


class ReviewAssignment(models.Model):
    cycle = models.ForeignKey(ReviewCycle, on_delete=models.PROTECT, related_name='assignments')
    reviewer = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name='medicine_assignments')
    state = models.CharField(max_length=12, default='pending', choices=[(x,x) for x in ('pending','voted','cancelled')])
    decision = models.CharField(max_length=10, blank=True, choices=[('approve','Approuver'),('reject','Rejeter')])
    comment = models.TextField(blank=True)
    checks = models.JSONField(default=dict)
    assigned_at = models.DateTimeField(auto_now_add=True)
    voted_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['cycle','reviewer'], name='one_vote_per_cycle_reviewer')]


class ReviewNotification(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='review_notifications')
    cycle = models.ForeignKey(ReviewCycle, on_delete=models.PROTECT)
    message = models.CharField(max_length=500)
    created_at = models.DateTimeField(auto_now_add=True)
    read_at = models.DateTimeField(null=True, blank=True)
MEDICHECK_REVIEW_FILE
cat > "$TMP/review_service.py" <<'MEDICHECK_REVIEW_FILE'
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
MEDICHECK_REVIEW_FILE
cat > "$TMP/review_urls.py" <<'MEDICHECK_REVIEW_FILE'
from django.urls import path
from . import review_api as a
urlpatterns=[
    path('reviews/inbox/',a.inbox), path('reviews/inbox/<int:pk>/vote/',a.vote),
    path('reviews/mine/',a.mine), path('reviews/mine/<int:pk>/revise/',a.revise),
    path('reviews/notifications/',a.notifications), path('reviews/notifications/<int:pk>/read/',a.mark_read),
    path('admin/reviews/',a.admin_cycles), path('admin/reviews/sync/',a.admin_sync),
]
MEDICHECK_REVIEW_FILE
cat > "$TMP/test_reviews.py" <<'MEDICHECK_REVIEW_FILE'
from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase
from .models import Profile, ProfessionalApplication, Medicine, ReviewCycle, ReviewAssignment, ReviewNotification, PointWallet, PointTransaction
from .review_service import sync_all


class ReviewTests(APITestCase):
    def pro(self,name):
        u=get_user_model().objects.create_user(username=name)
        p=Profile.objects.create(user=u,professional_requested=True,professional_verified=True)
        ProfessionalApplication.objects.create(profile=p,status='approved',proof=b'%PDF-test')
        return u

    def setUp(self):
        self.author=self.pro('author-review')
        self.reviewers=[self.pro(f'reviewer-{i}') for i in range(5)]
        self.ordinary=get_user_model().objects.create_user(username='ordinary-review')
        self.admin=get_user_model().objects.create_superuser(username='admin-review',password='test-pass-123')
        self.data=dict(name='Médicament fictif 10 mg',description='Fiche fictive exclusivement destinée aux tests.',source='https://example.org/test')
        self.vote_data=dict(decision='approve',comment='Examen fictif complet de la source et de la fiche.',source_checked=True,identity_checked=True,content_checked=True)

    def submit(self):
        self.client.force_authenticate(self.author)
        r=self.client.post('/api/proposals/',self.data,format='json'); self.assertEqual(r.status_code,201,r.data)
        return ReviewCycle.objects.get(medicine_id=r.data['id'])

    def vote(self,a,decision='approve'):
        self.client.force_authenticate(a.reviewer)
        return self.client.post(f'/api/reviews/inbox/{a.pk}/vote/',{**self.vote_data,'decision':decision},format='json')

    def test_unanimous_and_points_and_permissions(self):
        c=self.submit(); self.assertEqual(c.status,'reviewing'); self.assertEqual(c.assignments.count(),5)
        self.assertFalse(c.assignments.filter(reviewer=self.author).exists()); self.assertEqual(ReviewNotification.objects.filter(cycle=c,user__in=self.reviewers).count(),5)
        a=c.assignments.first(); self.client.force_authenticate(self.author)
        self.assertEqual(self.client.post(f'/api/reviews/inbox/{a.pk}/vote/',self.vote_data,format='json').status_code,404)
        self.client.force_authenticate(self.ordinary); self.assertEqual(self.client.get('/api/reviews/inbox/').status_code,403)
        self.assertEqual(self.client.get('/api/admin/reviews/').status_code,403)
        for i,a in enumerate(c.assignments.all()):
            self.assertEqual(self.vote(a).status_code,200)
            self.assertEqual(Medicine.objects.get(pk=c.medicine_id).published,i==4)
            self.assertEqual(self.vote(a).status_code,409)
        self.assertEqual(PointWallet.objects.get(user=self.author).balance,50)
        self.assertEqual(PointTransaction.objects.count(),6)
        self.assertTrue(all(PointWallet.objects.get(user=u).balance==10 for u in self.reviewers))
        sync_all(); self.assertEqual(PointTransaction.objects.count(),6)

    def test_reject_then_revision_no_double_reward(self):
        c=self.submit()
        for i,a in enumerate(c.assignments.all()): self.assertEqual(self.vote(a,'reject' if i==0 else 'approve').status_code,200)
        c.refresh_from_db(); self.assertEqual(c.status,'revision'); self.assertFalse(c.medicine.published)
        self.assertFalse(PointWallet.objects.filter(user=self.author).exists())
        self.client.force_authenticate(self.author)
        r=self.client.post(f'/api/reviews/mine/{c.pk}/revise/',{**self.data,'description':'Fiche fictive corrigée pour ce test.'},format='json'); self.assertEqual(r.status_code,201,r.data)
        c2=ReviewCycle.objects.get(pk=r.data['id']); self.assertEqual(c2.number,2)
        for a in c2.assignments.all(): self.assertEqual(self.vote(a).status_code,200)
        self.assertEqual(PointTransaction.objects.count(),6)
        self.assertEqual(PointWallet.objects.get(user=self.author).balance,50)

    def test_waiting_and_revocation(self):
        p=self.reviewers[-1].profile; p.professional_verified=False; p.save()
        c=self.submit(); self.assertEqual(c.status,'waiting'); self.assertEqual(c.assignments.count(),0)
        p.professional_verified=True; p.save(); sync_all(); c.refresh_from_db(); self.assertEqual(c.status,'reviewing')
        a=c.assignments.first(); p=a.reviewer.profile; p.professional_verified=False; p.save()
        extra=self.pro('replacement-reviewer'); sync_all(); a.refresh_from_db()
        self.assertEqual(a.state,'cancelled'); self.assertTrue(c.assignments.filter(reviewer=extra,state='pending').exists())
        self.assertEqual(self.vote(a).status_code,403)

    def test_import_pending_and_notification_privacy(self):
        m=Medicine.objects.create(**self.data,author=self.author,published=False); sync_all(); sync_all(); c=ReviewCycle.objects.get(medicine=m)
        n=ReviewNotification.objects.filter(cycle=c,user=self.reviewers[0]).first()
        self.client.force_authenticate(self.ordinary); self.assertEqual(self.client.get('/api/reviews/notifications/').data['count'],0)
        self.client.post(f'/api/reviews/notifications/{n.pk}/read/',{},format='json'); n.refresh_from_db(); self.assertIsNone(n.read_at)
MEDICHECK_REVIEW_FILE
python3 "$TMP/patch.py" "$ROOT" "$TMP" "$TMP/output"
backup="$ROOT/.reviews-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$backup"
while IFS= read -r -d '' f; do
  rel="${f#"$TMP/output/"}"
  if [[ -f "$ROOT/$rel" ]]; then mkdir -p "$backup/$(dirname "$rel")"; cp -p "$ROOT/$rel" "$backup/$rel"; fi
done < <(find "$TMP/output" -type f -print0)
if [[ -f backend/db.sqlite3 ]]; then
  python3 - "$backup/db.sqlite3" <<'MEDI_DB'
import sqlite3,sys
with sqlite3.connect('backend/db.sqlite3') as src, sqlite3.connect(sys.argv[1]) as dst:
    src.backup(dst)
MEDI_DB
  chmod 600 "$backup/db.sqlite3"
fi
printf 'Sauvegarde : %s\n' "$backup"
cp -R "$TMP/output/." "$ROOT/"
cd "$ROOT/backend"
uv run python manage.py check
uv run python manage.py makemigrations core
uv run python manage.py test core.test_reviews core.test_billing core.test_duplicates
uv run python manage.py migrate
uv run python manage.py shell -c "from core.review_service import sync_all; print('Propositions reprises :',sync_all())"
cd "$ROOT/admin-web"
npm run build
printf '\nInstallation terminée. Sauvegarde : %s\n' "$backup"
