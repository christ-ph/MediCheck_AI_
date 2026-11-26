#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/Bureau/MediCheck"
cd "$ROOT"
[[ -f backend/manage.py && -f backend/config/urls.py ]] || { echo 'Backend introuvable'; exit 1; }
command -v uv >/dev/null
command -v npm >/dev/null
for f in admin-web backend/core/admin_api.py backend/core/admin_urls.py; do
  [[ ! -e "$f" ]] || { echo "Déjà présent : $f. Installation annulée pour préserver le code."; exit 1; }
done
mkdir -p admin-web/src
cp -n backend/config/urls.py backend/config/urls.py.before-admin
cat > backend/core/admin_api.py <<'PY'
from django.contrib.auth import get_user_model
from django.db.models import Q
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import BasePermission
from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response
from .models import Profile, Medicine, Report

User = get_user_model()

class PlatformAdmin(BasePermission):
    def has_permission(self, request, view):
        u = request.user
        return bool(u.is_authenticated and u.is_active and u.is_staff and u.is_superuser)

class Decision(serializers.Serializer):
    verified = serializers.BooleanField()

class AccountStatus(serializers.Serializer):
    active = serializers.BooleanField()

def page(request, rows):
    p = PageNumberPagination()
    p.page_size = 20
    return p.get_paginated_response(list(p.paginate_queryset(rows, request)))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def overview(request):
    return Response(dict(username=request.user.username,
        users=User.objects.count(), medicines=Medicine.objects.count(),
        pending=Profile.objects.filter(professional_requested=True, professional_verified=False, user__is_active=True).count(),
        verified=Profile.objects.filter(professional_verified=True, user__is_active=True).count(),
        reports=Report.objects.count()))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def professionals(request):
    q = request.query_params.get('q', '').strip()
    rows = Profile.objects.filter(professional_requested=True).filter(Q(user__username__icontains=q) | Q(user__email__icontains=q))
    status = request.query_params.get('status', '')
    if status == 'pending':
        rows = rows.filter(professional_verified=False, user__is_active=True)
    elif status == 'verified':
        rows = rows.filter(professional_verified=True, user__is_active=True)
    return page(request, rows.order_by('id').values('id', 'user__username', 'user__email', 'user__is_active', 'professional_verified'))

@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def verify_professional(request, pk):
    s = Decision(data=request.data)
    s.is_valid(raise_exception=True)
    value = s.validated_data['verified']
    rows = Profile.objects.filter(pk=pk, professional_requested=True)
    if value:
        rows = rows.filter(user__is_active=True)
    if not rows.update(professional_verified=value):
        return Response({'detail': 'Profil introuvable ou inactif.'}, status=404)
    return Response({'verified': value})

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def users(request):
    q = request.query_params.get('q', '').strip()
    rows = User.objects.filter(Q(username__icontains=q) | Q(email__icontains=q))
    return page(request, rows.order_by('id').values('id', 'username', 'email', 'is_active', 'is_staff', 'is_superuser'))

@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def account_status(request, pk):
    s = AccountStatus(data=request.data)
    s.is_valid(raise_exception=True)
    updated = User.objects.filter(pk=pk, is_staff=False, is_superuser=False).update(is_active=s.validated_data['active'])
    if not updated:
        return Response({'detail': 'Compte introuvable ou protégé.'}, status=404)
    return Response({'active': s.validated_data['active']})

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def medicines(request):
    q = request.query_params.get('q', '').strip()
    return page(request, Medicine.objects.filter(name__icontains=q).order_by('name', 'id').values('id', 'name', 'source', 'published', 'author__username'))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def reports(request):
    q = request.query_params.get('q', '').strip()
    return page(request, Report.objects.filter(medicine__icontains=q).order_by('-created', '-id').values('id', 'medicine', 'kind', 'details', 'created', 'user__username'))
PY
cat > backend/core/admin_urls.py <<'PY'
from django.urls import path
from . import admin_api as a
urlpatterns = [
    path('overview/', a.overview),
    path('professionals/', a.professionals),
    path('professionals/<int:pk>/', a.verify_professional),
    path('users/', a.users),
    path('users/<int:pk>/', a.account_status),
    path('medicines/', a.medicines),
    path('reports/', a.reports),
]
PY
cat >> backend/config/urls.py <<'PY'

# Portail React MediCheck
from django.urls import include
urlpatterns += [path('api/admin/', include('core.admin_urls'))]
PY
cat > admin-web/package.json <<'JSON'
{"name":"medicheck-admin","version":"0.1.0","private":true,"type":"module","scripts":{"dev":"vite","build":"vite build","preview":"vite preview"},"dependencies":{"react":"^18.3.1","react-dom":"^18.3.1"},"devDependencies":{"vite":"^6.4.0"}}
JSON
cat > admin-web/vite.config.js <<'JS'
import { defineConfig } from 'vite';
const proxy = { '/api': { target: 'http://127.0.0.1:8000', changeOrigin: true } };
export default defineConfig({server:{host:'127.0.0.1',port:5173,strictPort:true,proxy},preview:{host:'127.0.0.1',proxy}});
JS
cat > admin-web/index.html <<'HTML'
<!doctype html><html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>MediCheck | Administration</title></head><body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body></html>
HTML
cat > admin-web/src/main.jsx <<'JSX'
import React, { useState, useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import './style.css';

async function api(path, token='', method='GET', data=null) {
  const res = await fetch('/api/'+path, {method, headers:{Accept:'application/json', ...(token?{Authorization:`Bearer ${token}`} : {}), ...(data!==null?{'Content-Type':'application/json'}:{})}, ...(data!==null?{body:JSON.stringify(data)}:{})});
  const result = await res.json().catch(()=>null);
  if (!res.ok) { const e = new Error(result?.detail || (result?JSON.stringify(result):`HTTP ${res.status}`)); e.status=res.status; throw e; }
  return result;
}
const sections = {overview:'Tableau de bord',professionals:'Professionnels de santé',users:'Utilisateurs',medicines:'Médicaments',reports:'Signalements'};
function App(){
  const [token,T]=useState(''), [username,U]=useState(''), [password,P]=useState('');
  const [section,S]=useState('overview'), [stats,Stats]=useState(null), [data,D]=useState(null);
  const [q,Q]=useState(''), [search,Search]=useState(''), [filter,F]=useState(''), [page,Page]=useState(1), [revision,R]=useState(0);
  const [error,E]=useState(''), [message,M]=useState(''), [loading,L]=useState(false), [busy,B]=useState(false);
  function logout(){T('');P('');D(null);Stats(null);S('overview');Q('');Search('');F('');Page(1);M('');E('');}
  function fail(e){if(e.status===401||e.status===403){logout();E('Session expirée ou accès administrateur refusé.');}else E(e.message);}
  async function login(e){e.preventDefault();B(true);E('');try{const j=await api('token/','','POST',{username,password});const info=await api('admin/overview/',j.access);Stats(info);P('');T(j.access);}catch(e){E(e.message);}finally{B(false);}}
  function navigate(key){S(key);Q('');Search('');F('');Page(1);D(null);E('');M('');}
  useEffect(()=>{if(!token)return;let alive=true;L(true);E('');D(null);
    const path=section==='overview'?'admin/overview/':`admin/${section}/?${new URLSearchParams({q:search,status:filter,page:String(page)})}`;
    api(path,token).then(j=>{if(alive){if(section==='overview')Stats(j);else D(j);}}).catch(e=>{if(alive)fail(e);}).finally(()=>{if(alive)L(false);});
    return()=>{alive=false;};
  },[token,section,search,filter,page,revision]);
  async function action(path,payload,question){if(!window.confirm(question))return;B(true);E('');M('');try{await api(path,token,'PATCH',payload);M('Modification enregistrée.');Page(1);R(x=>x+1);}catch(e){fail(e);}finally{B(false);}}
  if(!token)return <main className="login"><div className="login-art"><div className="mark">M+</div><h1>MediCheck AI</h1><p>Information pharmaceutique et supervision.</p><span>PORTAIL ADMINISTRATEUR</span></div><form className="login-form" onSubmit={login}><div className="eyebrow">ESPACE SÉCURISÉ</div><h1>Connexion</h1><p>Utilisez votre compte administrateur Django.</p>{error&&<div role="alert" className="error">{error}</div>}<label>Identifiant<input required autoComplete="username" value={username} onChange={e=>U(e.target.value)}/></label><label>Mot de passe<input required type="password" autoComplete="current-password" value={password} onChange={e=>P(e.target.value)}/></label><button disabled={busy}>{busy?'Connexion…':'Se connecter'}</button></form></main>;
  const rows=data?.results||[];
  return <div className="layout"><aside><div className="brand">MediCheck <span>AI</span><small>Administration</small></div><nav>{Object.entries(sections).map(([k,v])=><button key={k} disabled={busy} className={section===k?'selected':''} onClick={()=>navigate(k)}>{v}</button>)}</nav><button className="logout" disabled={busy} onClick={logout}>Se déconnecter</button></aside><main className="workspace"><header><div><div className="eyebrow">ESPACE ADMINISTRATION</div><h1>{sections[section]}</h1></div><span className="tag">{stats?.username||username}</span></header>{error&&<div role="alert" className="error">{error} <button className="secondary" onClick={()=>R(x=>x+1)}>Réessayer</button></div>}{message&&<div role="status" className="notice">{message}</div>}
  {section==='overview'?<><div className="hero"><h2>Bienvenue dans votre espace de gestion</h2><p>Consultez les demandes et supervisez le catalogue de MediCheck AI.</p></div>{loading&&<p>Chargement…</p>}{stats&&<div className="cards">{[['Utilisateurs','users','users'],['Médicaments','medicines','medicines'],['Demandes en attente','pending','professionals'],['Professionnels validés','verified','professionals'],['Signalements','reports','reports']].map(([label,k,target])=><button className="stat" key={k} onClick={()=>{navigate(target);if(k==='pending'||k==='verified')F(k);}}><span>{label}</span><strong>{stats[k]}</strong><small>Consulter</small></button>)}</div>}</>:<section className="panel"><div className="toolbar"><form onSubmit={e=>{e.preventDefault();Page(1);Search(q.trim());}}><input aria-label="Rechercher" placeholder="Rechercher…" value={q} onChange={e=>Q(e.target.value)}/><button disabled={loading||busy}>Rechercher</button></form>{section==='professionals'&&<select aria-label="Statut" value={filter} disabled={busy} onChange={e=>{F(e.target.value);Page(1);}}><option value="">Tous les statuts</option><option value="pending">En attente</option><option value="verified">Validés</option></select>}</div>
  {section==='professionals'&&<p className="hint">Vérifiez les justificatifs du professionnel hors de la plateforme avant de valider.</p>}
  {loading?<p>Chargement…</p>:data&&<><div className="table-wrap"><table><thead><tr>{(section==='professionals'?['Identifiant','Email','Statut','Action']:section==='users'?['Identifiant','Email','Statut','Action']:section==='medicines'?['Médicament','Auteur','Publication','Source']:['Médicament','Type','Utilisateur','Description','Date']).map(h=><th key={h}>{h}</th>)}</tr></thead><tbody>{rows.map(r=><tr key={r.id}>{section==='professionals'?<><td>{r.user__username}</td><td>{r.user__email}</td><td><span className="tag">{!r.user__is_active?'Suspendu':r.professional_verified?'Validé':'En attente'}</span></td><td><button disabled={busy||(!r.user__is_active&&!r.professional_verified)} className={r.professional_verified?'danger':'primary'} onClick={()=>action(`admin/professionals/${r.id}/`,{verified:!r.professional_verified},r.professional_verified?'Retirer la validation ?':'Confirmez-vous avoir vérifié les justificatifs professionnels ?')}>{r.professional_verified?'Révoquer':'Valider'}</button></td></>:section==='users'?<><td>{r.username}</td><td>{r.email}</td><td>{r.is_staff||r.is_superuser?'Administrateur / staff':r.is_active?'Actif':'Suspendu'}</td><td>{!(r.is_staff||r.is_superuser)&&<button className={r.is_active?'danger':'primary'} disabled={busy} onClick={()=>action(`admin/users/${r.id}/`,{active:!r.is_active},'Confirmer la modification du compte ?')}>{r.is_active?'Suspendre':'Réactiver'}</button>}</td></>:section==='medicines'?<><td>{r.name}</td><td>{r.author__username}</td><td>{r.published?'Publié (démo possible)':'Non publié'}</td><td>{/^https?:\/\//i.test(r.source||'')?<a href={r.source} target="_blank" rel="noreferrer">Consulter</a>:'—'}</td></>:<><td>{r.medicine}</td><td>{{expired:'Périmé',suspect:'Suspect',adverse:'Effet indésirable'}[r.kind]||r.kind}</td><td>{r.user__username}</td><td>{r.details}</td><td>{new Date(r.created).toLocaleString('fr-FR')}</td></>}</tr>)}</tbody></table></div>{rows.length===0&&<p className="hint">Aucun résultat.</p>}<div className="pagination"><span>{data.count} résultat(s) · Page {page} / {Math.max(1,Math.ceil(data.count/20))}</span><div><button className="secondary" disabled={busy||!data.previous} onClick={()=>Page(p=>p-1)}>Précédent</button> <button disabled={busy||!data.next} onClick={()=>Page(p=>p+1)}>Suivant</button></div></div></>}
  </section>}
  <footer>MediCheck AI · Prototype de développement · Les fiches publiées ne prouvent pas une validation médicale.</footer></main></div>;
}
createRoot(document.getElementById('root')).render(<App/>);
JSX
cat > admin-web/src/style.css <<'CSS'
:root{--primary:#125872;--secondary:#20D0CE;--tertiary:#FE5955;--background:#ECFFFD;--danger:#9E2A2A;--text:#153744;--muted:#526B74;--border:#D5E5E8;--surface:#fff;--radius:14px;--shadow:0 8px 28px #1258720b;font-family:system-ui,sans-serif;color:var(--text);background:var(--background)}
*{box-sizing:border-box}body{margin:0}button,input,select{font:inherit}button{cursor:pointer;border:0;border-radius:10px;padding:11px 16px;background:var(--primary);color:white;font-weight:650}button:disabled{opacity:.45;cursor:not-allowed}button:not(:disabled):hover{filter:brightness(.94)}button:focus-visible,input:focus-visible,select:focus-visible,a:focus-visible{outline:3px solid var(--secondary);outline-offset:2px}.secondary{background:var(--secondary);color:var(--text)}.danger{background:var(--danger)}input,select{min-width:0;border:1px solid var(--border);border-radius:10px;background:white;padding:12px;color:var(--text)}a{color:var(--primary)}h1,h2,p{margin-top:0}h1{color:var(--primary);margin-bottom:12px}.eyebrow{font-size:11px;letter-spacing:2px;font-weight:750;color:var(--primary);margin-bottom:8px}.login{display:grid;grid-template-columns:1fr 1fr;max-width:940px;margin:10vh auto;background:white;border-radius:24px;overflow:hidden;box-shadow:var(--shadow)}.login-art{background:var(--primary);color:white;padding:48px;display:flex;flex-direction:column;justify-content:center}.login-art h1{color:white}.login-art span{color:var(--secondary);font-size:12px;letter-spacing:2px}.mark{font-size:60px;font-weight:850;color:var(--secondary);margin-bottom:22px}.login-form{padding:48px;display:grid;gap:16px}.login-form label{display:grid;gap:8px;font-weight:600}.login-form p,.hint{color:var(--muted)}.layout{display:grid;grid-template-columns:245px minmax(0,1fr);min-height:100vh}aside{background:var(--primary);color:white;padding:24px 16px;position:sticky;top:0;height:100vh;display:flex;flex-direction:column;gap:34px}.brand{font-size:22px;font-weight:800}.brand span{color:var(--secondary)}.brand small{display:block;font-size:12px;font-weight:400;color:#d4eff4;margin-top:6px}nav{display:grid;gap:8px}nav button{text-align:left;background:transparent;color:#e4f7fa}nav .selected{background:var(--secondary);color:var(--text)}.logout{margin-top:auto;background:transparent;border:1px solid #ffffff66}.workspace{padding:32px;min-width:0}header{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:22px}.tag{display:inline-block;border-radius:999px;background:var(--background);border:1px solid var(--border);padding:6px 10px;font-size:12px;font-weight:650}.hero{background:var(--primary);border-left:6px solid var(--tertiary);color:white;border-radius:var(--radius);padding:28px;margin-bottom:24px}.hero p{margin-bottom:0}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:16px}.stat{display:grid;gap:12px;text-align:left;color:var(--text);background:white;border:1px solid var(--border);border-radius:var(--radius);padding:22px;box-shadow:var(--shadow)}.stat strong{font-size:36px;color:var(--primary)}.stat small{color:var(--muted)}.panel{background:white;border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);padding:20px}.toolbar,.toolbar form,.pagination{display:flex;align-items:center;gap:12px;flex-wrap:wrap;justify-content:space-between}.toolbar{margin-bottom:20px}.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;text-align:left}th,td{padding:14px 12px;border-bottom:1px solid var(--border);vertical-align:top;overflow-wrap:anywhere}th{font-size:12px;text-transform:uppercase;color:var(--muted);background:#f5fafb}td{font-size:14px}tbody tr:hover{background:#f7fcfc}.pagination{margin-top:20px;color:var(--muted);font-size:13px}.error,.notice{padding:14px;border-radius:10px;margin-bottom:16px;background:#fff0f0;color:var(--danger);border:1px solid #e9b8b8}.notice{background:var(--background);color:var(--primary);border-color:var(--secondary)}footer{margin-top:30px;font-size:12px;color:var(--muted)}@media(max-width:760px){.layout{grid-template-columns:1fr}aside{position:static;height:auto;gap:12px}nav{display:flex;flex-wrap:wrap}.workspace{padding:16px}.login{grid-template-columns:1fr;margin:16px}.login-art,.login-form{padding:28px}.mark{font-size:38px}.toolbar form{width:100%}.toolbar input{flex:1}header{align-items:flex-start}}
CSS
(cd backend && uv run python manage.py check)
(cd admin-web && npm install && npm run build)
echo 'Installation terminée. Lancez Django sur 8000 et admin-web avec npm run dev.'
