-- Timber Keys
-- 1.0.0 Beta 7 @markeats
-- llllllll.co/t/timber
--
-- Map samples across a
-- MIDI keyboard.
--
-- E1 : Page
-- K1+E1 : Sample slot
-- K1 (Hold) : Shift / Fine
--
-- K2 : Focus
-- K3 : Action
-- E2/3 : Params
--

local Timber = include("timber/lib/timber_engine")
local MusicUtil = require "musicutil"
local UI = require "ui"
local Formatters = require "formatters"

engine.name = "Timber"

local SCREEN_FRAMERATE = 15
local screen_dirty = true

local midi_in_device

local pages
local global_view
local sample_setup_view
local waveform_view
local filter_amp_view
local amp_env_view
local mod_env_view
local lfos_view
local mod_matrix_view
local key_matrix_view

local NUM_SAMPLES = 16
local current_sample_id = 0
local shift_mode = false


local function set_sample_id(id)
  current_sample_id = id
  while current_sample_id >= NUM_SAMPLES do current_sample_id = current_sample_id - NUM_SAMPLES end
  while current_sample_id < 0 do current_sample_id = current_sample_id + NUM_SAMPLES end
  sample_setup_view:set_sample_id(current_sample_id)
  waveform_view:set_sample_id(current_sample_id)
  filter_amp_view:set_sample_id(current_sample_id)
  amp_env_view:set_sample_id(current_sample_id)
  mod_env_view:set_sample_id(current_sample_id)
  lfos_view:set_sample_id(current_sample_id)
  mod_matrix_view:set_sample_id(current_sample_id)
  key_matrix_view:set_sample_id(current_sample_id)
end

local function note_on(voice_id, freq, vel, sample_id)
  engine.noteOn(voice_id, freq, vel, sample_id)
  if params:get("follow") == 2 then
    set_sample_id(sample_id)
  end
  screen_dirty = true
end

local function note_off(voice_id, sample_id)
  engine.noteOff(voice_id)
  screen_dirty = true
end

local function note_off_all()
  engine.noteOffAll()
  screen_dirty = true
end

local function note_kill_all()
  engine.noteKillAll()
  screen_dirty = true
end

local function set_pressure_voice(voice_id, pressure)
  engine.pressureVoice(voice_id, pressure)
end

local function set_pressure_sample(sample_id, pressure)
  engine.pressureSample(sample_id, pressure)
end

local function set_pressure_all(pressure)
  engine.pressureAll(pressure)
end

local function set_pitch_bend_voice(voice_id, bend_st)
  engine.pitchBendVoice(voice_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_sample(sample_id, bend_st)
  engine.pitchBendSample(sample_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_all(bend_st)
  engine.pitchBendAll(MusicUtil.interval_to_ratio(bend_st))
end


-- Encoder input
function enc(n, delta)
  
  -- Global
  if n == 1 then
    if shift_mode then
      if pages.index > 1 then
        set_sample_id(current_sample_id + delta)
      end
    else
      pages:set_index_delta(delta, false)
    end
  
  else
    
    if pages.index == 2 then
      sample_setup_view:enc(n, delta)
    elseif pages.index == 3 then
      waveform_view:enc(n, delta)
    elseif pages.index == 4 then
      filter_amp_view:enc(n, delta)
    elseif pages.index == 5 then
      amp_env_view:enc(n, delta)
    elseif pages.index == 6 then
      mod_env_view:enc(n, delta)
    elseif pages.index == 7 then
      lfos_view:enc(n, delta)
    elseif pages.index == 8 then
      mod_matrix_view:enc(n, delta)
    elseif pages.index == 9 then
      key_matrix_view:enc(n, delta)
    end
    
  end
  screen_dirty = true
end

-- Key input
function key(n, z)
  
  if n == 1 then
    -- Shift  
    if z == 1 then
      shift_mode = true
      Timber.shift_mode = shift_mode
    else
      shift_mode = false
      Timber.shift_mode = shift_mode
    end
    
  else
    
    if pages.index == 2 then
      sample_setup_view:key(n, z)
    elseif pages.index == 3 then
      waveform_view:key(n, z)
    elseif pages.index == 4 then
      filter_amp_view:key(n, z)
    elseif pages.index == 5 then
      amp_env_view:key(n, z)
    elseif pages.index == 6 then
      mod_env_view:key(n, z)
    elseif pages.index == 7 then
      lfos_view:key(n, z)
    elseif pages.index == 8 then
      mod_matrix_view:key(n, z)
    elseif pages.index == 9 then
      key_matrix_view:key(n, z)
    end
  end
  
  screen_dirty = true
end

-- MIDI input
local function midi_event(data)
  
  local msg = midi.to_msg(data)
  local sample_id
  if msg.ch then
    sample_id = msg.ch - 1
  end
  local voice_id
  if msg.note then
    voice_id = (msg.ch - 1) * 128 + msg.note
  end
  
  -- Note off
  if msg.type == "note_off" then
    note_off(voice_id, sample_id)
    -- print("note off", msg.note, voice_id, sample_id)
  
  -- Note on
  elseif msg.type == "note_on" then
    
    if pages.index == 2 then
      sample_setup_view:sample_key(sample_id)
    end
    
    note_on(voice_id, MusicUtil.note_num_to_freq(msg.note), msg.vel / 127, sample_id)
    -- print("note on", msg.note, msg.vel, voice_id, sample_id)
    
  -- Key pressure
  elseif msg.type == "key_pressure" then
    set_pressure_voice(voice_id, msg.val / 127)
    
  -- Channel pressure
  elseif msg.type == "channel_pressure" then
    set_pressure_sample(sample_id, msg.val / 127)
    
  -- Pitch bend
  elseif msg.type == "pitchbend" then
    local bend_st = (util.round(msg.val / 2)) / 8192 * 2 -1 -- Convert to -1 to 1
    local bend_range = params:get("bend_range")
    set_pitch_bend_sample(sample_id, bend_st * bend_range)
    
  end

end

local function update()
  waveform_view:update()
  lfos_view:update()
end


-- Views

local GlobalView = {}
GlobalView.__index = GlobalView

function GlobalView.new(sample_id)
  local global = {
    sample_id = sample_id or 1,
    particle_properties = {}
  }
  
  -- Generate random properties for particles
  for i = 0, 127 do
    global.particle_properties[i] = {}
    global.particle_properties[i].level = math.random(1, 5)
    global.particle_properties[i].length = math.random(4, 9)
    if math.random() > 0.5 then
      global.particle_properties[i].y = math.random(3, 20)
    else
      global.particle_properties[i].y = math.random(43, 60)
    end
  end
  
  setmetatable(GlobalView, {__index = GlobalView})
  setmetatable(global, GlobalView)
  return global
end

function GlobalView:redraw()
  local text_x, text_y = 4, 29
  local PARTICLES_X, PARTICLES_W = 4, 120
  for i = 0, NUM_SAMPLES - 1 do
    
    -- Draw numbers
    screen.move(text_x, text_y)
    if Timber.samples_meta[i] and Timber.samples_meta[i].num_frames > 0 then
      if Timber.samples_meta[i].playing then screen.level(15) else screen.level(3) end
      screen.text(i)
    else
      screen.level(1)
      screen.text("/")
    end
    if (i + 1) % 8 == 0 then
      text_x = 4
      text_y = text_y + 11
    else
      text_x = text_x + 14
    end
    
    -- Draw particles
    if Timber.samples_meta[i].playing then
      for k, v in pairs(Timber.samples_meta[i].positions) do
        local note = k % 128
        local position_x = PARTICLES_X + util.round(v * (PARTICLES_W - 1 + self.particle_properties[note].length))
        screen.move(util.clamp(position_x, PARTICLES_X, PARTICLES_X + PARTICLES_W - 1), self.particle_properties[note].y + 0.5)
        screen.line(position_x - self.particle_properties[note].length, self.particle_properties[note].y + 0.5)
        screen.level(self.particle_properties[note].level)
        screen.stroke()
      end
    end
    
  end
  screen.fill()
end


-- Drawing functions

local function draw_background_rects()
  -- 4px edge margins. 8px gutter.
  screen.level(1)
  screen.rect(4, 22, 56, 38)
  screen.rect(68, 22, 56, 38)
  screen.fill()
end

function redraw()
  
  screen.clear()
  
  if Timber.file_select_active then
    Timber.FileSelect.redraw()
    return
  end
  
  -- draw_background_rects()
  
  pages:redraw()
  
  if pages.index == 1 then
    global_view:redraw()
  elseif pages.index == 2 then
    sample_setup_view:redraw()
  elseif pages.index == 3 then
    waveform_view:redraw()
  elseif pages.index == 4 then
    filter_amp_view:redraw()
  elseif pages.index == 5 then
    amp_env_view:redraw()
  elseif pages.index == 6 then
    mod_env_view:redraw()
  elseif pages.index == 7 then
    lfos_view:redraw()
  elseif pages.index == 8 then
    mod_matrix_view:redraw()
  elseif pages.index == 9 then
    key_matrix_view:redraw()
  end
  
  screen.update()
end

local function callback_set_screen_dirty(id)
  if id == nil or id == current_sample_id or pages.index == 1 then
    screen_dirty = true
  end
end

local function callback_set_waveform_dirty(id)
  if ((id == nil or id == current_sample_id) and pages.index == 3) or pages.index == 1 then
    screen_dirty = true
  end
end


function init()
  
  midi_in_device = midi.connect(1)
  midi_in_device.event = midi_event
  
  pages = UI.Pages.new(1, 9)
  
  -- Callbacks
  Timber.sample_changed_callback = function(id)
    
    if Timber.samples_meta[id].manual_load then
      
      -- Set our own loop point defaults
      params:set("loop_start_frame_" .. id, util.round(Timber.samples_meta[id].num_frames * 0.2))
      params:set("loop_end_frame_" .. id, util.round(Timber.samples_meta[id].num_frames * 0.5))
      
      -- Set env defaults
      params:set("amp_env_attack_" .. id, 0.01)
      params:set("amp_env_sustain_" .. id, 0.8)
      params:set("amp_env_release_" .. id, 0.4)
    end
    
    callback_set_screen_dirty(id)
  end
  Timber.meta_changed_callback = callback_set_screen_dirty
  Timber.waveform_changed_callback = callback_set_waveform_dirty
  Timber.play_positions_changed_callback = callback_set_waveform_dirty
  Timber.views_changed_callback = callback_set_screen_dirty
  
  -- Add params
  
  params:add{type = "number", id = "midi_device", name = "MIDI Device", min = 1, max = 4, default = 1, action = function(value)
    midi_in_device.event = nil
    midi_in_device = midi.connect(value)
    midi_in_device.event = midi_event
  end}
  params:add{type = "number", id = "bend_range", name = "Pitch Bend Range", min = 1, max = 48, default = 2}
  
  params:add{type = "option", id = "follow", name = "Follow", options = {"Off", "On"}, default = 2}
  
  params:add_separator()
  
  Timber.add_params()
  for i = 0, NUM_SAMPLES - 1 do
    params:add_separator()
    Timber.add_sample_params(i)
  end
  
  -- Default sample
  Timber.load_sample(0, _path.code .. "/timber/audio/piano-c.wav")
  
  -- UI
  
  global_view = GlobalView.new()
  sample_setup_view = Timber.UI.SampleSetup.new(current_sample_id)
  waveform_view = Timber.UI.Waveform.new(current_sample_id)
  filter_amp_view = Timber.UI.FilterAmp.new(current_sample_id)
  amp_env_view = Timber.UI.AmpEnv.new(current_sample_id)
  mod_env_view = Timber.UI.ModEnv.new(current_sample_id)
  lfos_view = Timber.UI.Lfos.new(current_sample_id)
  mod_matrix_view = Timber.UI.ModMatrix.new(current_sample_id)
  key_matrix_view = Timber.UI.KeyMatrix.new(current_sample_id)
  
  screen.aa(1)
  
  local screen_refresh_metro = metro.init()
  screen_refresh_metro.event = function()
    update()
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  screen_refresh_metro:start(1 / SCREEN_FRAMERATE)
  
end
