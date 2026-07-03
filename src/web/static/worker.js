self.addEventListener("message", async (e) => {
	const imports = {
		env: {
			memory: e.data.buffer,
		}
	}
	const app = await WebAssembly.instantiate(e.data.wasm_module, imports);
	app.exports.worker(e.data.app_memory_offset);
});
