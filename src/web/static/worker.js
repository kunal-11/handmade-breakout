function wasmLog(ptr, len) {
	const bytes = new Uint8Array(e.data.buffer.buffer, ptr, len);
	const copy = bytes.slice();
	const message = new TextDecoder("utf-8").decode(copy);
	console.log("wasm: ", message);
}

self.addEventListener("message", async (e) => {
	const imports = {
		env: {
			memory: e.data.buffer,
			jsConsoleLog: wasmLog,
		}
	};
	const app = await WebAssembly.instantiate(e.data.wasm_module, imports);
	app.exports.worker(e.data.app_memory_offset, e.data.stack_offset);
});
