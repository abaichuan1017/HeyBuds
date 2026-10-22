"""Deterministically import GPL OppoPodsManager brand catalogs; references stay read-only."""
from pathlib import Path
import re,json
root=Path(__file__).resolve().parents[1]
src=root.parent/'OppoPodsManager-main'
read=lambda f:(src/f).read_text(encoding='utf-8-sig')
models=[]
def add(id,name,brand,family,aliases=(),**extra):
 d=dict(id=id,name=name,brand=brand,protocolFamily=family,children=[dict(name=n) for n in aliases],function={},**extra); models.append(d);return d
vivo=json.loads(read('Assets/Vivo/Data/DeviceModels.json'))['tws_config']
matrix={k:set(re.findall(r'\w+',v)) for k,v in re.findall(r'\["([^"]+)"\] = new HashSet<int>\s*(?:\(\))?\s*\{([^}]*)\}',read('Control/Brands/Vivo/VivoFeatureMatrix.cs').split('private static readonly IReadOnlyDictionary<string, IReadOnlySet<int>> KnownForced')[0])}
groups={}
for entry in vivo:groups.setdefault(entry['name'],[]).append(entry)
zh=json.loads(read('Assets/Localization/Strings.json'));en=json.loads(read('Assets/Localization/Strings.en.json'))
for name,entries in sorted(groups.items()):
 e=max(entries,key=lambda x:(sum(v>0 for v in x['feature'].values()),x['model']))
 features=e['feature']; n=re.sub(r'\W','',name.lower()); allowed=matrix.get(n,set()); suffix=[4,0] if 'air3pro' in n else [3] if 'tws3e' in n else [3,1]
 m=add('vivo:'+str(e['model']),name,'iQOO' if name.lower().startswith('iqoo') else 'vivo','vivo',sorted({x['project_name'] for x in entries if x.get('project_name')}),sourceEntries=entries,gaiaVersion=3 if suffix!=[3,1] else 4,noiseSuffix=suffix)
 f=m['function']; f['findDevice']='FindEarphone' in allowed;f['wearDetection']='WearDetection' in allowed;f['hearingProtection']=features.get('hearing_protection',0)>0
 f['gameMode']=features.get('low_latency_gaming',0)>0 and 'LowLatencyGaming' in allowed
 f['multiDevicesConnect']='DualConnection' in allowed and n!='vivotws3e'
 if features.get('spatial_audio',0)>0 or features.get('spatial_audio_3d',0)>0:f['spatialTypes']=[0,1,2]
 if features.get('noise_reduction',0)>0:m['noise']=[dict(mode='off',bytes=[1]),dict(mode='anc',bytes=[0]),dict(mode='transparency',bytes=[2])]
 version=features.get('audio_effect',0)
 ids={2:[0,1,2,3,4],10:[0,1,2,3,4],3:[0,1,2,3,4],11:[0,1,2,3,4],4:[0,1,2,3,5],12:[0,1,2,3,5],5:[0,1,2,3,4,5],13:[0,1,2,3,4,5],6:[0,1,2,3,4,5],14:[0,1,2,3,4,5],25:[0,1,2,3,11],27:[0,1,2,3,4,11],28:[0,1,2,3,5,11],30:[0,1,2,3,4,5,11]}.get(version,[0,1,2,3])
 if version:m['presets']=[dict(id=i,zh=zh[f'Vivo_AudioEffect_{i}'],en=en[f'Vivo_AudioEffect_{i}']) for i in ids]
h=read('Control/Brands/Huawei/HuaweiModels.cs')
for route,name,body in re.findall(r'\[HuaweiRoute\.(\w+)\] = new\("([^"]+)",\s*(.*?)\),',h,re.S):
 caps={k:v=='true' for k,v in re.findall(r'(\w+): (true|false)',body)}
 aliases=re.findall(r'Add\(HuaweiRoute\.'+route+r', "([^"]+)"\)',h)
 m=add('huawei:'+route,name,'HUAWEI','huawei',aliases,sourceCapabilities=caps,route=route)
 f=m['function'];f.update(wearDetection=caps.get('SupportsWearDetection',False),gameMode=caps.get('SupportsLowLatency',False),multiDevicesConnect=caps.get('SupportsDualConnect',False),singleBattery=not caps.get('HasChargingCase',True))
 noise=[]
 if caps.get('SupportsAnc'):
  noise=[dict(mode='off',bytes=[0,0]),dict(mode='anc',bytes=[1,255])]
  levels=[('smart',3),('light',1),('medium',0),('deep',2)]
  if route in ['FreeBudsPro2','FreeLacePro']:levels=levels[1:]
  elif route=='FreeBuds5':levels=levels[:3]
  elif route=='FreeBuds4E':levels=levels[1:3]
  elif route not in ['FreeBuds5I','FreeBuds6I','FreeBudsPro','FreeBudsPro3','FreeBudsPro5','FreeBuds7I','FreeBudsSe4','FreeBudsStudio','FreeLacePro2']:levels=[]
  if caps.get('SupportsDiscreteAncLevels'):
   noise[1]['bytes']=[1,levels[0][1] if levels else 255];noise.extend(dict(mode=k,bytes=[1,v]) for k,v in levels)
  if caps.get('SupportsTransparency'):noise.append(dict(mode='transparency',bytes=[2,2 if route=='FreeBuds6I' else 255]))
 m['noise']=noise
 if caps.get('SupportsEqualizer') and route!='FreeLacePro2':
  ids=[5,1,2,9] if route in ['FreeBudsPro3','FreeBudsPro4','FreeBudsPro5'] else [1,2,3] if route in ['FreeBudsPro2','FreeBudsStudio'] else [1,2,3,9]
  m['presets']=[dict(id=i,zh=z,en=e) for i,z,e in zip(ids,['默认','重低音','高音增强','人声'],['Default','Bass boost','Treble boost','Voice'])]
 if route in ['FreeBuds6I','FreeBudsPro3','FreeBudsPro4','FreeBudsPro5','FreeBuds7I','FreeArc','FreeLacePro2']:f.update(customEqualizer=True,customEqFrequency=[31,62,125,250,500,1000,2000,4000,8000,16000],customEqMax=3,customEqMinimum=-60,customEqMaximum=60)
for hexid,name in re.findall(r'\[0x([A-Fa-f0-9]+)\] = "([^"]+)"',read('Control/Brands/Apple/AppleModels.cs').split('ColorNames')[0]):
 m=add('apple:'+hexid.upper(),name,'Apple','apple');m['function']['singleBattery']='Max' in name or any(s in name for s in ['Beats X','Beats Flex','Beats Solo','Beats Studio','Powerbeats 3'])
# Xiaomi has a family matcher, no model catalog. Preserve that distinction.
add('xiaomi:family','Xiaomi / Redmi','Xiaomi','xiaomi',familyOnly=True)
for name in ['W820NB','W200BT','EDIFIER']:
 m=add('edifier:'+name,name,'EDIFIER','edifier',familyOnly=True);m['noise']=[dict(mode='off',bytes=[1]),dict(mode='anc',bytes=[2]),dict(mode='transparency',bytes=[3])];m['function']['singleBattery']=True
out=root/'Sources/HeyBudsProtocol/Resources/MigratedModels.json';out.write_text(json.dumps(dict(source='OppoPodsManager-main',models=models),ensure_ascii=False,indent=2)+'\n')
(root/'docs/reference').mkdir(exist_ok=True)
(root/'docs/reference/VivoDeviceModels.json').write_bytes((src/'Assets/Vivo/Data/DeviceModels.json').read_bytes())
print(dict(vivoVariants=len(vivo),vivoNames=len(groups),huawei=sum(m['protocolFamily']=='huawei' for m in models),apple=sum(m['protocolFamily']=='apple' for m in models),total=len(models)))
