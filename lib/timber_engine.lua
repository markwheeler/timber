--- Timber Engine lib
-- Engine params, functions and UI views.
--
-- @module TimberEngine
-- @release v1.0.0 Beta 7
-- @author Mark Eats

local ControlSpec = require "controlspec"
local Formatters = require "formatters"
local MusicUtil = require "musicutil"
local UI = require "ui"
local Graph = require "graph"
local FilterGraph = require "filtergraph"
local EnvGraph = require "envgraph"

local Timber = {}

Timber.FileSelect = require "fileselect"

local SCREEN_FRAMERATE = 15

Timber.sample_changed_callback = function() end
Timber.meta_changed_callback = function() end
Timber.waveform_changed_callback = function() end
Timber.play_positions_changed_callback = function() end
Timber.views_changed_callback = function() end

Timber.setup_params_dirty = false
Timber.filter_dirty = false
Timber.env_dirty = false
Timber.lfo_functions_dirty = false
Timber.lfo_1_dirty = false
Timber.lfo_2_dirty = false
Timber.bpm = 120
Timber.display = "id" -- Can be "id", "note" or "none"
Timber.shift_mode = false
Timber.file_select_active = false

local samples_meta = {}
local specs = {}
local options = {}

local STREAMING_BUFFER_SIZE = 65536
local MAX_FRAMES = 2000000000

Timber.specs = specs
Timber.options = options
Timber.samples_meta = samples_meta
Timber.num_sample_params = 0

local param_ids = {
  "sample", "quality", "transpose", "detune_cents", "play_mode", "start_frame", "end_frame", "loop_start_frame", "loop_end_frame",
  "scale_by", "by_percentage", "by_length", "by_bars",
  "freq_mod_lfo_1", "freq_mod_lfo_2", "freq_mod_env",
  "filter_type", "filter_freq", "filter_resonance", "filter_freq_mod_lfo_1", "filter_freq_mod_lfo_2", "filter_freq_mod_env", "filter_freq_mod_vel", "filter_freq_mod_pressure", "filter_tracking",
  "pan", "pan_mod_lfo_1", "pan_mod_lfo_2", "pan_mod_env", "amp", "amp_mod_lfo_1", "amp_mod_lfo_2",
  "amp_env_attack", "amp_env_decay", "amp_env_sustain", "amp_env_release",
  "mod_env_attack", "mod_env_decay", "mod_env_sustain", "mod_env_release",
  "lfo_1_fade", "lfo_2_fade"
}
local extra_param_ids = {}
local beat_params = false

options.PLAY_MODE_BUFFER = {"Loop", "Inf. Loop", "Gated", "1-Shot"}
options.PLAY_MODE_BUFFER_DEFAULT = 1
options.PLAY_MODE_STREAMING = {"Loop", "Gated", "1-Shot"}
options.PLAY_MODE_STREAMING_DEFAULT = 1
options.PLAY_MODE_IDS = {{0, 1, 2, 3}, {1, 2, 3}}

options.SCALE_BY = {"Percentage", "Length", "Bars"}
options.SCALE_BY_NO_BARS = {"Percentage", "Length"}
specs.BY_PERCENTAGE = ControlSpec.new(10, 500, "lin", 0, 100, "%")

options.BY_BARS = {"1/64", "1/48", "1/32", "1/24", "1/16", "1/12", "1/8", "1/6", "1/4", "1/3", "1/2", "2/3", "3/4", "1 bar"}
options.BY_BARS_DECIMAL = {1/64, 1/48, 1/32, 1/24, 1/16, 1/12, 1/8, 1/6, 1/4, 1/3, 1/2, 2/3, 3/4, 1}
for i = 2, 32 do
  table.insert(options.BY_BARS, i .. " bars")
  table.insert(options.BY_BARS_DECIMAL, i)
end
options.BY_BARS_NA = {}
for i = 1, #options.BY_BARS do table.insert(options.BY_BARS_NA, "N/A") end

specs.LFO_1_FREQ = ControlSpec.new(0.05, 20, "exp", 0, 2, "Hz")
specs.LFO_2_FREQ = ControlSpec.new(0.05, 20, "exp", 0, 4, "Hz")
options.LFO_WAVE_SHAPE = {"Sine", "Triangle", "Saw", "Square", "Random"}
specs.LFO_FADE = ControlSpec.new(-10, 10, "lin", 0, 0, "s")
options.FILTER_TYPE = {"Low Pass", "High Pass"}
specs.FILTER_FREQ = ControlSpec.new(20, 20000, "exp", 0, 20000, "Hz")
specs.FILTER_RESONANCE = ControlSpec.new(0, 1, "lin", 0, 0, "")
specs.FILTER_TRACKING = ControlSpec.new(0, 2, "lin", 0, 1, ":1")
specs.AMP_ENV_ATTACK = ControlSpec.new(0, 5, "lin", 0, 0, "s")
specs.AMP_ENV_DECAY = ControlSpec.new(0.003, 5, "lin", 0, 1, "s")
specs.AMP_ENV_SUSTAIN = ControlSpec.new(0, 1, "lin", 0, 1, "")
specs.AMP_ENV_RELEASE = ControlSpec.new(0.003, 10, "lin", 0, 0.003, "s")
specs.MOD_ENV_ATTACK = ControlSpec.new(0.003, 5, "lin", 0, 1, "s")
specs.MOD_ENV_DECAY = ControlSpec.new(0.003, 5, "lin", 0, 2, "s")
specs.MOD_ENV_SUSTAIN = ControlSpec.new(0, 1, "lin", 0, 0.65, "")
specs.MOD_ENV_RELEASE = ControlSpec.new(0.003, 10, "lin", 0, 1, "s")
options.QUALITY = {"Nasty", "Low", "Medium", "High"}
specs.AMP = ControlSpec.new(-48, 16, 'db', 0, 0, "dB")

QUALITY_SAMPLE_RATES = {8000, 16000, 32000, 48000}
QUALITY_BIT_DEPTHS = {8, 10, 12, 24}

local function default_sample()
  local sample = {
    manual_load = false,
    streaming = 0,
    num_frames = 0,
    num_channels = 0,
    sample_rate = 0,
    freq_multiplier = 1,
    playing = false,
    positions = {},
    waveform = {},
    waveform_requested = false
  }
  return sample
end

-- Meta data
-- These are index zero to align with SC and MIDI note numbers
for i = 0, 255 do
  samples_meta[i] = default_sample()
end

local waveform_last_edited
local lfos_last_edited
local filter_last_edited


-- Functions

local function copy_table(obj)
  if type(obj) ~= "table" then return obj end
  local result = setmetatable({}, getmetatable(obj))
  for k, v in pairs(obj) do result[copy_table(k)] = copy_table(v) end
  return result
end

local function lookup_play_mode(sample_id)
  return options.PLAY_MODE_IDS[samples_meta[sample_id].streaming + 1][params:get("play_mode_" .. sample_id)]
end

local function update_by_bars_options(sample_id)
  if beat_params then
    local param = params:lookup_param("by_bars_" .. sample_id)
    if params:get("scale_by_" .. sample_id) == 3 then
      param.options = options.BY_BARS
    else
      param.options = options.BY_BARS_NA
    end
  end
end

local function update_freq_multiplier(sample_id)
  
  local scale_by = params:get("scale_by_" .. sample_id)
  local multiplier = 1
  local sample_duration = math.abs(params:get("end_frame_" .. sample_id) - params:get("start_frame_" .. sample_id)) / samples_meta[sample_id].sample_rate
  if scale_by == 1 then
    multiplier = params:get("by_percentage_" .. sample_id) / 100
  elseif scale_by == 2 then
    multiplier = sample_duration / params:get("by_length_" .. sample_id)
  elseif scale_by == 3 then
    multiplier = sample_duration / (options.BY_BARS_DECIMAL[params:get("by_bars_" .. sample_id)] * (60 / Timber.bpm * 4))
  end
  
  if multiplier ~= samples_meta[sample_id].freq_multiplier then
    engine.freqMultiplier(sample_id, multiplier)
    samples_meta[sample_id].freq_multiplier = multiplier
  end
end

local function update_by_bar_multipliers()
  for i = 0, Timber.num_sample_params - 1 do
    if params:get("scale_by_" .. i) == 3 then
      update_freq_multiplier(i)
    end
  end
end

local function set_play_mode(id, play_mode)
  engine.playMode(id, play_mode)
  if samples_meta[id].streaming == 1 then
    local start_frame = params:get("start_frame_" .. id)
    params:set("start_frame_" .. id, start_frame - 1)
    params:set("start_frame_" .. id, start_frame)
  end
end

function Timber.load_sample(id, file)
  samples_meta[id].manual_load = true
  params:set("sample_" .. id, file)
end

local function set_marker(id, param_prefix)
  
  -- Updates start frame, end frame, loop start frame, loop end frame all at once to make sure everything is valid

  local start_frame = params:get("start_frame_" .. id)
  local end_frame = params:get("end_frame_" .. id)
  
  if samples_meta[id].streaming == 0 then -- Buffer
    
    local loop_start_frame = params:get("loop_start_frame_" .. id)
    local loop_end_frame = params:get("loop_end_frame_" .. id)
    
    local first_frame = math.min(start_frame, end_frame)
    local last_frame = math.max(start_frame, end_frame)
    
    -- Set loop min and max
    params:lookup_param("loop_start_frame_" .. id).controlspec.minval = first_frame
    params:lookup_param("loop_start_frame_" .. id).controlspec.maxval = last_frame
    params:lookup_param("loop_end_frame_" .. id).controlspec.minval = first_frame
    params:lookup_param("loop_end_frame_" .. id).controlspec.maxval = last_frame
    
    local SHORTEST_LOOP = 100
    if loop_start_frame > loop_end_frame - SHORTEST_LOOP then
      if param_prefix == "loop_start_frame_" then
        loop_end_frame = loop_start_frame + SHORTEST_LOOP
      elseif param_prefix == "loop_end_frame_" then
        loop_start_frame = loop_end_frame - SHORTEST_LOOP
      end
    end
    
    if param_prefix == "loop_start_frame_" or loop_start_frame ~= params:get("loop_start_frame_" .. id) then
      engine.loopStartFrame(id, params:get("loop_start_frame_" .. id))
    end
    if param_prefix == "loop_end_frame_" or loop_end_frame ~= params:get("loop_end_frame_" .. id) then
      engine.loopEndFrame(id, params:get("loop_end_frame_" .. id))
    end
        
    -- Set loop start and end
    params:set("loop_start_frame_" .. id, loop_start_frame - 1, true) -- Hack to make sure it gets set
    params:set("loop_start_frame_" .. id, loop_start_frame, true)
    params:set("loop_end_frame_" .. id, loop_end_frame + 1, true)
    params:set("loop_end_frame_" .. id, loop_end_frame, true)
    
    
  else -- Streaming
    
    if param_prefix == "start_frame_" then
      params:lookup_param("end_frame_" .. id).controlspec.minval = params:get("start_frame_" .. id)
    end
    
    if lookup_play_mode(id) < 2 then
      params:lookup_param("start_frame_" .. id).controlspec.maxval = samples_meta[id].num_frames - STREAMING_BUFFER_SIZE
    else
      params:lookup_param("start_frame_" .. id).controlspec.maxval = params:get("end_frame_" .. id)
    end
    
  end
  
  -- Set start and end
  params:set("start_frame_" .. id, start_frame - 1, true)
  params:set("start_frame_" .. id, start_frame, true)
  params:set("end_frame_" .. id, end_frame + 1, true)
  params:set("end_frame_" .. id, end_frame, true)
  
  if param_prefix == "start_frame_" or start_frame ~= params:get("start_frame_" .. id) then
    engine.startFrame(id, params:get("start_frame_" .. id))
    update_freq_multiplier(id)
  end
  if param_prefix == "end_frame_" or end_frame ~= params:get("end_frame_" .. id) then
    engine.endFrame(id, params:get("end_frame_" .. id))
    update_freq_multiplier(id)
  end
  
  waveform_last_edited = {id = id, param = param_prefix .. id}
  Timber.views_changed_callback(id)
end

local function sample_loaded(id, streaming, num_frames, num_channels, sample_rate)
  
  samples_meta[id].streaming = streaming
  samples_meta[id].num_frames = num_frames
  samples_meta[id].num_channels = num_channels
  samples_meta[id].sample_rate = sample_rate
  samples_meta[id].freq_multiplier = 1
  samples_meta[id].playing = false
  samples_meta[id].positions = {}
  samples_meta[id].waveform = {}
  samples_meta[id].waveform_requested = false
  
  local start_frame = params:get("start_frame_" .. id)
  local end_frame = params:get("end_frame_" .. id)
  local by_length = params:get("by_length_" .. id)
  
  local start_frame_max = num_frames
  if streaming == 1 and lookup_play_mode(id) < 2 then
    start_frame_max = start_frame_max - STREAMING_BUFFER_SIZE
  end
  params:lookup_param("start_frame_" .. id).controlspec.maxval = start_frame_max
  params:lookup_param("end_frame_" .. id).controlspec.maxval = num_frames
  
  local play_mode_param = params:lookup_param("play_mode_" .. id)
  if streaming == 0 then
    play_mode_param.options = options.PLAY_MODE_BUFFER
    play_mode_param.count = #options.PLAY_MODE_BUFFER
  else
    play_mode_param.options = options.PLAY_MODE_STREAMING
    play_mode_param.count = #options.PLAY_MODE_STREAMING
  end
  
  update_by_bars_options(id)
  local duration = num_frames / sample_rate
  params:lookup_param("by_length_" .. id).controlspec.default = duration
  params:lookup_param("by_length_" .. id).controlspec.minval = duration * 0.1
  params:lookup_param("by_length_" .. id).controlspec.maxval = duration * 10
  
  -- Set defaults
  if samples_meta[id].manual_load then
    if streaming == 0 then
      params:set("play_mode_" .. id, options.PLAY_MODE_BUFFER_DEFAULT)
    else
      params:set("play_mode_" .. id, options.PLAY_MODE_STREAMING_DEFAULT)
    end
    
    params:set("start_frame_" .. id, 1) -- Odd little hack to make sure it actually gets set
    params:set("start_frame_" .. id, 0)
    params:set("end_frame_" .. id, 1)
    params:set("end_frame_" .. id, num_frames)
    params:set("loop_start_frame_" .. id, 1)
    params:set("loop_start_frame_" .. id, 0)
    params:set("loop_end_frame_" .. id, 1)
    params:set("loop_end_frame_" .. id, num_frames)
    
    params:set("transpose_" .. id, 0)
    params:set("detune_cents_" .. id, 0)
    params:set("scale_by_" .. id, 1)
    params:set("by_length_" .. id, duration)
    params:set("by_percentage_" .. id, specs.BY_PERCENTAGE.default)
    if beat_params then params:set("by_bars_" .. id, 14) end
    
  else
    -- These need resetting after having their ControlSpecs altered
    params:set("start_frame_" .. id, start_frame, true)
    params:set("end_frame_" .. id, end_frame, true)
    params:set("by_length_" .. id, by_length)
    set_marker(id, "end_frame_", params:get("end_frame_" .. id))

    -- This fixes some weirdness when loading from params menu
    params:set("loop_end_frame_" .. id, params:get("loop_end_frame_" .. id), true)
    
    -- These need pushing to engine
    engine.startFrame(id, params:get("start_frame_" .. id))
    engine.endFrame(id, params:get("end_frame_" .. id))
    engine.loopStartFrame(id, params:get("loop_start_frame_" .. id))
    engine.loopEndFrame(id, params:get("loop_end_frame_" .. id))
    
    set_play_mode(id, lookup_play_mode(id))
  end
  
  waveform_last_edited = nil
  lfos_last_edited = nil
  filter_last_edited = nil
  Timber.sample_changed_callback(id)
  Timber.meta_changed_callback(id)
  Timber.waveform_changed_callback(id)
  Timber.play_positions_changed_callback(id)
  
  samples_meta[id].manual_load = false
end

local function sample_load_failed(id, error_status)
  
  samples_meta[id] = default_sample()
  samples_meta[id].error_status = error_status
  
  waveform_last_edited = nil
  lfos_last_edited = nil
  filter_last_edited = nil
  Timber.sample_changed_callback(id)
  Timber.meta_changed_callback(id)
  Timber.waveform_changed_callback(id)
  Timber.play_positions_changed_callback(id)
  
  samples_meta[id].manual_load = false
end

function Timber.clear_samples(first, last)
  first = first or 0
  last = last or first
  if last < first then last = first end
  
  engine.clearSamples(first, last)
  
  local extended_params = {}
  for _, v in pairs(param_ids) do table.insert(extended_params, v) end
  for _, v in pairs(extra_param_ids) do table.insert(extended_params, v) end
  
  for i = first, last do
    
    samples_meta[i] = default_sample()
    
    -- Set all params to default without firing actions
    for k, v in pairs(extended_params) do
      local param = params:lookup_param(v .. "_" .. i)
      local param_action = param.action
      param.action = function(value) end
      if param.t == 3 then -- Control
        params:set(v .. "_" .. i, param.controlspec.default)
      elseif param.t == 4 then -- File
        params:set(v .. "_" .. i, "-")
      elseif param.t ~= 6 then -- Not trigger
        params:set(v .. "_" .. i, param.default)
      end
      param.action = param_action
    end
    
    Timber.meta_changed_callback(i)    
    Timber.waveform_changed_callback(i)
    Timber.play_positions_changed_callback(i)
  end
  
  Timber.views_changed_callback(nil)
  Timber.setup_params_dirty = true
end

function Timber.request_waveform(sample_id)
  samples_meta[sample_id].waveform_requested = true
  engine.generateWaveform(sample_id)
end

local function build_extended_params(exclusions)
  
  exclusions = exclusions or {}
  local extended_params = {}
  for _, v in pairs(param_ids) do
    
    local include = true
    for _, e in pairs(exclusions) do
      if v == e then
        include = false
        break
      end
    end
    
    if include then
      if v ~= "by_bars" or beat_params then
        table.insert(extended_params, v)
      end
    end
  end
  for _, v in pairs(extra_param_ids) do table.insert(extended_params, v) end
  
  return extended_params
end

local function copy_param(from_param, to_param, exclude_controlspec)
  local to_param_action = to_param.action
  to_param.action = function(value) end
  
  if to_param.t == 2 then -- Option
    to_param.options = from_param.options
    to_param:set(from_param:get())
  elseif to_param.t == 3 then -- Control
    if not exclude_controlspec then
      if string.sub(from_param.id, 1, 11) == "start_frame" or string.sub(from_param.id, 1, 9) == "end_frame" or string.sub(from_param.id, 1, 16) == "loop_start_frame" or string.sub(from_param.id, 1, 14) == "loop_end_frame" then
        to_param.controlspec = copy_table(from_param.controlspec)
      else
        to_param.controlspec = from_param.controlspec
      end
    end
    to_param:set(from_param:get())
  elseif to_param.t == 4 then -- File
    to_param:set(from_param:get())
  elseif from_param.t ~= 6 then -- Not trigger
    to_param:set(from_param:get())
  end
  
  to_param.action = to_param_action
  return to_param
end

local function move_copy_update(from_id, to_id)
  local ids = {from_id, to_id}
  for _, id in pairs(ids) do
    update_by_bars_options(id)
    update_freq_multiplier(id)
    samples_meta[id].positions = {}
    samples_meta[id].playing = false
    Timber.meta_changed_callback(id)    
    Timber.waveform_changed_callback(id)
    Timber.play_positions_changed_callback(id)
  end
  
  Timber.setup_params_dirty = true
  Timber.filter_dirty = true
  Timber.env_dirty = true
  Timber.lfo_functions_dirty = true
  Timber.views_changed_callback(nil)
end

function Timber.move_sample(from_id, to_id)
  
  if from_id == to_id then return end
  
  engine.moveSample(from_id, to_id)
  
  local from_meta = samples_meta[from_id]
  samples_meta[from_id] = samples_meta[to_id]
  samples_meta[to_id] = from_meta
  
  local extended_params = build_extended_params()
  
  for k, v in pairs(extended_params) do
    local from_param = params:lookup_param(v .. "_" .. from_id)
    local to_param = params:lookup_param(v .. "_" .. to_id)
    local to_param_orig = copy_table(to_param)
    
    to_param = copy_param(from_param, to_param)
    from_param = copy_param(to_param_orig, from_param)
  end
  
  move_copy_update(from_id, to_id)
end

function Timber.copy_sample(from_id, to_first_id, to_last_id)
  
  engine.copySample(from_id, to_first_id, to_last_id)
  
  local extended_params = build_extended_params()
  
  for i = to_first_id, to_last_id do
    if from_id ~= i then
    
      samples_meta[i] = copy_table(samples_meta[from_id])
      
      for k, v in pairs(extended_params) do
        local from_param = params:lookup_param(v .. "_" .. from_id)
        local to_param = params:lookup_param(v .. "_" .. i)
        
        to_param = copy_param(from_param, to_param)
      end
      
      move_copy_update(from_id, i)
    end
  end
end

function Timber.copy_params(from_id, to_first_id, to_last_id, param_ids)
  
  engine.copyParams(from_id, to_first_id, to_last_id)
  
  local exclusions = {"sample", "start_frame", "end_frame", "loop_start_frame", "loop_end_frame", "play_mode"}
  local extended_params = build_extended_params(exclusions)
  
  for i = to_first_id, to_last_id do
    if from_id ~= i and samples_meta[i].num_frames > 0 then
      
      for k, v in pairs(extended_params) do
        local from_param = params:lookup_param(v .. "_" .. from_id)
        local to_param = params:lookup_param(v .. "_" .. i)
        
        local exclude_controlspec = false
        if v == "by_length" then exclude_controlspec = true end
        to_param = copy_param(from_param, to_param, exclude_controlspec)
      end
      
      move_copy_update(from_id, i)
    end
  end
end

local function store_waveform(id, offset, padding, waveform_blob)
  
  for i = 1, string.len(waveform_blob) - padding do
    
    local value = string.byte(string.sub(waveform_blob, i, i + 1))
    value = util.linlin(0, 126, -1, 1, value)
    
    local frame_index = math.ceil(i / 2) + offset
    if i % 2 > 0 then
      samples_meta[id].waveform[frame_index] = {}
      samples_meta[id].waveform[frame_index][1] = value -- Min
    else
      samples_meta[id].waveform[frame_index][2] = value -- Max
    end
  end
  
  Timber.waveform_changed_callback(id)
end

local function play_position(id, voice_id, position)
  
  samples_meta[id].positions[voice_id] = position
  Timber.play_positions_changed_callback(id)
  
  if not samples_meta[id].playing then
    samples_meta[id].playing = true
    Timber.meta_changed_callback(id)
  end
end

local function voice_freed(id, voice_id)
  samples_meta[id].positions[voice_id] = nil
  samples_meta[id].playing = false
  for _, _ in pairs(samples_meta[id].positions) do
    samples_meta[id].playing = true
    break
  end
  Timber.meta_changed_callback(id)
  Timber.play_positions_changed_callback(id)
end

function Timber.osc_event(path, args, from)
  
  if path == "/engineSampleLoaded" then
    sample_loaded(args[1], args[2], args[3], args[4], args[5])
    
  elseif path == "/engineSampleLoadFailed" then
    sample_load_failed(args[1], args[2])
    
  elseif path == "/engineWaveform" then
    store_waveform(args[1], args[2], args[3], args[4])
  
  elseif path == "/enginePlayPosition" then
    play_position(args[1], args[2], args[3])
    
  elseif path == "/engineVoiceFreed" then
    voice_freed(args[1], args[2])
    
  end
end

osc.event = Timber.osc_event
-- NOTE: If you need the OSC callback in your script then Timber.osc_event(path, args, from)
-- must be called from the end of that function to pass the data down to this lib

function Timber.set_bpm(bpm)
  Timber.bpm = bpm
  update_by_bar_multipliers()
end


-- Formatters

local function format_st(param)
  local formatted = param:get() .. " ST"
  if param:get() > 0 then formatted = "+" .. formatted end
  return formatted
end

local function format_cents(param)
  local formatted = param:get() .. " cents"
  if param:get() > 0 then formatted = "+" .. formatted end
  return formatted
end

local function format_frame_number(sample_id)
  return function(param)
    local sample_rate = samples_meta[sample_id].sample_rate
    if sample_rate <= 0 then
      return "-"
    else
      return Formatters.format_secs_raw(param:get() / sample_rate)
    end
  end
end

local function format_by_percentage(sample_id)
  return function(param)
    local return_string
    if params:get("scale_by_" .. sample_id) == 1 then
      return_string = util.round(param:get(), 0.1) .. "%"
    else
      return_string = "N/A"
    end
    return return_string
  end
end

local function format_by_length(sample_id)
  return function(param)
    local return_string
    if params:get("scale_by_" .. sample_id) == 2 then
      return_string = Formatters.format_secs(param)
    else
      return_string = "N/A"
    end
    return return_string
  end
end

local function format_fade(param)
  local secs = param:get()
  local suffix = " in"
  if secs < 0 then
    secs = secs - specs.LFO_FADE.minval
    suffix = " out"
  end
  secs = util.round(secs, 0.01)
  return math.abs(secs) .. " s" .. suffix
end

local function format_ratio_to_one(param)
  return util.round(param:get(), 0.01) .. ":1"
end

local function format_hide_for_stream(sample_id, param_name, formatter)
  return function(param)
    if Timber.samples_meta[sample_id].streaming == 1 then
      return "N/A"
    else
      if formatter then
        return formatter(param)
      else
        return util.round(param:get(), 0.01) .. " " .. param.controlspec.units
      end
    end
  end
end

-- Params

function Timber.add_params()
  
  params:add_separator("Timber")
  
  params:add{type = "trigger", id = "clear_all", name = "Clear All", action = function(value)
    Timber.clear_samples(0, #samples_meta - 1)
  end}
  params:add{type = "control", id = "lfo_1_freq", name = "LFO1 Freq", controlspec = specs.LFO_1_FREQ, formatter = Formatters.format_freq, action = function(value)
    engine.lfo1Freq(value)
    lfos_last_edited = {id = nil, param = "lfo_1_freq"}
    Timber.views_changed_callback(nil)
    Timber.lfo_1_dirty = true
  end}
  params:add{type = "option", id = "lfo_1_wave_shape", name = "LFO1 Shape", options = options.LFO_WAVE_SHAPE, default = 1, action = function(value)
    engine.lfo1WaveShape(value - 1)
    lfos_last_edited = {id = nil, param = "lfo_1_wave_shape"}
    Timber.views_changed_callback(nil)
    Timber.lfo_1_dirty = true
  end}
  params:add{type = "control", id = "lfo_2_freq", name = "LFO2 Freq", controlspec = specs.LFO_2_FREQ, formatter = Formatters.format_freq, action = function(value)
    engine.lfo2Freq(value)
    lfos_last_edited = {id = nil, param = "lfo_2_freq"}
    Timber.views_changed_callback(nil)
    Timber.lfo_2_dirty = true
  end}
  params:add{type = "option", id = "lfo_2_wave_shape", name = "LFO2 Shape", options = options.LFO_WAVE_SHAPE, default = 4, action = function(value)
    engine.lfo2WaveShape(value - 1)
    lfos_last_edited = {id = nil, param = "lfo_2_wave_shape"}
    Timber.views_changed_callback(nil)
    Timber.lfo_2_dirty = true
  end}

end

function Timber.add_sample_params(id, include_beat_params, extra_params)
  
  if id then
    local num_params = 50
    if include_beat_params then num_params = num_params + 1 end
    if extra_params then num_params = num_params + #extra_params end
    params:add_group("Sample " .. id, num_params)
  end
  id = id or 0
  if include_beat_params then beat_params = true end
  
  params:add_separator("Sample - " .. id)
  
  params:add{type = "file", id = "sample_" .. id, name = "Sample", action = function(value)
    if samples_meta[id].num_frames > 0 or value ~= "-" then
      
      -- Set some large defaults in case a pset load is about to try and set all these
      params:lookup_param("start_frame_" .. id).controlspec.maxval = MAX_FRAMES
      params:lookup_param("end_frame_" .. id).controlspec.maxval = MAX_FRAMES
      params:lookup_param("loop_start_frame_" .. id).controlspec.maxval = MAX_FRAMES
      params:set("loop_start_frame_" .. id, 0)
      params:lookup_param("loop_end_frame_" .. id).controlspec.maxval = MAX_FRAMES
      params:set("loop_end_frame_" .. id, MAX_FRAMES)
      params:lookup_param("by_length_" .. id).controlspec.minval = 0
      params:lookup_param("by_length_" .. id).controlspec.maxval = 100000
      local play_mode_param = params:lookup_param("play_mode_" .. id)
      play_mode_param.options = options.PLAY_MODE_BUFFER
      play_mode_param.count = #options.PLAY_MODE_BUFFER
      
      engine.loadSample(id, value)
      Timber.views_changed_callback(id)
    else
      samples_meta[id].manual_load = false
    end
  end}
  params:add{type = "trigger", id = "clear_" .. id, name = "Clear", action = function(value)
    Timber.clear_samples(id)
    Timber.views_changed_callback(id)
  end}
  
  params:add{type = "option", id = "quality_" .. id, name = "Quality", options = options.QUALITY, default = #options.QUALITY, action = function(value)
    engine.downSampleTo(id, QUALITY_SAMPLE_RATES[value])
    engine.bitDepth(id, QUALITY_BIT_DEPTHS[value])
    Timber.views_changed_callback(id)
    Timber.setup_params_dirty = true
  end}
  params:add{type = "number", id = "transpose_" .. id, name = "Transpose", min = -48, max = 48, default = 0, formatter = format_st, action = function(value)
    engine.transpose(id, value)
    Timber.views_changed_callback(id)
    Timber.setup_params_dirty = true
  end}
  params:add{type = "number", id = "detune_cents_" .. id, name = "Detune", min = -100, max = 100, default = 0, formatter = format_cents, action = function(value)
    engine.detuneCents(id, value)
    Timber.views_changed_callback(id)
    Timber.setup_params_dirty = true
  end}
  
  local scale_by_options
  if include_beat_params then scale_by_options = options.SCALE_BY
  else scale_by_options = options.SCALE_BY_NO_BARS end
  params:add{type = "option", id = "scale_by_" .. id, name = "Scale By", options = scale_by_options, default = 1, action = function(value)
    update_by_bars_options(id)
    update_freq_multiplier(id)
    Timber.views_changed_callback(id)
    Timber.setup_params_dirty = true
  end}
  
  params:add{type = "control", id = "by_percentage_" .. id, name = "Percentage", controlspec = specs.BY_PERCENTAGE, formatter = format_by_percentage(id), action = function(value)
    update_freq_multiplier(id)
    Timber.views_changed_callback(id)
    Timber.setup_params_dirty = true
  end}
  params:add{type = "control", id = "by_length_" .. id, name = "Length", controlspec = ControlSpec.new(0.1, 10, "lin", 0, 1, "s"), formatter = format_by_length(id), action = function(value)
    update_freq_multiplier(id)
    Timber.views_changed_callback(id)
    Timber.setup_params_dirty = true
  end}
  
  if include_beat_params then
    params:add{type = "option", id = "by_bars_" .. id, name = "Bars", options = options.BY_BARS_NA, action = function(value)
      update_freq_multiplier(id)
      Timber.views_changed_callback(id)
      Timber.setup_params_dirty = true
    end}
  end
  
  local store_extra_param_ids = false
  if #extra_param_ids == 0 then store_extra_param_ids = true end
  if extra_params then
    for _, v in ipairs(extra_params) do
      params:add(v)
      if store_extra_param_ids then
        table.insert(extra_param_ids, string.sub(v.id, 1, string.match(v.id, '^.*()_') - 1))
      end
    end
  end
  
  params:add_separator("Playback - " .. id)
  
  params:add{type = "option", id = "play_mode_" .. id, name = "Play Mode", options = options.PLAY_MODE_BUFFER, default = options.PLAY_MODE_BUFFER_DEFAULT, action = function(value)
    set_play_mode(id, lookup_play_mode(id))
    waveform_last_edited = {id = id}
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "start_frame_" .. id, name = "Start", controlspec = ControlSpec.new(0, MAX_FRAMES, "lin", 1, 0), formatter = format_frame_number(id), action = function(value)
    set_marker(id, "start_frame_")
  end}
  params:add{type = "control", id = "end_frame_" .. id, name = "End", controlspec = ControlSpec.new(0, MAX_FRAMES, "lin", 1, MAX_FRAMES), formatter = format_frame_number(id), action = function(value)
    set_marker(id, "end_frame_")
  end}
  params:add{type = "control", id = "loop_start_frame_" .. id, name = "Loop Start", controlspec = ControlSpec.new(0, MAX_FRAMES, "lin", 1, 0),
  formatter = format_hide_for_stream(id, "loop_start_frame_" .. id, format_frame_number(id)), action = function(value)
    set_marker(id, "loop_start_frame_")
  end}
  params:add{type = "control", id = "loop_end_frame_" .. id, name = "Loop End", controlspec = ControlSpec.new(0, MAX_FRAMES, "lin", 1, MAX_FRAMES),
  formatter = format_hide_for_stream(id, "loop_end_frame_" .. id, format_frame_number(id)), action = function(value)
    set_marker(id, "loop_end_frame_")
  end}
  
  params:add_separator("Freq Mod - " .. id)
  
  params:add{type = "control", id = "freq_mod_lfo_1_" .. id, name = "Freq Mod (LFO1)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.freqModLfo1(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "freq_mod_lfo_2_" .. id, name = "Freq Mod (LFO2)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.freqModLfo2(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "freq_mod_env_" .. id, name = "Freq Mod (Env)", controlspec = ControlSpec.BIPOLAR, action = function(value)
    engine.freqModEnv(id, value)
    Timber.views_changed_callback(id)
  end}
  
  params:add_separator("Filter - " .. id)

  params:add{type = "option", id = "filter_type_" .. id, name = "Filter Type", options = options.FILTER_TYPE, default = 1, action = function(value)
    engine.filterType(id, value - 1)
    Timber.filter_dirty = true
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_freq_" .. id, name = "Filter Cutoff", controlspec = specs.FILTER_FREQ, formatter = Formatters.format_freq, action = function(value)
    engine.filterFreq(id, value)
    filter_last_edited = {id = id, param = "filter_freq_" .. id}
    Timber.filter_dirty = true
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_resonance_" .. id, name = "Filter Resonance", controlspec = specs.FILTER_RESONANCE, action = function(value)
    engine.filterReso(id, value)
    filter_last_edited = {id = id, param = "filter_resonance_" .. id}
    Timber.filter_dirty = true
    Timber.views_changed_callback(id)
  end}

  params:add{type = "control", id = "filter_freq_mod_lfo_1_" .. id, name = "Filter Cutoff Mod (LFO1)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.filterFreqModLfo1(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_freq_mod_lfo_2_" .. id, name = "Filter Cutoff Mod (LFO2)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.filterFreqModLfo2(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_freq_mod_env_" .. id, name = "Filter Cutoff Mod (Env)", controlspec = ControlSpec.BIPOLAR, action = function(value)
    engine.filterFreqModEnv(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_freq_mod_vel_" .. id, name = "Filter Cutoff Mod (Vel)", controlspec = ControlSpec.BIPOLAR, action = function(value)
    engine.filterFreqModVel(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_freq_mod_pressure_" .. id, name = "Filter Cutoff Mod (Pres)", controlspec = ControlSpec.BIPOLAR, action = function(value)
    engine.filterFreqModPressure(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "filter_tracking_" .. id, name = "Filter Tracking", controlspec = specs.FILTER_TRACKING, formatter = format_ratio_to_one, action = function(value)
    engine.filterTracking(id, value)
    Timber.views_changed_callback(id)
  end}

  params:add_separator("Pan & Amp - " .. id)

  params:add{type = "control", id = "pan_" .. id, name = "Pan", controlspec = ControlSpec.PAN, formatter = Formatters.bipolar_as_pan_widget, action = function(value)
    engine.pan(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "pan_mod_lfo_1_" .. id, name = "Pan Mod (LFO1)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.panModLfo1(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "pan_mod_lfo_2_" .. id, name = "Pan Mod (LFO2)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.panModLfo2(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "pan_mod_env_" .. id, name = "Pan Mod (Env)", controlspec = ControlSpec.BIPOLAR, action = function(value)
    engine.panModEnv(id, value)
    Timber.views_changed_callback(id)
  end}
  
  params:add{type = "control", id = "amp_" .. id, name = "Amp", controlspec = specs.AMP, action = function(value)
    engine.amp(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "amp_mod_lfo_1_" .. id, name = "Amp Mod (LFO1)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.ampModLfo1(id, value)
    Timber.views_changed_callback(id)
  end}
  params:add{type = "control", id = "amp_mod_lfo_2_" .. id, name = "Amp Mod (LFO2)", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    engine.ampModLfo2(id, value)
    Timber.views_changed_callback(id)
  end}
  
  params:add_separator("Amp Env - " .. id)
  
  params:add{type = "control", id = "amp_env_attack_" .. id, name = "Amp Env Attack", controlspec = specs.AMP_ENV_ATTACK, formatter = Formatters.format_secs, action = function(value)
    engine.ampAttack(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  params:add{type = "control", id = "amp_env_decay_" .. id, name = "Amp Env Decay", controlspec = specs.AMP_ENV_DECAY, formatter = Formatters.format_secs, action = function(value)
    engine.ampDecay(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  params:add{type = "control", id = "amp_env_sustain_" .. id, name = "Amp Env Sustain", controlspec = specs.AMP_ENV_SUSTAIN, action = function(value)
    engine.ampSustain(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  params:add{type = "control", id = "amp_env_release_" .. id, name = "Amp Env Release", controlspec = specs.AMP_ENV_RELEASE, formatter = Formatters.format_secs, action = function(value)
    engine.ampRelease(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}

  params:add_separator("Mod Env - " .. id)

  params:add{type = "control", id = "mod_env_attack_" .. id, name = "Mod Env Attack", controlspec = specs.MOD_ENV_ATTACK, formatter = Formatters.format_secs, action = function(value)
    engine.modAttack(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  params:add{type = "control", id = "mod_env_decay_" .. id, name = "Mod Env Decay", controlspec = specs.MOD_ENV_DECAY, formatter = Formatters.format_secs, action = function(value)
    engine.modDecay(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  params:add{type = "control", id = "mod_env_sustain_" .. id, name = "Mod Env Sustain", controlspec = specs.MOD_ENV_SUSTAIN, action = function(value)
    engine.modSustain(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  params:add{type = "control", id = "mod_env_release_" .. id, name = "Mod Env Release", controlspec = specs.MOD_ENV_RELEASE, formatter = Formatters.format_secs, action = function(value)
    engine.modRelease(id, value)
    Timber.views_changed_callback(id)
    Timber.env_dirty = true
  end}
  
  params:add_separator("LFO Fade - " .. id)
  
  params:add{type = "control", id = "lfo_1_fade_" .. id, name = "LFO1 Fade", controlspec = specs.LFO_FADE, formatter = format_fade, action = function(value)
    if value < 0 then value = specs.LFO_FADE.minval - 0.00001 + math.abs(value) end
    engine.lfo1Fade(id, value)
    lfos_last_edited = {id = id, param = "lfo_1_fade_" .. id}
    Timber.views_changed_callback(id)
    Timber.lfo_1_dirty = true
  end}
  params:add{type = "control", id = "lfo_2_fade_" .. id, name = "LFO2 Fade", controlspec = specs.LFO_FADE, formatter = format_fade, action = function(value)
    if value < 0 then value = specs.LFO_FADE.minval - 0.00001 + math.abs(value) end
    engine.lfo2Fade(id, value)
    lfos_last_edited = {id = id, param = "lfo_2_fade_" .. id}
    Timber.views_changed_callback(id)
    Timber.lfo_2_dirty = true
  end}
  
  Timber.num_sample_params = Timber.num_sample_params + 1
end


-- Timber UI views

Timber.UI = {}
Timber.UI.__index = Timber.UI

function Timber.draw_title(sample_id, show_sample_name)
  if show_sample_name == nil then show_sample_name = true end
  
  screen.level(15)
  
  if Timber.shift_mode then
    screen.rect(0, 4, 1, 5)
    screen.fill()
  end
  
  local max_title_width = 100
  screen.move(4, 9)
  if Timber.display == "id" then
    screen.text(string.format("%03d", sample_id))
    screen.move(23, 9)
  elseif Timber.display == "note" then
    screen.text(MusicUtil.note_num_to_name(sample_id, true))
    screen.move(27, 9)
    max_title_width = 96
  end
  
  if show_sample_name or Timber.shift_mode then
    local title
    
    if samples_meta[sample_id].num_frames <= 0 then
      title = samples_meta[sample_id].error_status or "No sample"
      screen.level(3)
    else
      title = params:string("sample_" .. sample_id)
      title = util.trim_string_to_width(title, max_title_width)
    end
    
    screen.text(title)
  end
  
  screen.fill()
end


-------- Sample Setup --------

Timber.UI.SampleSetup = {}
Timber.UI.SampleSetup.__index = Timber.UI.SampleSetup

local function update_setup_params(self)
  local scale_by = params:get("scale_by_" .. self.sample_id)
  local scale
  if scale_by == 1 then
    scale = "by_percentage_" .. self.sample_id
  elseif scale_by == 2 then
    scale = "by_length_" .. self.sample_id
  else
    scale = "by_bars_" .. self.sample_id
  end
  
  self.param_names = {
    "",
    "",
    "",
    "",
    "",
    "quality_" .. self.sample_id,
    "transpose_" .. self.sample_id,
    "detune_cents_" .. self.sample_id,
    "scale_by_" .. self.sample_id,
    scale
  }
  
  self.names_list.entries = {"Load", "Clear", "Move", "Copy", "Copy Params", "Quality", "Transpose", "Detune", "Scale By", "Scale"}
  self.selected_param_name = self.param_names[self.index]
  
  for _, v in ipairs(extra_param_ids) do
    table.insert(self.names_list.entries, params:lookup_param(v .. "_" .. self.sample_id).name)
    table.insert(self.param_names, v .. "_" .. self.sample_id)
  end
  
  self.params_list.entries = {}
  for k, v in pairs(self.param_names) do
    local text = ""
    if v ~= "" then text = params:string(v) end
    self.params_list.entries[k] = text
  end
  
  Timber.setup_params_dirty = false
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.SampleSetup.new(sample_id, index)
  
  names_list = UI.ScrollingList.new(4, 30)
  names_list.num_visible = 3
  names_list.num_above_selected = 0
  
  params_list = UI.ScrollingList.new(120, 30)
  params_list.num_visible = 3
  params_list.num_above_selected = 0
  params_list.text_align = "right"
  
  local sample_setup = {
    sample_id = sample_id or 1,
    index = index or 1,
    names_list = names_list,
    params_list = params_list,
    move_active = false,
    copy_active = false,
    copy_params_active = false,
    move_to = 0,
    copy_to_first = 0,
    copy_to_last = 0
  }
  setmetatable(Timber.UI.SampleSetup, {__index = Timber.UI})
  setmetatable(sample_setup, Timber.UI.SampleSetup)
  
  update_setup_params(sample_setup)
  
  return sample_setup
end

function Timber.UI.SampleSetup:set_sample_id(id)
  self.sample_id = id
  Timber.setup_params_dirty = true
  self.move_active = false
  self.copy_active = false
  self.copy_params_active = false
  Timber.views_changed_callback(id)
end

function Timber.UI.SampleSetup:set_index(index)
  self.index = util.clamp(index, 1, #self.names_list.entries)
  names_list:set_index(self.index)
  params_list:set_index(self.index)
  self.selected_param_name = self.param_names[self.index]
end

function Timber.UI.SampleSetup:set_param_default()
  if self.selected_param_name ~= "" then
    local param = params:lookup_param(self.selected_param_name)
    local default
    if param.default then
      default = param.default
    else
      default = param.controlspec.default
    end
    params:set(self.selected_param_name, default)
  end
end

function Timber.UI.SampleSetup:set_param_delta(delta)
  if self.selected_param_name ~= "" then
    if string.find(self.selected_param_name, "by_percentage") or string.find(self.selected_param_name, "by_length") then
      if Timber.shift_mode then
        delta = delta * 0.01
      else
        delta = delta * 0.1
      end
    end
    params:delta(self.selected_param_name, delta)
  end
end

function Timber.UI.SampleSetup:enc(n, delta)
  
  if self.move_active then
    if n == 2 or n == 3 then
      self.move_to = util.clamp(util.round(self.move_to + delta), 0, Timber.num_sample_params - 1)
    end
    
  elseif self.copy_active or self.copy_params_active then
    if n == 2 then
      self.copy_to_first = util.clamp(util.round(self.copy_to_first + delta), 0, Timber.num_sample_params - 1)
      self.copy_to_last = util.clamp(self.copy_to_last, self.copy_to_first, Timber.num_sample_params - 1)
    elseif n == 3 then
      self.copy_to_last = util.clamp(util.round(self.copy_to_last + delta), self.copy_to_first, Timber.num_sample_params - 1)
    end
    
  else
    if n == 2 then
      self:set_index(self.index + delta)
    elseif n == 3 then
      self:set_param_delta(delta)
    end
  end
  
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.SampleSetup:key(n, z)
  if z == 1 then
    
    if self.move_active then
      
      if n == 2 then
        self.move_active = false
        self.move_to = 0
        Timber.views_changed_callback(self.sample_id)
        
      elseif n == 3 then
        Timber.move_sample(self.sample_id, self.move_to)
        self.move_active = false
        self.move_to = 0
        Timber.views_changed_callback(self.sample_id)
      end
      
    elseif self.copy_active then
      
      if n == 2 then
        self.copy_active = false
        self.copy_to_first = 0
        self.copy_to_last = 0
        Timber.views_changed_callback(self.sample_id)
        
      elseif n == 3 then
        Timber.copy_sample(self.sample_id, self.copy_to_first, self.copy_to_last)
        self.copy_active = false
        self.copy_to_first = 0
        self.copy_to_last = 0
        Timber.views_changed_callback(self.sample_id)
      end
      
    elseif self.copy_params_active then
      
      if n == 2 then
        self.copy_params_active = false
        self.copy_to_first = 0
        self.copy_to_last = 0
        Timber.views_changed_callback(self.sample_id)
        
      elseif n == 3 then
        Timber.copy_params(self.sample_id, self.copy_to_first, self.copy_to_last, {})
        self.copy_params_active = false
        self.copy_to_first = 0
        self.copy_to_last = 0
        Timber.views_changed_callback(self.sample_id)
      end
      
    else
      
      if n == 3 then
        
        if self.index == 1 then
          Timber.file_select_active = true
          Timber.FileSelect.enter(_path.audio, function(file)
            Timber.file_select_active = false
            Timber.views_changed_callback(self.sample_id)
            if file ~= "cancel" then
              Timber.load_sample(self.sample_id, file)
            end
          end)
          
        elseif self.index == 2 then
          params:set("clear_" .. self.sample_id, true)
          
        elseif self.index == 3 then
          self.move_active = true
          
        elseif self.index == 4 then
          self.copy_active = true
          
        elseif self.index == 5 then
          self.copy_params_active = true
          
        else
          self:set_param_default()
          Timber.views_changed_callback(self.sample_id)
        end
      end
      
    end
  end
end

function Timber.UI.SampleSetup:sample_key(sample_id)
  
  if self.move_active then
    Timber.move_sample(self.sample_id, sample_id)
    self.move_active = false
    self.move_to = 0
    Timber.views_changed_callback(self.sample_id)
    
  elseif self.copy_active then
    Timber.copy_sample(self.sample_id, sample_id, sample_id)
    self.copy_active = false
    self.copy_to_first = 0
    self.copy_to_last = 0
    Timber.views_changed_callback(self.sample_id)
    
  elseif self.copy_params_active then
    Timber.copy_params(self.sample_id, sample_id, sample_id)
    self.copy_active = false
    self.copy_to_first = 0
    self.copy_to_last = 0
    Timber.views_changed_callback(self.sample_id)
    
  end
end

function Timber.UI.SampleSetup:redraw()
  
  if Timber.setup_params_dirty then
    update_setup_params(self)
    self.selected_param_name = self.param_names[self.index]
  end
  
  Timber.draw_title(self.sample_id)
  local info = ""
  
  if self.move_active then
    
    screen.level(3)
    screen.move(4, 35)
    screen.text("Move")
    screen.level(15)
    screen.move(68, 35)
    if Timber.display == "note" then
       screen.text(MusicUtil.note_num_to_name(self.move_to, true))
    else
      screen.text(string.format("%03d", self.move_to))
    end
    screen.fill()
    
  elseif self.copy_active or self.copy_params_active then
    
    screen.level(3)
    screen.move(4, 35)
    if self.copy_active then
      screen.text("Copy")
    else
      screen.text("Copy Params")
    end
    screen.level(15)
    screen.move(68, 35)
    if Timber.display == "note" then
       screen.text(MusicUtil.note_num_to_name(self.copy_to_first, true))
       screen.move(88, 35)
    else
      screen.text(string.format("%03d", self.copy_to_first))
      screen.move(86, 35)
    end
    screen.text("-")
    screen.move(93, 35)
    if Timber.display == "note" then
       screen.text(MusicUtil.note_num_to_name(self.copy_to_last, true))
    else
      screen.text(string.format("%03d", self.copy_to_last))
    end
    screen.fill()
      
  else
  
    if samples_meta[self.sample_id].num_frames > 0 then
      
      -- Sample rate
      local info = Formatters.format_freq_raw(samples_meta[self.sample_id].sample_rate)
      
      -- Channels
      if samples_meta[self.sample_id].num_channels == 1 then
        info = info .. " mono"
      else
       info = info .. " stereo" 
      end
      
      -- Type
      if samples_meta[self.sample_id].streaming == 1 then
        info = info .. " stream"
      end
      
      screen.move(4, 18)
      screen.level(3)
      screen.text(info)
      screen.fill()
    end
    
    self.names_list:redraw()
    self.params_list:redraw()
  end
  
end


-------- Waveform --------

Timber.UI.Waveform = {}
Timber.UI.Waveform.__index = Timber.UI.Waveform

function Timber.UI.Waveform.new(sample_id)
  local waveform = {
    sample_id = sample_id or 1,
    tab_id = 1,
    last_edited_param = nil,
    last_edited_timeout = 0
  }
  setmetatable(Timber.UI.Waveform, {__index = Timber.UI})
  setmetatable(waveform, Timber.UI.Waveform)
  return waveform
end

function Timber.UI.Waveform:set_sample_id(id)
  self.sample_id = id
  Timber.views_changed_callback(id)
end

function Timber.UI.Waveform:set_tab(id)
  self.tab_id = util.clamp(id, 1, 2)
end

function Timber.UI.Waveform:enc(n, delta)
  
  -- Trim tab
  if self.tab_id == 1 then
    if n == 2 then
      if Timber.shift_mode then
        params:set("start_frame_" .. self.sample_id, params:get("start_frame_" .. self.sample_id) + delta)
      else
        params:delta("start_frame_" .. self.sample_id, delta)
      end
    elseif n == 3 then
      if samples_meta[self.sample_id].streaming == 0 or lookup_play_mode(self.sample_id) > 1 then
        if Timber.shift_mode then
          params:set("end_frame_" .. self.sample_id, params:get("end_frame_" .. self.sample_id) + delta)
        else
          params:delta("end_frame_" .. self.sample_id, delta)
        end
      end
    end
  
  -- Loop tab
  else
    if n == 2 then
      if Timber.shift_mode then
        params:set("loop_start_frame_" .. self.sample_id, params:get("loop_start_frame_" .. self.sample_id) + delta)
      else
        params:delta("loop_start_frame_" .. self.sample_id, delta)
      end
    elseif n == 3 then
      if Timber.shift_mode then
        params:set("loop_end_frame_" .. self.sample_id, params:get("loop_end_frame_" .. self.sample_id) + delta)
      else
        params:delta("loop_end_frame_" .. self.sample_id, delta)
      end
    end
  end
  
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.Waveform:key(n, z)
  if z == 1 then
    if n == 2 then
      self:set_tab(self.tab_id % 2 + 1)
      
    elseif n == 3 then
      
      if not samples_meta[self.sample_id].waveform_requested then
        Timber.request_waveform(self.sample_id)
        
      else
        if Timber.shift_mode then
          local start_frame = params:get("start_frame_" .. self.sample_id)
          local loop_start_frame = params:get("loop_start_frame_" .. self.sample_id)
          local loop_end_frame = params:get("loop_end_frame_" .. self.sample_id)
          params:set("start_frame_" .. self.sample_id, params:get("end_frame_" .. self.sample_id))
          params:set("end_frame_" .. self.sample_id, start_frame)
          params:set("loop_start_frame_" .. self.sample_id, loop_start_frame)
          params:set("loop_end_frame_" .. self.sample_id, loop_end_frame)
        else
          params:set("play_mode_" .. self.sample_id, params:get("play_mode_" .. self.sample_id) % #params:lookup_param("play_mode_" .. self.sample_id).options + 1)
        end
      end
    end
    Timber.views_changed_callback(self.sample_id)
  end
end

function Timber.UI.Waveform:update()
  
  if self.tab_id ~= 1 and (lookup_play_mode(self.sample_id) > 1 or samples_meta[self.sample_id].streaming == 1) then
    self:set_tab(1)
    Timber.views_changed_callback(self.sample_id)
  end
  
  if waveform_last_edited and waveform_last_edited.id == self.sample_id then
    if waveform_last_edited.param then
      self.last_edited_param = waveform_last_edited.param
      self.last_edited_timeout = 1
    else
      self.last_edited_timeout = -1
      self.last_edited_param = nil
    end
  end
  
  waveform_last_edited = nil
  if self.last_edited_timeout > 0 then
    self.last_edited_timeout = self.last_edited_timeout - 1 / SCREEN_FRAMERATE
  elseif self.last_edited_timeout > -1 then
    self.last_edited_timeout = -1
    self.last_edited_param = nil
    Timber.views_changed_callback(self.sample_id)
  end
end

local function draw_loop_markers(id, x, y, w, h, active)
  if samples_meta[id].streaming == 0 and lookup_play_mode(id) < 2 then
    
    local LOOP_W = 2.5
    local num_frames = samples_meta[id].num_frames
    local top = y + 0.5
    local bottom = y + h - 0.5
    
    local loop_start_x = x + 0.5 + util.round((params:get("loop_start_frame_" .. id) / num_frames) * (w - 1))
    local loop_end_x = x + 0.5 + util.round((params:get("loop_end_frame_" .. id) / num_frames) * (w - 1))
    
    if active then screen.level(15) else screen.level(3) end
    
    screen.move(loop_start_x + LOOP_W, top)
    screen.line(loop_start_x, top)
    screen.line(loop_start_x, bottom)
    screen.line(loop_start_x + LOOP_W, bottom)
    
    screen.move(loop_end_x - LOOP_W, top)
    screen.line(loop_end_x, top)
    screen.line(loop_end_x, bottom)
    screen.line(loop_end_x - LOOP_W, bottom)
    screen.stroke()
  end
end

local function draw_start_end_markers(id, x, y, w, h, active)
  local num_frames = samples_meta[id].num_frames
  local start_x = x + 0.5 + util.round((params:get("start_frame_" .. id) / num_frames) * (w - 1))
  local end_x = x + 0.5 + util.round((params:get("end_frame_" .. id) / num_frames) * (w - 1))
  
  if active then screen.level(15) else screen.level(3) end
  
  -- Start
  screen.move(start_x, y)
  screen.line(start_x, y + h)
  screen.stroke()
  
  local arrow_direction = 1
  if start_x > end_x then arrow_direction = -1 end
  screen.move(start_x + 0.5 * arrow_direction, y + h * 0.5 - 2.5)
  screen.line(start_x + 3 * arrow_direction, y + h * 0.5)
  screen.line(start_x + 0.5 * arrow_direction, y + h * 0.5 + 2.5)
  screen.fill()
  
  -- End
  if samples_meta[id].streaming == 0 or lookup_play_mode(id) > 1 then
    screen.move(end_x, y)
    screen.line(end_x, y + h)
    screen.stroke()
  end
  
end

function Timber.UI.Waveform:redraw()
  local X = 4
  local Y = 25
  local W = 120
  local H = 35
  local WAVE_H = 25
  local PLAY_H = 31
  local play_y_margin = (H - PLAY_H) * 0.5
  local play_top = Y + play_y_margin
  local play_bottom = Y + play_y_margin + PLAY_H
  local y_center = Y + H * 0.5
  
  Timber.draw_title(self.sample_id)
  
  -- Waveform
  screen.level(2)
  local wave_from_center_h = WAVE_H * 0.5
  for i = 1, 60 do
    local wave_x = X + i * 2 - 0.5
    local sample = samples_meta[self.sample_id].waveform[i]
    if sample then
      screen.move(wave_x, util.round(y_center - sample[1] * wave_from_center_h))
      screen.line(wave_x, util.round(y_center - math.max(sample[2] * wave_from_center_h, 1)))
    else
      screen.move(wave_x, y_center - 0.5)
      screen.line(wave_x, y_center + 0.5)
    end
  end
  screen.stroke()
  
  if samples_meta[self.sample_id].num_frames > 0 then
    
    -- Info
    screen.move(X, 18)
    screen.level(3)
    local info
    if self.last_edited_param then
      
      -- Edited param value
      if Timber.shift_mode then
        info = params:get(self.last_edited_param) .. " (" .. params:string(self.last_edited_param) .. ")"
      else
        info = params:string(self.last_edited_param)
      end
      
    else
      
      -- Duration
      local sample_duration = math.abs(params:get("end_frame_" .. self.sample_id) - params:get("start_frame_" .. self.sample_id)) / samples_meta[self.sample_id].sample_rate
      info = Formatters.format_secs_raw(sample_duration)
      if samples_meta[self.sample_id].freq_multiplier ~= 1 then
        info = info .. "/" .. Formatters.format_secs_raw(sample_duration * (1 / samples_meta[self.sample_id].freq_multiplier))
      end
      
      if Timber.shift_mode then
        -- Frames
        info = samples_meta[self.sample_id].num_frames .. " (" .. info .. ")"
      else
        info = info .. " " .. params:string("play_mode_" .. self.sample_id)
      end
      
    end
    screen.text(info)
    screen.fill()
    
    -- Request waveform prompt
    if not samples_meta[self.sample_id].waveform_requested then
      screen.level(0)
      screen.rect(X + W / 2 - 7, util.round(Y + H / 2 - 4), 15, 7)
      screen.fill()
      screen.move(X + W / 2, Y + H / 2 + 2)
      screen.level(3)
      screen.text_center("K3")
      screen.fill()
    end
    
    -- Play positions
    screen.level(2)
    for _, v in pairs(samples_meta[self.sample_id].positions) do
      local position_x = X + 0.5 + util.round(v * (W - 1))
      screen.move(position_x, play_top)
      screen.line(position_x, play_bottom)
    end
    screen.stroke()
    
    -- Start/end edit
    if self.tab_id == 1 then
      draw_loop_markers(self.sample_id, X, Y, W, H, false)
      draw_start_end_markers(self.sample_id, X, Y, W, H, true)
      
    -- Loop edit
    else
      draw_start_end_markers(self.sample_id, X, Y, W, H, false)
      draw_loop_markers(self.sample_id, X, Y, W, H, true)
    end
    
  else
    
    -- Placeholder lines
    screen.level(2)
    screen.move(X + 0.5, Y)
    screen.line(X + 0.5, Y + H)
    screen.move(X - 0.5 + W, Y)
    screen.line(X - 0.5 + W, Y + H)
    screen.stroke()
    
  end
end


-------- Filter / Amp --------

Timber.UI.FilterAmp = {}
Timber.UI.FilterAmp.__index = Timber.UI.FilterAmp

local function filter_type_num_to_string(type_num)
  local filter_type_string
  if type_num == 2 then
    filter_type_string = "highpass"
  else
    filter_type_string = "lowpass"
  end
  return filter_type_string
end

function Timber.UI.FilterAmp.new(sample_id, tab_id)
  
  local filter_graph = FilterGraph.new(10, 24000, -60, 32.5, filter_type_num_to_string(params:get("filter_type_" .. sample_id)), 12,
    params:get("filter_freq_" .. sample_id), params:get("filter_resonance_" .. sample_id))
  filter_graph:set_position_and_size(4, 22, 56, 38)
  
  local pan_dial = UI.Dial.new(68.5, 21, 22, params:get("pan_" .. sample_id) * 100, -100, 100, 1, 0, {0}, nil, "Pan")
  local amp_dial = UI.Dial.new(97, 32, 22, params:get("amp_" .. sample_id), specs.AMP.minval, specs.AMP.maxval, 0.1, nil, {0}, "dB")
  
  local filter_amp = {
    sample_id = sample_id or 1,
    tab_id = tab_id or 1,
    filter_graph = filter_graph,
    pan_dial = pan_dial,
    amp_dial = amp_dial,
  }
  
  filter_graph:set_active(filter_amp.tab_id == 1)
  pan_dial.active = filter_amp.tab_id == 2
  amp_dial.active = filter_amp.tab_id == 2
  
  setmetatable(Timber.UI.FilterAmp, {__index = Timber.UI})
  setmetatable(filter_amp, Timber.UI.FilterAmp)
  return filter_amp
end

function Timber.UI.FilterAmp:set_sample_id(id)
  self.sample_id = id
  Timber.filter_dirty = true
  Timber.views_changed_callback(id)
end

function Timber.UI.FilterAmp:set_tab(id)
  self.tab_id = util.clamp(id, 1, 2)
  self.filter_graph:set_active(self.tab_id == 1)
  self.pan_dial.active = self.tab_id == 2
  self.amp_dial.active = self.tab_id == 2
end

function Timber.UI.FilterAmp:enc(n, delta)
  if Timber.shift_mode then delta = delta * 0.1 end
  if self.tab_id == 1 then
    if n == 2 then
      params:delta("filter_freq_" .. self.sample_id, delta)
    elseif n == 3 then
      params:delta("filter_resonance_" .. self.sample_id, delta)
    end
  else
    if n == 2 then
      params:delta("pan_" .. self.sample_id, delta)
    elseif n == 3 then
      params:delta("amp_" .. self.sample_id, delta)
    end
  end
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.FilterAmp:key(n, z)
  if z == 1 then
    if n == 2 then
      self:set_tab(self.tab_id % 2 + 1)
    elseif n == 3 then
      if self.tab_id == 1 then
        params:set("filter_type_" .. self.sample_id, params:get("filter_type_" .. self.sample_id) % #Timber.options.FILTER_TYPE + 1)
      end
    end
    Timber.views_changed_callback(self.sample_id)
  end
end

function Timber.UI.FilterAmp:redraw()
  
  Timber.draw_title(self.sample_id)
  
  if Timber.filter_dirty then
    self.filter_graph:edit(filter_type_num_to_string(params:get("filter_type_" .. self.sample_id)), nil, params:get("filter_freq_" .. self.sample_id), params:get("filter_resonance_" .. self.sample_id))
    Timber.filter_dirty = false
  end
  self.pan_dial:set_value(params:get("pan_" .. self.sample_id) * 100)
  self.amp_dial:set_value(params:get("amp_" .. self.sample_id))
  
  local filter_type = params:get("filter_type_" .. self.sample_id)
  local type_short
  if filter_type == 2 then
    type_short = "HP"
  else
    type_short = "LP"
  end
  screen.level(3)
  screen.move(4, 18)
  screen.text(type_short .. " " .. params:string("filter_freq_" .. self.sample_id))
  
  self.filter_graph:redraw()
  self.pan_dial:redraw()
  self.amp_dial:redraw()
  
  if params:get("amp_" .. self.sample_id) > 2 then
    screen.level(15)
    screen.move(108, 46)
    screen.text_center("!")
  end
  
  screen.fill()
end


-------- Env --------
-- Just here as a superclass of AmpEnv and ModEnv

Timber.UI.Env = {}
Timber.UI.Env.__index = Timber.UI.Env

function Timber.UI.Env.new(env_name, sample_id, tab_id)
  local graph = EnvGraph.new_adsr(0, 20, nil, nil, params:get(env_name .. "_env_attack_" .. sample_id), params:get(env_name .. "_env_decay_" .. sample_id),
    params:get(env_name .. "_env_sustain_" .. sample_id), params:get(env_name .. "_env_release_" .. sample_id), 1, -4)
  graph:set_position_and_size(57, 34, 60, 25)
  local env = {
    env_name = env_name,
    title = string.upper(string.sub(env_name, 1, 1)) .. string.sub(env_name, 2),
    sample_id = sample_id or 1,
    tab_id = tab_id or 1,
    graph = graph
  }
  setmetatable(Timber.UI.Env, {__index = Timber.UI})
  setmetatable(env, Timber.UI.Env)
  return env
end

function Timber.UI.Env:set_sample_id(id)
  self.sample_id = id
  Timber.env_dirty = true
  Timber.views_changed_callback(id)
end

function Timber.UI.Env:set_tab(id)
  self.tab_id = util.clamp(id, 1, 2)
end

function Timber.UI.Env:enc(n, delta)
  
end

function Timber.UI.Env:key(n, z)
  if z == 1 then
    if n == 2 then
      self:set_tab(self.tab_id % 2 + 1)
    end
    Timber.views_changed_callback(self.sample_id)
  end
end

function Timber.UI.Env:redraw()
  
  Timber.draw_title(self.sample_id)
  
  if self.tab_id == 1 then screen.level(15) else screen.level(3) end
  screen.move(4, 27)
  screen.text("A " .. params:string(self.env_name .. "_env_attack_" .. self.sample_id))
  screen.move(4, 38)
  screen.text("D " .. params:string(self.env_name .. "_env_decay_" .. self.sample_id))
  if self.tab_id == 2 then screen.level(15) else screen.level(3) end
  screen.move(4, 49)
  screen.text("S " .. params:string(self.env_name .. "_env_sustain_" .. self.sample_id))
  screen.move(4, 60)
  screen.text("R " .. params:string(self.env_name .. "_env_release_" .. self.sample_id))
  
  screen.level(3)
  screen.move(56, 27)
  screen.text(self.title)
  
  screen.fill()
  
  if Timber.env_dirty then
    self.graph:edit_adsr(params:get(self.env_name .. "_env_attack_" .. self.sample_id), params:get(self.env_name .. "_env_decay_" .. self.sample_id),
      params:get(self.env_name .. "_env_sustain_" .. self.sample_id), params:get(self.env_name .. "_env_release_" .. self.sample_id))
    Timber.env_dirty = false
  end
  self.graph:redraw()
end

-------- Amp Env --------

Timber.UI.AmpEnv = {}
Timber.UI.AmpEnv.__index = Timber.UI.AmpEnv

function Timber.UI.AmpEnv.new(sample_id, tab_id)
  local env = Timber.UI.Env.new("amp", sample_id, tab_id)
  setmetatable(Timber.UI.AmpEnv, {__index = Timber.UI.Env})
  setmetatable(env, Timber.UI.AmpEnv)
  return env
end

function Timber.UI.AmpEnv:enc(n, delta)
  if Timber.shift_mode then delta = delta * 0.1 end
  if self.tab_id == 1 then
    if n == 2 then
      params:delta("amp_env_attack_" .. self.sample_id, delta)
    elseif n == 3 then
      params:delta("amp_env_decay_" .. self.sample_id, delta)
    end
  else
    if n == 2 then
      params:delta("amp_env_sustain_" .. self.sample_id, delta)
    elseif n == 3 then
      params:delta("amp_env_release_" .. self.sample_id, delta)
    end
  end
  Timber.views_changed_callback(self.sample_id)
end

-------- Mod Env --------

Timber.UI.ModEnv = {}
Timber.UI.ModEnv.__index = Timber.UI.ModEnv

function Timber.UI.ModEnv.new(sample_id, tab_id)
  local env = Timber.UI.Env.new("mod", sample_id, tab_id)
  setmetatable(Timber.UI.ModEnv, {__index = Timber.UI.Env})
  setmetatable(env, Timber.UI.ModEnv)
  return env
end

function Timber.UI.ModEnv:enc(n, delta)
  if Timber.shift_mode then delta = delta * 0.1 end
  if self.tab_id == 1 then
    if n == 2 then
      params:delta("mod_env_attack_" .. self.sample_id, delta)
    elseif n == 3 then
      params:delta("mod_env_decay_" .. self.sample_id, delta)
    end
  else
    if n == 2 then
      params:delta("mod_env_sustain_" .. self.sample_id, delta)
    elseif n == 3 then
      params:delta("mod_env_release_" .. self.sample_id, delta)
    end
  end
  Timber.views_changed_callback(self.sample_id)
end


-------- LFOs --------

Timber.UI.Lfos = {}
Timber.UI.Lfos.__index = Timber.UI.Lfos

local function generate_lfo_wave(sample_id, lfo_id)
  
  return function(x)
    
    shape = params:get("lfo_" .. lfo_id .. "_wave_shape")
    freq = params:get("lfo_" .. lfo_id .. "_freq")
    fade = params:get("lfo_" .. lfo_id .. "_fade_" .. sample_id)
    
    local fade_end
    local y_fade
    local MIN_Y = 0.15
    
    if fade > 0 then
      fade_end = util.linlin(0, Timber.specs.LFO_FADE.maxval, 0, 1, fade)
      y_fade = util.linlin(0, fade_end, MIN_Y, 1, x)
    else
      fade_end = util.linlin(Timber.specs.LFO_FADE.minval, 0, 0, 1, fade)
      y_fade = util.linlin(0, fade_end, 1, util.linlin(Timber.specs.LFO_FADE.minval * 0.2, 0, MIN_Y, 1, fade), x)
    end
    
    x = x * util.linlin(Timber.specs.LFO_1_FREQ.minval, Timber.specs.LFO_1_FREQ.maxval, 0.5, 10, freq)
    local y
    
    if shape == 1 then -- Sine
      y = math.sin(x * math.pi * 2)
    elseif shape == 2 then -- Tri
      y = math.abs((x * 2 - 0.5) % 2 - 1) * 2 - 1
    elseif shape == 3 then -- Ramp
      y = ((x + 0.5) % 1) * 2 - 1
    elseif shape == 4 then -- Square
      y = math.abs(x * 2 % 2 - 1) - 0.5
      y = y > 0 and 1 or math.floor(y)
    elseif shape == 5 then -- Random
      local NOISE = {0.7, -0.65, 0.2, 0.9, -0.1, -0.5, 0.7, -0.9, 0.25, 1.0, -0.6, -0.2, 0.6, -0.35, 0.7, 0.1, -0.5, 0.7, 0.2, -0.85, -0.3}
      y = NOISE[util.round(x * 2) + 1]
    end
    
    return y * y_fade * 0.75
  end
end

function Timber.UI.Lfos.new(sample_id, tab_id)
  
  local SUB_SAMPLING = 4
  
  local lfo_1_graph = Graph.new(0, 1, "lin", -1, 1, "lin", nil, true, false)
  lfo_1_graph:set_position_and_size(4, 21, 56, 34)
  lfo_1_graph:add_function(generate_lfo_wave(sample_id, 1), SUB_SAMPLING)
  
  local lfo_2_graph = Graph.new(0, 1, "lin", -1, 1, "lin", nil, true, false)
  lfo_2_graph:set_position_and_size(68, 21, 56, 34)
  lfo_2_graph:add_function(generate_lfo_wave(sample_id, 2), SUB_SAMPLING)
  
  local lfos = {
    sample_id = sample_id or 1,
    tab_id = tab_id or 1,
    lfo_1_graph = lfo_1_graph,
    lfo_2_graph = lfo_2_graph,
    last_edited_param = nil,
    last_edited_timeout = 0
  }
  
  lfo_1_graph:set_active(lfos.tab_id == 1)
  lfo_2_graph:set_active(lfos.tab_id == 2)
  
  setmetatable(Timber.UI.Lfos, {__index = Timber.UI})
  setmetatable(lfos, Timber.UI.Lfos)
  return lfos
end

function Timber.UI.Lfos:set_sample_id(id)
  self.sample_id = id
  Timber.lfo_functions_dirty = true
  Timber.views_changed_callback(id)
end

function Timber.UI.Lfos:set_tab(id)
  self.tab_id = util.clamp(id, 1, 2)
  self.lfo_1_graph:set_active(self.tab_id == 1)
  self.lfo_2_graph:set_active(self.tab_id == 2)
end

function Timber.UI.Lfos:enc(n, delta)
  if Timber.shift_mode then delta = delta * 0.05 end
  if self.tab_id == 1 then
    if n == 2 then
      params:delta("lfo_1_freq", delta)
    elseif n == 3 then
      params:delta("lfo_1_fade_" .. self.sample_id, delta)
    end
  else
    if n == 2 then
      params:delta("lfo_2_freq", delta)
    elseif n == 3 then
      params:delta("lfo_2_fade_" .. self.sample_id, delta)
    end
  end
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.Lfos:key(n, z)
  if z == 1 then
    if n == 2 then
      self:set_tab(self.tab_id % 2 + 1)
    elseif n == 3 then
      if self.tab_id == 1 then
        params:set("lfo_1_wave_shape", params:get("lfo_1_wave_shape") % #Timber.options.LFO_WAVE_SHAPE + 1)
      else
        params:set("lfo_2_wave_shape", params:get("lfo_2_wave_shape") % #Timber.options.LFO_WAVE_SHAPE + 1)
      end
    end
    Timber.views_changed_callback(self.sample_id)
  end
end


function Timber.UI.Lfos:update()
  
  if lfos_last_edited and (lfos_last_edited.id == self.sample_id or lfos_last_edited.id == nil) then
    self.last_edited_param = lfos_last_edited.param
    self.last_edited_timeout = 1
  end
  
  lfos_last_edited = nil
  if self.last_edited_timeout > 0 then
    self.last_edited_timeout = self.last_edited_timeout - 1 / SCREEN_FRAMERATE
  elseif self.last_edited_timeout > -1 then
    self.last_edited_timeout = -1
    self.last_edited_param = nil
    Timber.views_changed_callback(self.sample_id)
  end
end

function Timber.UI.Lfos:redraw()
  
  Timber.draw_title(self.sample_id)
  
  if Timber.lfo_functions_dirty then
    self.lfo_1_graph:edit_function(1, generate_lfo_wave(self.sample_id, 1))
    self.lfo_2_graph:edit_function(1, generate_lfo_wave(self.sample_id, 2))
    Timber.lfo_functions_dirty = false
  end
  
  if Timber.lfo_1_dirty then
    self.lfo_1_graph:update_functions()
    Timber.lfo_1_dirty = false
  end
  if Timber.lfo_2_dirty then
    self.lfo_2_graph:update_functions()
    Timber.lfo_2_dirty = false
  end
  
  self.lfo_1_graph:redraw()
  self.lfo_2_graph:redraw()
  
  screen.level(3)
  
  if self.last_edited_param then
    screen.move(4, 18)
    screen.text(params:string(self.last_edited_param))
  end
  
  screen.move(4, 60)
  screen.text("LFO1")
  screen.move(68, 60)
  screen.text("LFO2")
  
  screen.fill()
end


-------- Matrices --------

local function draw_matrix(cols, rows, data, index, shift_mode)
  local grid_left = 46
  local grid_top = 27
  local col = 28
  
  screen.level(3)
  
  if not Timber.shift_mode then
    for i = 1, #cols do
      if (index - 1) % 3 + 1 == i then screen.level(15) end
      screen.move(grid_left + (i - 1) * col, 9)
      screen.text_center(cols[i])
      if (index - 1) % 3 + 1 == i then screen.level(3) end
    end
  end
  
  for i = 1, #rows do
    if math.ceil(index / 3) == i then screen.level(15) end
    screen.move(4, grid_top + (i - 1) * 11)
    screen.text(rows[i])
    if math.ceil(index / 3) == i then screen.level(3) end
  end
  
  local x = grid_left
  local y = grid_top
  for i = 1, #data do
    if i == index then screen.level(15) end
    screen.move(x, y)
    screen.text_center(data[i])
    if i == index then screen.level(3) end
    x = x + col
    if i % 3 == 0 then
      x = grid_left
      y = y + 11
    end
  end
  
  screen.fill()
end

-------- Mod Matrix --------

Timber.UI.ModMatrix = {}
Timber.UI.ModMatrix.__index = Timber.UI.ModMatrix

function Timber.UI.ModMatrix.new(sample_id, index)
  local matrix = {
    sample_id = sample_id or 1,
    index = index or 1
  }
  setmetatable(Timber.UI.ModMatrix, {__index = Timber.UI})
  setmetatable(matrix, Timber.UI.ModMatrix)
  return matrix
end

function Timber.UI.ModMatrix:set_sample_id(id)
  self.sample_id = id
  Timber.views_changed_callback(id)
end

function Timber.UI.ModMatrix:set_index(index)
  self.index = util.clamp(index, 1, 11)
end

function Timber.UI.ModMatrix:enc(n, delta)
  if n == 2 then
    self:set_index(self.index + delta)
  elseif n == 3 then
    if Timber.shift_mode then delta = delta * 0.1 end
    if self.index == 1 then
      params:delta("freq_mod_lfo_1_" .. self.sample_id, delta)
    elseif self.index == 2 then
      params:delta("freq_mod_lfo_2_" .. self.sample_id, delta)
    elseif self.index == 3 then
      params:delta("freq_mod_env_" .. self.sample_id, delta)
    elseif self.index == 4 then
      params:delta("filter_freq_mod_lfo_1_" .. self.sample_id, delta)
    elseif self.index == 5 then
      params:delta("filter_freq_mod_lfo_2_" .. self.sample_id, delta)
    elseif self.index == 6 then
      params:delta("filter_freq_mod_env_" .. self.sample_id, delta)
    elseif self.index == 7 then
      params:delta("pan_mod_lfo_1_" .. self.sample_id, delta)
    elseif self.index == 8 then
      params:delta("pan_mod_lfo_2_" .. self.sample_id, delta)
    elseif self.index == 9 then
      params:delta("pan_mod_env_" .. self.sample_id, delta)
    elseif self.index == 10 then
      params:delta("amp_mod_lfo_1_" .. self.sample_id, delta)
    elseif self.index == 11 then
      params:delta("amp_mod_lfo_2_" .. self.sample_id, delta)
    end
  end
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.ModMatrix:key(n, z)
  if n == 3 and z == 1 then
    if self.index == 1 then
      params:set("freq_mod_lfo_1_" .. self.sample_id, 0)
    elseif self.index == 2 then
      params:set("freq_mod_lfo_2_" .. self.sample_id, 0)
    elseif self.index == 3 then
      params:set("freq_mod_env_" .. self.sample_id, 0)
    elseif self.index == 4 then
      params:set("filter_freq_mod_lfo_1_" .. self.sample_id, 0)
    elseif self.index == 5 then
      params:set("filter_freq_mod_lfo_2_" .. self.sample_id, 0)
    elseif self.index == 6 then
      params:set("filter_freq_mod_env_" .. self.sample_id, 0)
    elseif self.index == 7 then
      params:set("pan_mod_lfo_1_" .. self.sample_id, 0)
    elseif self.index == 8 then
      params:set("pan_mod_lfo_2_" .. self.sample_id, 0)
    elseif self.index == 9 then
      params:set("pan_mod_env_" .. self.sample_id, 0)
    elseif self.index == 10 then
      params:set("amp_mod_lfo_1_" .. self.sample_id, 0)
    elseif self.index == 11 then
      params:set("amp_mod_lfo_2_" .. self.sample_id, 0)
    end
    Timber.views_changed_callback(self.sample_id)
  end
end

function Timber.UI.ModMatrix:redraw()
  
  Timber.draw_title(self.sample_id, false)
  
  local grid_text = {
    params:get("freq_mod_lfo_1_" .. self.sample_id), params:get("freq_mod_lfo_2_" .. self.sample_id), params:get("freq_mod_env_" .. self.sample_id),
    params:get("filter_freq_mod_lfo_1_" .. self.sample_id), params:get("filter_freq_mod_lfo_2_" .. self.sample_id), params:get("filter_freq_mod_env_" .. self.sample_id),
    params:get("pan_mod_lfo_1_" .. self.sample_id), params:get("pan_mod_lfo_2_" .. self.sample_id), params:get("pan_mod_env_" .. self.sample_id),
    params:get("amp_mod_lfo_1_" .. self.sample_id), params:get("amp_mod_lfo_2_" .. self.sample_id), "/"
  }
  for i = 1, #grid_text - 1 do
    grid_text[i] = util.round(grid_text[i] * 100)
  end
  
  draw_matrix({"LFO1", "LFO2", "Env"}, {"Freq", "Filter", "Pan", "Amp"}, grid_text, self.index)
end

-------- Key Matrix --------

Timber.UI.KeyMatrix = {}
Timber.UI.KeyMatrix.__index = Timber.UI.KeyMatrix

function Timber.UI.KeyMatrix.new(sample_id, index)
  local matrix = {
    sample_id = sample_id or 1,
    index = index or 1
  }
  setmetatable(Timber.UI.KeyMatrix, {__index = Timber.UI})
  setmetatable(matrix, Timber.UI.KeyMatrix)
  return matrix
end

function Timber.UI.KeyMatrix:set_sample_id(id)
  self.sample_id = id
  Timber.views_changed_callback(id)
end

function Timber.UI.KeyMatrix:set_index(index)
  self.index = util.clamp(index, 1, 3)
end

function Timber.UI.KeyMatrix:enc(n, delta)
  if n == 2 then
    self:set_index(self.index + delta)
  elseif n == 3 then
    if Timber.shift_mode then delta = delta * 0.1 end
    if self.index == 1 then
      params:delta("filter_freq_mod_vel_" .. self.sample_id, delta)
    elseif self.index == 2 then
      params:delta("filter_freq_mod_pressure_" .. self.sample_id, delta)
    elseif self.index == 3 then
      params:delta("filter_tracking_" .. self.sample_id, delta)
    end
  end
  Timber.views_changed_callback(self.sample_id)
end

function Timber.UI.KeyMatrix:key(n, z)
  if n == 3 and z == 1 then
    if self.index == 1 then
      params:set("filter_freq_mod_vel_" .. self.sample_id, 0)
    elseif self.index == 2 then
      params:set("filter_freq_mod_pressure_" .. self.sample_id, 0)
    elseif self.index == 3 then
      params:set("filter_tracking_" .. self.sample_id, 1)
    end
    Timber.views_changed_callback(self.sample_id)
  end
end

function Timber.UI.KeyMatrix:redraw()
  
  Timber.draw_title(self.sample_id, false)
  
  local grid_text = {
    params:get("filter_freq_mod_vel_" .. self.sample_id), params:get("filter_freq_mod_pressure_" .. self.sample_id), params:string("filter_tracking_" .. self.sample_id)
  }
  for i = 1, 2 do
    grid_text[i] = util.round(grid_text[i] * 100)
  end
  
  draw_matrix({"Vel", "Pres", "Key"}, {"Filter"}, grid_text, self.index)
end


return Timber
