self.addEventListener("message", async (e) => {
	function wasmLog(ptr, len) {
		const bytes = new Uint8Array(e.data.buffer.buffer, ptr, len);
		const copy = bytes.slice();
		const message = new TextDecoder("utf-8").decode(copy);
		console.log("wasm: ", message);
	}

	const file_paths = ["assets.hra"];
	function readFile(file_id, offset, len, dest) {
		try {
			const xhr = new XMLHttpRequest();
			xhr.open("GET", self.location.origin + "/" + file_paths[file_id], false);
			xhr.setRequestHeader("Range", `bytes=${offset}-${offset + BigInt(len - 1)}`)
			xhr.responseType = "arraybuffer";
			xhr.send();

			if (xhr.status !== 206) return false;

			const bytes = new Uint8Array(xhr.response);
			new Uint8Array(e.data.buffer.buffer).set(bytes, dest);
			return true;
		} catch (err) {
			console.log("worker fetch failed", err);
			return false;
		}
	}
	const imports = {
		env: {
			memory: e.data.buffer,
			jsConsoleLog: wasmLog,
			jsReadFile: readFile,
		}
	};

	const app = await WebAssembly.instantiate(e.data.wasm_module, imports);
	app.exports.worker(e.data.app_memory_offset, e.data.stack_offset);
});
