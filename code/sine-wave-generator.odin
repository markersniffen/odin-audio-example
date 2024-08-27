package sine_wave_generator

import ma "vendor:miniaudio"
import rl "vendor:raylib"
import "core:sync"
import "core:mem"
import "core:thread"
import "core:time"
import "core:fmt"
import "base:runtime"
import "core:math"
import "core:strings"

AUDIO_BUFFER_TYPE     :: f32
OUTPUT_NUM_CHANNELS   :: 2
OUTPUT_SAMPLE_RATE    :: 48000
PREFERRED_BUFFER_SIZE :: 512
OUTPUT_BUFFER_SIZE    :: OUTPUT_SAMPLE_RATE * size_of(f32) * OUTPUT_NUM_CHANNELS

App :: struct {
	time:         f32,
	device:       ma.device,
	buffer_size:  int,
	ring_buffer:  Buffer,
	mutex:        sync.Mutex,
	hz:           f32,
	key_pressed:  string,
}

app: App

main :: proc() {
	rl.InitWindow(800, 600, "Sine Wave Generator")
	// rl.SetTargetFPS(60)  

	fmt.println("Initializing audio buffer")
  result: ma.result

  // set audio device settings
  device_config := ma.device_config_init(ma.device_type.playback)
  device_config.playback.format    = ma.format.f32
  device_config.playback.channels  = OUTPUT_NUM_CHANNELS
  device_config.sampleRate         = OUTPUT_SAMPLE_RATE
  device_config.dataCallback       = ma.device_data_proc(audio_callback)
  device_config.periodSizeInFrames = PREFERRED_BUFFER_SIZE

	fmt.println("Configuring MiniAudio Device")
  if (ma.device_init(nil, &device_config, &app.device) != .SUCCESS) {
      fmt.println("Failed to open playback device.")
      return
  }

  // get audio device info just so we can get thre real device buffer size
  info: ma.device_info
  ma.device_get_info(&app.device, ma.device_type.playback, &info)
  app.buffer_size = int(app.device.playback.internalPeriodSizeInFrames)

	// initialize ring buffer to be 8 times the size of the audio device buffer...
	buffer_init(&app.ring_buffer, app.buffer_size * OUTPUT_NUM_CHANNELS * 8)

	// starts the audio device and the audio callback thread
	fmt.println("Starting MiniAudio Device:", runtime.cstring_to_string(cstring(&info.name[0])))
  if (ma.device_start(&app.device) != .SUCCESS) {
      fmt.println("Failed to start playback device.")
      ma.device_uninit(&app.device)
      return
  }

  // main loop
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		defer rl.EndDrawing()
		rl.ClearBackground(rl.BLACK)

		rl.DrawText("Press Key:", 200, 150, 60, rl.WHITE)
		rl.DrawText(rl.TextFormat("Freq: %4v", app.hz), 200, 210, 60, rl.WHITE)

	  // KEYS
    //     | s | d |    | g | h | j |
    //   | z | x | c | v | b | n | m |

    notes         := []f32 { 60,61,62,63,64,65,66,67,68,69,70,71 }
    keyboard_keys := []rl.KeyboardKey {.Z,.S,.X,.D,.C,.V,.G,.B,.H,.N,.J,.M}
    key_names     := []cstring { "Z","S","X","D","C","V","G","B","H","N","J","M" }
    offsets       := [][2]i32{ {200,350}, {230,290}, {260,350}, {290,290}, {320,350}, {380,350}, {410,290}, {440,350}, {470,290}, {500,350}, {530,290}, {560,350} }

    get_key_color :: proc(k:string) -> rl.Color {
    	if app.key_pressed == k do return rl.WHITE
    	return rl.GRAY
    }

		for key, ki in keyboard_keys {
			key_name := string(key_names[ki])
  		// draw keyboard
			rl.DrawText(key_names[ki], offsets[ki].x, offsets[ki].y, 60, get_key_color(key_name))
			
			// get note frequency from key presses
			if rl.IsKeyPressed(key) {
				app.hz = calc_freq_from_midi_note(notes[ki])
				app.key_pressed = key_name
			}
		}

		// only write new samples if there is enough "free" space in the ring buffer
		space_in_buffer := len(app.ring_buffer.data) - app.ring_buffer.written
		if space_in_buffer > app.buffer_size * OUTPUT_NUM_CHANNELS {
			sync.lock(&app.mutex)
			for i in 0..<app.buffer_size {

				// generate sample from note frequency
				sample := math.sin(f32(math.PI) * 2 * app.hz * app.time)
				
				// write two samples, one for each channel
				buffer_write_sample(&app.ring_buffer, sample, true)
				buffer_write_sample(&app.ring_buffer, sample, true)

				// advance the time
				app.time += 1/f32(OUTPUT_SAMPLE_RATE)
			}
			sync.unlock(&app.mutex)
		}
  }

  audio_quit()
}

calc_freq_from_midi_note :: proc(note:f32) -> f32 {
	note := note - 9
	hz := 27.5 * math.pow(2, (note / 12))
	fmt.println("New frequency:", hz)
	return hz
}

audio_quit :: proc() {
	ma.device_stop(&app.device)	
	ma.device_uninit(&app.device)
}

audio_callback :: proc(device: ^ma.device, output, input: rawptr, frame_count: u32) {
	buffer_size := int(frame_count*OUTPUT_NUM_CHANNELS)

	// get device buffer
	device_buffer := mem.slice_ptr((^f32)(output), buffer_size)

	// if there are enough samples written to the ring buffer to fill the device buffer, read them
	if app.ring_buffer.written >= buffer_size {
		sync.lock(&app.mutex)
		buffer_read(device_buffer, &app.ring_buffer, true)		
		sync.unlock(&app.mutex)
	}
}

// simple ring buffer
Buffer :: struct {
	data:       []f32,
	written:    int,
	write_pos:  int,
	read_pos:   int,
}

buffer_init :: proc(b:^Buffer, size:int) {
	b.data = make([]f32, size)
}

// this writes a single sample of data to the buffer, overwriting what was previously there
buffer_write_sample :: proc(b:^Buffer, sample:f32, advance_pos:bool) {
	buffer_write_slice(b, {sample}, advance_pos)
}

// this writes a slice data to the buffer, overwriting what was previously there
buffer_write_slice :: proc(b:^Buffer, data:[]f32, advance_pos:bool) {
	assert(len(b.data) - b.written > len(data))
	write_pos := b.write_pos
	for di in 0..<len(data) {
		write_pos += 1
		if write_pos >= len(b.data) do write_pos = 0
		b.data[write_pos] = data[di]
	}

	if advance_pos {
		b.written += len(data)
		b.write_pos = write_pos
	}
}

// this reads data from the buffer and copies it into the dst slice
buffer_read :: proc(dst:[]f32, b:^Buffer, advance_index:bool=true) {
	read_pos := b.read_pos
	for di in 0..<len(dst) {
		read_pos += 1
		if read_pos >= len(b.data) do read_pos = 0
		dst[di] = b.data[read_pos]
		b.data[read_pos] = 0
	}

	if advance_index {
		b.written -= len(dst)
		b.read_pos = read_pos
	}
}