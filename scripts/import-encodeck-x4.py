#!/usr/bin/env python3
"""Import only X4 from the frozen EncoDeck catalog; no network or reference checkout."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMIT = 'ba5db26753eceacaa4ba48ab3b87067cc0ec7da4'
SOURCE = 'src/EncoDeck.Protocol/Oppo/Models/OppoCatalog.g.cs'


def catalog():
    text = (ROOT / 'docs/reference/EncoDeck-X4.cs').read_text()
    entry = re.search(r'new\("06EC10", "oppo", "([^"]+)", (\[[^\n]+\]), "([^"]+)"\)\s*\{(.*?)\n        \},', text, re.S)
    if entry is None:
        raise ValueError('Frozen EncoDeck X4 entry is missing')
    form, names, uuid, body = entry.groups()
    names = json.loads(names)

    def records(field):
        value = re.search(r'^\s*' + field + r' = (\[.*\]),$', body, re.M).group(1)
        return json.loads(value.replace('new(', '[').replace(')', ']'))

    def noise(values):
        return [dict(modeType=mode, protocolIndex=index, childrenMode=noise(children)) for mode, index, children in values]

    def equalizer(field):
        labels = {42: ('丹拿原声', 'Dynaudio original sound'), 43: ('丹拿高解析', 'Dynaudio high-resolution'),
                  28: ('纯享人声', 'Pure vocals'), 46: ('清亮高音', 'Crisp highs'), 29: ('澎湃低音', 'Thundering bass')}
        return [dict(modeType=mode, protocolIndex=index, order=order,
                     **(dict(minFirmVersion=firmware) if firmware > 0 else {}),
                     colorId=color, chinese=labels[mode][0], english=labels[mode][1])
                for mode, index, order, firmware, color in records(field)]

    flags = re.search(r'Flags = .*?\{(.*?)\}', body).group(1)
    function = {key: int(value) for key, value in re.findall(r'\["([^"]+)"\] = (\d+)', flags)}
    lists = re.search(r'Lists = .*?\{(.*?)\}', body).group(1)
    function.update({key: json.loads(value) for key, value in re.findall(r'\["([^"]+)"\] = (\[[^\]]*\])', lists)})
    tree = records('Noise')
    function['noiseReductionMode'] = noise(tree)
    # Parent buttons may report a child index. Keep this mapping specific to the
    # imported profile so older catalogs retain their existing wire semantics.
    report_modes = {}
    modes = {1: 'off', 2: 'transparency', 3: 'light', 4: 'deep', 5: 'smart', 7: 'smart', 8: 'medium', 10: 'adaptive'}
    for mode, index, children in tree:
        report_modes[str(index)] = modes[mode]
        for child_mode, child_index, _ in children:
            report_modes[str(child_index)] = modes[child_mode] if mode == 5 else modes[mode]
    function['noiseReportModes'] = report_modes
    for field, key in [('Equalizer', 'equalizerMode'), ('EqualizerCompat', 'equalizerModeCompat'), ('EqualizerByVersion', 'equalizerModeByVersion')]:
        function[key] = equalizer(field)
    for field, key in [('Controls', 'control'), ('CallControls', 'callControl')]:
        function[key] = [dict(zip(['action', 'support', 'showEar', 'defaultFunction', 'minSelectCount'], values)) for values in records(field)]
    function['gameSoundList'] = [dict(type=value) for value in records('GameSoundTypes')]
    function['multiConnectFunctions'] = [dict(functionType=value) for value in records('MultiConnectFunctions')]
    function['promptVolumeRange'] = None
    return dict(source=dict(project='TIANLI0/EncoDeck', commit=COMMIT, path=SOURCE,
                            license='GPL-3.0-only', catalogVersion=int(re.search(r'SourceVersion = (\d+)', text).group(1))),
                whiteList=[dict(id='06EC10', name=names[0], brand='OPPO', type=form, uuid=uuid,
                                children=[dict(name=name) for name in names[1:]], function=function)])


if __name__ == '__main__':
    target = ROOT / 'Sources/HeyBudsProtocol/Resources/EncoDeckModels.json'
    target.write_text(json.dumps(catalog(), ensure_ascii=False, indent=2) + '\n')
    print('Imported OPPO Enco X4 (06EC10) from EncoDeck ' + COMMIT)
