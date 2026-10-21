fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "get_state",
            "add_server",
            "remove_server",
            "set_server_notify",
            "set_settings",
            "open_server",
        ])),
    )
    .expect("tauri build");
}
