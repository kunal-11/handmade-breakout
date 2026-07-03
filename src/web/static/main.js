const shared_buffer = new WebAssembly.Memory({ initial: 1024, maximum: 1024, shared: true });
const dv = new DataView(shared_buffer.buffer);

const KB = 1 << 10;
const MB = 1 << 20;
const imports = {
	env: {
		memory: shared_buffer,
	}
};

const app = await WebAssembly.instantiateStreaming(fetch("app.wasm"), imports);
console.log(app.instance.exports);

// allocate memory
const permanent_len = 1 * MB;
const transient_len = 10 * MB;
const app_memory = app.instance.exports.allocMemory(permanent_len, transient_len);

const worker_count = 7;
for (let i = 0; i < worker_count; i++) {
	const worker = new Worker("worker.js");
	worker.postMessage({
		wasm_module: app.module,
		buffer: shared_buffer,
		app_memory_offset: app_memory,
	});
}

// input handeling
const target_frame_time_ms = 1000 / 60;
const app_input = app.instance.exports.allocInput(target_frame_time_ms / 1000);

const key_count = 4;
const key_indices = {
	"KeyW": 0,
	"KeyS": 1,
	"KeyA": 2,
	"KeyD": 3,
};

let inputs = [];
let paused = false;

window.addEventListener("keydown", (e) => {
	if (e.repeat) return;
	if (e.code == "KeyP") {
		paused = !paused;
	} else {
		const index = key_indices[e.code];
		if (index === undefined) return;
		const state = inputs[index] ??= { down: false, half_transitions: 0 };
		state.down = true;
		state.half_transitions += 1;
	}
});

window.addEventListener("keyup", (e) => {
	if (e.repeat) return;
	const index = key_indices[e.code];
	if (index === undefined) return;
	const state = inputs[index] ??= { down: false, half_transitions: 0 };
	state.down = false;
	state.half_transitions += 1;
});

const keyboard_controller_offset = 0;
const button_state_size = 8;

function copyInputs() {
	for (let i = 0; i < key_count; i++) {
		const state = inputs[i] ??= { down: false, half_transitions: 0 };
		dv.setUint32(app_input + keyboard_controller_offset + i * button_state_size, state.half_transitions, true);
		dv.setUint32(app_input + keyboard_controller_offset + i * button_state_size + 4, state.down ? 1 : 0, true);
		state.half_transitions = 0;
	}
}

// screen handeling
const canvas = document.getElementById("screen");
const app_screen = app.instance.exports.allocScreen(canvas.width, canvas.height);

const screen_buffer_offset = 0;
const frame_buffer = new Uint8ClampedArray(shared_buffer.buffer, dv.getUint32(app_screen, true) + screen_buffer_offset, canvas.height * canvas.width * 4);

const screen_ctx = canvas.getContext('2d');
const image_data = screen_ctx.createImageData(canvas.width, canvas.height);

function frame() {
	copyInputs();
	if (!paused) {
		app.instance.exports.updateAndRender(app_screen, app_memory, app_input);
		image_data.data.set(frame_buffer);
		screen_ctx.putImageData(image_data, 0, 0);
	}
	requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

