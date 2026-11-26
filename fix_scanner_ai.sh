#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")"
ROOT="$PWD"
for f in mobile/App.js mobile/IntelligencePanel.js backend/core/intelligence_api.py backend/manage.py; do
  [[ -f "$f" ]] || { echo "Fichier manquant : $f (lancer depuis la racine MediCheck)" >&2; exit 1; }
done
command -v python3 >/dev/null
command -v uv >/dev/null
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/patch.py" <<'MEDICHECK_PATCH'
from pathlib import Path
import sys, ast
root=Path(sys.argv[1]); out=Path(sys.argv[2]); out.mkdir(parents=True,exist_ok=True)
def edit(rel, changes):
    p=root/rel; s=p.read_text()
    for a,b in changes:
        if s.count(a)<1 or (s.count(a)!=1 and a!='{busy&&<ActivityIndicator color={c.primary}/>} {!!error'): raise SystemExit(f'Version inattendue : {rel}: {a[:95]} ({s.count(a)})')
        s=s.replace(a,b,1)
    dest=out/rel; dest.parent.mkdir(parents=True,exist_ok=True); dest.write_text(s)
    if dest.suffix=='.py': ast.parse(s)
edit('mobile/IntelligencePanel.js', [
("import React,{useRef,useState} from 'react';", "import React,{useRef,useState,useEffect,useCallback} from 'react';"),
("ActivityIndicator,Linking,Platform} from 'react-native';", "ActivityIndicator,Linking,Platform,Modal,ScrollView} from 'react-native';"),
("export default function IntelligencePanel({api,token,section}){", "export default function IntelligencePanel({api,token,section,pendingImage,onPendingConsumed}){"),
("[camera,Cam]=useState(false)", "[camera,Cam]=useState(null),[cameraReady,Ready]=useState(false),[captured,Captured]=useState('')"),
("const lock=useRef(false), scanned=useRef(false);", "const lock=useRef(false), scanned=useRef(false), cameraRef=useRef(null), photoLock=useRef(false);\n const barcodeSettings=React.useMemo(()=>({barcodeTypes:['ean13','ean8','datamatrix','qr','upc_a','code128']}),[]);\n const onScan=useCallback(({data})=>{if(scanned.current||typeof data!=='string'||!data.trim())return;scanned.current=true;Captured(data);Code(data);},[]);"),
("async function cameraOn(){try{const p=permission?.granted?permission:await requestPermission();if(!p.granted){E('Permission caméra refusée. Saisissez le code manuellement.');return}scanned.current=false;Cam(true)}catch(e){E('Caméra indisponible : '+e.message)}}", """function closeCamera(){Cam(null);Ready(false);Captured('');scanned.current=false;}
 async function cameraOn(mode='barcode'){try{E('');const p=permission?.granted?permission:await requestPermission();if(!p.granted){E('Permission caméra refusée. Saisissez le code manuellement.');return}scanned.current=false;Captured('');Ready(false);Cam(mode)}catch(e){E('Caméra indisponible : '+e.message)}}
 async function processImage(image){if(!image||image.length>6_600_000)throw Error('Image absente ou trop volumineuse. Réessayez avec une photo plus petite.');Results(null);Ocr('');const r=await api('intelligence/ocr','POST',{image},token);Ocr(r.text||'');Results(r);if(!r.text?.trim())E('Aucun texte reconnu. Photographiez le nom et le dosage avec un bon éclairage.');}
 async function capturePhoto(){if(!cameraReady||!cameraRef.current||photoLock.current)return;photoLock.current=true;try{await run(async()=>{const pic=await cameraRef.current.takePictureAsync({base64:true,quality:0.35});closeCamera();await processImage(pic?.base64);})}finally{photoLock.current=false}}
 useEffect(()=>{if(section!=='scanner'||!pendingImage)return;onPendingConsumed?.();if(pendingImage.code){E(pendingImage.message||'La galerie a retourné une erreur.');return;}if(!pendingImage.canceled)run(()=>processImage(pendingImage.assets?.[0]?.base64));},[pendingImage,section]);"""),
("async function photo(take){await run(async()=>{if(take&&Platform.OS!=='web'){const p=await ImagePicker.requestCameraPermissionsAsync();if(!p.granted)throw Error('Permission caméra refusée.')}const options={base64:true,quality:.65,mediaTypes:ImagePicker.MediaTypeOptions.Images};const result=take?await ImagePicker.launchCameraAsync(options):await ImagePicker.launchImageLibraryAsync(options);if(result.canceled)return;const image=result.assets?.[0]?.base64;if(!image||image.length>7_000_000)throw Error('Image absente ou trop volumineuse.');Results(null);const r=await api('intelligence/ocr','POST',{image},token);Ocr(r.text);Results(r)})}", "async function photo(){await run(async()=>{const result=await ImagePicker.launchImageLibraryAsync({base64:true,quality:0.35,mediaTypes:['images']});if(!result.canceled)await processImage(result.assets?.[0]?.base64);})}"),
("<Text style={s.muted}>Mode : {r.mode}</Text>", "<Text style={s.muted}>Mode : {({rag_groq:'Groq + références',retrieval:'Recherche documentaire locale',retrieval_fallback:'Groq indisponible — réponse locale',retrieval_no_key:'Clé Groq absente — réponse locale',no_source:'Aucune source correspondante',no_reference:'Référentiel non importé'})[r.mode]||r.mode}</Text>{!!r.provider_notice&&<Text style={s.muted}>{r.provider_notice}</Text>}"),
("<Button title={camera?'Fermer la caméra':'Scanner un code-barres'} onPress={()=>camera?Cam(false):cameraOn()} disabled={busy}/>{camera&&<View style={{height:250,overflow:'hidden',borderRadius:12}}><CameraView style={{flex:1}} facing=\"back\" barcodeScannerSettings={{barcodeTypes:['ean13','ean8','datamatrix','qr','upc_a','code128']}} onBarcodeScanned={({data})=>{if(scanned.current)return;scanned.current=true;Code(data);Cam(false);run(()=>verify(data))}} onMountError={()=>{Cam(false);E('Caméra indisponible. Saisissez le code manuellement.')}}/></View>}<Button title=\"Photographier la boîte (OCR)\" secondary onPress={()=>photo(true)} disabled={busy}/><Button title=\"Importer une photo (OCR)\" secondary onPress={()=>photo(false)} disabled={busy}/>", """<Button title="Scanner un code-barres" onPress={()=>cameraOn('barcode')} disabled={busy}/><Button title="Photographier la boîte (OCR)" secondary onPress={()=>cameraOn('photo')} disabled={busy}/><Button title="Importer une photo (OCR)" secondary onPress={photo} disabled={busy}/><Modal visible={camera!==null} animationType="fade" onRequestClose={()=>{if(!busy)closeCamera()}} presentationStyle="fullScreen"><View style={s.cameraScreen}><Text style={s.cameraTitle}>{camera==='photo'?'Photographier le médicament':'Scanner un code-barres'}</Text>{camera!==null&&<View style={s.cameraFrame}><CameraView ref={cameraRef} style={StyleSheet.absoluteFill} facing="back" barcodeScannerSettings={camera==='barcode'?barcodeSettings:undefined} onBarcodeScanned={camera==='barcode'&&!captured?onScan:undefined} onCameraReady={()=>Ready(true)} onMountError={event=>{closeCamera();E('Caméra indisponible : '+(event?.message||'vérifiez les permissions.'))}}/></View>}<ScrollView style={{maxHeight:130}} contentContainerStyle={{gap:8}}>{!!captured&&<Text selectable style={s.cameraText}>Code détecté : {captured}</Text>}{!cameraReady&&<Text style={s.cameraText}>Initialisation de la caméra…</Text>}{camera==='barcode'&&!captured&&<Text style={s.cameraText}>Placez le code dans la zone de lecture.</Text>}{!!error&&<Text style={s.cameraText}>{error}</Text>}</ScrollView>{camera==='barcode'?<><Button title="Vérifier le code détecté" disabled={!captured||busy} onPress={()=>{const value=captured;closeCamera();run(()=>verify(value));}}/><Button title="Scanner à nouveau" secondary disabled={!captured||busy} onPress={()=>{scanned.current=false;Captured('')}}/></>:<Button title="Prendre la photo" disabled={!cameraReady||busy} onPress={capturePhoto}/>}<Button title="Fermer la caméra" secondary disabled={busy} onPress={closeCamera}/>{busy&&<ActivityIndicator color="#fff"/>}</View></Modal>"""),
("{busy&&<ActivityIndicator color={c.primary}/>} {!!error", "{busy&&<ActivityIndicator color={c.primary}/>}{!!error"),
("{busy&&<ActivityIndicator color={c.primary}/>} {!!error", "{busy&&<ActivityIndicator color={c.primary}/>}{!!error"),
("panel:{gap:12},card:", "cameraScreen:{flex:1,backgroundColor:'#10242B',padding:20,paddingTop:Platform.OS==='android'?48:60,paddingBottom:36,gap:12},cameraTitle:{color:'#fff',fontSize:21,fontWeight:'800'},cameraFrame:{flex:1,minHeight:160,overflow:'hidden',borderRadius:16,backgroundColor:'#000'},cameraText:{color:'#fff',fontSize:14,lineHeight:20},panel:{gap:12},card:")
])
# App recovers a pending gallery result if Android recreated the activity.
edit('mobile/App.js', [
("import * as DocumentPicker from 'expo-document-picker';", "import * as DocumentPicker from 'expo-document-picker';\nimport * as ImagePicker from 'expo-image-picker';"),
("const [searchOpen, setSearchOpen] = useState(false);", "const [searchOpen, setSearchOpen] = useState(false);\n    const [pendingImage, setPendingImage] = useState(null);\n    const recoveredImage = useRef(false);\n    useEffect(() => {\n        if (Platform.OS !== 'android' || boot !== 'ready' || recoveredImage.current) return;\n        recoveredImage.current = true;\n        if (!token) { ImagePicker.getPendingResultAsync().catch(() => {}); return; }\n        let alive = true;\n        ImagePicker.getPendingResultAsync().then(result => {\n            if (alive && result && !result.canceled) { setPendingImage(result); setScreen('scanner'); }\n        }).catch(() => {});\n        return () => { alive = false; };\n    }, [boot, token]);"),
("<IntelligencePanel key={screen} api={api} token={token} section={screen}/>", "<IntelligencePanel key={screen} api={api} token={token} section={screen} pendingImage={pendingImage} onPendingConsumed={()=>setPendingImage(null)}/>"),
("setMode('login'); setProfile(null);", "setMode('login'); setProfile(null); setPendingImage(null);")
])
edit('backend/core/intelligence_api.py', [
("    # Retrieval strictly uses imported reference metadata, never arbitrary user proposals.", "    # Retrieval strictly uses imported reference metadata, never arbitrary user proposals.\n    if not MedicineReference.objects.filter(medicine__published=True).exists():\n        return Response(dict(mode='no_reference',answer='Le référentiel officiel BDPM n’a pas encore été importé. Contactez l’administration.',sources=[],notice=NOTICE))"),
("    if d['external'] and key:", "    provider_notice=''\n    if d['external'] and not key:\n        mode='retrieval_no_key'; provider_notice='Groq non configuré sur Django (GROQ_API_KEY absente). Réponse locale.'\n    if d['external'] and key:"),
("        except (URLError,TimeoutError,ValueError,KeyError,TypeError,IndexError,OSError):mode='retrieval_fallback'", "        except (URLError,TimeoutError,ValueError,KeyError,TypeError,IndexError,OSError):\n            mode='retrieval_fallback'; provider_notice='Groq indisponible : vérifier la clé, le modèle et la connexion serveur. Réponse locale.'"),
("return Response(dict(mode=mode,answer='\\n'.join(lines),sources=", "return Response(dict(mode=mode,provider_notice=provider_notice,answer='\\n'.join(lines),sources=")
])

MEDICHECK_PATCH
python3 "$TMP/patch.py" "$ROOT" "$TMP/out"
BACKUP="$ROOT/.scanner-ai-backup-$(date +%Y%m%d-%H%M%S)-$$"
for f in mobile/App.js mobile/IntelligencePanel.js backend/core/intelligence_api.py; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp -p "$f" "$BACKUP/$f"
  cp "$TMP/out/$f" "$f"
done
printf 'Sauvegarde : %s\n' "$BACKUP"
cd backend
uv run python manage.py check
uv run python manage.py test core.test_intelligence
uv run python manage.py shell -c "import os; from core.models import Medicine, MedicineReference, MedicinePresentation; print('Medicaments publies :', Medicine.objects.filter(published=True).count()); print('References officielles publiees :', MedicineReference.objects.filter(medicine__published=True).count()); print('Presentations CIP :', MedicinePresentation.objects.count()); print('Groq configure dans ce terminal :', bool(os.environ.get('GROQ_API_KEY')))"
printf '\nCorrection installee. Aucun changement de schema. Relancer Django et Expo.\n'
