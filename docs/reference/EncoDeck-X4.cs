// SPDX-License-Identifier: GPL-3.0-only
// EncoDeck contributors. Exact X4 entry excerpt from OppoCatalog.g.cs.
// Source commit: ba5db26753eceacaa4ba48ab3b87067cc0ec7da4
// See ../UPSTREAM.md for the source URL and extraction details.
    public const long SourceVersion = 117006008;
        new("06EC10", "oppo", "T1", ["OPPO Enco X4", "OPPO Enco Bohr"], "0000079A-D102-11E1-9B23-00025B00A5A5")
        {
            Noise = [new(5, 1, [new(7, 7, []), new(4, 4, []), new(8, 5, []), new(3, 6, [])]), new(10, 11, [new(11, 12, []), new(12, 13, []), new(13, 14, [])]), new(1, 0, [new(1, 3, [])]), new(2, 2, [new(2, 8, [])])],
            Equalizer = [new(42, 0, 0, 0, -1), new(43, 7, 0, 0, -1), new(28, 2, 0, 0, -1), new(46, 1, 0, 0, -1), new(29, 3, 0, 0, -1)],
            EqualizerCompat = [],
            EqualizerByVersion = [],
            Controls = [new(16, 16777732, 0, 0, 0), new(17, 8805, 0, 0, 0), new(18, 33628769, 0, 0, 0), new(5, 3584, 0, 0, 0), new(20, 0, 0, 0, 0)],
            CallControls = [new(32, 524800, 0, 524288, 0), new(33, 262656, 0, 262144, 0), new(34, 131584, 0, 0, 0)],
            GameSoundTypes = [3, 0],
            MultiConnectFunctions = ["displayPairedDevice", "connectDisconnectDevice", "unpairDevice", "setPriorityDevice"],
            PromptVolumeRange = null,
            Flags = new Dictionary<string, int> { ["equalizer"] = 4, ["customEqualizer"] = 1, ["customEqUiVersion"] = 2, ["gameMode"] = 1, ["wearDetection"] = 2, ["multiDevicesConnect"] = 2, ["sleepDetection"] = 1, ["swiftPair"] = 1, ["voiceCommand"] = 2, ["headMotion"] = 1, ["highToneQuality"] = 1, ["spatialHiResMutex"] = 1, ["bassEngineSupport"] = 1, ["promptVolume"] = 1, ["heyFindDevice"] = 1, ["fitDetection"] = 1, ["utcTimeZone"] = 1, ["sendHostCapabilities"] = 1, ["zenMode"] = 3, ["longPressType"] = 8833, ["supportPinch"] = 1, ["noiseReductionUIVersion"] = 2, ["spatialDescriptionType"] = 1, ["incomingCallControl"] = 0, ["hearingEnhancement"] = 1, ["headSetSoundRecord"] = 1, ["controlAutoVolumeSupport"] = 1, ["collectLogs"] = 1, ["spineHealth"] = 2, ["speechPerception"] = 1, ["gmnVoiceAssist"] = 1 },
            Lists = new Dictionary<string, int[]> { ["spatialTypes"] = [0, 1, 2], ["customEqFrequency"] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000], ["gameSoundMutexes"] = [1, 3] },
        },
