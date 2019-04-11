// CroneEngine_Timber
//
// v1.0.0 Mark Eats

Engine_Timber : CroneEngine {

	var maxVoices = 5;
	var numActiveVoices = 0;
	var maxSamples = 256;
	var waveformDisplayRes = 60;

	var voiceGroup;
	var voiceList;
	var samples;
	var replyFunc;

	var players;
	var synthNames;
	var lfos;
	var mixer;

	var lfoBus;
	var mixerBus;

	var loadQueue;
	var loadingSample = -1;

	var generateWaveformsOnLoad = true;
	var scriptAddress;
	var waveformQueue;
	var waveformRoutine;
	var generatingWaveform = -1;
	var abandonCurrentWaveform = false;

	var pitchBendAllRatio = 1;
	var pressureAll = 0;

	var defaultSample;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		defaultSample = (

			streaming: 0,
			buffer: nil,
			path: nil,

			channels: 0,
			sampleRate: 0,
			numFrames: 0,

			originalFreq: 60.midicps,
			detuneCents: 0,
			pitchBendRatio: 1,
			pressure: 0,

			lfo1Fade: 0,
			lfo2Fade: 0,

			startFrame: 0,
			endFrame: 0,
			playMode: 0,
			loopStartFrame: 0,
			loopEndFrame: 0,
			crossfadeDuration: 0.01,

			freqMultiplier: 1,

			freqModLfo1: 0,
			freqModLfo2: 0,
			freqModEnv: 0,

			ampAttack: 0.003,
			ampDecay: 1,
			ampSustain: 1,
			ampRelease: 0.003,
			modAttack: 1,
			modDecay: 2,
			modSustain: 0.65,
			modRelease: 1,

			downSampleTo: 48000,
			bitDepth: 24,

			filterFreq: 20000,
			filterReso: 0,
			filterType: 0,
			filterTracking: 1,
			filterFreqModLfo1: 0,
			filterFreqModLfo2: 0,
			filterFreqModEnv: 0,

			pan: 0,
			panModLfo1: 0,
			panModLfo2: 0,
			panModEnv: 0,
			amp: 0,
			ampModLfo1: 0,
			ampModLfo2: 0,
		);

		voiceGroup = Group.new(context.xg);
		voiceList = List.new();

		lfoBus = Bus.control(context.server, 2);
		mixerBus = Bus.audio(context.server, 2);
		players = Array.newClear(4);

		loadQueue = Array.new(maxSamples);
		scriptAddress = NetAddr("localhost", 10111);
		waveformQueue = Array.new(maxSamples);

		// Receive messages from server
		replyFunc = OSCFunc({
			arg msg;
			var id = msg[2];
			scriptAddress.sendBundle(0, ['/enginePlayPosition', msg[3].asInt, msg[4].asInt, msg[5]]);
		}, path: '/replyPlayPosition', srcID: context.server.addr);

		// Sample defaults
		samples = Array.fill(maxSamples, { defaultSample.copy; });

		// Buffer players
		2.do({
			arg i;
			players[i] = {
				arg freqRatio = 1, sampleRate, gate, playMode, voiceId, sampleId, bufnum, numFrames, startFrame, endFrame, loopStartFrame, loopEndFrame, crossfadeDuration;

				var signal, crossfadeSignal, progress, phase, offsetPhase, direction, rate, phaseStart, phaseEnd,
				latchedStartFrame, firstFrame, lastFrame, shouldLoop, inLoop, inDuckLoop, loopEnabled, loopInf, loopChanged, loopChangedEnv, crossfadeControl, duckDuration, duckLoop, loopDuckControl, startEndDuckControl, loopDuration;

				latchedStartFrame = Latch.kr(startFrame, 1);
				firstFrame = startFrame.min(endFrame);
				lastFrame = startFrame.max(endFrame);

				loopDuration = loopEndFrame - loopStartFrame;

				loopEnabled = InRange.kr(playMode, 0, 1);
				loopInf = InRange.kr(playMode, 1, 1);

				direction = (endFrame - startFrame).sign;
				rate = freqRatio * BufRateScale.ir(bufnum) * direction;

				progress = (Sweep.ar(1, SampleRate.ir * rate) + latchedStartFrame).clip(firstFrame, lastFrame);

				shouldLoop = loopEnabled * gate.max(loopInf);

				inLoop = Select.ar(direction > 0, [
					progress <= loopEndFrame,
					progress >= loopStartFrame
				]);
				inLoop = PulseCount.ar(inLoop).clip * shouldLoop;

				phaseStart = Select.kr(inLoop, [
					latchedStartFrame,
					loopStartFrame
				]);
				// Let phase run over end so it is caught by FreeSelf below. 150 is chosen to work even with drastic re-pitching.
				phaseEnd = Select.kr(inLoop, [
					endFrame + (BlockSize.ir * 150 * direction),
					loopEndFrame
				]);

				phase = Phasor.ar(trig: 0, rate: rate, start: phaseStart, end: phaseEnd, resetPos: 0);

				// Free if reached end of sample
				FreeSelf.kr(Select.kr(direction > 0, [
					phase < firstFrame,
					phase > lastFrame
				]));

				SendReply.kr(trig: Impulse.kr(15), cmdName: '/replyPlayPosition', values: [sampleId, voiceId, (phase / numFrames).clip]);

				signal = BufRd.ar(numChannels: i + 1, bufnum: bufnum, phase: phase, interpolation: 4);


				// Crossfades and de-clicking

				// If loop just moved then generate an env
				loopChanged = (Changed.kr(loopStartFrame) + Changed.kr(loopEndFrame)) * loopEnabled;
				loopChangedEnv = EnvGen.ar(Env.linen(0, 0.01, 0.2), loopChanged, -1, 1);

				// Crossfade
				crossfadeDuration = crossfadeDuration * BufSampleRate.ir(bufnum); // Secs to frames, sample time
				offsetPhase = phase + (loopDuration * (direction * -1));

				crossfadeSignal = BufRd.ar(numChannels: i + 1, bufnum: bufnum, phase: offsetPhase, interpolation: 4);

				crossfadeControl = Select.ar(direction > 0, [
					phase.linlin(loopStartFrame, loopEndFrame.min(loopStartFrame + crossfadeDuration), 1, 0),
					phase.linlin(loopStartFrame.max(loopEndFrame - crossfadeDuration), loopEndFrame, 0, 1)
				]) * shouldLoop;

				// Only apply crossfade if loop is static
				signal = SelectX.ar(crossfadeControl * loopChangedEnv, [signal, crossfadeSignal]);

				// Duck across loop points and near start/end to avoid clicks (3ms, playback time)
				duckDuration = 0.003 * BufSampleRate.ir(bufnum) * (freqRatio * BufRateScale.ir(bufnum)).reciprocal;

				// Slighty different version of inLoop
				inDuckLoop = Select.ar(direction > 0, [
					progress <= (loopEndFrame - duckDuration),
					progress >= (loopStartFrame + duckDuration)
				]) * shouldLoop;

				loopDuckControl = Select.ar(inDuckLoop, [
					K2A.ar(1),
					phase.linlin(loopStartFrame, loopStartFrame + duckDuration, 0, 1) * phase.linlin(loopEndFrame - duckDuration, loopEndFrame, 1, 0)
				]);

				// Only apply loop ducks when loop position is changing or crossfade is < 5ms
				loopDuckControl = loopDuckControl.linlin(0, 1, loopChangedEnv.min(crossfadeDuration > (0.005 * BufSampleRate.ir(bufnum))), 1);
				signal = signal * loopDuckControl;

				// Start (these also mute one-shots)
				startEndDuckControl = Select.ar(firstFrame > 0, [
					phase.linlin(firstFrame, firstFrame + 1, 0, 1),
					phase.linlin(firstFrame, firstFrame + duckDuration, 0, 1)
				]);

				// End
				startEndDuckControl = startEndDuckControl * Select.ar(lastFrame < numFrames, [
					phase.linlin(lastFrame - 1, lastFrame, 1, 0),
					phase.linlin(lastFrame - duckDuration, lastFrame, 1, 0)
				]);

				signal = signal * startEndDuckControl.max(inLoop);
			};
		});

		// Streaming players
		2.do({
			arg i;
			players[i + 2] = {
				arg freqRatio = 1, sampleRate, gate, playMode, voiceId, sampleId, bufnum, numFrames, startFrame, endFrame, loopStartFrame, loopEndFrame;
				var signal, rate, progress, loopEnabled, oneShotActive, duckDuration, startEndDuckControl;

				startFrame = Latch.kr(startFrame, 1);

				loopEnabled = InRange.kr(playMode, 0, 1);

				rate = (sampleRate / SampleRate.ir) * freqRatio;

				signal = VDiskIn.ar(numChannels: i + 1, bufnum: bufnum, rate: rate, loop: loopEnabled);

				progress = Sweep.ar(1, SampleRate.ir * rate) + startFrame;
				progress = Select.ar(loopEnabled, [progress.clip(0, endFrame), progress.wrap(0, numFrames)]);

				SendReply.kr(trig: Impulse.kr(15), cmdName: '/replyPlayPosition', values: [sampleId, voiceId, progress / numFrames]);

				// Ducking
				duckDuration = 0.003 * sampleRate * rate.reciprocal;

				// Start
				startEndDuckControl = Select.ar(startFrame > 0, [
					K2A.ar(1),
					progress.linlin(startFrame, startFrame + duckDuration, 0, 1) + (progress < startFrame)
				]);

				// End
				startEndDuckControl = startEndDuckControl * Select.ar(endFrame < numFrames, [
					progress.linlin(endFrame, endFrame + 1, 1, loopEnabled),
					progress.linlin(endFrame - duckDuration, endFrame, 1, loopEnabled)
				]);

				// Duck at end of stream if loop is enabled and startFrame > 0
				startEndDuckControl = startEndDuckControl * Select.ar(loopEnabled * (startFrame > 0), [
					K2A.ar(1),
					progress.linlin(numFrames - duckDuration, numFrames, 1, 0)
				]);

				// One shot freer
				FreeSelf.kr((progress >= endFrame) * (1 - loopEnabled));

				signal = signal * startEndDuckControl;
			};
		});


		// SynthDefs

		lfos = SynthDef(\lfos, {
			arg out, lfo1Freq = 2, lfo1WaveShape = 0, lfo2Freq = 4, lfo2WaveShape = 3;
			var lfos, i_controlLag = 0.005;

			var lfoFreqs = [Lag.kr(lfo1Freq, i_controlLag), Lag.kr(lfo2Freq, i_controlLag)];
			var lfoWaveShapes = [lfo1WaveShape, lfo2WaveShape];

			lfos = Array.fill(2, {
				arg i;
				var lfo, lfoOscArray = [
					SinOsc.kr(lfoFreqs[i]),
					LFTri.kr(lfoFreqs[i]),
					LFSaw.kr(lfoFreqs[i]),
					LFPulse.kr(lfoFreqs[i], mul: 2, add: -1),
					LFNoise0.kr(lfoFreqs[i])
				];
				lfo = Select.kr(lfoWaveShapes[i], lfoOscArray);
				lfo = Lag.kr(lfo, 0.005);
			});

			Out.kr(out, lfos);

		}).play(target:context.xg, args: [\out, lfoBus], addAction: \addToHead);


		synthNames = Array.with(\monoBufferVoice, \stereoBufferVoice, \monoStreamingVoice, \stereoStreamingVoice);
		synthNames.do({

			arg name, i;

			SynthDef(name, {

				arg out, sampleRate, originalFreq, freq, detuneRatio = 1, pitchBendRatio = 1, pitchBendSampleRatio = 1, playMode = 0, gate = 0, killGate = 1, vel = 1, pressure = 0, pressureSample = 0, amp = 1,
				lfos, lfo1Fade, lfo2Fade, freqModLfo1, freqModLfo2, freqModEnv, freqMultiplier,
				ampAttack, ampDecay, ampSustain, ampRelease, modAttack, modDecay, modSustain, modRelease,
				downSampleTo, bitDepth,
				filterFreq, filterReso, filterType, filterTracking, filterFreqModLfo1, filterFreqModLfo2, filterFreqModEnv,
				pan, panModLfo1, panModLfo2, panModEnv, ampModLfo1, ampModLfo2;

				var i_nyquist = SampleRate.ir * 0.5, i_cFreq = 48.midicps, signal, freqRatio, freqModRatio, filterFreqRatio,
				killEnvelope, ampEnvelope, modEnvelope, lfo1, lfo2, i_controlLag = 0.005;

				// LFOs
				lfo1 = Line.kr(start: (lfo1Fade < 0), end: (lfo1Fade >= 0), dur: lfo1Fade.abs, mul: In.kr(lfos, 1));
				lfo2 = Line.kr(start: (lfo2Fade < 0), end: (lfo2Fade >= 0), dur: lfo2Fade.abs, mul: In.kr(lfos, 2)[1]);

				// Envelopes
				gate = gate.max(InRange.kr(playMode, 3, 3)); // Ignore gate for one shots
				killGate = killGate + Impulse.kr(0); // Make sure doneAction fires
				killEnvelope = EnvGen.ar(envelope: Env.asr(0, 1, 0.006), gate: killGate, doneAction: Done.freeSelf);
				ampEnvelope = EnvGen.ar(envelope: Env.adsr(ampAttack, ampDecay, ampSustain, ampRelease), gate: gate, doneAction: Done.freeSelf);
				modEnvelope = EnvGen.ar(envelope: Env.adsr(modAttack, modDecay, modSustain, modRelease), gate: gate);

				// Freq modulation
				freqModRatio = 2.pow((lfo1 * freqModLfo1) + (lfo2 * freqModLfo2) + (modEnvelope * freqModEnv));
				freq = freq * detuneRatio * pitchBendRatio * pitchBendSampleRatio;
				freq = (freq * freqModRatio).clip(20, i_nyquist);
				freqRatio = (freq / originalFreq) * freqMultiplier;

				// Player
				signal = SynthDef.wrap(players[i], [\kr, \kr, \kr, \kr], [freqRatio, sampleRate, gate, playMode]);

				// Downsample and bit reduction
				if(i > 1, { // Streaming
					downSampleTo = downSampleTo.min(sampleRate);
				}, {
					downSampleTo = Select.kr(downSampleTo >= sampleRate, [
						downSampleTo,
						downSampleTo = context.server.sampleRate
					]);
				});
				signal = Decimator.ar(signal, downSampleTo, bitDepth);

				// 12dB LP/HP filter
				filterFreqRatio = Select.kr((freq < i_cFreq), [
					i_cFreq + ((freq - i_cFreq) * filterTracking),
					i_cFreq - ((i_cFreq - freq) * filterTracking)
				]);
				filterFreqRatio = filterFreqRatio / i_cFreq;
				filterFreq = filterFreq * filterFreqRatio;
				filterFreq = filterFreq * ((48 * lfo1 * filterFreqModLfo1) + (48 * lfo2 * filterFreqModLfo2) + (96 * modEnvelope * filterFreqModEnv)).midiratio;
				filterFreq = filterFreq * (1 + (0.25 * (pressure + pressureSample)));
				filterFreq = filterFreq.clip(20, 20000);
				filterReso = filterReso.linlin(0, 1, 1, 0.02);
				signal = Select.ar(filterType, [
					RLPF.ar(signal, filterFreq, filterReso),
					RHPF.ar(signal, filterFreq, filterReso)
				]);

				// Panning
				pan = (pan + (lfo1 * panModLfo1) + (lfo2 * panModLfo2) + (modEnvelope * panModEnv)).clip(-1, 1);
				signal = Splay.ar(inArray: signal, spread: 1 - pan.abs, center: pan);

				// Amp
				signal = signal * lfo1.range(1 - ampModLfo1, 1) * lfo2.range(1 - ampModLfo2, 1) * ampEnvelope * killEnvelope * vel;
				signal = tanh(signal * amp.dbamp * (1 + pressure + pressureSample)).softclip;

				Out.ar(out, signal);
			}).add;
		});


		// Mixer and FX
		mixer = SynthDef(\mixer, {

			arg in, out;
			var signal;

			signal = In.ar(in, 2);

			// Compression etc
			signal = CompanderD.ar(in: signal, thresh: 0.7, slopeBelow: 1, slopeAbove: 0.33, clampTime: 0.008, relaxTime: 0.25);
			signal = tanh(signal).softclip;

			Out.ar(out, signal);

		}).play(target:context.xg, args: [\in, mixerBus, \out, context.out_b], addAction: \addToTail);


		this.addCommands;
	}



	// Functions

	queueLoadSample {
		arg sampleId, filePath;
		var item = (
			sampleId: sampleId,
			filePath: filePath
		);

		loadQueue = loadQueue.addFirst(item);
		if(loadingSample == -1, {
			this.loadSample()
		});
	}

	clearBuffer {
		arg sampleId;
		var activeVoices;

		// Kill any voices that are currently playing this sampleId
		activeVoices = voiceList.select{arg v; v.sampleId == sampleId};
		activeVoices.do({
			arg v;
			v.theSynth.set(\killGate, -1);
		});

		if(samples[sampleId].buffer.notNil, {
			samples[sampleId].buffer.close;
			samples[sampleId].buffer.free;
			samples[sampleId].buffer = nil;
		});

		samples[sampleId].numFrames = 0;
	}

	loadFailed {
		arg sampleId, message;
		if(message.notNil, {
			(sampleId.asString ++ ":" + message).postln;
		});
		scriptAddress.sendBundle(0, ['/engineSampleLoadFailed', sampleId, message]);
	}

	loadSample {
		var timeoutRoutine, item, sampleId, filePath, file, buffer, sample = ();

		if(loadQueue.notEmpty, {

			item = loadQueue.pop;
			sampleId = item.sampleId;
			filePath = item.filePath;

			loadingSample = sampleId;
			// ("Load" + sampleId + filePath).postln;

			this.clearBuffer(sampleId);

			if((sampleId < 0).or(sampleId >= samples.size), {
				("Invalid sample ID:" + sampleId + "(must be 0-" ++ (samples.size - 1) ++ ").").postln;
				this.loadSample();

			}, {

				if(filePath.compare("-") != 0, {

					file = SoundFile.openRead(filePath);
					if(file.isNil, {
						this.loadFailed(sampleId, "Could not open file");
						this.loadSample();
					}, {

						// 1 sec then timeout and move to next one
						timeoutRoutine = Routine.new({
							1.yield;
							this.loadFailed(sampleId, "Loading timed out");
							this.loadSample();
						}).play;

						sample = samples[sampleId];

						sample.channels = file.numChannels.min(2);
						sample.sampleRate = file.sampleRate;
						sample.startFrame = 0;
						sample.endFrame = file.numFrames;
						sample.loopStartFrame = 0;
						sample.loopEndFrame = file.numFrames;
						sample.crossfadeDuration = 0.01;

						// If file is over the buffer-addressable number of frames (~5.8mins at 48kHz) then prepare it for streaming instead.
						// Streaming has fairly limited options for playback (no looping etc).

						// TODO
						// if(file.numFrames < 16777216, {
						if(file.duration < 10, {

							// Load into memory
							if(file.numChannels == 1, {
								buffer = Buffer.read(server: context.server, path: filePath, action: {
									arg buf;
									sample.numFrames = file.numFrames;
									scriptAddress.sendBundle(0, ['/engineSampleLoaded', sampleId, 0, file.numFrames, file.numChannels, file.sampleRate]);
									// ("Buffer" + sampleId + "loaded:" + buf.numFrames + "frames." + buf.duration.round(0.01) + "secs." + buf.numChannels + "channel.").postln;
									this.queueWaveformGeneration(sampleId, filePath);
									timeoutRoutine.stop();
									this.loadSample();
								});
							}, {
								buffer = Buffer.readChannel(server: context.server, path: filePath, channels: [0, 1], action: {
									arg buf;
									sample.numFrames = file.numFrames;
									scriptAddress.sendBundle(0, ['/engineSampleLoaded', sampleId, 0, file.numFrames, file.numChannels, file.sampleRate]);
									// ("Buffer" + sampleId + "loaded:" + buf.numFrames + "frames." + buf.duration.round(0.01) + "secs." + buf.numChannels + "channels.").postln;
									this.queueWaveformGeneration(sampleId, filePath);
									timeoutRoutine.stop();
									this.loadSample();
								});
							});
							sample.buffer = buffer;
							sample.streaming = 0;

						}, {
							if(file.numChannels > 2, {
								this.loadFailed(sampleId, "Too many chans (" ++ file.numChannels ++ ")");
								timeoutRoutine.stop();
								this.loadSample();
							}, {
								// Prepare for streaming from disk
								sample.path = filePath;
								sample.streaming = 1;
								sample.numFrames = file.numFrames;
								scriptAddress.sendBundle(0, ['/engineSampleLoaded', sampleId, 1, file.numFrames, file.numChannels, file.sampleRate]);
								// ("Stream buffer" + sampleId + "prepared:" + file.numFrames + "frames." + file.duration.round(0.01) + "secs." + file.numChannels + "channels.").postln;
								this.queueWaveformGeneration(sampleId, filePath);
								timeoutRoutine.stop();
								this.loadSample();
							});
						});

						file.close;
						samples[sampleId] = sample;

					});
				}, {
					this.loadFailed(sampleId);
					this.loadSample();
				});
			});
		}, {
			// Done
			loadingSample = -1;
		});
	}

	clearSamples {
		arg firstId, lastId = firstId;

		this.stopWaveformGeneration(firstId, lastId);

		firstId.for(lastId, {
			arg i;
			var removeQueueIndex;

			if(samples[i].notNil, {

				// Remove from load queue
				removeQueueIndex = loadQueue.detectIndex({
					arg item;
					item.sampleId == i;
				});
				if(removeQueueIndex.notNil, {
					loadQueue.removeAt(removeQueueIndex);
				});

				this.clearBuffer(i);

				samples[i] = defaultSample.copy;
			});

		});
	}

	queueWaveformGeneration {
		arg sampleId, filePath;
		var item;

		this.stopWaveformGeneration(sampleId);

		if(generateWaveformsOnLoad, {

			item = (
				sampleId: sampleId,
				filePath: filePath
			);

			waveformQueue = waveformQueue.addFirst(item);

			if(generatingWaveform == -1, {
				this.generateWaveforms()
			});
		});
	}

	stopWaveformGeneration {
		arg firstId, lastId = firstId;

		// Clear from queue
		firstId.for(lastId, {
			arg i;
			var removeQueueIndex;

			// Remove any existing with same ID
			removeQueueIndex = waveformQueue.detectIndex({
				arg item;
				item.sampleId == i;
			});
			if(removeQueueIndex.notNil, {
				waveformQueue.removeAt(removeQueueIndex);
			});
		});

		// Stop currently in progress
		if((generatingWaveform >= firstId).and(generatingWaveform <= lastId), {
			abandonCurrentWaveform = true;
		});
	}

	generateWaveforms {

		var sendEvery = 24000;
		var sampleId, file, samplesArray, numFrames, numChannels, sampleRate, block, iterations, downsample;
		var min, max, offset, i, f;
		var waveform, routine;

		"Started generating waveforms".postln;

		waveformRoutine = Routine.new({

			while({ waveformQueue.notEmpty }, {
				var startSecs = Date.getDate.rawSeconds;
				var item = waveformQueue.pop;
				sampleId = item.sampleId;
				generatingWaveform = sampleId;

				file = SoundFile.openRead(item.filePath);
				if(file.isNil, {
					("File could not be opened for waveform generation:" + item.filePath).postln;
				}, {

					// Load samples into array
					numFrames = file.numFrames;
					numChannels = file.numChannels;
					sampleRate = file.sampleRate;
					samplesArray = FloatArray.newClear(numFrames * numChannels);
					file.readData(samplesArray);
					file.close;

					block = (numFrames / waveformDisplayRes).roundUp;
					iterations = waveformDisplayRes.min(numFrames);
					downsample = ((10 * (sampleRate / 48000)).min(block / 10).round).max(1);

					offset = 0;
					waveform = Int8Array.new((iterations * 2) + (iterations % 4));

					i = 0;
					while({ (i < iterations).and(abandonCurrentWaveform == false) }, {

						if(abandonCurrentWaveform == false, {

							min = 0;
							max = 0;

							f = i * block;
							while({ (f < (i * block + block).min(numFrames)).and(abandonCurrentWaveform == false) }, {
								var sample = 0;

								if(abandonCurrentWaveform == false, {

									for(0, numChannels.min(2) - 1, {
										arg c;
										sample = sample + samplesArray[f * numChannels + c];
									});
									sample = sample / numChannels;

									min = sample.min(min);
									max = sample.max(max);

									// Let other sclang work happen
									0.00004.yield;
								});
								f = f + downsample;
							});

							// 0-126, 63 is center (zero)
							min = min.linlin(-1, 0, 0, 63).round.asInt;
							max = max.linlin(0, 1, 63, 126).round.asInt;
							waveform = waveform.add(min);
							waveform = waveform.add(max);

							if(((i + 1 - offset) * block * numChannels >= sendEvery).and(abandonCurrentWaveform == false), {
								this.sendWaveform(sampleId, offset, waveform);
								offset = i + 1;
								waveform = Int8Array.new(((iterations - offset) * 2) + (iterations % 4));
							});
						});
						i = i + 1;
					});

					if(abandonCurrentWaveform, {
						abandonCurrentWaveform = false;
						("Waveform" + sampleId + "abandoned after" + (Date.getDate.rawSeconds - startSecs).round(0.001) + "s").postln;
					}, {
						if(waveform.size > 0, {
							this.sendWaveform(sampleId, offset, waveform);
						});
						("Waveform" + sampleId + "generated in" + (Date.getDate.rawSeconds - startSecs).round(0.001) + "s").postln;
					});
				});
			});

			"Finished generating waveforms".postln;
			generatingWaveform = -1;

		}).play;
	}

	sendWaveform {
		arg sampleId, offset, waveform;
		var padding = 0;

		// Pad to work around https://github.com/supercollider/supercollider/issues/2125
		while({ waveform.size % 4 > 0 }, {
			waveform = waveform.add(0);
			padding = padding + 1;
		});

		// ("Send waveform for" + sampleId + "offset" + offset + "size" + waveform.size).postln;
		scriptAddress.sendBundle(0, ['/engineWaveform', sampleId, offset, padding, waveform]);
	}

	addVoice {
		arg voiceId, sampleId, freq, pitchBendRatio, vel;
		var voiceToRemove, defName, sample = samples[sampleId], streamBuffer;

		if(sample.numFrames > 0, {

			// Remove a voice if ID matches or there are too many
			voiceToRemove = voiceList.detect{arg v; v.id == voiceId};
			if(voiceToRemove.isNil && (voiceList.size >= maxVoices), {
				voiceToRemove = voiceList.detect{arg v; v.gate == 0};
				if(voiceToRemove.isNil, {
					voiceToRemove = voiceList.last;
				});
			});
			if(voiceToRemove.notNil, {
				voiceToRemove.theSynth.set(\killGate, 0);
				voiceList.remove(voiceToRemove);
			});

			if(numActiveVoices < (maxVoices + 1), {
				if(sample.streaming == 0, {
					if(sample.buffer.numChannels == 1, {
						defName = \monoBufferVoice;
					}, {
						defName = \stereoBufferVoice;
					});
					this.addSynth(defName, voiceId, sampleId, sample.buffer, freq, pitchBendRatio, vel);

				}, {
					Buffer.cueSoundFile(server: context.server, path: sample.path, startFrame: sample.startFrame, numChannels: sample.channels, bufferSize: 65536, completionMessage: {
						arg streamBuffer;
						if(streamBuffer.numChannels == 1, {
							defName = \monoStreamingVoice;
						}, {
							defName = \stereoStreamingVoice;
						});
						this.addSynth(defName, voiceId, sampleId, streamBuffer, freq, pitchBendRatio, vel);
						0;
					});
				});
			});
		});
	}

	addSynth {
		arg defName, voiceId, sampleId, buffer, freq, pitchBendRatio, vel;
		var newVoice, sample = samples[sampleId];

		// TODO sometimes makeBundle causes "FAILURE IN SERVER /s_get Node 9 not found" error?!
		// context.server.makeBundle(nil, {
		newVoice = (id: voiceId, sampleId: sampleId, theSynth: Synth.new(defName: defName, args: [
			\out, mixerBus,
			\bufnum, buffer.bufnum,

			\voiceId, voiceId,
			\sampleId, sampleId,

			\sampleRate, sample.sampleRate,
			\numFrames, sample.numFrames,
			\originalFreq, sample.originalFreq,
			\freq, freq,
			\detuneRatio, (sample.detuneCents / 100).midiratio,
			\pitchBendRatio, pitchBendRatio,
			\pitchBendSampleRatio, sample.pitchBendRatio,
			\gate, 1,
			\vel, vel.linlin(0, 1, 0.2, 1),
			\pressure, pressureAll,
			\pressureSample, sample.pressure,

			\startFrame, sample.startFrame,
			\endFrame, sample.endFrame,
			\playMode, sample.playMode,
			\loopStartFrame, sample.loopStartFrame,
			\loopEndFrame, sample.loopEndFrame,
			\crossfadeDuration, sample.crossfadeDuration,

			\lfos, lfoBus,
			\lfo1Fade, sample.lfo1Fade,
			\lfo2Fade, sample.lfo2Fade,

			\freqMultiplier, sample.freqMultiplier,

			\freqModLfo1, sample.freqModLfo1,
			\freqModLfo2, sample.freqModLfo2,
			\freqModEnv, sample.freqModEnv,

			\ampAttack, sample.ampAttack,
			\ampDecay, sample.ampDecay,
			\ampSustain, sample.ampSustain,
			\ampRelease, sample.ampRelease,
			\modAttack, sample.modAttack,
			\modDecay, sample.modDecay,
			\modSustain, sample.modSustain,
			\modRelease, sample.modRelease,

			\downSampleTo, sample.downSampleTo,
			\bitDepth, sample.bitDepth,

			\filterFreq, sample.filterFreq,
			\filterReso, sample.filterReso,
			\filterType, sample.filterType,
			\filterTracking, sample.filterTracking,
			\filterFreqModLfo1, sample.filterFreqModLfo1,
			\filterFreqModLfo2, sample.filterFreqModLfo2,
			\filterFreqModEnv, sample.filterFreqModEnv,

			\pan, sample.pan,
			\panModLfo1, sample.panModLfo1,
			\panModLfo2, sample.panModLfo2,
			\panModEnv, sample.panModEnv,

			\amp, sample.amp,
			\ampModLfo1, sample.ampModLfo1,
			\ampModLfo2, sample.ampModLfo2,

		], target: voiceGroup).onFree({

			if(sample.streaming == 1, {
				if(buffer.notNil, {
					buffer.close;
					buffer.free;
				});
			});
			voiceList.remove(newVoice);
			numActiveVoices = numActiveVoices - 1;

			scriptAddress.sendBundle(0, ['/engineVoiceFreed', sampleId, voiceId]);

		}), gate: 1);
		voiceList.addFirst(newVoice);
		numActiveVoices = numActiveVoices + 1;

		scriptAddress.sendBundle(0, ['/enginePlayPosition', sampleId, voiceId, sample.startFrame / sample.numFrames]);
		// });
	}



	// Commands

	setArgOnVoice {
		arg voiceId, name, value;
		var voice = voiceList.detect{arg v; v.id == voiceId};
		if(voice.notNil, {
			voice.theSynth.set(name, value);
		});
	}

	setArgOnSample {
		arg sampleId, name, value;
		if(samples[sampleId].notNil, {
			samples[sampleId][name] = value;
			this.setArgOnVoicesPlayingSample(sampleId, name, value);
		});
	}

	setArgOnVoicesPlayingSample {
		arg sampleId, name, value;
		var voices = voiceList.select{arg v; v.sampleId == sampleId};
		voices.do({
			arg v;
			v.theSynth.set(name, value);
		});
	}

	addCommands {

		this.addCommand(\generateWaveforms, "i", {
			arg msg;
			generateWaveformsOnLoad = (msg[1] == 1);
		});

		// noteOn(voiceId, sampleId, freq, vel)
		this.addCommand(\noteOn, "iiff", {
			arg msg;
			var voiceId = msg[1], sampleId = msg[2], freq = msg[3], vel = msg[4],
			sample = samples[sampleId];

			if(sample.notNil, {
				this.addVoice(voiceId, sampleId, freq, pitchBendAllRatio, vel);
			});
		});

		// noteOff(id)
		this.addCommand(\noteOff, "i", {
			arg msg;
			var voice = voiceList.detect{arg v; v.id == msg[1]};
			if(voice.notNil, {
				voice.theSynth.set(\gate, 0);
				voice.gate = 0;
			});
		});

		// noteOffAll()
		this.addCommand(\noteOffAll, "", {
			arg msg;
			voiceGroup.set(\gate, 0);
			voiceList.do({ arg v; v.gate = 0; });
		});

		// noteKill(id)
		this.addCommand(\noteKill, "i", {
			arg msg;
			var voice = voiceList.detect{arg v; v.id == msg[1]};
			if(voice.notNil, {
				voice.theSynth.set(\killGate, 0);
				voiceList.remove(voice);
			});
		});

		// noteKillAll()
		this.addCommand(\noteKillAll, "", {
			arg msg;
			voiceGroup.set(\killGate, 0);
			voiceList.clear;
		});

		// pitchBendVoice(id, ratio)
		this.addCommand(\pitchBendVoice, "if", {
			arg msg;
			this.setArgOnVoice(msg[1], \pitchBendRatio, msg[2]);
		});

		// pitchBendSample(id, ratio)
		this.addCommand(\pitchBendSample, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \pitchBendSampleRatio, msg[2]);
		});

		// pitchBendAll(ratio)
		this.addCommand(\pitchBendAll, "f", {
			arg msg;
			pitchBendAllRatio = msg[1];
			voiceGroup.set(\pitchBendRatio, pitchBendAllRatio);
		});

		// pressureVoice(id, pressure)
		this.addCommand(\pressureVoice, "if", {
			arg msg;
			this.setArgOnVoice(msg[1], \pressure, msg[2]);
		});

		// pressureSample(id, pressure)
		this.addCommand(\pressureSample, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \pressureSample, msg[2]);
		});

		// pressureAll(pressure)
		this.addCommand(\pressureAll, "f", {
			arg msg;
			pressureAll = msg[1];
			voiceGroup.set(\pressure, pressureAll);
		});

		this.addCommand(\lfo1Freq, "f", { arg msg;
			lfos.set(\lfo1Freq, msg[1]);
		});

		this.addCommand(\lfo1WaveShape, "i", { arg msg;
			lfos.set(\lfo1WaveShape, msg[1]);
		});

		this.addCommand(\lfo2Freq, "f", { arg msg;
			lfos.set(\lfo2Freq, msg[1]);
		});

		this.addCommand(\lfo2WaveShape, "i", { arg msg;
			lfos.set(\lfo2WaveShape, msg[1]);
		});


		// Sample commands

		// loadSample(id, filePath)
		this.addCommand(\loadSample, "is", {
			arg msg;
			this.queueLoadSample(msg[1], msg[2].asString);
		});

		this.addCommand(\clearSamples, "ii", {
			arg msg;
			this.clearSamples(msg[1], msg[2]);
		});

		this.addCommand(\originalFreq, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \originalFreq, msg[2]);
		});

		this.addCommand(\detuneCents, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \detuneCents, msg[2]);
		});

		this.addCommand(\startFrame, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \startFrame, msg[2]);
		});

		this.addCommand(\endFrame, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \endFrame, msg[2]);
		});

		this.addCommand(\playMode, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \playMode, msg[2]);
		});

		this.addCommand(\loopStartFrame, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \loopStartFrame, msg[2]);
		});

		this.addCommand(\loopEndFrame, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \loopEndFrame, msg[2]);
		});

		this.addCommand(\crossfadeDuration, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \crossfadeDuration, msg[2]);
		});

		this.addCommand(\lfo1Fade, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \lfo1Fade, msg[2]);
		});

		this.addCommand(\lfo2Fade, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \lfo2Fade, msg[2]);
		});

		this.addCommand(\freqModLfo1, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \freqModLfo1, msg[2]);
		});

		this.addCommand(\freqModLfo2, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \freqModLfo2, msg[2]);
		});

		this.addCommand(\freqModEnv, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \freqModEnv, msg[2]);
		});

		this.addCommand(\freqMultiplier, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \freqMultiplier, msg[2]);
		});

		this.addCommand(\ampAttack, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \ampAttack, msg[2]);
		});

		this.addCommand(\ampDecay, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \ampDecay, msg[2]);
		});

		this.addCommand(\ampSustain, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \ampSustain, msg[2]);
		});

		this.addCommand(\ampRelease, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \ampRelease, msg[2]);
		});

		this.addCommand(\modAttack, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \modAttack, msg[2]);
		});

		this.addCommand(\modDecay, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \modDecay, msg[2]);
		});

		this.addCommand(\modSustain, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \modSustain, msg[2]);
		});

		this.addCommand(\modRelease, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \modRelease, msg[2]);
		});

		this.addCommand(\downSampleTo, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \downSampleTo, msg[2]);
		});

		this.addCommand(\bitDepth, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \bitDepth, msg[2]);
		});

		this.addCommand(\filterFreq, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterFreq, msg[2]);
		});

		this.addCommand(\filterReso, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterReso, msg[2]);
		});

		this.addCommand(\filterType, "ii", {
			arg msg;
			this.setArgOnSample(msg[1], \filterType, msg[2]);
		});

		this.addCommand(\filterTracking, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterTracking, msg[2]);
		});

		this.addCommand(\filterFreqModLfo1, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterFreqModLfo1, msg[2]);
		});

		this.addCommand(\filterFreqModLfo2, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterFreqModLfo2, msg[2]);
		});

		this.addCommand(\filterFreqModEnv, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterFreqModEnv, msg[2]);
		});

		this.addCommand(\pan, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \pan, msg[2]);
		});

		this.addCommand(\panModLfo1, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \panModLfo1, msg[2]);
		});

		this.addCommand(\panModLfo2, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \panModLfo2, msg[2]);
		});

		this.addCommand(\panModEnv, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \panModEnv, msg[2]);
		});

		this.addCommand(\amp, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \amp, msg[2]);
		});

		this.addCommand(\ampModLfo1, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \ampModLfo1, msg[2]);
		});

		this.addCommand(\ampModLfo2, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \ampModLfo2, msg[2]);
		});

	}

	free {
		if(waveformRoutine.notNil, {
			waveformRoutine.stop;
			waveformRoutine.free;
		});
		samples.do({
			arg item, i;
			if(item.notNil, {
				if(item.buffer.notNil, {
					item.buffer.free;
				});
			});
		});
		scriptAddress.free;
		replyFunc.free;
		synthNames.free;
		voiceGroup.free;
		voiceList.free;
		players.free;
		lfos.free;
		mixer.free;
	}
}
