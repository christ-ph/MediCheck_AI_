import React, {useEffect,useRef,useState} from 'react';
import {View,Text,TextInput,Pressable,StyleSheet,Linking,ActivityIndicator} from 'react-native';
import {colors as c} from './theme';
const labels={waiting:'En attente de réviseurs',reviewing:'En cours de validation',published:'Publié',revision:'Correction demandée',pending:'À examiner',voted:'Avis transmis',cancelled:'Annulé',approve:'Approuvé',reject:'Rejeté'};
const checks=[['source_checked','J’ai examiné la source officielle et sa fiabilité.'],['identity_checked','J’ai vérifié le nom, la forme et le dosage disponibles.'],['content_checked','J’ai examiné les indications, risques et informations de la fiche.']];
function Btn({title,onPress,disabled=false,danger=false}){return <Pressable accessibilityRole="button" disabled={disabled} onPress={onPress} style={[s.button,{backgroundColor:danger?c.danger:c.primary,opacity:disabled ? 0.45 : 1}]}><Text style={s.white}>{title}</Text></Pressable>}
function Source({url}){return /^https?:\/\//i.test(url||'')?<Pressable onPress={()=>Linking.openURL(url).catch(()=>{})}><Text style={s.link}>{url}</Text></Pressable>:null}
export default function ReviewPanel({api,token,section,onChanged}){
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
    <Text style={s.muted}>{section==='validations'?'Examinez chaque fiche de façon indépendante. Les autres votes ne sont pas affichés pendant le cycle.':section==='myproposals'?'Suivez vos cycles et corrigez les fiches qui nécessitent une révision.':'Abonnements, dossiers professionnels et contributions.'}</Text>
    <Btn title="Actualiser" disabled={busy||loading} onPress={()=>R(x=>x+1)}/>
    {!!error&&<Text style={s.error}>{error}</Text>}{!!message&&<Text style={s.muted}>{message}</Text>}{loading&&<ActivityIndicator color={c.primary}/>}
    {data?.results?.length===0&&<Text style={s.muted}>Aucun élément pour le moment.</Text>}
    {data?.results?.map(row=>{
      if(section==='notifications')return <View key={row.id} style={[s.card,!row.read&&s.unread]}><Text style={s.label}>{({subscription:'Abonnement',professional:'Dossier professionnel',review:'Validation médicale'})[row.category]||'Notification'} · {row.read?'Lu':'Nouveau'} · {new Date(row.created_at).toLocaleString('fr-FR')}</Text><Text style={s.body}>{row.message}</Text>{!row.read&&<Btn title="Marquer comme lu" disabled={busy} onPress={()=>act(async()=>{await api(`reviews/notifications/${row.id}/read`,'POST',{},token);onChanged?.();})}/>}</View>;
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
const s=StyleSheet.create({panel:{gap:12},unread:{borderLeftWidth:4,borderLeftColor:c.primary,backgroundColor:'#F2FAFA'},card:{gap:10,padding:15,borderWidth:1,borderColor:c.border,borderRadius:16,backgroundColor:c.surface},title:{fontSize:19,fontWeight:'800',color:c.primary},label:{fontWeight:'700',color:c.text},body:{color:c.text,lineHeight:22},muted:{color:c.muted,lineHeight:20},error:{color:c.danger},link:{color:c.primary,textDecorationLine:'underline'},button:{padding:12,borderRadius:10,alignItems:'center'},white:{color:'#fff',fontWeight:'700'},input:{borderWidth:1,borderColor:c.border,borderRadius:10,padding:12,color:c.text,backgroundColor:c.surface,textAlignVertical:'top'},check:{padding:10,borderRadius:8,backgroundColor:c.background,gap:4}});
