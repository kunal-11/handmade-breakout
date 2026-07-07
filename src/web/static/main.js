function wasmLog(ptr, len) {
	const bytes = new Uint8Array(shared_buffer.buffer, ptr, len);
	const copy = bytes.slice();
	const message = new TextDecoder("utf-8").decode(copy);
	console.log("wasm: ", message);
}

const file_paths = ["assets.hra"];

function readFile(file_id, offset, len, dest) {
	try {
		const xhr = new XMLHttpRequest();
		xhr.open("GET", file_paths[file_id], false);
		xhr.setRequestHeader("Range", `bytes=${offset}-${offset + BigInt(len - 1)}`)
		xhr.overrideMimeType("text/plain; charset=x-user-defined");
		xhr.send();

		if (xhr.status !== 206) return false;

		const bytes = new Uint8Array(xhr.responseText.length);
		for (let i = 0; i < xhr.responseText.length; i++) {
			bytes[i] = xhr.responseText.charCodeAt(i) & 0xff;
		}
		new Uint8Array(shared_buffer.buffer).set(bytes, dest);
		return true;
	} catch (err) {
		console.log("main fetch failed", err);
		return false;
	}
}

// init wasm
const shared_buffer = new WebAssembly.Memory({ initial: 4096, maximum: 4096, shared: true });
const dv = new DataView(shared_buffer.buffer);

const imports = {
	env: {
		memory: shared_buffer,
		jsConsoleLog: wasmLog,
		jsReadFile: readFile,
	}
};
const app = await WebAssembly.instantiateStreaming(fetch("app.wasm"), imports);

// allocate memory
const KB = 1 << 10;
const MB = 1 << 20;

const permanent_len = 1 * MB;
const transient_len = 50 * MB;
const app_memory = app.instance.exports.allocMemory(permanent_len, transient_len);

// setup workers
const worker = await fetch("worker.js");
const worker_bytes = await worker.blob();
const worker_url = URL.createObjectURL(worker_bytes);

const worker_count = 7;
const stack_size = 1 * MB;
const worker_stack_base = app.instance.exports.allocBytes((worker_count + 1) * stack_size);

for (let i = 0; i < worker_count; i++) {
	const worker = new Worker(worker_url, { type: "module" });
	worker.postMessage({
		wasm_module: app.module,
		buffer: shared_buffer,
		app_memory_offset: app_memory,
		// assumsing stack grows towards 0, this is end of stack block
		stack_offset: worker_stack_base + (i + 1) * stack_size,
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
canvas.width = 1600;
canvas.height = 900;
const app_screen = app.instance.exports.allocScreen(canvas.width, canvas.height);

const screen_buffer_offset = 0;
const frame_buffer = new Uint8ClampedArray(shared_buffer.buffer, dv.getUint32(app_screen, true) + screen_buffer_offset, canvas.height * canvas.width * 4);

const screen_ctx = canvas.getContext('2d');
const image_data = screen_ctx.createImageData(canvas.width, canvas.height);

// render loop
let last_render = 0;
const frame_sync_epsilon = 2;
function frame(now) {
	if (now - last_render + frame_sync_epsilon >= target_frame_time_ms) {
		copyInputs();
		if (!paused) {
			app.instance.exports.updateAndRender(app_screen, app_memory, app_input);
			image_data.data.set(frame_buffer);
			screen_ctx.putImageData(image_data, 0, 0);
		}
		last_render = now;
	}
	requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

