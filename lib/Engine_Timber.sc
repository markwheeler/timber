// CroneEngine_Timber
//
// v1.0.0 Beta 7 Mark Eats

Engine_Timber : CroneEngine {

	var maxVoices = 7;
	var maxSamples = 256;
	var killDuration = 0.003;
	var waveformDisplayRes = 60;
	var fadeTimeGlobal = 0;

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

	var scriptAddress;
	var waveformQueue;
	var waveformRoutine;
	var generatingWaveform = -1; // -1 not running
	var abandonCurrentWaveform = false;

	var pitchBendAllRatio = 1;
	var pressureAll = 0;

	var defaultSample;

	// var debugBuffer;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		// debugBuffer = Buffer.alloc(context.server, context.server.sampleRate * 4, 5);

		defaultSample = (

			streaming: 0,
			buffer: nil,
			filePath: nil,

			channels: 0,
			sampleRate: 0,
			numFrames: 0,

			transpose: 0,
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

			freqMultiplier: 1,

			freqModLfo1: 0,
			freqModLfo2: 0,
			freqModEnv: 0,

			ampAttack: 0,
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
			filterFreqModVel: 0,
			filterFreqModPressure: 0,

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
		samples = Array.fill(maxSamples, { defaultSample.deepCopy; });

		// Buffer players
		2.do({
			arg i;
			players[i] = {
				arg fadeTime=0, freqRatio = 1, sampleRate, gate, playMode, voiceId, sampleId, bufnum, numFrames, startFrame, i_lockedStartFrame, endFrame, loopStartFrame, loopEndFrame;

				var signal, progress, phase, offsetPhase, direction, rate, phaseStart, phaseEnd,
				firstFrame, lastFrame, shouldLoop, inLoop, loopEnabled, loopInf, duckDuration, duckNumFrames, duckNumFramesShortened, duckGate, duckControl;

				firstFrame = startFrame.min(endFrame);
				lastFrame = startFrame.max(endFrame);

				loopEnabled = InRange.kr(playMode, 0, 1);
				loopInf = InRange.kr(playMode, 1, 1);

				direction = (endFrame - startFrame).sign;
				rate = freqRatio * BufRateScale.ir(bufnum) * direction;

				progress = (Sweep.ar(1, SampleRate.ir * rate) + i_lockedStartFrame).clip(firstFrame, lastFrame);

				shouldLoop = loopEnabled * gate.max(loopInf);
				shouldLoop = Latch.kr(shouldLoop,Impulse.kr(0)+TDelay.kr(Changed.kr(shouldLoop),fadeTime));

				inLoop = Select.ar(direction > 0, [
					progress < (loopEndFrame - 40), // NOTE: This tiny offset seems odd but avoids some clicks when phasor start changes
					progress > (loopStartFrame + 40)
				]);
				inLoop = PulseCount.ar(inLoop).clip * shouldLoop;

				phaseStart = Select.ar(inLoop, [
					K2A.ar(i_lockedStartFrame),
					K2A.ar(loopStartFrame)
				]);
				// Let phase run over end so it is caught by FreeSelf below. 150 is chosen to work even with drastic re-pitching.
				phaseEnd = Select.ar(inLoop, [
					K2A.ar(endFrame + (BlockSize.ir * 150 * direction)),
					K2A.ar(loopEndFrame)
				]);

				phase = Phasor.ar(trig: 0, rate: rate, start: phaseStart, end: phaseEnd, resetPos: 0);

				// Free if reached end of sample
				FreeSelf.kr(Select.kr(direction > 0, [
					phase < firstFrame,
					phase > lastFrame
				]));

				SendReply.kr(trig: Impulse.kr(15), cmdName: '/replyPlayPosition', values: [sampleId, voiceId, (phase / numFrames).clip]);

				signal = BufRd.ar(numChannels: i + 1, bufnum: bufnum, phase: phase, interpolation: 4);

				// Duck across loop points and near start/end to avoid clicks (3ms * 2, playback time)
				duckDuration = 0.003;
				duckNumFrames = duckDuration * BufSampleRate.ir(bufnum) * freqRatio * BufRateScale.ir(bufnum);

				// Start (these also mute one-shots)
				duckControl = Select.ar(firstFrame > 0, [
					phase > firstFrame,
					phase.linlin(firstFrame, firstFrame + duckNumFrames, 0, 1)
				]);

				// End
				duckControl = duckControl * Select.ar(lastFrame < numFrames, [
					phase < lastFrame,
					phase.linlin(lastFrame - duckNumFrames, lastFrame, 1, 0)
				]);

				duckControl = duckControl.max(inLoop);

				duckNumFramesShortened = duckNumFrames.min((loopEndFrame - loopStartFrame) * 0.45);
				duckDuration = (duckNumFramesShortened / duckNumFrames) * duckDuration;
				duckNumFrames = duckNumFramesShortened;

				duckGate = Select.ar(direction > 0, [
					InRange.ar(phase, loopStartFrame, loopStartFrame + duckNumFrames),
					InRange.ar(phase, loopEndFrame - duckNumFrames, loopEndFrame)
				]) * inLoop;

				duckControl = duckControl * EnvGen.ar(Env.new([1, 0, 1], [A2K.kr(duckDuration)], \linear, nil, nil), duckGate);
        
				// Debug buffer
				/*BufWr.ar([
					phase.linlin(firstFrame, lastFrame, 0, 1),
					duckControl,
					K2A.ar(gate),
					inLoop,
					duckGate,
				], debugBuffer.bufnum, Phasor.ar(1, 1, 0, debugBuffer.numFrames), 0);*/

				signal = signal * duckControl;
			};
		});

		// Streaming players
		2.do({
			arg i;
			players[i + 2] = {
				arg fadeTime=0, freqRatio = 1, sampleRate, gate, playMode, voiceId, sampleId, bufnum, numFrames, i_lockedStartFrame, endFrame, loopStartFrame, loopEndFrame;
				var signal, rate, progress, loopEnabled, oneShotActive, duckDuration, duckControl;

				loopEnabled = InRange.kr(playMode, 0, 1);

				rate = (sampleRate / SampleRate.ir) * freqRatio;

				signal = VDiskIn.ar(numChannels: i + 1, bufnum: bufnum, rate: rate, loop: loopEnabled);

				progress = Sweep.ar(1, SampleRate.ir * rate) + i_lockedStartFrame;
				progress = Select.ar(loopEnabled, [progress.clip(0, endFrame), progress.wrap(0, numFrames)]);

				SendReply.kr(trig: Impulse.kr(15), cmdName: '/replyPlayPosition', values: [sampleId, voiceId, progress / numFrames]);

				// Ducking
				// Note: There will be some inaccuracies with the length of the duck for really long samples but tested fine at 1hr
				duckDuration = 0.003 * sampleRate * rate.reciprocal;

				// Start
				duckControl = Select.ar(i_lockedStartFrame > 0, [
					K2A.ar(1),
					progress.linlin(i_lockedStartFrame, i_lockedStartFrame + duckDuration, 0, 1) + (progress < i_lockedStartFrame)
				]);

				// End
				duckControl = duckControl * Select.ar(endFrame < numFrames, [
					((progress <= endFrame) + loopEnabled).min(1),
					progress.linlin(endFrame - duckDuration, endFrame, 1, loopEnabled)
				]);

				// Duck at end of stream if loop is enabled and startFrame > 0
				duckControl = duckControl * Select.ar(loopEnabled * (i_lockedStartFrame > 0), [
					K2A.ar(1),
					progress.linlin(numFrames - duckDuration, numFrames, 1, 0)
				]);

				// One shot freer
				FreeSelf.kr((progress >= endFrame) * (1 - loopEnabled));

				signal = signal * duckControl;
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

				arg out, sampleRate, freq, transposeRatio, detuneRatio = 1, pitchBendRatio = 1, pitchBendSampleRatio = 1, playMode = 0, gate = 0, killGate = 1, vel = 1, pressure = 0, pressureSample = 0, amp = 1,fadeTime=0,
				lfos, lfo1Fade, lfo2Fade, freqModLfo1, freqModLfo2, freqModEnv, freqMultiplier,
				ampAttack, ampDecay, ampSustain, ampRelease, modAttack, modDecay, modSustain, modRelease,
				downSampleTo, bitDepth,
				filterFreq, filterReso, filterType, filterTracking, filterFreqModLfo1, filterFreqModLfo2, filterFreqModEnv, filterFreqModVel, filterFreqModPressure,
				pan, panModLfo1, panModLfo2, panModEnv, ampModLfo1, ampModLfo2;

				var i_nyquist = SampleRate.ir * 0.5, i_cFreq = 48.midicps, i_origFreq = 60.midicps, signal, freqRatio, freqModRatio, filterFreqRatio,
				killEnvelope, ampEnvelope, modEnvelope, lfo1, lfo2, i_controlLag = 0.005;

				// Lag inputs
				detuneRatio = Lag.kr(detuneRatio * pitchBendRatio * pitchBendSampleRatio, i_controlLag);
				pressure = Lag.kr(pressure + pressureSample, i_controlLag);
				amp = Lag.kr(amp, i_controlLag);
				filterFreq = Lag.kr(filterFreq, i_controlLag);
				filterReso = Lag.kr(filterReso, i_controlLag);
				pan = Lag.kr(pan, i_controlLag);

				// LFOs
				lfo1 = Line.kr(start: (lfo1Fade < 0), end: (lfo1Fade >= 0), dur: lfo1Fade.abs, mul: In.kr(lfos, 1));
				lfo2 = Line.kr(start: (lfo2Fade < 0), end: (lfo2Fade >= 0), dur: lfo2Fade.abs, mul: In.kr(lfos, 2)[1]);

				// Envelopes
				gate = gate.max(InRange.kr(playMode, 3, 3)); // Ignore gate for one shots
				killGate = killGate + Impulse.kr(0); // Make sure doneAction fires
				killEnvelope = EnvGen.ar(envelope: Env.asr(0, 1, killDuration), gate: killGate, doneAction: Done.freeSelf);
				ampEnvelope = EnvGen.ar(envelope: Env.adsr(ampAttack+fadeTime, ampDecay, ampSustain, ampRelease+fadeTime), gate: gate, doneAction: Done.freeSelf);
				modEnvelope = EnvGen.ar(envelope: Env.adsr(modAttack, modDecay, modSustain, modRelease), gate: gate);
        
				// Freq modulation
				freqModRatio = 2.pow((lfo1 * freqModLfo1) + (lfo2 * freqModLfo2) + (modEnvelope * freqModEnv));
				freq = freq * transposeRatio * detuneRatio;
				freq = (freq * freqModRatio).clip(20, i_nyquist);
				freqRatio = (freq / i_origFreq) * freqMultiplier;

				// Player
				signal = SynthDef.wrap(players[i], [\kr, \kr, \kr, \kr, \kr], [fadeTime, freqRatio, sampleRate, gate, playMode]);

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
				filterFreq = filterFreq * ((48 * lfo1 * filterFreqModLfo1) + (48 * lfo2 * filterFreqModLfo2) + (96 * modEnvelope * filterFreqModEnv) + (48 * vel * filterFreqModVel) + (48 * pressure * filterFreqModPressure)).midiratio;
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
				signal = signal * lfo1.range(1 - ampModLfo1, 1) * lfo2.range(1 - ampModLfo2, 1) * ampEnvelope * killEnvelope * vel.linlin(0, 1, 0.1, 1);
				signal = tanh(signal * amp.dbamp * (1 + pressure)).softclip;

				Out.ar(out, signal);
			}).add;
		});


		// Mixer and FX
		mixer = SynthDef(\mixer, {

			arg in, out;
			var signal;

			signal = In.ar(in, 2);

			// Compression etc
			signal = CompanderD.ar(in: signal, thresh: 0.7, slopeBelow: 1, slopeAbove: 0.4, clampTime: 0.008, relaxTime: 0.2);
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

	killVoicesPlaying {
		arg sampleId;
		var activeVoices;

		// Kill any voices that are currently playing this sampleId
		activeVoices = voiceList.select{arg v; v.sampleId == sampleId};
		activeVoices.do({
			arg v;
			if(v.startRoutine.notNil, {
				v.startRoutine.stop;
				v.startRoutine.free;
			}, {
				v.theSynth.set(\killGate, -1);
			});
			voiceList.remove(v);
		});
	}

	clearBuffer {
		arg sampleId;

		this.killVoicesPlaying(sampleId);

		if(samples[sampleId].buffer.notNil, {
			samples[sampleId].buffer.close;
			samples[sampleId].buffer.free;
			samples[sampleId].buffer = nil;
		});

		samples[sampleId].numFrames = 0;
	}

	moveSample {
		arg fromId, toId;
		var fromSample = samples[fromId];

		if(fromId != toId, {
			this.killVoicesPlaying(fromId);
			this.killVoicesPlaying(toId);
			samples[fromId] = samples[toId];
			samples[toId] = fromSample;
		});
	}

	copySample {
		arg fromId, toFirstId, toLastId;

		for(toFirstId, toLastId, {
			arg i;
			if(fromId != i, {
				this.killVoicesPlaying(fromId);
				this.killVoicesPlaying(i);
				samples[i] = samples[fromId].deepCopy;
			});
		});
	}

	copyParams {
		arg fromId, toFirstId, toLastId;

		for(toFirstId, toLastId, {
			arg i;
			var newSample;

			if((fromId != i).and(samples[i].numFrames > 0), {
				this.killVoicesPlaying(fromId);
				this.killVoicesPlaying(i);

				// Copies all except play mode and marker positions
				newSample = samples[fromId].deepCopy;

				newSample.streaming = samples[i].streaming;
				newSample.buffer = samples[i].buffer;
				newSample.filePath = samples[i].filePath;

				newSample.channels = samples[i].channels;
				newSample.sampleRate = samples[i].sampleRate;
				newSample.numFrames = samples[i].numFrames;

				newSample.startFrame = samples[i].startFrame;
				newSample.endFrame = samples[i].endFrame;
				newSample.playMode = samples[i].playMode;
				newSample.loopStartFrame = samples[i].loopStartFrame;
				newSample.loopEndFrame = samples[i].loopEndFrame;

				samples[i] = newSample;
			});
		});
	}

	loadFailed {
		arg sampleId, message;
		if(message.notNil, {
			(sampleId.asString ++ ":" + message).postln;
		});
		scriptAddress.sendBundle(0, ['/engineSampleLoadFailed', sampleId, message]);
	}

	loadSample {
		var item, sampleId, filePath, file, buffer, sample = ();

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

						sample = samples[sampleId];

						sample.filePath = filePath;
						sample.channels = file.numChannels.min(2);
						sample.sampleRate = file.sampleRate;
						sample.startFrame = 0;
						sample.endFrame = file.numFrames;
						sample.loopStartFrame = 0;
						sample.loopEndFrame = file.numFrames;

						// Max sample size of 2hr at 48kHz (aribtary number)
						if(file.numFrames > 345600000, {
							this.loadFailed(sampleId, "Too long, 2hr@48k max");
							this.loadSample();

						}, {

							// If file is over 5 secs stereo or 10 secs mono (at 48kHz) then prepare it for streaming instead.
							// This makes for max buffer memory usage of 500MB which seems to work out.
							// Streaming has fairly limited options for playback (no looping etc).

							if(file.numFrames * sample.channels < 480000, {

								// Load into memory
								if(file.numChannels == 1, {
									buffer = Buffer.read(server: context.server, path: filePath, action: {
										arg buf;
										if(buf.numFrames > 0, {
											sample.numFrames = file.numFrames;
											samples[sampleId] = sample;
											scriptAddress.sendBundle(0, ['/engineSampleLoaded', sampleId, 0, file.numFrames, file.numChannels, file.sampleRate]);
											// ("Buffer" + sampleId + "loaded:" + buf.numFrames + "frames." + buf.duration.round(0.01) + "secs." + buf.numChannels + "channel.").postln;
										}, {
											this.loadFailed(sampleId, "Failed to load");
										});
										this.loadSample();
									});
								}, {
									buffer = Buffer.readChannel(server: context.server, path: filePath, channels: [0, 1], action: {
										arg buf;
										if(buf.numFrames > 0, {
											sample.numFrames = file.numFrames;
											samples[sampleId] = sample;
											scriptAddress.sendBundle(0, ['/engineSampleLoaded', sampleId, 0, file.numFrames, file.numChannels, file.sampleRate]);
											// ("Buffer" + sampleId + "loaded:" + buf.numFrames + "frames." + buf.duration.round(0.01) + "secs." + buf.numChannels + "channels.").postln;
										}, {
											this.loadFailed(sampleId, "Failed to load");
										});
										this.loadSample();
									});
								});
								sample.buffer = buffer;
								sample.streaming = 0;

							}, {
								if(file.numChannels > 2, {
									this.loadFailed(sampleId, "Too many chans (" ++ file.numChannels ++ ")");
									this.loadSample();
								}, {
									// Prepare for streaming from disk
									sample.streaming = 1;
									sample.numFrames = file.numFrames;
									samples[sampleId] = sample;
									scriptAddress.sendBundle(0, ['/engineSampleLoaded', sampleId, 1, file.numFrames, file.numChannels, file.sampleRate]);
									// ("Stream buffer" + sampleId + "prepared:" + file.numFrames + "frames." + file.duration.round(0.01) + "secs." + file.numChannels + "channels.").postln;
									this.loadSample();
								});
							});
						});

						file.close;

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

				samples[i] = defaultSample.deepCopy;
			});

		});
	}

	queueWaveformGeneration {
		arg sampleId;
		var item;

		this.stopWaveformGeneration(sampleId);

		if(samples[sampleId].filePath.notNil, {

			item = (
				sampleId: sampleId,
				filePath: samples[sampleId].filePath
			);

			waveformQueue = waveformQueue.addFirst(item);

			if(generatingWaveform == -1, {
				this.generateWaveforms();
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

		var samplesPerSlice = 1000; // Changes the fidelity of each 'slice' of the waveform (number of samples it checks peaks of)
		var sendEvery = 3;
		var totalStartSecs = Date.getDate.rawSeconds;
		var waveformRoutine;

		generatingWaveform = waveformQueue.last.sampleId;
		"Started generating waveforms".postln;

		waveformRoutine = Routine.new({

			while({ waveformQueue.notEmpty }, {
				var startSecs = Date.getDate.rawSeconds;
				var file, rawData, waveform, numFramesRemaining, numChannels, chunkSize, numSlices, sliceSize, stride, framesInSliceRemaining;
				var frame = 0, slice = 0, offset = 0;
				var item = waveformQueue.pop;
				var sampleId = item.sampleId;

				generatingWaveform = sampleId;

				// Pause if we're loading samples
				while({ loadQueue.notEmpty }, {
					0.2.yield;
				});

				file = SoundFile.openRead(item.filePath);
				if(file.isNil, {
					("File could not be opened for waveform generation:" + item.filePath).postln;
				}, {

					// ("Waveform" + sampleId + "started").postln;

					numFramesRemaining = file.numFrames;
					numChannels = file.numChannels;
					chunkSize = (1048576 / numChannels).floor * numChannels;
					numSlices = waveformDisplayRes.min(file.numFrames);
					sliceSize = file.numFrames / waveformDisplayRes;
					framesInSliceRemaining = sliceSize;
					stride = (sliceSize / samplesPerSlice).max(1);

					waveform = Int8Array.new((numSlices * 2) + (numSlices % 4));

					// Process in chunks
					while({
						(numFramesRemaining > 0).and({
							rawData = FloatArray.newClear(min(numFramesRemaining * numChannels, chunkSize));
							file.readData(rawData);
							rawData.size > 0;
						}).and(abandonCurrentWaveform == false)
					}, {

						var min = 0, max = 0;

						while({ (frame.round * numChannels + numChannels - 1 < rawData.size).and(abandonCurrentWaveform == false) }, {
							for(0, numChannels.min(2) - 1, {
								arg c;
								var sample = rawData[frame.round.asInt * numChannels + c];
								min = sample.min(min);
								max = sample.max(max);
							});

							frame = frame + stride;
							framesInSliceRemaining = framesInSliceRemaining - stride;

							// Slice done
							if(framesInSliceRemaining < 1, {

								framesInSliceRemaining = framesInSliceRemaining + sliceSize;

								// 0-126, 63 is center (zero)
								min = min.linlin(-1, 0, 0, 63).round.asInt;
								max = max.linlin(0, 1, 63, 126).round.asInt;
								waveform = waveform.add(min);
								waveform = waveform.add(max);
								min = 0;
								max = 0;

								if(((slice + 1) % sendEvery == 0).and(abandonCurrentWaveform == false), {
									this.sendWaveform(sampleId, offset, waveform);
									offset = offset + sendEvery;
									waveform = Int8Array.new(((numSlices - offset) * 2) + (numSlices % 4));
								});
								slice = slice + 1;
							});

							// Let other sclang work happen if it's a long file
							if(file.numFrames > 1000000, {
								0.00004.yield;
							});
						});

						frame = frame - (rawData.size / numChannels);
						numFramesRemaining = numFramesRemaining - (rawData.size / numChannels);
					});

					file.close;

					if(abandonCurrentWaveform, {
						abandonCurrentWaveform = false;
						// ("Waveform" + sampleId + "abandoned after" + (Date.getDate.rawSeconds - startSecs).round(0.001) + "s").postln;
					}, {
						if(waveform.size > 0, {
							this.sendWaveform(sampleId, offset, waveform);
						});
						// ("Waveform" + sampleId + "generated in" + (Date.getDate.rawSeconds - startSecs).round(0.001) + "s").postln;
					});
				});

				// Let other sclang work happen
				0.002.yield;
			});

			("Finished generating waveforms in" + (Date.getDate.rawSeconds - totalStartSecs).round(0.001) + "s").postln;
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

	assignVoice {
		arg voiceId, sampleId, freq, pitchBendRatio, vel;
		var voiceToRemove;

		// Remove a voice if ID matches or there are too many
		voiceToRemove = voiceList.detect{arg v; v.id == voiceId};
		if(voiceToRemove.isNil && (voiceList.size >= maxVoices), {
			voiceToRemove = voiceList.detect{arg v; v.gate == 0};
			if(voiceToRemove.isNil, {
				voiceToRemove = voiceList.last;
			});
		});

		if(voiceToRemove.notNil, {
			if(voiceToRemove.startRoutine.notNil, {
				voiceToRemove.startRoutine.stop;
				voiceToRemove.startRoutine.free;
				voiceList.remove(voiceToRemove);
				this.addVoice(voiceId, sampleId, freq, pitchBendAllRatio, vel, false);
			}, {
				voiceToRemove.theSynth.set(\killGate, 0);
				voiceList.remove(voiceToRemove);
				this.addVoice(voiceId, sampleId, freq, pitchBendAllRatio, vel, true);
			});
		}, {
			this.addVoice(voiceId, sampleId, freq, pitchBendAllRatio, vel, false);
		});
	}

	addVoice {
		arg voiceId, sampleId, freq, pitchBendRatio, vel, delayStart;
		var defName, sample = samples[sampleId], streamBuffer, delay = 0, cueSecs;

		if(delayStart, { delay = killDuration; });

		if(sample.numFrames > 0, {
			if(sample.streaming == 0, {
				if(sample.buffer.numChannels == 1, {
					defName = \monoBufferVoice;
				}, {
					defName = \stereoBufferVoice;
				});
				this.addSynth(defName, voiceId, sampleId, sample.buffer, freq, pitchBendRatio, vel, delay);

			}, {
				cueSecs = Date.getDate.rawSeconds;
				Buffer.cueSoundFile(server: context.server, path: sample.filePath, startFrame: sample.startFrame, numChannels: sample.channels, bufferSize: 65536, completionMessage: {
					arg streamBuffer;
					// ("Sound file cued. Chans:" + streamBuffer.numChannels + "size" + streamBuffer.size).postln;
					if(streamBuffer.numChannels == 1, {
						defName = \monoStreamingVoice;
					}, {
						defName = \stereoStreamingVoice;
					});
					delay = (delay - (Date.getDate.rawSeconds - cueSecs)).max(0);
					this.addSynth(defName, voiceId, sampleId, streamBuffer, freq, pitchBendRatio, vel, delay);
					0;
				});
			});
		});
	}

	addSynth {
		arg defName, voiceId, sampleId, buffer, freq, pitchBendRatio, vel, delay;
		var newVoice, sample = samples[sampleId];

		newVoice = (id: voiceId, sampleId: sampleId, gate: 1);

		// Delay adding a new synth until after killDuration if need be
		newVoice.startRoutine = Routine {
			delay.wait;

			newVoice.theSynth = Synth.new(defName: defName, args: [
				\out, mixerBus,
				\bufnum, buffer.bufnum,

				\voiceId, voiceId,
				\sampleId, sampleId,

				\sampleRate, sample.sampleRate,
				\numFrames, sample.numFrames,
				\freq, freq,
				\transposeRatio, sample.transpose.midiratio,
				\detuneRatio, (sample.detuneCents / 100).midiratio,
				\pitchBendRatio, pitchBendRatio,
				\pitchBendSampleRatio, sample.pitchBendRatio,
				\gate, 1,
				\vel, vel,
				\pressure, pressureAll,
				\pressureSample, sample.pressure,

				\startFrame, sample.startFrame,
				\i_lockedStartFrame, sample.startFrame,
				\endFrame, sample.endFrame,
				\playMode, sample.playMode,
				\loopStartFrame, sample.loopStartFrame,
				\loopEndFrame, sample.loopEndFrame,

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
				\filterFreqModVel, sample.filterFreqModVel,
				\filterFreqModPressure, sample.filterFreqModPressure,

				\pan, sample.pan,
				\panModLfo1, sample.panModLfo1,
				\panModLfo2, sample.panModLfo2,
				\panModEnv, sample.panModEnv,

				\amp, sample.amp,
				\ampModLfo1, sample.ampModLfo1,
				\ampModLfo2, sample.ampModLfo2,

				\fadeTime, fadeTimeGlobal,

			], target: voiceGroup).onFree({

				if(sample.streaming == 1, {
					if(buffer.notNil, {
						buffer.close;
						buffer.free;
					});
				});
				voiceList.remove(newVoice);

				scriptAddress.sendBundle(0, ['/engineVoiceFreed', sampleId, voiceId]);

			});

			scriptAddress.sendBundle(0, ['/enginePlayPosition', sampleId, voiceId, sample.startFrame / sample.numFrames]);

			newVoice.startRoutine.free;
			newVoice.startRoutine = nil;
		}.play;

		voiceList.addFirst(newVoice);
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

		// generateWaveform(id)
		this.addCommand(\generateWaveform, "i", {
			arg msg;
			this.queueWaveformGeneration(msg[1]);
		});

		// noteOn(id, freq, vel, sampleId)
		this.addCommand(\noteOn, "iffi", {
			arg msg;
			var id = msg[1], freq = msg[2], vel = msg[3] ?? 1, sampleId = msg[4] ?? 0,
			sample = samples[sampleId];

			// debugBuffer.zero();

			if(sample.notNil, {
				this.assignVoice(id, sampleId, freq, pitchBendAllRatio, vel);
			});
		});

		// noteOff(id)
		this.addCommand(\noteOff, "i", {
			arg msg;
			var voice = voiceList.detect{arg v; v.id == msg[1]};
			if(voice.notNil, {
				if(voice.startRoutine.notNil, {
					voice.startRoutine.stop;
					voice.startRoutine.free;
					voiceList.remove(voice);
				}, {
					voice.theSynth.set(\gate, 0);
					voice.gate = 0;
					// Move voice to end so that oldest gate-off voices are found first when stealing
					voiceList.remove(voice);
					voiceList.add(voice);
				});
			});
		});

		// noteOffAll()
		this.addCommand(\noteOffAll, "", {
			arg msg;
			voiceList.do({
				arg v;
				if(v.startRoutine.notNil, {
					v.startRoutine.stop;
					v.startRoutine.free;
					voiceList.remove(v);
				});
				v.gate = 0;
			});
			voiceGroup.set(\gate, 0);
		});

		// noteKill(id)
		this.addCommand(\noteKill, "i", {
			arg msg;
			var voice = voiceList.detect{arg v; v.id == msg[1]};
			if(voice.notNil, {
				if(voice.startRoutine.notNil, {
					voice.startRoutine.stop;
					voice.startRoutine.free;
				}, {
					voice.theSynth.set(\killGate, 0);
				});
				voiceList.remove(voice);
			});
		});

		// noteKillAll()
		this.addCommand(\noteKillAll, "", {
			arg msg;
			voiceList.do({
				arg v;
				if(v.startRoutine.notNil, {
					v.startRoutine.stop;
					v.startRoutine.free;
				});
				v.gate = 0;
			});
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

		this.addCommand(\moveSample, "ii", {
			arg msg;
			this.moveSample(msg[1], msg[2]);
		});

		this.addCommand(\copySample, "iii", {
			arg msg;
			this.copySample(msg[1], msg[2], msg[3]);
		});

		this.addCommand(\copyParams, "iii", {
			arg msg;
			this.copyParams(msg[1], msg[2], msg[3]);
		});

		this.addCommand(\transpose, "if", {
			arg msg;
			var sampleId = msg[1], value = msg[2];
			if(samples[sampleId].notNil, {
				samples[sampleId][\transpose] = value;
				this.setArgOnVoicesPlayingSample(sampleId, \transposeRatio, value.midiratio);
			});

			// TODO
			// debugBuffer.write('/home/we/dust/code/timber/lib/debug.wav');
		});

		this.addCommand(\detuneCents, "if", {
			arg msg;
			var sampleId = msg[1], value = msg[2];
			if(samples[sampleId].notNil, {
				samples[sampleId][\detuneCents] = value;
				this.setArgOnVoicesPlayingSample(sampleId, \detuneRatio, (value / 100).midiratio);
			});
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

		this.addCommand(\filterFreqModVel, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterFreqModVel, msg[2]);
		});

		this.addCommand(\filterFreqModPressure, "if", {
			arg msg;
			this.setArgOnSample(msg[1], \filterFreqModPressure, msg[2]);
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

		this.addCommand("fadeTime", "f", {
			arg msg;
			fadeTimeGlobal=msg[1];
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
		// NOTE: Are these already getting freed elsewhere?
		scriptAddress.free;
		replyFunc.free;
		synthNames.free;
		voiceList.free;
		players.free;
		voiceGroup.free;
		lfos.free;
		mixer.free;
	}
}
