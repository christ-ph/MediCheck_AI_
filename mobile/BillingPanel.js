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
